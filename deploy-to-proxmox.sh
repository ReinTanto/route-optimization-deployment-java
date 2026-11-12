#!/usr/bin/env bash
#
# deploy-to-proxmox.sh — provision the route-optimization backend on our Proxmox host.
#
# This script captures the exact steps (and fixes) used to stand up the service
# on 192.168.6.229 as LXC 201. Run it from the machine that has SSH access to
# the Proxmox host. It is idempotent-ish: re-running re-applies config.
#
# Prerequisites on THIS machine:
#   - SSH access to root@<PROXMOX_HOST>
#   - The pre-built osrm-data/ directory (built by preprocess-osrm.sh on a
#     big-RAM machine — do NOT build inside the LXC, it OOMs).
#
# Usage:
#   ./deploy-to-proxmox.sh
#
set -euo pipefail

# ---- Config ----------------------------------------------------------------
PROXMOX_HOST="${PROXMOX_HOST:-192.168.6.229}"
VMID="${VMID:-201}"
LXC_IP="${LXC_IP:-192.168.6.242}"
GATEWAY="${GATEWAY:-192.168.6.1}"
LXC_NAME="route-opt"
TEMPLATE="/var/lib/vz/template/cache/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
# OSRM image digest that MATCHES the pre-built java-latest.osrm data (26.10.0).
# If you rebuild the data, update this to the digest of the version that built it.
OSRM_DIGEST="sha256:55dbfd47d984c2cacd64e32901b4321c86b5ec761438e69aa053dc78698a786f"

# Local path to the pre-built OSRM data (adjust if needed).
OSRM_DATA_DIR="${OSRM_DATA_DIR:-$HOME/Documents/Projects/route-optimization-backend/osrm-data}"

ssh() { ssh -o StrictHostKeyChecking=accept-new "root@$PROXMOX_HOST" "$@"; }
pct() { ssh "pct $*"; }

echo "==> Target: $PROXMOX_HOST, LXC $VMID ($LXC_IP)"

# ---- 1. Create the LXC ------------------------------------------------------
# NOTE: `--nameserver` FAILS on PVE 9.2, so we create without it and add it after.
if ! ssh "test -f /etc/pve/lxc/$VMID.conf" 2>/dev/null; then
  echo "==> Creating LXC $VMID..."
  ssh "pct create $VMID $TEMPLATE \
    --name $LXC_NAME --ostype ubuntu --cores 4 --memory 4096 \
    --rootfs local-lvm:vm-$VMID-disk-0,size=8G \
    --net0 name=eth0,bridge=vmbr0,ip=$LXC_IP/24 \
    --unprivileged 0 --features nesting=1 --onboot 1" || true
  ssh "lvcreate -L 8G -n vm-$VMID-disk-0 pve 2>/dev/null || true"
  ssh "grep -q 'nameserver:' /etc/pve/lxc/$VMID.conf || echo 'nameserver: 8.8.8.8' >> /etc/pve/lxc/$VMID.conf"
else
  echo "==> LXC $VMID already exists, skipping create."
fi

# ---- 2. AppArmor fix (host-side) --------------------------------------------
# The LXC lacks AppArmor policy-admin; Docker cannot load docker-default.
# Load an empty profile on the host kernel (shared with the LXC).
echo "==> Applying AppArmor fix on host..."
ssh 'printf "profile docker-default flags=(complain) {\n}\n" > /tmp/dd.aap \
  && /usr/sbin/apparmor_parser -W /tmp/dd.aap && rm -f /tmp/dd.aap'

# ---- 3. Start LXC, configure network, install Docker ------------------------
echo "==> Starting LXC and configuring..."
ssh "pct start $VMID 2>/dev/null || true"
sleep 10
ssh "pct exec $VMID -- /bin/sh -c '
  set -e
  ip addr add $LXC_IP/24 dev eth0 2>/dev/null || true
  ip link set eth0 up
  ip route add default via $GATEWAY 2>/dev/null || true
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq docker.io docker-compose-v2 git curl
  cat > /etc/systemd/system/eth0-config.service <<EOF
