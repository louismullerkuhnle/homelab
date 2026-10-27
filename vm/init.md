# First boot of an Ubuntu VM

Updates, base tools, QEMU guest agent, automatic security updates, extended disk, hardened SSH, mounted network share, IPv6 disabled if requested.

|                  |                                                                                                                                                             |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Target**       | Ubuntu Server 26.04 LTS VM, Proxmox guest                                                                                                                   |
| **Requirements** | VM created with **QEMU Guest Agent** checked; Ubuntu installed with **OpenSSH server**; workstation SSH key added ([workstation/ssh.md](../workstation/ssh.md)); `curl` (missing from Ubuntu *minimized*: `sudo apt update && sudo apt install -y curl`) |
| **Files**        | `/etc/apt/apt.conf.d/20auto-upgrades`, `/etc/ssh/sshd_config.d/10-hardening.conf`, `/etc/share.cred`, `/etc/fstab`, `/etc/default/grub.d/99-disable-ipv6.cfg` |

## Script

```bash
curl -fsSL https://raw.githubusercontent.com/louismullerkuhnle/homelab/main/vm/init.sh | sudo bash
```

On first run, the script asks for the main user, timezone, SSH keys to import, network share (and its credentials), access mode and IPv6. Each answer stays on screen, passwords as `*`. Answers are saved in `/etc/homelab.conf`.

```bash
sudo reboot
curl -fsSL https://raw.githubusercontent.com/louismullerkuhnle/homelab/main/vm/init.sh | sudo bash -s -- --check
```

> Test a new SSH session before closing the current one: without a valid key, the script leaves password login enabled; with one, it disables it.

## Manual

`<user>`: the main user of the VM.

### 1. Update the system

```bash
sudo apt update && sudo apt full-upgrade -y && sudo apt autoremove -y
```

> `Could not get lock` on first boot: `unattended-upgrades` is already running, wait for it to finish.

### 2. Install base tools

```bash
sudo apt install -y curl wget git nano htop tree bash-completion ca-certificates gnupg cloud-guest-utils
```

> `cloud-guest-utils` provides `growpart` (step 6).

### 3. Install the QEMU guest agent

```bash
sudo apt install -y qemu-guest-agent
sudo systemctl start qemu-guest-agent
```

> `start`, not `enable`: the service starts by itself at every boot as soon as Proxmox provides the agent channel.
>
> If it refuses to start, the *QEMU Guest Agent* option is not checked: check it, then stop and start the VM from Proxmox. A reboot from inside the VM is not enough.

### 4. Enable automatic security updates

```bash
sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
```

### 5. Set the timezone

```bash
sudo timedatectl set-timezone Europe/Paris
```

### 6. Extend the root volume

The Ubuntu installer only gives part of the disk to LVM:

```bash
sudo vgs                                                                              # VFree > 0?
sudo lvextend -r -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
```

> Disk grown in Proxmox after installation: grow the partition and the PV first. `sudo pvs` shows the PV, `/dev/sda3` with VirtIO SCSI or `/dev/vda3` with VirtIO Block. For `/dev/sda3`: `sudo growpart /dev/sda 3 && sudo pvresize /dev/sda3`, then the `lvextend`.

### 7. Harden SSH

First check that `ssh <vm>` from the workstation logs in without a password.

```bash
sudo tee /etc/ssh/sshd_config.d/10-hardening.conf >/dev/null <<'EOF'
PermitRootLogin no
PasswordAuthentication no
EOF

sudo sshd -t && sudo systemctl restart ssh
```

> `10-` prefix: sshd keeps the first value it reads, and this file comes before `50-cloud-init.conf`, which re-enables passwords.

### 8. Give `/srv` and `/opt` to the user

```bash
sudo chown <user>:<user> /srv /opt
sudo chmod g+s /srv /opt
```

> `setgid`: everything created inside inherits the user's group, even through `sudo` or a container. No `-R`: after Docker, it would change the owner of what Docker installs under `/opt`.

### 9. Mount the network share

```bash
sudo apt install -y cifs-utils
sudo mkdir -p /mnt/share
sudo install -m 600 -o root -g root /dev/null /etc/share.cred
sudo nano /etc/share.cred                                                             # username=… and password=…

echo '<//SHARE_IP/share> /mnt/share cifs rw,credentials=/etc/share.cred,uid=<user>,gid=<user>,file_mode=0644,dir_mode=0755,_netdev,nofail 0 0' \
  | sudo tee -a /etc/fstab
sudo systemctl daemon-reload && sudo mount /mnt/share
```

> `nano` rather than `echo`: the password goes neither into the shell history nor through `!` and `$` expansion.
>
> IP rather than DNS name: the mount does not depend on DNS at boot. `nofail`: an unreachable share does not block boot. `ro` instead of `rw` for a VM that only reads.

### 10. Disable IPv6 (optional)

```bash
echo 'GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX ipv6.disable=1"' | sudo tee /etc/default/grub.d/99-disable-ipv6.cfg
sudo update-grub && sudo reboot
```

> Disabled at kernel boot: a `sysctl` setting is not enough, `systemd-networkd` re-enables IPv6 on the network card.

### 11. Check and take a snapshot

```bash
systemctl is-active qemu-guest-agent unattended-upgrades                              # active x2
sudo sshd -T | grep -E 'permitrootlogin|passwordauthentication'                       # no x2
df -h / /mnt/share
```

Snapshot with the VM **powered off**: the disk is frozen with no write in progress, and there is no RAM to save.

```bash
sudo poweroff
```

Proxmox: VM → **Snapshots** → **Take Snapshot**, name `init`, **Include RAM** unchecked; then start the VM.

## Notes

- **Remount the share** after an outage: `sudo mount /mnt/share`.
- **Enter the share credentials again**: `sudo rm /etc/share.cred`, then run the script again.
- **Next**: [docker.md](docker.md).
