#!/usr/bin/env bash
# Proxmox web UI exposed through a Cloudflare tunnel, no open port, behind Access.
#
#   curl -fsSL https://raw.githubusercontent.com/louismullerkuhnle/homelab/main/pve/cloudflared.sh | bash
#   … | bash -s -- --check        check            … | bash -s -- --new-token     replace the token
#   … | bash -s -- --uninstall    undo             … | bash -s -- --reconfigure   change the public name
#
# Guide: pve/cloudflared.md (the tunnel, Access and the route are created in the Cloudflare dashboard)
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

# Paths from the official docs (pkg.cloudflare.com), to take over a manual installation.
KEYRING=/usr/share/keyrings/cloudflare-main.gpg
SOURCES=/etc/apt/sources.list.d/cloudflared.list
# "CloudFlare Software Packaging 2025" key, published on 2025-10-30.
KEY_FPR=CC94B39C77AE7342A68B89628A682D308D4E5E73
ENV_DIR=/etc/cloudflared
ENV_FILE=$ENV_DIR/tunnel.env
UNIT=/etc/systemd/system/cloudflared.service
NEW_TOKEN=0
CHANGED=0

settings() {
  setting HL_PVE_HOSTNAME "Public name of the web UI (e.g. pve.example.com, none to skip the check)" "" '^([a-z0-9-]+\.)+[a-z]{2,}$|^$'
}