[Unit]
Description=Configure eth0 static IP
Before=docker.service
[Service]
Type=oneshot
ExecStart=/bin/sh -c \"ip addr add $LXC_IP/24 dev eth0; ip link set eth0 up; ip route add default via $GATEWAY\"
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable eth0-config
  systemctl enable --now docker
'"

# ---- 4. Clone the repo (this repo) into the LXC ----------------------------
echo "==> Cloning repo into LXC..."
ssh "pct exec $VMID -- /bin/sh -c '
  set -e
  if [ ! -d /opt/route-optimization-backend ]; then
    git clone https://github.com/ReinTanto/route-optimization-deploy /opt/route-optimization-backend
  fi
  cd /opt/route-optimization-backend && git pull
'"

# ---- 5. Transfer the pre-built OSRM data ------------------------------------
if [ -d "$OSRM_DATA_DIR" ]; then
  echo "==> Transferring OSRM data ($OSRM_DATA_DIR)..."
  # Copy to a readable temp dir (fileIndex is root-only).
  TMP_COPY=$(mktemp -d)
  sudo cp -r "$OSRM_DATA_DIR"/java-latest.osrm.* "$TMP_COPY"/ 2>/dev/null || \
    cp -r "$OSRM_DATA_DIR"/java-latest.osrm.* "$TMP_COPY"/
  sudo chmod 644 "$TMP_COPY"/java-latest.osrm.fileIndex 2>/dev/null || true
  # scp to the host (NOT /tmp — it is a small tmpfs).
  scp -o StrictHostKeyChecking=accept-new -r "$TMP_COPY" "root@$PROXMOX_HOST:/var/lib/vz/osrm-transfer/"
  # Push each file into the LXC (the scp'd dir is named after the temp dir).
  local_dirname=$(basename "$TMP_COPY")
  for f in java-latest.osrm.*; do
    ssh "pct push $VMID /var/lib/vz/osrm-transfer/$local_dirname/$f \
      /opt/route-optimization-backend/osrm-data/$f"
  done
  rm -rf "$TMP_COPY"
  ssh "rm -rf /var/lib/vz/osrm-transfer"
else
  echo "!! $OSRM_DATA_DIR not found — skipping data transfer."
  echo "   Build it first (see README §2.5) or set OSRM_DATA_DIR."
fi

# ---- 6. Pin OSRM image, pull VROOM, start ---------------------------------
echo "==> Pinning OSRM image, pulling VROOM, starting stack..."
ssh "pct exec $VMID -- /bin/sh -c '
  set -e
  cd /opt/route-optimization-backend
  # Pin the OSRM image by digest in docker-compose.yml.
  sed -i \"s|image: ghcr.io/project-osrm/osrm-backend:latest|image: ghcr.io/project-osrm/osrm-backend@$OSRM_DIGEST|\" docker-compose.yml
  docker pull ghcr.io/vroom-project/vroom-docker:v1.14.0
  docker pull ghcr.io/project-osrm/osrm-backend@$OSRM_DIGEST
  docker compose down 2>/dev/null || true
  docker compose up -d
'"

echo ""
echo "==> Done. Verify from the LAN:"
echo "    curl \"http://$LXC_IP:5000/route/v1/car/106.8456,-6.2088;106.8063,-6.2573\""
echo "    curl \"http://$LXC_IP:3080/\" -X POST -H \"Content-Type: application/json\" \\"
echo "         -d '{\"vehicles\":[{\"id\":1,\"start\":[106.8456,-6.2088],\"end\":[106.8456,-6.2088],\"capacity\":[100]}],\"jobs\":[{\"id\":1,\"location\":[106.8217,-6.1853],\"delivery\":[30],\"service\":120}]}'"
