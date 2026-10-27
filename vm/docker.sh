#!/usr/bin/env bash
# Docker Engine from the official repository, log rotation, access without sudo.
#
#   curl -fsSL https://raw.githubusercontent.com/louismullerkuhnle/homelab/main/vm/docker.sh | sudo bash
#   … | sudo bash -s -- --check          check            … | sudo bash -s -- --uninstall     undo
#
# Guide: vm/docker.md · Requires: vm/init
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

REPO=https://download.docker.com/linux/ubuntu
KEY_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
KEYRING=/etc/apt/keyrings/docker.asc
SOURCES=/etc/apt/sources.list.d/docker.sources
DAEMON_JSON=/etc/docker/daemon.json
PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
# Distribution packages that conflict with Docker's (official docs).
CONFLICTS=(docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc)

settings() {
  setting HL_USER "Main user" "${SUDO_USER:-}" '^[a-z_][a-z0-9_-]*$'
  id "$HL_USER" &>/dev/null || die "user $HL_USER does not exist"
}

step_conflicts() {
  step "Conflicting packages"
  local p found=()
  for p in "${CONFLICTS[@]}"; do
    if is_installed "$p"; then found+=("$p"); fi
  done
  # No automatic removal: on a VM already in use, they may be running containers.
  if (( ${#found[@]} )); then
    note "remove them first: sudo apt remove ${found[*]}"
    die "installed: ${found[*]}"
  fi
  ok "None"
}

step_repo() {
  step "Docker APT repository"
  local codename arch
  # shellcheck source=/dev/null
  codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
  arch=$(dpkg --print-architecture)
  # A brand-new Ubuntu release may not be published by Docker yet.
  spin "Availability for $codename" curl -fsI "$REPO/dists/$codename/Release" \
    || die "Docker does not publish for $codename yet ($REPO/dists/)"
  add_apt_repo Docker "$REPO/gpg" "$KEYRING" "$SOURCES" "Types: deb
URIs: $REPO
Suites: $codename
Components: stable
Architectures: $arch
Signed-By: $KEYRING" "$KEY_FPR"
}

step_install() {
  step "Docker Engine"
  local before after
  before=$(dpkg-query -W -f='${Version}' docker-ce 2>/dev/null || true)
  run "Package index" "${APT[@]}" update --error-on=any
  run "Install / upgrade" "${APT[@]}" install "${PACKAGES[@]}"
  after=$(dpkg-query -W -f='${Version}' docker-ce)
  if [[ $before == "$after" ]]; then note "already up to date ($after)"; else note "${before:-none} → $after"; fi
}

step_logs() {
  step "Log rotation"
  local restart=0
  install -d -m 755 /etc/docker
  cat >"$TMP/daemon.json" <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
  if [[ -f $DAEMON_JSON ]] && ! cmp -s "$TMP/daemon.json" "$DAEMON_JSON"; then
    # File edited by hand (registry mirror, etc.): kept as is.
    if grep -q '"max-size"' "$DAEMON_JSON"; then
      ok "Custom $DAEMON_JSON kept, rotation present"
    else
      warn "custom $DAEMON_JSON without log rotation"
      note "add log-driver and log-opts by hand (vm/docker.md, step 4)"
    fi
  elif replace_if_changed "$TMP/daemon.json" "$DAEMON_JSON" 644; then
    restart=1
    ok "10 MB × 3 files per container"
  else
    ok "Already configured (10 MB × 3)"
  fi
  run "Validating $DAEMON_JSON" dockerd --validate --config-file "$DAEMON_JSON"
  if (( restart )); then
    run "Restarting Docker" systemctl restart docker
    note "applies to containers created from now on"
  fi
}

step_group() {
  step "Access without sudo"
  if id -nG "$HL_USER" | grep -qw docker; then
    ok "$HL_USER already in the docker group"
  else
    usermod -aG docker "$HL_USER"
    ok "$HL_USER added to the docker group"
    note "applies at next login"
  fi
  note "the docker group is equivalent to root access on the VM"
}

check() {
  step "Checks"
  chk "docker running"                   systemctl is-active --quiet docker
  chk "containerd running"               systemctl is-active --quiet containerd
  chk "docker enabled at boot"           systemctl is-enabled --quiet docker
  chk "Log rotation active"              bash -c "[[ \$(docker info --format '{{.LoggingDriver}}') == json-file ]] && grep -q '\"max-size\"' $DAEMON_JSON"
  chk "$HL_USER in the docker group"     bash -c "id -nG '$HL_USER' | grep -qw docker"
  chk "docker compose available"         docker compose version
  # Pulled from Docker Hub: also checks container networking and DNS.
  chk "Test container (hello-world)"     bash -c "docker run --rm hello-world && docker rmi hello-world"
  note "$(docker version --format 'Engine {{.Server.Version}}' 2>/dev/null || true) · compose $(docker compose version --short 2>/dev/null || true)"
}

uninstall() {
  step "Uninstall"
  confirm "Remove Docker? Containers stopped, data kept." || die "cancelled, nothing changed"
  run "Removing packages" "${APT[@]}" purge "${PACKAGES[@]}" docker-ce-rootless-extras
  rm -f "$SOURCES" "$KEYRING"
  rm -rf /etc/docker
  ok "Repository, key and configuration removed"
  note "data kept: /var/lib/docker and /var/lib/containerd"
}

main() {
  local mode=install a
  for a in "$@"; do
    case $a in
      --check)       mode=check ASK=0 ;;
      --uninstall)   mode=uninstall ;;
      --reconfigure) RECONFIGURE=1 ;;
      *)             die "unknown option: $a (--check, --uninstall, --reconfigure)" ;;
    esac
  done
  start vm/docker "Docker Engine"
  require_ubuntu 26.04
  settings

  case $mode in
    check)
      check
      finish "Compliant" ;;
    uninstall)
      uninstall
      mark_undone
      finish "Uninstalled" ;;
    install)
      require_done vm/init
      run_steps step_conflicts step_repo step_install step_logs step_group check
      mark_done
      finish "Done"
      next_steps "Log out and back in: docker ps must work without sudo" \
                 "Check: curl -fsSL $HL_RAW/vm/docker.sh | sudo bash -s -- --check" \
                 "Snapshot: sudo poweroff, then Proxmox → Snapshots → Take Snapshot \"docker\", then start the VM" ;;
  esac
  hl_exit
}

main "$@"
