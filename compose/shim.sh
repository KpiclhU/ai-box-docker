#!/usr/bin/env bash
# shim.sh — let the Docker VM reach its own macvlan containers.
#
#   sudo ./shim.sh up
#   sudo ./shim.sh down
#
# A macvlan parent and its children cannot talk to each other: traffic from the
# VM to 192.168.150.51 would have to leave through eth0 and come back to the same
# interface, which the kernel drops. The usual fix is a second macvlan interface
# on the host, plus a /32 route per container through it, with a source address
# that is not the VM's own (two addresses on one subnet in one namespace is the
# conflict this avoids).
#
# Nothing in the stack needs this — the containers talk to ai-box and to each
# other, not to the VM. It is here so `curl` from the VM is a real check.
set -euo pipefail

ENV_FILE="${ENV_FILE:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.env}"
SHIM=mv-shim

die() { echo "error: $*" >&2; exit 1; }
get() { sed -n "s|^$1=||p" "$ENV_FILE" 2>/dev/null | tail -1 | tr -d '\r' || true; }

[ -f "$ENV_FILE" ] || die "no $ENV_FILE — run install.sh first"
PARENT="$(get LAN_PARENT)";   PARENT="${PARENT:-eth0}"
SHIM_IP="$(get SHIM_IP)";     SHIM_IP="${SHIM_IP:-192.168.150.54}"
IPS="$(get OPENWEBUI_IP) $(get OPEN_TERMINAL_IP) $(get OPENCLAW_IP)"

case "${1:-up}" in
  up)
    ip link show "$PARENT" >/dev/null 2>&1 || die "no interface $PARENT (set LAN_PARENT in .env)"
    if ! ip link show "$SHIM" >/dev/null 2>&1; then
      ip link add "$SHIM" link "$PARENT" type macvlan mode bridge
    fi
    ip addr replace "$SHIM_IP/32" dev "$SHIM"
    ip link set "$SHIM" up
    for ip in $IPS; do
      [ -n "$ip" ] || continue
      ip route replace "$ip/32" dev "$SHIM" src "$SHIM_IP"
    done
    echo "shim up: $SHIM_IP on $SHIM -> $IPS"
    ;;
  down)
    for ip in $IPS; do
      [ -n "$ip" ] || continue
      ip route del "$ip/32" dev "$SHIM" 2>/dev/null || true
    done
    ip link del "$SHIM" 2>/dev/null || true
    echo "shim down"
    ;;
  *)
    die "usage: $0 [up|down]"
    ;;
esac
