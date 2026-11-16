# Deployment Guide

A step-by-step guide to deploying the Indonesia car route optimization backend
(OSRM + VROOM) on a Proxmox host as a Docker-based LXC. This is the exact
process used for the reference deployment, including every pitfall hit and its
fix.

> **TL;DR:** provision an LXC → fix AppArmor → install Docker → clone this repo
> → transfer the pre-built OSRM data → pin the OSRM image → `docker compose up`.
> The automated version is [`deploy-to-proxmox.sh`](deploy-to-proxmox.sh).

---

## 1. What you're deploying

```
Proxmox host (PVE)
└── LXC (Ubuntu 24.04, 4 vCPU / 4 GB RAM, 8 GB rootfs)
    └── Docker
        ├── osrm-car      (OSRM, port 5000)  — serves pre-built java-latest.osrm
        └── vroom-optimizer (VROOM, port 3080) — vroom-express, router → osrm-car:5000
    └── route-frontend (static server, port 8080) — the web UI
```

| Service | Port |
|---------|------|
| Frontend (web UI) | 8080 |
| VROOM (optimization) | 3080 |
| OSRM (routing) | 5000 |

**Reference deployment:** LXC VMID 201 (`route-opt`), IP `192.168.6.242`, on
host `192.168.6.229`.

---

## 2. Requirements

| | Build (one-time) | Serve (runtime) |
|---|---|---|
| RAM | **~12 GB peak** (Java island) | 4 GB |
| vCPU | 4+ | 2+ |
| Disk | — | ~8 GB |

**Critical:** the `osrm-extract` build step needs ~12 GB peak RAM and is
**OOM-killed on a 4 GB box**. Build the OSRM data on a big-RAM machine (≥16 GB),
then transfer the 4 GB `osrm-data/` to the LXC. Do **not** build inside the LXC.

---

## 3. Build the OSRM data (on a big-RAM machine)

```bash
git clone https://github.com/ReinTanto/route-optimization-deployment-java
cd route-optimization-deployment-java

# 1. Download the OSM data (Java island, ~900 MB)
curl -sL -o osm-java-latest.osm.pbf \
  https://download.geofabrik.de/asia/indonesia/java-latest.osm.pbf

# 2. Build the OSRM routing database (one-time, 20–60 min, ~12 GB peak RAM)
./preprocess-osrm.sh
# → produces osrm-data/java-latest.osrm*  (~4 GB)
```

---

## 4. Provision the LXC (on the Proxmox host)

```bash
# 1. Create the LXC from the cached Ubuntu 24.04 template.
#    NOTE: `--nameserver 8.8.8.8` FAILS on PVE 9.2 — create WITHOUT it.
pct create 201 /var/lib/vz/template/cache/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
  --name route-opt --ostype ubuntu --cores 4 --memory 4096 \
  --rootfs local-lvm:vm-201-disk-0,size=8G \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.6.242/24 \
  --unprivileged 0 --features nesting=1 --onboot 1

# 2. The rootfs LV must exist first.
lvcreate -L 8G -n vm-201-disk-0 pve

# 3. Add DNS to the config file directly.
echo "nameserver: 8.8.8.8" >> /etc/pve/lxc/201.conf

# 4. Start it.
pct start 201
```

> **Pitfall — template won't unpack** (pre-start hook exits 32): the container
> boots into an empty rootfs. Fix by formatting + populating the LV manually:
> ```bash
> mkfs.ext4 -F /dev/pve/vm-201-disk-0
> mount /dev/pve/vm-201-disk-0 /mnt/lxc201
> tar --zstd -xf <template>.tar.zst -C /tmp/t
> (cd /tmp/t && tar -cf - --exclude=./dev --exclude=./proc --exclude=./sys . | \
>   tar -xf - -C /mnt/lxc201)
> umount /mnt/lxc201
> ```

---

## 5. Fix AppArmor (critical — Docker will not run without this)

