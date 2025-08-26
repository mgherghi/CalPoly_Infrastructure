#!/usr/bin/env bash
set -euo pipefail

# Reuse the host OVS via its unix socket
OVS_SOCK=/var/run/openvswitch/db.sock

# Determine ENCAP_IP if set to 'auto' (use host's ovs-mgmt IP)
if [[ "${ENCAP_IP}" == "auto" ]]; then
  if ip -4 addr show dev ovs-mgmt &>/dev/null; then
    ENCAP_IP=$(ip -4 addr show dev ovs-mgmt | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)
  else
    # fallback: default route source
    ENCAP_IP=$(ip -4 route get 4.0.0.1 | awk '/src/{for(i=1;i<=NF;i++){if($i=="src"){print $(i+1); exit}}}')
  fi
fi

echo "[host] Using OVN SB remotes: ${OVN_SB_REMOTES}"
echo "[host] ENCAP_TYPE=${ENCAP_TYPE} ENCAP_IP=${ENCAP_IP}"

# Configure OVS external IDs for OVN
ovs-vsctl --db="unix:${OVS_SOCK}" set open_vswitch . \
  external_ids:ovn-remote="${OVN_SB_REMOTES}" \
  external_ids:ovn-encap-type="${ENCAP_TYPE}" \
  external_ids:ovn-encap-ip="${ENCAP_IP}"

# Keep a stable system-id
if ! ovs-vsctl --db="unix:${OVS_SOCK}" get open_vswitch . external_ids:system-id >/dev/null 2>&1; then
  ovs-vsctl --db="unix:${OVS_SOCK}" set open_vswitch . external_ids:system-id="$(uuidgen)"
fi

# Start ovn-controller (talks to host OVS via unix socket)
echo "[host] Starting ovn-controller"
ovn-controller \
  --detach \
  --pidfile=/var/run/ovn/ovn-controller.pid \
  --log-file=/var/log/ovn/ovn-controller.log

touch /var/log/ovn/ovn-controller.log
tail -F /var/log/ovn/ovn-controller.log
