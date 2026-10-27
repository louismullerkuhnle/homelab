#!/usr/bin/env bash
# First boot of an Ubuntu VM: system, hardened SSH, disk, network share, IPv6.
#
#   curl -fsSL https://raw.githubusercontent.com/louismullerkuhnle/homelab/main/vm/init.sh | sudo bash
#   … | sudo bash -s -- --check          check            … | sudo bash -s -- --reconfigure   ask the questions again
#   … | sudo bash -s -- --reboot         reboot at the end if needed
#
# Guide: vm/init.md
# shellcheck disable=SC2329  # steps called by run_steps

set -Eeuo pipefail
HL_RAW=${HL_RAW:-https://raw.githubusercontent.com/louismullerkuhnle/homelab/main}
here=$(dirname "${BASH_SOURCE[0]:-.}")
if [[ -f $here/../lib.sh ]]; then
  # shellcheck source=lib.sh
  . "$here/../lib.sh"
else
  lib=$(mktemp)
  curl -fsSL "$HL_RAW/lib.sh" -o "$lib" || { echo "✗ $HL_RAW/lib.sh not found" >&2; exit 1; }
  # shellcheck source=/dev/null
  . "$lib"
  rm -f "$lib"
fi

SHARE_CRED=/etc/share.cred
SSH_DROPIN=/etc/ssh/sshd_config.d/10-hardening.conf
GRUB_DROPIN=/etc/default/grub.d/99-disable-ipv6.cfg
AUTO_UPGRADES=/etc/apt/apt.conf.d/20auto-upgrades
PACKAGES=(curl wget git nano htop tree bash-completion ca-certificates gnupg
          cloud-guest-utils qemu-guest-agent unattended-upgrades cifs-utils)
NEED_REBOOT=0

# Current timezone; empty if timedatectl is unavailable, without triggering the error trap.
current_tz() { timedatectl show -p Timezone --value 2>/dev/null || true; }

settings() {
  setting HL_USER            "Main user"                                                    "${SUDO_USER:-}"  '^[a-z_][a-z0-9_-]*$'
  setting HL_TIMEZONE        "Timezone"                                                     "$(current_tz)"
  setting HL_SSH_GITHUB_USER "SSH keys from GitHub account (- to skip)"                     ""                '^[A-Za-z0-9-]*$'
  setting HL_SHARE           "Network share (SMB, e.g. //192.168.1.10/share, - for none)"   ""                '^(//[^ ]+)?$'
  if [[ -n $HL_SHARE ]]; then
    setting HL_SHARE_MODE    "Network share access (rw or ro)"                              rw                '^(rw|ro)$'
    setting HL_SHARE_MOUNT   "Network share mount point"                                    /mnt/share        '^/[^ ]+$'
  fi
  setting HL_IPV6            "IPv6 (on or off)"                                             on                '^(on|off)$'
  [[ $HL_USER != root ]] || die "HL_USER cannot be root"
  id "$HL_USER" &>/dev/null || die "user $HL_USER does not exist"
  HL_GROUP=$(id -gn "$HL_USER")
  HL_HOME=$(getent passwd "$HL_USER" | cut -d: -f6)
}

step_settings() {
  step "Settings"
  settings
  note "saved in $HL_CONF; --reconfigure to change them"

  # Asked now so the rest runs unattended.
  if [[ -n $HL_SHARE && ! -s $SHARE_CRED ]]; then
    local user pass
    ask user "Network share user"
    ok "Network share user: $user"
    ask_secret pass "Network share password"
    ok "Network share password: ********"
    [[ -n $user && -n $pass ]] || die "empty network share credentials"
    install -m 600 -o root -g root /dev/null "$SHARE_CRED"
    # printf is a builtin: the password shows up neither in ps nor in the shell history.
    printf 'username=%s\npassword=%s\n' "$user" "$pass" >"$SHARE_CRED"
    unset pass
    note "credentials saved in $SHARE_CRED (600 root)"
  fi
}

step_packages() {
  step "System updates"
  local n p missing=()
  run "Package index" "${APT[@]}" update --error-on=any
  n=$(apt-get -s full-upgrade 2>/dev/null | grep -c '^Inst' || true)
  if (( n )); then
    run "Upgrading $n package(s)" \
      "${APT[@]}" -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
  else
    ok "System already up to date"
  fi
  for p in "${PACKAGES[@]}"; do is_installed "$p" || missing+=("$p"); done
  if (( ${#missing[@]} )); then
    run "Installing: ${missing[*]}" "${APT[@]}" install "${missing[@]}"
  else
    ok "Base tools already installed"
  fi
  run "Removing unused packages" "${APT[@]}" autoremove
}

step_qemu_agent() {
  step "QEMU guest agent"
  if [[ ! -e /dev/virtio-ports/org.qemu.guest_agent.0 ]]; then
    warn "no agent channel: Proxmox → VM → Options → QEMU Guest Agent, then stop and start the VM from Proxmox"
  elif systemctl start qemu-guest-agent >>"$LOG" 2>&1; then
    ok "qemu-guest-agent running"
  else
    warn "qemu-guest-agent does not start: journalctl -u qemu-guest-agent"
  fi
}

step_auto_upgrades() {
  step "Automatic security updates"
  if write_if_changed "$AUTO_UPGRADES" 644 <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  then ok "Enabled"; else ok "Already enabled"; fi
}

step_timezone() {
  step "Timezone"
  if [[ $(current_tz) == "$HL_TIMEZONE" ]]; then
    ok "Already $HL_TIMEZONE"
  else
    timedatectl set-timezone "$HL_TIMEZONE" || die "unknown timezone: $HL_TIMEZONE (timedatectl list-timezones)"
    ok "$HL_TIMEZONE"
  fi
}

# Grows partition → PV → LV → filesystem, without assuming sda/vda or the partition number.
step_disk() {
  step "Root volume"
  local root_dev vg pv name part disk out free before
  root_dev=$(findmnt -no SOURCE /)
  if ! vg=$(lvs --noheadings -o vg_name "$root_dev" 2>/dev/null | xargs) || [[ -z $vg ]]; then
    skip "root is not on LVM ($root_dev): not handled"
    return
  fi
  before=$(df -h --output=size / | tail -n1 | xargs)
  while read -r pv; do
    name=${pv##*/}
    if [[ -r /sys/class/block/$name/partition ]]; then
      part=$(<"/sys/class/block/$name/partition")
      disk=$(lsblk -no PKNAME "$pv" | head -n1)
      if out=$(growpart "/dev/$disk" "$part" 2>&1); then
        printf '%s\n' "$out" >>"$LOG"
        ok "Partition $pv grown"
      elif [[ $out != *NOCHANGE* ]]; then
        printf '%s\n' "$out" >>"$LOG"
        die "growpart /dev/$disk $part"
      fi
    fi
    pvresize "$pv" >>"$LOG" 2>&1
  done < <(pvs --noheadings -o pv_name -S "vg_name=$vg" | xargs -n1)
  free=$(vgs --noheadings --units b --nosuffix -o vg_free "$vg" | xargs)
  if (( free > 0 )); then
    run "Extending / to the whole disk" lvextend -r -l +100%FREE "$root_dev"
    note "$before → $(df -h --output=size / | tail -n1 | xargs)"
  else
    ok "Already at full size ($before)"
  fi
}

step_ssh() {
  step "SSH"
  local ak keys line added=0 n=0
  ak=$HL_HOME/.ssh/authorized_keys
  install -d -m 700 -o "$HL_USER" -g "$HL_GROUP" "$HL_HOME/.ssh"
  if [[ -n $HL_SSH_GITHUB_USER ]]; then
    if keys=$(curl -fsSL --max-time 15 "https://github.com/$HL_SSH_GITHUB_USER.keys"); then
      [[ -f $ak ]] || install -m 600 -o "$HL_USER" -g "$HL_GROUP" /dev/null "$ak"
      while IFS= read -r line; do
        [[ -n $line ]] || continue
        ssh-keygen -lf - <<<"$line" &>/dev/null || continue
        if ! grep -qxF "$line" "$ak"; then printf '%s\n' "$line" >>"$ak"; added=$((added + 1)); fi
      done <<<"$keys"
      ok "Keys from github.com/$HL_SSH_GITHUB_USER: $added added"
    else
      warn "cannot fetch keys from github.com/$HL_SSH_GITHUB_USER"
    fi
  fi

  # Safeguard: without a valid key, disabling passwords would lock you out.
  if [[ -s $ak ]]; then n=$(ssh-keygen -lf "$ak" 2>/dev/null | wc -l || true); fi
  if (( n == 0 )); then
    warn "no valid key in $ak: password login left enabled"
    note "add a key (workstation/ssh.md), then run again"
    return
  fi
  ok "$n authorized key(s) for $HL_USER"

  # 10- prefix: sshd keeps the first value it reads, this file comes before 50-cloud-init.conf.
  if write_if_changed "$SSH_DROPIN" 644 <<'EOF'
PermitRootLogin no
PasswordAuthentication no
EOF
  then
    if ! sshd -t >>"$LOG" 2>&1; then rm -f "$SSH_DROPIN"; die "invalid sshd configuration: $SSH_DROPIN removed"; fi
    # With socket activation, ssh may be stopped: the config is then read on the next connection.
    systemctl try-reload-or-restart ssh >>"$LOG" 2>&1
    ok "Root and password login disabled"
    note "test a new SSH session before closing this one"
  else
    ok "Already hardened: root and passwords refused"
  fi
}

# Not recursive: after Docker, -R would change the owner of what it installs under /opt.
step_dirs() {
  step "/srv and /opt"
  chown "$HL_USER:$HL_GROUP" /srv /opt
  chmod g+s /srv /opt
  ok "Owned by $HL_USER, setgid set"
}

step_share() {
  step "Network share"
  if [[ -z $HL_SHARE ]]; then skip "no network share"; return; fi
  local line n bak
  line="$HL_SHARE $HL_SHARE_MOUNT cifs $HL_SHARE_MODE,credentials=$SHARE_CRED,uid=$HL_USER,gid=$HL_GROUP,file_mode=0644,dir_mode=0755,_netdev,nofail 0 0"
  mkdir -p "$HL_SHARE_MOUNT"
  if grep -qxF "$line" /etc/fstab; then
    ok "fstab already up to date"
  else
    bak=/etc/fstab.bak.$(date +%Y%m%d-%H%M%S)
    cp -a /etc/fstab "$bak"
    { awk -v m="$HL_SHARE_MOUNT" '!($2 == m && $3 == "cifs")' /etc/fstab; printf '%s\n' "$line"; } >"$TMP/fstab"
    cat "$TMP/fstab" >/etc/fstab                # cat > keeps inode, permissions and context
    systemctl daemon-reload
    # Options changed on a mounted share: unmount so they apply on remount.
    if mountpoint -q "$HL_SHARE_MOUNT"; then umount "$HL_SHARE_MOUNT" >>"$LOG" 2>&1 || true; fi
    ok "fstab updated"
    note "backup: $bak"
  fi
  if mountpoint -q "$HL_SHARE_MOUNT"; then
    ok "Already mounted on $HL_SHARE_MOUNT"
  elif spin "Mounting $HL_SHARE" mount "$HL_SHARE_MOUNT"; then
    n=$(find "$HL_SHARE_MOUNT" -mindepth 1 -maxdepth 1 | wc -l)
    ok "Mounted on $HL_SHARE_MOUNT ($n entries)"
  else
    warn "mount failed: share unreachable or wrong credentials"
    note "fix $SHARE_CRED, then: sudo mount $HL_SHARE_MOUNT"
  fi
}

step_ipv6() {
  step "IPv6"
  if [[ $HL_IPV6 == off ]]; then
    if write_if_changed "$GRUB_DROPIN" 644 <<'EOF'
GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX ipv6.disable=1"
EOF
    then run "Disabling at kernel boot (GRUB)" update-grub
    else ok "Already disabled in GRUB"
    fi
    if ! grep -qw 'ipv6.disable=1' /proc/cmdline; then NEED_REBOOT=1; note "takes effect at next reboot"; fi
  elif [[ -f $GRUB_DROPIN ]]; then
    rm -f "$GRUB_DROPIN"
    run "Re-enabling at kernel boot (GRUB)" update-grub
    NEED_REBOOT=1
    note "takes effect at next reboot"
  else
    skip "unchanged"
  fi
}

check() {
  step "Checks"
  chk "qemu-guest-agent running"         systemctl is-active --quiet qemu-guest-agent
  chk "Automatic security updates"       bash -c "apt-config dump | grep -qx 'APT::Periodic::Unattended-Upgrade \"1\";'"
  chk "SSH root login refused"           bash -c "sshd -T | grep -qx 'permitrootlogin no'"
  chk "SSH password login refused"       bash -c "sshd -T | grep -qx 'passwordauthentication no'"
  chk "Timezone $HL_TIMEZONE"            test "$(current_tz)" = "$HL_TIMEZONE"
  if [[ -n $HL_SHARE ]]; then chk "Network share mounted on $HL_SHARE_MOUNT" mountpoint -q "$HL_SHARE_MOUNT"; fi
  if [[ $HL_IPV6 == off ]]; then chk "IPv6 disabled" test ! -e /proc/net/if_inet6; fi
  note "/: $(df -h --output=avail,size / | tail -n1 | awk '{print $1 " free of " $2}')"
}

main() {
  local mode=install reboot=0 a
  for a in "$@"; do
    case $a in
      --check)       mode=check ASK=0 ;;
      --reconfigure) RECONFIGURE=1 ;;
      --reboot)      reboot=1 ;;
      *)             die "unknown option: $a (--check, --reconfigure, --reboot)" ;;
    esac
  done
  start vm/init "First boot of an Ubuntu VM"
  require_ubuntu 26.04

  if [[ $mode == check ]]; then
    settings
    check
    finish "Compliant"
    hl_exit
  fi

  run_steps step_settings step_packages step_qemu_agent step_auto_upgrades step_timezone \
            step_disk step_ssh step_dirs step_share step_ipv6
  mark_done
  [[ ! -f /var/run/reboot-required ]] || NEED_REBOOT=1
  finish "Done"
  if (( NEED_REBOOT && reboot )); then note "rebooting in 5 s"; sleep 5; systemctl reboot; fi
  if (( NEED_REBOOT )); then
    next_steps "Test a new SSH session from your workstation" "sudo reboot" "Run again with --check" "Take a Proxmox snapshot"
  else
    next_steps "Test a new SSH session from your workstation" "Run again with --check" "Take a Proxmox snapshot"
  fi
}

main "$@"
