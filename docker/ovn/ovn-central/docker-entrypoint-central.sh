#!/usr/bin/env bash
set -euo pipefail

NB_DB=/var/lib/ovn/ovnnb_db.db
SB_DB=/var/lib/ovn/ovnsb_db.db
NB_SCHEMA=/usr/share/ovn/ovn-nb.ovsschema
SB_SCHEMA=/usr/share/ovn/ovn-sb.ovsschema
RUN_DIR=/var/run/ovn

rm -f "${RUN_DIR}"/*.pid "${RUN_DIR}"/*.sock 2>/dev/null || true
mkdir -p "${RUN_DIR}" /var/lib/ovn /etc/ovn /var/log/ovn
umask 027

mkdir -p "$RUN_DIR" /var/lib/ovn /etc/ovn /var/log/ovn

# If compose mounted ./ovn-script → overwrite default config
if [[ -f /tmp/ovn-script ]]; then
  install -m 0644 /tmp/ovn-script /etc/default/ovn-central
fi

echo "[central] NODE_IP=$NODE_IP IS_BOOTSTRAP=$IS_BOOTSTRAP BOOTSTRAP_IP=$BOOTSTRAP_IP"
echo "[central] NB=$OVN_NB_PORT SB=$OVN_SB_PORT NB_RAFT=$NB_RAFT_PORT SB_RAFT=$SB_RAFT_PORT"

# Initialize RAFT (note tcp: prefixes)
if [[ "${IS_BOOTSTRAP,,}" == "true" ]]; then
  [[ -s "$NB_DB" ]] || ovsdb-tool create-cluster "$NB_DB" "$NB_SCHEMA" "tcp:${NODE_IP}:${NB_RAFT_PORT}"
  [[ -s "$SB_DB" ]] || ovsdb-tool create-cluster "$SB_DB" "$SB_SCHEMA" "tcp:${NODE_IP}:${SB_RAFT_PORT}"
else
  [[ -s "$NB_DB" ]] || ovsdb-tool join-cluster "$NB_DB" "$NB_SCHEMA" "tcp:${NODE_IP}:${NB_RAFT_PORT}" "tcp:${BOOTSTRAP_IP}:${NB_RAFT_PORT}"
  [[ -s "$SB_DB" ]] || ovsdb-tool join-cluster "$SB_DB" "$SB_SCHEMA" "tcp:${NODE_IP}:${SB_RAFT_PORT}" "tcp:${BOOTSTRAP_IP}:${SB_RAFT_PORT}"
fi

# Start ovsdb-server (listens on host IP due to network_mode: host)
# AFTER (correct — OVN NB/SB DB files passed)
ovsdb-server \
  --unixctl="$RUN_DIR/ovsdb-server.ctl" \
  --remote=punix:$RUN_DIR/ovnnb_db.sock \
  --remote=punix:$RUN_DIR/ovnsb_db.sock \
  --remote=ptcp:${OVN_NB_PORT}:${NODE_IP} \
  --remote=ptcp:${OVN_SB_PORT}:${NODE_IP} \
  --pidfile=/var/run/ovn/ovsdb-server.pid \
  --log-file=/var/log/ovn/ovsdb-server.log \
  --detach \
  "$NB_DB" "$SB_DB"

sleep 1

ovn-northd \
  --ovnnb-db=unix:$RUN_DIR/ovnnb_db.sock \
  --ovnsb-db=unix:$RUN_DIR/ovnsb_db.sock \
  --detach \
  --pidfile=/var/run/ovn/ovn-northd.pid \
  --log-file=/var/log/ovn/ovn-northd.log

touch /var/log/ovn/ovn-northd.log /var/log/ovn/ovsdb-server.log
tail -F /var/log/ovn/ovn-northd.log /var/log/ovn/ovsdb-server.log
