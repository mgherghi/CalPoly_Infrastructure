#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Config / paths
# -----------------------------
NB_DB=/var/lib/ovn/ovnnb_db.db
SB_DB=/var/lib/ovn/ovnsb_db.db
NB_SCHEMA=/usr/share/ovn/ovn-nb.ovsschema
SB_SCHEMA=/usr/share/ovn/ovn-sb.ovsschema
RUN_DIR=/var/run/ovn
LOG_DIR=/var/log/ovn

# Expect these from the environment (compose):
#   NODE_IP        (e.g., 4.0.0.7/.8/.9)
#   IS_BOOTSTRAP   ("true" or "false")
#   BOOTSTRAP_IP   (bootstrap node IP, e.g., 4.0.0.7)
#   OVN_NB_PORT    (default 6641)
#   OVN_SB_PORT    (default 6642)
#   NB_RAFT_PORT   (default 6643)
#   SB_RAFT_PORT   (default 6644)

# -----------------------------
# Hardening / prereqs
# -----------------------------
# Clean stale runtime files and ensure directories exist with safe perms.
rm -f "${RUN_DIR}"/*.pid "${RUN_DIR}"/*.sock 2>/dev/null || true
mkdir -p "${RUN_DIR}" /var/lib/ovn /etc/ovn "${LOG_DIR}"
umask 027

# If compose mounted ./ovn-script -> overwrite default config
if [[ -f /tmp/ovn-script ]]; then
  install -m 0644 /tmp/ovn-script /etc/default/ovn-central
fi

# Basic sanity
: "${NODE_IP:?NODE_IP is required}"
: "${IS_BOOTSTRAP:?IS_BOOTSTRAP is required}"
: "${BOOTSTRAP_IP:?BOOTSTRAP_IP is required}"
: "${OVN_NB_PORT:=6641}"
: "${OVN_SB_PORT:=6642}"
: "${NB_RAFT_PORT:=6643}"
: "${SB_RAFT_PORT:=6644}"

echo "[central] NODE_IP=${NODE_IP} IS_BOOTSTRAP=${IS_BOOTSTRAP} BOOTSTRAP_IP=${BOOTSTRAP_IP}"
echo "[central] NB=${OVN_NB_PORT} SB=${OVN_SB_PORT} NB_RAFT=${NB_RAFT_PORT} SB_RAFT=${SB_RAFT_PORT}"

# -----------------------------
# RAFT init (create / join)
# -----------------------------
if [[ "${IS_BOOTSTRAP,,}" == "true" ]]; then
  if [[ ! -s "${NB_DB}" ]]; then
    echo "[central] Initializing NB cluster on tcp:${NODE_IP}:${NB_RAFT_PORT}"
    ovsdb-tool create-cluster "${NB_DB}" "${NB_SCHEMA}" "tcp:${NODE_IP}:${NB_RAFT_PORT}"
  fi
  if [[ ! -s "${SB_DB}" ]]; then
    echo "[central] Initializing SB cluster on tcp:${NODE_IP}:${SB_RAFT_PORT}"
    ovsdb-tool create-cluster "${SB_DB}" "${SB_SCHEMA}" "tcp:${NODE_IP}:${SB_RAFT_PORT}"
  fi
else
  if [[ ! -s "${NB_DB}" ]]; then
    echo "[central] Joining NB cluster via tcp:${BOOTSTRAP_IP}:${NB_RAFT_PORT} (local tcp:${NODE_IP}:${NB_RAFT_PORT})"
    ovsdb-tool join-cluster "${NB_DB}" "${NB_SCHEMA}" "tcp:${NODE_IP}:${NB_RAFT_PORT}" "tcp:${BOOTSTRAP_IP}:${NB_RAFT_PORT}"
  fi
  if [[ ! -s "${SB_DB}" ]]; then
    echo "[central] Joining SB cluster via tcp:${BOOTSTRAP_IP}:${SB_RAFT_PORT} (local tcp:${NODE_IP}:${SB_RAFT_PORT})"
    ovsdb-tool join-cluster "${SB_DB}" "${SB_SCHEMA}" "tcp:${NODE_IP}:${SB_RAFT_PORT}" "tcp:${BOOTSTRAP_IP}:${SB_RAFT_PORT}"
  fi
fi

# -----------------------------
# Start ovsdb-server for NB/SB
# -----------------------------
echo "[central] Starting ovsdb-server (NB:tcp:${OVN_NB_PORT} SB:tcp:${OVN_SB_PORT})"
ovsdb-server \
  --unixctl="${RUN_DIR}/ovsdb-server.ctl" \
  --remote=punix:${RUN_DIR}/ovnnb_db.sock \
  --remote=punix:${RUN_DIR}/ovnsb_db.sock \
  --remote=ptcp:${OVN_NB_PORT}:${NODE_IP} \
  --remote=ptcp:${OVN_SB_PORT}:${NODE_IP} \
  --pidfile="${RUN_DIR}/ovsdb-server.pid" \
  --log-file="${LOG_DIR}/ovsdb-server.log" \
  --detach \
  "${NB_DB}" "${SB_DB}"

# Wait for unix sockets before starting northd
for s in "${RUN_DIR}/ovnnb_db.sock" "${RUN_DIR}/ovnsb_db.sock"; do
  for i in {1..30}; do
    [[ -S "$s" ]] && break
    echo "[central] Waiting for $s ($i/30) ..."
    sleep 1
  done
  [[ -S "$s" ]] || { echo "[central] ERROR: $s not ready"; exit 1; }
done

# -----------------------------
# Start ovn-northd
# -----------------------------
echo "[central] Starting ovn-northd"
ovn-northd \
  --ovnnb-db=unix:${RUN_DIR}/ovnnb_db.sock \
  --ovnsb-db=unix:${RUN_DIR}/ovnsb_db.sock \
  --pidfile="${RUN_DIR}/ovn-northd.pid" \
  --log-file="${LOG_DIR}/ovn-northd.log" \
  --detach

# -----------------------------
# Keep container alive / stream logs
# -----------------------------
touch "${LOG_DIR}/ovn-northd.log" "${LOG_DIR}/ovsdb-server.log"
tail -F "${LOG_DIR}/ovn-northd.log" "${LOG_DIR}/ovsdb-server.log"
