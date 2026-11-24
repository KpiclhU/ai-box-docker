#!/usr/bin/env bash
# create-vm.sh — create the Docker VM on a Proxmox host.
#
# Run this on the Proxmox host itself, as root — not inside a VM:
#
#   sudo ./proxmox/create-vm.sh --ssh-key /root/.ssh/id_ed25519.pub
#   sudo ./proxmox/create-vm.sh --dry-run --ssh-key /root/.ssh/id_ed25519.pub
#
# It downloads the Ubuntu cloud image once, creates an empty VM from it, points
# cloud-init at proxmox/cloud-init/user-data (which installs Docker), sets the
# static address, and starts it. The stack itself is installed from inside the
# VM — see compose/install.sh.
set -euo pipefail

VMID=150
NAME=docker-vm
CIUSER=ai-admin
CORES=4
MEMORY=8192
DISK=40
STORAGE=local-lvm
SNIPPET_STORAGE=local
BRIDGE=vmbr0
IP=192.168.150.50/24
GW=192.168.150.1
DNS=192.168.150.1
IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
SSH_KEY=""
DRY_RUN=0

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SNIPPET_DIR=/var/lib/vz/snippets

die() { echo "error: $*" >&2; exit 1; }
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --vmid)     VMID="${2:-}"; shift ;;
    --name)     NAME="${2:-}"; shift ;;
    --user)     CIUSER="${2:-}"; shift ;;
    --cores)    CORES="${2:-}"; shift ;;
    --memory)   MEMORY="${2:-}"; shift ;;
    --disk)     DISK="${2:-}"; shift ;;
    --storage)  STORAGE="${2:-}"; shift ;;
    --snippet-storage) SNIPPET_STORAGE="${2:-}"; shift ;;
    --bridge)   BRIDGE="${2:-}"; shift ;;
    --ip)       IP="${2:-}"; shift ;;
    --gateway)  GW="${2:-}"; shift ;;
    --dns)      DNS="${2:-}"; shift ;;
    --image)    IMAGE_URL="${2:-}"; shift ;;
    --ssh-key)  SSH_KEY="${2:-}"; shift ;;
    --dry-run)  DRY_RUN=1 ;;
    -h|--help)  usage 0 ;;
    *)          die "unknown argument: $1 (try --help)" ;;
  esac
  if [ $# -gt 0 ]; then shift; fi
done

[ "$(id -u)" -eq 0 ] || die "needs root on the Proxmox host: sudo $0 $*"
command -v qm >/dev/null 2>&1 || die "qm not found — this script runs on the Proxmox host, not in the VM"
printf '%s' "$IP" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$' || die "--ip wants 192.168.150.50/24"
printf '%s' "$GW" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || die "--gateway wants an IPv4 address"

if qm status "$VMID" >/dev/null 2>&1; then
  die "VM $VMID already exists — pick another with --vmid"
fi

# Cloud-init snippets need a storage that has the 'snippets' content type.
if [ ! -d "$SNIPPET_DIR" ]; then
  die "no $SNIPPET_DIR — enable 'snippets' on the '$SNIPPET_STORAGE' storage first:
       Datacenter -> Storage -> $SNIPPET_STORAGE -> Edit -> Content -> Snippets
     (or: pvesm set $SNIPPET_STORAGE --content <existing list>,snippets)"
fi

# SSH keys, or a password that is printed once.
PASSWORD=""
if [ -n "$SSH_KEY" ]; then
  [ -f "$SSH_KEY" ] || die "no such key file: $SSH_KEY"
else
  PASSWORD="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-18)"
  echo "no --ssh-key given; inventing a password for $CIUSER (printed at the end)"
fi

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  would run: %s\n' "$*"
    return 0
  fi
  "$@"
}

# ---- image ------------------------------------------------------------------
IMG="/var/lib/vz/template/iso/$(basename "$IMAGE_URL")"
mkdir -p "$(dirname "$IMG")"
if [ -s "$IMG" ]; then
  echo "using cached $IMG"
else
  say "Downloading $(basename "$IMAGE_URL")"
  run curl -fL --retry 3 -o "$IMG.part" "$IMAGE_URL"
  [ "$DRY_RUN" -eq 1 ] || mv "$IMG.part" "$IMG"
fi

# ---- cloud-init payload -----------------------------------------------------
SNIPPET="$SNIPPET_DIR/$NAME-user-data.yaml"
say "Installing the cloud-init payload"
run install -m 0644 "$REPO/proxmox/cloud-init/user-data" "$SNIPPET"

# ---- the VM -----------------------------------------------------------------
say "Creating VM $VMID ($NAME)"
# i440fx + SeaBIOS is the default and boots the Ubuntu cloud image; `--vga
# serial0` gives a working `qm terminal` without a graphical console.
run qm create "$VMID" \
  --name "$NAME" \
  --ostype l26 \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --balloon 0 \
  --scsihw virtio-scsi-single \
  --net0 "virtio,bridge=$BRIDGE" \
  --agent enabled=1 \
  --serial0 socket \
  --vga serial0 \
  --onboot 1

say "Importing the disk into $STORAGE"
run qm importdisk "$VMID" "$IMG" "$STORAGE"
run qm set "$VMID" --scsi0 "$STORAGE:vm-$VMID-disk-0" --boot order=scsi0
run qm resize "$VMID" scsi0 "${DISK}G"

say "Wiring cloud-init"
run qm set "$VMID" --ide2 "$STORAGE:cloudinit"
run qm set "$VMID" --ciuser "$CIUSER"
if [ -n "$SSH_KEY" ]; then
  run qm set "$VMID" --sshkeys "$SSH_KEY"
else
  run qm set "$VMID" --cipassword "$PASSWORD"
fi
run qm set "$VMID" --ipconfig0 "ip=$IP,gw=$GW" --nameserver "$DNS"
run qm set "$VMID" --cicustom "user=$SNIPPET_STORAGE:snippets/$(basename "$SNIPPET")"
run qm cloudinit update "$VMID"

say "Starting"
run qm start "$VMID"

cat <<EOF

VM $VMID created. First boot installs Docker; give it two or three minutes, then:

  ssh $CIUSER@${IP%%/*}
  git clone <this repo> ~/ai-docker && cd ~/ai-docker/compose && sudo ./install.sh

The stack's containers then take their own addresses on the LAN
(192.168.150.51-53 by default) — the VM keeps ${IP%%/*} for itself.
EOF

if [ -n "$PASSWORD" ]; then
  cat <<EOF

Password for $CIUSER (shown once):
  $PASSWORD
EOF
fi
