# Docker Engine

Docker Engine from Docker's official APT repository, with log rotation and access without `sudo`.

|                  |                                                                                                     |
| ---------------- | --------------------------------------------------------------------------------------------------- |
| **Target**       | Ubuntu Server 26.04 LTS VM                                                                          |
| **Requirements** | [init.md](init.md)                                                                                  |
| **Files**        | `/etc/apt/keyrings/docker.asc`, `/etc/apt/sources.list.d/docker.sources`, `/etc/docker/daemon.json` |

## Script

```bash
curl -fsSL https://raw.githubusercontent.com/louismullerkuhnle/homelab/main/vm/docker.sh | sudo bash
```

Log in again afterwards to use `docker` without `sudo`. Check with `… | sudo bash -s -- --check`, undo with `--uninstall`, which asks separately whether to delete images, containers and volumes.

> The script stops before changing anything if the key fingerprint differs, if Docker does not publish for this Ubuntu release yet, or if conflicting packages (`docker.io`, `containerd`, `runc`…) are installed. A hand-edited `daemon.json` is never overwritten.

## Manual

### 1. Add Docker's GPG key

```bash
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
gpg --show-keys /etc/apt/keyrings/docker.asc
```

> Expected fingerprint: `9DC858229FC7DD38854AE2D88D81803C0EBFCD88`. If it differs, stop and delete the file.

### 2. Add the repository

```bash
sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update
```

> Unquoted `<<EOF` on purpose: the Ubuntu release and the architecture are filled in automatically.

### 3. Install Docker Engine

```bash
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

### 4. Enable log rotation

```bash
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

sudo systemctl restart docker
```

> Without it, container logs grow until the disk is full. Applies to containers created afterwards: recreate the others (`docker compose up -d --force-recreate`).

### 5. Use Docker without `sudo`

```bash
sudo usermod -aG docker <user> && exit
```

> Applies at next login. The `docker` group is equivalent to root access on the VM.

### 6. Check and take a snapshot

```bash
systemctl is-active docker containerd                                                 # active x2
docker run --rm hello-world && docker rmi hello-world
```

Snapshot with the VM **powered off**: the disk is frozen with no write in progress.

```bash
sudo poweroff
```

Proxmox: VM → **Snapshots** → **Take Snapshot**, name `docker`; then start the VM.

## Undo

```bash
sudo apt purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras
sudo rm -f /etc/apt/sources.list.d/docker.sources /etc/apt/keyrings/docker.asc
sudo rm -rf /etc/docker
sudo groupdel docker
sudo rm -rf /var/lib/docker /var/lib/containerd                                       # optional: images, containers, volumes
```

> Without the last line, images, containers and volumes stay in `/var/lib/docker` and `/var/lib/containerd`.

## Notes

- **Projects**: `/srv/<project>/compose.yaml`, `/srv` being owned by the user ([init.md](init.md), step 8).
- **Data on a network share**: no database (Postgres, SQLite…) on an SMB share, which handles file locks poorly.
- **Disk space**: `docker system df`; `docker builder prune` and `docker image prune -a` to clean up.
- **IPv6 disabled**: Docker handles it since version 28.0.1; an image that requires IPv6 inside the container will fail.
- **Firewall**: Docker bypasses `ufw` for published ports. Publish on `127.0.0.1:<PORT>:<PORT>` to keep a service local.
