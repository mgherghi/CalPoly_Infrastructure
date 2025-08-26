#!/usr/bin/env bash
set -euo pipefail

# Require host to have kernel module loaded:
#   sudo modprobe openvswitch

CONFDB=/etc/openvswitch/conf.db
SCHEMA=/usr/share/openvswitch/vswitch.ovsschema
OVS_RUN=/var/run/openvswitch
OVS_SOCK="${OVS_RUN}/db.sock"

mkdir -p "$OVS_RUN" /var/lib/openvswitch /etc/openvswitch /var/log/openvswitch /var/log/ovn

# If ENCAP_IP = auto, derive from host's ovs-mgmt (host net namespace due to network_mode: host)
if [[ "${ENCAP_IP}" == "auto" ]]; then
  if ip -4 addr show dev ovs-mgmt &>/dev/null; then
    ENCAP_IP=$(ip -4 addr show dev ovs-mgmt | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)
  else
    ENCAP_IP=$(ip -4 route get 4.0.0.1 | awk '/src/{for(i=1;i<=NF;i++){if($i=="src"){print $(i+1);exit}}}')
  fi
fi
echo "[host] ENCAP_TYPE=${ENCAP_TYPE} ENCAP_IP=${ENCAP_IP}"
echo "[host] SB remotes: ${OVN_SB_REMOTES}"

# Initialize OVS local DB if missing
if [[ ! -s "$CONFDB" ]]; then
  echo "[host] Initializing OVS conf.db"
  ovsdb-tool create "$CONFDB" "$SCHEMA"
fi

# Start ovsdb-server (in-container) and listen on unix socket
echo "[host] Starting ovsdb-server"
ovsdb-server \
  --remote=punix:${OVS_SOCK} \
  --remote=ptcp:6640:127.0.0.1 \
  --pidfile="${OVS_RUN}/ovsdb-server.pid" \
  --log-file=/var/log/openvswitch/ovsdb-server.log \
  --detach

# Initialize schema
ovs-vsctl --db="unix:${OVS_SOCK}" --no-wait init

# Start ovs-vswitchd (kernel datapath must exist on host)
echo "[host] Starting ovs-vswitchd"
ovs-vswitchd \
  --pidfile="${OVS_RUN}/ovs-vswitchd.pid" \
  --log-file=/var/log/openvswitch/ovs-vswitchd.log \
  --detach

# Configure external-ids for OVN controller
ovs-vsctl --db="unix:${OVS_SOCK}" set open_vswitch . \
  external_ids:ovn-remote="${OVN_SB_REMOTES}" \
  external_ids:ovn-encap-type="${ENCAP_TYPE}" \
  external_ids:ovn-encap-ip="${ENCAP_IP}"

# Stable system-id
if ! ovs-vsctl --db="unix:${OVS_SOCK}" get open_vswitch . external_ids:system-id >/dev/null 2>&1; then
  ovs-vsctl --db="unix:${OVS_SOCK}" set open_vswitch . external_ids:system-id="$(uuidgen)"
fi

# Start ovn-controller
echo "[host] Starting ovn-controller"
ovn-controller \
  --pidfile=/var/run/ovn/ovn-controller.pid \
  --log-file=/var/log/ovn/ovn-controller.log \
  --detach

# Health tail
touch /var/log/ovn/ovn-controller.log /var/log/openvswitch/ovs-vswitchd.log /var/log/openvswitch/ovsdb-server.log
tail -F /var/log/ovn/ovn-controller.log /var/log/openvswitch/ovs-vswitchd.log /var/log/openvswitch/ovsdb-server.log