**Symptom:** every `docker run` fails with:
```
AppArmor enabled on system but the docker-default profile could not be loaded:
apparmor_parser: Unable to replace "docker-default". Access denied.
You need policy admin privileges to manage profiles.
```

The LXC lacks AppArmor policy-admin privileges, so it can't load the
`docker-default` profile Docker needs. **Fix: load an empty `docker-default`
profile on the host kernel** (the LXC shares the host kernel):

```bash
# On the Proxmox HOST (not the LXC):
printf 'profile docker-default flags=(complain) {\n}\n' > /tmp/dd.aap
/usr/sbin/apparmor_parser -W /tmp/dd.aap
rm -f /tmp/dd.aap
```

> You **cannot** `rmmod apparmor` or write
> `/sys/module/apparmor/parameters/enabled` from inside the LXC (read-only,
> module unloading unsupported). The host-side profile load is the working fix.
> **Re-run this after a host reboot** — Docker will not start otherwise.

---

## 6. Network + Docker (inside the LXC)

```bash
# Configure eth0 (the template's net config doesn't auto-apply)
ip addr add 192.168.6.242/24 dev eth0
ip link set eth0 up
ip route add default via 192.168.6.1

# Make it persistent across reboots
cat > /etc/systemd/system/eth0-config.service <<'EOF'
[Unit]
Description=Configure eth0 static IP
Before=docker.service
[Service]
Type=oneshot
ExecStart=/bin/sh -c "ip addr add 192.168.6.242/24 dev eth0; ip link set eth0 up; ip route add default via 192.168.6.1"
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable eth0-config

# Install Docker
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y docker.io docker-compose-v2 git curl
systemctl enable --now docker
```

---

## 7. Clone the repo + transfer the OSRM data

```bash
# Inside the LXC:
git clone https://github.com/ReinTanto/route-optimization-deployment-java \
  /opt/route-optimization-backend
cd /opt/route-optimization-backend

# Transfer the 4 GB osrm-data/ from the big-RAM machine:
#  1) copy to a readable temp dir (fileIndex is root-only):
sudo cp -r osrm-data/java-latest.osrm.* /tmp/osrm-copy/
sudo chmod 644 /tmp/osrm-copy/java-latest.osrm.fileIndex
#  2) scp to the Proxmox host (NOT /tmp — it's a small tmpfs, too small for 4 GB):
scp -r /tmp/osrm-copy root@<host>:/var/lib/vz/osrm-transfer/
#  3) push each file into the LXC:
for f in java-latest.osrm.*; do
  pct push 201 "/var/lib/vz/osrm-transfer/osrm-copy/$f" \
    "/opt/route-optimization-backend/osrm-data/$f"
done
```

> **Pitfalls hit:**
> - `tar` on the 4 GB data hangs/fails on the root-only `fileIndex` — use
>   `sudo cp` + `chmod 644`.
> - The host `/tmp` is a small tmpfs — scp'ing 4 GB there fails with "No space
>   left". Use `/var/lib/vz/...` instead.
> - `pct push <dir>/. <dir>/` fails ("Is a directory") — push each file.

---

## 8. Pin the OSRM image + start

**The OSRM image MUST be pinned by digest.** `osrm-backend:latest` drifts between
build and deploy, and the data is rejected as incompatible:
```
File is incompatible with this version of OSRM: /data/java-latest.osrm.cells
prepared with OSRM 26.10.0 but this is v26.11.0
```

The `docker-compose.yml` in this repo already pins it:
```yaml
osrm-car:
  image: ghcr.io/project-osrm/osrm-backend@sha256:55dbfd47d984c2cacd64e32901b4321c86b5ec761438e69aa053dc78698a786f
```
(= OSRM 26.10.0, the version that built `java-latest.osrm`.) If you rebuild the
data, update this digest to match.

