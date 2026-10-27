#!/usr/bin/env bash
# Development tools: mise (node, bun, python…), GitHub CLI, Claude Code.
#
#   curl -fsSL https://raw.githubusercontent.com/louismullerkuhnle/homelab/main/vm/devtools.sh | sudo bash
#   … | sudo bash -s -- --check          check            … | sudo bash -s -- --reconfigure   change the tools
#
# Guide: vm/devtools.md · Requires: vm/init
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

PACKAGES=(build-essential pkg-config jq ripgrep fd-find unzip)
MISE_KEY_FPR=24853EC9F655CE80B48E6C3A8B81C9D17413A06D
# GitHub CLI publishes two primary keys in the same file.
GH_KEY_FPRS=(2C6106201985B60E6C7AC87323F3D4EA75716059 7F38BBB59D064DBCB3D84D725612B36462313325)
CLAUDE_INSTALLER=https://claude.ai/install.sh

settings() {
  setting HL_USER       "Main user"                          "${SUDO_USER:-}"                              '^[a-z_][a-z0-9_-]*$'
  setting HL_DEV_TOOLS  "mise tools (none to skip)"          "node@lts bun@latest python@latest uv@latest" '^[a-z0-9@._ /-]*$'
  setting HL_DEV_CLAUDE "Install Claude Code (yes or no)"    yes                                           '^(yes|no)$'
  [[ $HL_USER != root ]] || die "HL_USER cannot be root"
  id "$HL_USER" &>/dev/null || die "user $HL_USER does not exist"
  HL_GROUP=$(id -gn "$HL_USER")
  HL_HOME=$(getent passwd "$HL_USER" | cut -d: -f6)
}

# Tools are installed in the user's home, never as root.
as_user() { sudo -H -u "$HL_USER" env MISE_YES=1 "$@"; }

step_settings() {
  step "Settings"
  settings
  note "saved in $HL_CONF; --reconfigure to change them"
}

step_packages() {
  step "Build tools and utilities"
  local p missing=()
  for p in "${PACKAGES[@]}"; do is_installed "$p" || missing+=("$p"); done
  if (( ${#missing[@]} )); then
    run "Package index" "${APT[@]}" update --error-on=any
    run "Installing: ${missing[*]}" "${APT[@]}" install "${missing[@]}"
  else
    ok "Already installed"
  fi
}

step_repos() {
  step "mise and GitHub CLI APT repositories"
  local arch
  arch=$(dpkg --print-architecture)
  add_apt_repo mise https://mise.jdx.dev/gpg-key.pub /etc/apt/keyrings/mise.asc \
    /etc/apt/sources.list.d/mise.sources "Types: deb
URIs: https://mise.jdx.dev/deb
Suites: stable
Components: main
Architectures: $arch
Signed-By: /etc/apt/keyrings/mise.asc" "$MISE_KEY_FPR"
  add_apt_repo "GitHub CLI" https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    /etc/apt/keyrings/githubcli.gpg /etc/apt/sources.list.d/github-cli.sources "Types: deb
URIs: https://cli.github.com/packages
Suites: stable
Components: main
Architectures: $arch
Signed-By: /etc/apt/keyrings/githubcli.gpg" "${GH_KEY_FPRS[@]}"
}

step_install() {
  step "mise and gh"
  run "Package index" "${APT[@]}" update --error-on=any
  run "Install / upgrade" "${APT[@]}" install mise gh
}

step_tools() {
  step "Languages and tools for $HL_USER"
  local tools
  read -ra tools <<<"$HL_DEV_TOOLS"
  if (( ${#tools[@]} )); then
    run "Installing: ${tools[*]}" as_user mise use --global "${tools[@]}"
  else
    skip "no tools requested"
  fi
  # Enables mise in the user's interactive shells.
  if grep -qF 'mise activate bash' "$HL_HOME/.bashrc" 2>/dev/null; then
    ok "mise already enabled in ~/.bashrc"
  else
    # shellcheck disable=SC2016  # $(…) must stay literal in .bashrc
    printf '\n# Tools installed by mise\neval "$(mise activate bash)"\n' >>"$HL_HOME/.bashrc"
    chown "$HL_USER:$HL_GROUP" "$HL_HOME/.bashrc"
    ok "mise enabled in ~/.bashrc"
    note "applies at next login"
  fi
}

step_claude() {
  step "Claude Code"
  if [[ $HL_DEV_CLAUDE != yes ]]; then
    skip "not requested"
  elif [[ -x $HL_HOME/.local/bin/claude ]]; then
    ok "Already installed, updates itself"
  else
    # Official installer: refuses root and installs into ~/.local/bin.
    run "Installing for $HL_USER" as_user bash -c "set -o pipefail; curl -fsSL $CLAUDE_INSTALLER | bash"
    note "first login: run claude and follow the authentication"
  fi
}

check() {
  step "Checks"
  local tool tools
  read -ra tools <<<"$HL_DEV_TOOLS"
  chk "mise installed"                    mise --version
  for tool in "${tools[@]}"; do
    chk "$tool for $HL_USER"              as_user mise where "${tool%%@*}"
  done
  chk "mise enabled in ~/.bashrc"         grep -qF 'mise activate bash' "$HL_HOME/.bashrc"
  chk "gh installed"                      gh --version
  if [[ $HL_DEV_CLAUDE == yes ]]; then
    chk "Claude Code installed"           as_user "$HL_HOME/.local/bin/claude" --version
  fi
  if (( ${#tools[@]} )); then note "$( { as_user mise current 2>/dev/null || true; } | paste -sd' ' | sed 's/ \([a-z]\)/ · \1/g')"; fi
}

main() {
  local mode=install a
  for a in "$@"; do
    case $a in
      --check)       mode=check ASK=0 ;;
      --reconfigure) RECONFIGURE=1 ;;
      *)             die "unknown option: $a (--check, --reconfigure)" ;;
    esac
  done
  start vm/devtools "Development tools"
  require_ubuntu 26.04

  if [[ $mode == check ]]; then
    settings
    check
    finish "Compliant"
  else
    require_done vm/init
    run_steps step_settings step_packages step_repos step_install step_tools step_claude check
    mark_done
    finish "Done"
    next_steps "Log out and back in, then run claude to authenticate" \
               "Check: curl -fsSL $HL_RAW/vm/devtools.sh | sudo bash -s -- --check" \
               "Snapshot: sudo poweroff, then Proxmox → Snapshots → Take Snapshot \"devtools\", then start the VM"
  fi
  hl_exit
}

main "$@"