# The token is asked first so the rest runs unattended.
step_settings() {
  step "Settings and token"
  settings
  if [[ -z $HL_PVE_HOSTNAME ]]; then note "no public name: Access will not be checked"; fi

  if [[ -s $ENV_FILE && $NEW_TOKEN == 0 ]]; then
    ok "Existing token reused ($ENV_FILE)"
    note "--new-token to replace it"
    return
  fi
  local raw json token tunnel_id
  ask_secret raw "Tunnel token (or the full install command)"
  ok "Tunnel token: ********"
  # Accepts the token alone or the full command.
  [[ $raw =~ (eyJ[A-Za-z0-9+/_=-]{50,}) ]] || die "no token found (it starts with eyJ)"
  token=${BASH_REMATCH[1]}
  unset raw
  # The token is base64 JSON {"a":account,"t":tunnel_id,"s":secret}: the ID is shown as a visual check.
  json=$(printf '%s' "$token" | base64 -d 2>/dev/null) || true
  [[ $json =~ \"t\":\"([0-9a-f-]{36})\" ]] || die "unreadable token: copy it again from the dashboard"
  tunnel_id=${BASH_REMATCH[1]}
  unset json

  install -d -m 700 -o root -g root "$ENV_DIR"
  install -m 600 /dev/null "$TMP/tunnel.env"
  # printf is a builtin: the token shows up neither in ps nor in the shell history.
  printf 'TUNNEL_TOKEN=%s\n' "$token" >"$TMP/tunnel.env"
  unset token
  if replace_if_changed "$TMP/tunnel.env" "$ENV_FILE" 600; then
    CHANGED=1
    ok "Token saved in $ENV_FILE (600 root)"
  else
    ok "Token identical to the saved one"
  fi
  note "tunnel $tunnel_id: check in the dashboard that it is the right one"
}

step_repo() {
  step "Cloudflare APT repository"
  add_apt_repo Cloudflare https://pkg.cloudflare.com/cloudflare-main.gpg "$KEYRING" "$SOURCES" \
    "deb [signed-by=$KEYRING] https://pkg.cloudflare.com/cloudflared any main" "$KEY_FPR"
}

step_install() {
  step "cloudflared"
  local before after
  before=$(dpkg-query -W -f='${Version}' cloudflared 2>/dev/null || true)
  # Index of this repository only: the enterprise repository of an unsubscribed Proxmox (401) does not block.
  run "Cloudflare repository index" apt-get update -q --error-on=any \
    -o Dir::Etc::sourcelist="$SOURCES" -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0
  run "Install / upgrade" "${APT[@]}" install cloudflared
  after=$(dpkg-query -W -f='${Version}' cloudflared)
  if [[ $before == "$after" ]]; then note "already up to date ($after)"; else CHANGED=1; note "${before:-none} → $after"; fi
}

step_service() {
  step "systemd service"
  # Also replaces the unit from "cloudflared service install", which puts the token in plain text in ExecStart.
  if write_if_changed "$UNIT" 644 <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
EnvironmentFile=$ENV_FILE
ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate run
Restart=always
RestartSec=5s
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
  then
    CHANGED=1
    systemctl daemon-reload
    ok "Unit written"
  else
    ok "Unit already up to date"
  fi
  systemctl enable --quiet cloudflared.service
  if (( CHANGED )) || ! systemctl is-active --quiet cloudflared; then
    # Type=notify: restart returns once the first connection is up.
    run "Starting the tunnel" timeout 60 systemctl restart cloudflared.service
  else
    ok "Nothing changed, tunnel left as is"
  fi
}

connections() {
  local inv
  inv=$(systemctl show -p InvocationID --value cloudflared 2>/dev/null || true)
  if [[ -z $inv ]]; then echo 0; return; fi
  journalctl -q _SYSTEMD_INVOCATION_ID="$inv" -o cat | grep -c 'Registered tunnel connection' || true
}
# The 4 connections come up within seconds; succeeds from the first one.
wait_connections() {
  local n=0
  for _ in {1..10}; do
    n=$(connections)
    if (( n >= 4 )); then break; fi
    sleep 2
  done
  (( n >= 1 ))
}

check() {
  step "Checks"
  local code loc err
  chk "cloudflared running"            systemctl is-active --quiet cloudflared
  chk "cloudflared enabled at boot"    systemctl is-enabled --quiet cloudflared
  chk "Token file 600 root"            test "$(stat -c '%a %U' "$ENV_FILE" 2>/dev/null || true)" = "600 root"
  if spin "Connections to the Cloudflare network" wait_connections; then
    ok "$(connections) connection(s) to the Cloudflare network"
  else
    ko "No connection to the Cloudflare network"
    note "journalctl -u cloudflared -n 50"
  fi
  if [[ -z $HL_PVE_HOSTNAME ]]; then skip "Access not checked (no public name)"; return; fi
  # Resolved through public DNS over HTTPS: /etc/hosts maps the host's own FQDN to its LAN IP,
  # which would test Proxmox directly instead of the tunnel.
  IFS='|' read -r code loc err < <(curl -s -o /dev/null --max-time 15 --doh-url https://cloudflare-dns.com/dns-query \
    -w '%{http_code}|%{redirect_url}|%{errormsg}\n' "https://$HL_PVE_HOSTNAME/" || true) || true
  # Without a session, Access must redirect to <team>.cloudflareaccess.com before reaching Proxmox.
  if [[ $code == 30[12378] && $loc == *cloudflareaccess.com* ]]; then
    ok "Access protects $HL_PVE_HOSTNAME"
  elif [[ $code == 200 ]]; then
    warn "$HL_PVE_HOSTNAME answers without login from this network: no Access application, or a bypass rule for this IP"
    note "check from another network (mobile data): the Access page must show up (guide, step 4)"
  elif [[ ${code:-000} == 000 ]]; then
    ko "$HL_PVE_HOSTNAME unreachable: ${err:-no answer}"
    note "route published? (guide, step 5)"
  else
    ko "$HL_PVE_HOSTNAME answers HTTP $code"
    note "route to https://localhost:8006 with No TLS Verify? (guide, step 5)"
  fi
}

uninstall() {
  step "Uninstall"
  confirm "Stop the tunnel and remove cloudflared?" || die "cancelled, nothing changed"
  systemctl disable --now cloudflared.service >>"$LOG" 2>&1 || true
  rm -f "$UNIT"
  rm -rf "$ENV_DIR"
  systemctl daemon-reload
  conf_unset HL_PVE_HOSTNAME
  ok "Service, token and setting removed"
  if is_installed cloudflared; then run "Removing the package" "${APT[@]}" purge cloudflared; fi
  rm -f "$SOURCES" "$KEYRING"
  ok "Repository and key removed"
  note "also delete the tunnel and the Access application in the dashboard"
}

main() {
  local mode=install a
  for a in "$@"; do
    case $a in
      --check)       mode=check ASK=0 ;;
      --uninstall)   mode=uninstall ;;
      --new-token)   NEW_TOKEN=1 ;;
      --reconfigure) RECONFIGURE=1 ;;
      *)             die "unknown option: $a (--check, --uninstall, --new-token, --reconfigure)" ;;
    esac
  done
  start pve/cloudflared "Cloudflare tunnel"
  require_pve 9

  case $mode in
    check)
      settings
      check
      finish "Compliant" ;;
    uninstall)
      uninstall
      mark_undone
      finish "Uninstalled" ;;
    install)
      run_steps step_settings step_repo step_install step_service check
      mark_done
      finish "Done"
      if (( FAILS )); then
        note "expected if the Access application and the route are not created yet in the dashboard"
        next_steps "Do steps 4 and 5 of the pve/cloudflared.md guide" "Run again with --check"
      elif [[ -n $HL_PVE_HOSTNAME ]]; then
        next_steps "Open https://$HL_PVE_HOSTNAME in a private window: Access page, then Proxmox login"
      fi ;;
  esac
  hl_exit
}

main "$@"