```bash
docker pull ghcr.io/vroom-project/vroom-docker:v1.14.0
docker compose up -d
```

### Serve the frontend (port 8080)
```bash
cat > /etc/systemd/system/route-frontend.service <<'EOF'
[Unit]
Description=Route Optimizer frontend
After=network.target
[Service]
Type=simple
WorkingDirectory=/opt/route-optimization-backend
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0
Restart=always
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable --now route-frontend
```

---

## 9. Verify

```bash
# From any machine on the LAN:
curl "http://192.168.6.242:5000/route/v1/car/106.8456,-6.2088;106.8063,-6.2573"
# → expect code "Ok"

curl "http://192.168.6.242:3080/" -X POST -H "Content-Type: application/json" -d '{
  "vehicles":[{"id":1,"start":[106.8456,-6.2088],"end":[106.8456,-6.2088],"capacity":[100]}],
  "jobs":[{"id":1,"location":[106.8217,-6.1853],"delivery":[30],"service":120}]
}'
# → expect code 0

curl -I "http://192.168.6.242:8080/route-optimizer.html"
# → expect HTTP 200
```

---

## 10. Operations

```bash
# From the Proxmox host:
ssh root@192.168.6.229
pct exec 201 -- systemctl status docker
pct exec 201 -- docker compose -f /opt/route-optimization-backend/docker-compose.yml ps
pct exec 201 -- docker logs osrm-car
pct exec 201 -- docker logs vroom-optimizer
pct restart 201
```

### After a host reboot
1. **Re-run the host-side AppArmor fix** (§5) — Docker will not start otherwise.
2. The LXC is `onboot: 1`; `eth0-config` re-applies the IP; Docker starts the
   containers; `route-frontend` starts the web UI.

### Updating map data
1. On the big-RAM machine: re-download the PBF → re-run `./preprocess-osrm.sh`.
2. Re-transfer `osrm-data/` to the LXC (§7).
3. **Re-pin the OSRM image digest** to the version that built the new data (§8).
4. `docker compose down && docker compose up -d` in the LXC.

### Disk management (important)
The LXC rootfs is 8 GB and fills up (4 GB data + images + logs). When it hits
100% (`ENOSPC`), VROOM crashes. To free space:
```bash
# Remove the PBF (data already built) and unneeded images:
rm -f /opt/route-optimization-backend/osm-java-latest.osm.pbf
docker rmi alpine:latest hello-world:latest 2>/dev/null
docker image prune -f
docker restart vroom-optimizer
```
For a durable fix, allocate more disk/LVM on the host, or add log rotation for
VROOM's `access.log`.

---

## 11. Pitfalls (the ones we hit)

1. **`pct create --nameserver` fails on PVE 9.2** — create without the flag; add
   it to the conf file directly.
2. **Template won't unpack** (pre-start hook exits 32) — format + populate the LV
   manually.
3. **Docker blocked by AppArmor** — "Unable to replace docker-default. Access
   denied." The LXC can't load AppArmor profiles. Fix: load an empty
   `docker-default` profile on the **host** kernel (`apparmor_parser -W`).
4. **OSRM extract OOM-killed in the LXC** — needs ~12 GB peak; a 4 GB LXC dies.
   Build on a big-RAM machine and transfer the data.
5. **Transferring 4 GB fails** — `tar` hangs on the root-only `fileIndex` (use
   `sudo cp` + `chmod 644`); the host `/tmp` is a small tmpfs (use
   `/var/lib/vz/...`); `pct push <dir>/. <dir>/` fails (push each file).
6. **OSRM version mismatch** — `:latest` drifted between build and deploy; the
   data is rejected. Pin the image by digest.
7. **LXC network lost on restart** — use the `eth0-config` systemd service.
8. **Disk full (`ENOSPC`)** — VROOM crashes when the 8 GB rootfs hits 100%. Free
   space (remove PBF + unneeded images) or grow the disk.
