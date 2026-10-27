#!/usr/bin/env bash
# Intel CPU throttling on the Proxmox host: turbo, governor, EPP, reapplied at boot.
#
#   curl -fsSL https://raw.githubusercontent.com/louismullerkuhnle/homelab/main/pve/cpu-powersave.sh | bash
#   … | bash -s -- --check        check            … | bash -s -- --uninstall     undo
#
# Installs the cpu-powersave command (profile menu) and its service. The power limit stays in the BIOS.
# Guide: pve/cpu-powersave.md
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

BIN=/usr/local/sbin/cpu-powersave
CONF=/etc/cpu-powersave.conf
UNIT=/etc/systemd/system/cpu-powersave.service
CPU=/sys/devices/system/cpu
RAPL=/sys/class/powercap/intel-rapl:0

# Command installed as $BIN.
tool() {
  cat <<'TOOL'
#!/bin/bash
# CPU throttling for a Proxmox host with an Intel CPU (intel_pstate driver): turbo, governor, EPP.
#   cpu-powersave          menu: pick a setting, save it and apply it
#   cpu-powersave apply    applies the saved setting (run at boot by cpu-powersave.service)
#   cpu-powersave status   saved setting and actual CPU state
# The power limit is set in the BIOS, not here.
set -uo pipefail

CONF=/etc/cpu-powersave.conf
CPU=/sys/devices/system/cpu
RAPL=/sys/class/powercap/intel-rapl:0

# Writes a value; a refusal is logged without stopping the script
w() { { echo "$1" > "$2"; } 2>/dev/null || echo "failed: $2 ← $1" >&2; }

# Reads the saved setting; missing or invalid value → default
load() {
  TURBO=off EPP=balance_power
  [ -r "$CONF" ] && . "$CONF"
  case "$TURBO" in on|off) ;; *) echo "invalid TURBO ($TURBO): using off" >&2; TURBO=off ;; esac
  case "$EPP" in performance|balance_performance|balance_power|power) ;;
    *) echo "invalid EPP ($EPP): using balance_power" >&2; EPP=balance_power ;; esac
}

save() {
  printf '# Written by cpu-powersave - change it with the command: cpu-powersave\nTURBO=%s\nEPP=%s\n' \
    "$TURBO" "$EPP" > "$CONF"
}

# 1. Turbo (1 = off), 2. powersave governor (the only mode where EPP applies), 3. EPP
apply() {
  [ "$TURBO" = off ] && v=1 || v=0
  w "$v" "$CPU/intel_pstate/no_turbo"
  for f in "$CPU"/cpu[0-9]*/cpufreq/scaling_governor; do w powersave "$f"; done
  for f in "$CPU"/cpu[0-9]*/cpufreq/energy_performance_preference; do w "$EPP" "$f"; done
}

status() {
  local turbo pl="?"
  [ "$(cat "$CPU/intel_pstate/no_turbo")" = 1 ] && turbo=off || turbo=on
  [ -r "$RAPL/constraint_1_power_limit_uw" ] && pl="PL1 $(( $(cat "$RAPL/constraint_0_power_limit_uw") / 1000000 )) W  PL2 $(( $(cat "$RAPL/constraint_1_power_limit_uw") / 1000000 )) W"
  echo "Saved     : TURBO=$TURBO  EPP=$EPP  ($CONF)"
  echo "Applied   : TURBO=$turbo  EPP=$(cat "$CPU/cpu0/cpufreq/energy_performance_preference")  governor=$(cat "$CPU/cpu0/cpufreq/scaling_governor")"
  echo "Max freq. : $(cat "$CPU"/cpu[0-9]*/cpufreq/scaling_max_freq | sort -nu | awk '{printf "%d MHz  ", $1/1000}')"
  echo "Limits    : $pl  (BIOS)"
}

# choose <question> <current> <value> <description> [<value> <description>]... → prints the chosen value
choose() {
  local q=$1 cur=$2 vals=() n=0 r; shift 2
  printf '\n%s\n' "$q" >&2
  while [ $# -gt 0 ]; do
    vals+=("$1"); n=$((n + 1))
    printf '  %d) %-20s %s%s\n' "$n" "$1" "$2" "$([ "$1" = "$cur" ] && echo '  ← current')" >&2
    shift 2
  done
  while :; do
    read -rp "Choice [Enter = $cur]: " r
    [ -z "$r" ] && { echo "$cur"; return; }
    [[ "$r" =~ ^[0-9]+$ ]] && [ "$r" -ge 1 ] && [ "$r" -le "$n" ] && { echo "${vals[r - 1]}"; return; }
    echo "  Invalid choice." >&2
  done
}

menu() {
  local cur p r
  status
  case "$TURBO/$EPP" in
    off/power)              cur=eco ;;
    off/balance_power)      cur=balanced ;;
    on/balance_performance) cur=performance ;;
    on/performance)         cur=max ;;
    *)                      cur=custom ;;
  esac
  p=$(choose "Profile?" "$cur" \
    eco         "turbo off, EPP power - lowest consumption" \
    balanced    "turbo off, EPP balance_power - recommended for a server" \
    performance "turbo on, EPP balance_performance - responsive, PC default" \
    max         "turbo on, EPP performance - max frequency at the slightest load" \
    custom      "pick turbo and EPP separately")
  case "$p" in
    eco)         TURBO=off EPP=power ;;
    balanced)    TURBO=off EPP=balance_power ;;
    performance) TURBO=on  EPP=balance_performance ;;
    max)         TURBO=on  EPP=performance ;;
    custom)
      TURBO=$(choose "Turbo?" "$TURBO" \
        off "base frequencies - efficient, quiet" \
        on  "boost up to max frequency - responsive, heats up on peaks")
      EPP=$(choose "Energy performance preference (EPP)?" "$EPP" \
        performance         "goes to max as soon as there is load" \
        balance_performance "kernel default" \
        balance_power       "favours efficiency" \
        power               "maximum efficiency, lower responsiveness") ;;
  esac
  printf '\nNew setting: TURBO=%s  EPP=%s\n' "$TURBO" "$EPP"
  read -rp "Save and apply? [Y/n] " r
  case "$r" in n|N) echo "Cancelled: nothing changed."; return ;; esac
  save; apply
  printf '\n'; status
  echo "Reminder: the power limit is set in the BIOS."
}

[ "$EUID" -eq 0 ] || { echo "Must run as root." >&2; exit 1; }
[ "$(cat "$CPU/cpu0/cpufreq/scaling_driver" 2>/dev/null)" = intel_pstate ] \
  || { echo "intel_pstate missing: an Intel CPU with the intel_pstate driver is required." >&2; exit 1; }

load
case "${1:-menu}" in
  apply)  apply ;;
  status) status ;;
  menu)   [ -t 0 ] || { echo "Interactive menu: run it from a terminal." >&2; exit 1; }; menu ;;
  *)      echo "Usage: cpu-powersave [apply|status]" >&2; exit 1 ;;
esac
exit 0
TOOL
}

# RAPL limit in W; empty if unavailable.
rapl_w() { if [[ -r $RAPL/constraint_$1_power_limit_uw ]]; then echo $(( $(cat "$RAPL/constraint_$1_power_limit_uw") / 1000000 )); fi; }

require_intel_pstate() {
  local driver
  driver=$(cat "$CPU/cpu0/cpufreq/scaling_driver" 2>/dev/null || true)
  [[ $driver == intel_pstate ]] || die "driver ${driver:-missing}: an Intel CPU with intel_pstate is required"
  [[ -e $CPU/cpu0/cpufreq/energy_performance_preference ]] || die "EPP unavailable: CPU without HWP"
}

# BIOS limits are saved so that --check spots a BIOS reset. Default: current values.
settings() {
  setting HL_CPU_PL1 "Expected BIOS PL1 limit, in W (- to skip the check)" "$(rapl_w 0)" '^[0-9]*$'
  setting HL_CPU_PL2 "Expected BIOS PL2 limit, in W (- to skip the check)" "$(rapl_w 1)" '^[0-9]*$'
}

step_settings() {
  step "Settings"
  settings
  if [[ -n $HL_CPU_PL1$HL_CPU_PL2 ]]; then ok "Expected limits: PL1 ${HL_CPU_PL1:-?} W, PL2 ${HL_CPU_PL2:-?} W"; else skip "BIOS limits not checked"; fi
}

# TLP, tuned and power-profiles-daemon write the same settings: the last writer wins.
step_conflicts() {
  step "Competing tools"
  local svc found=0
  for svc in tlp tuned power-profiles-daemon; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      warn "$svc running: it will override cpu-powersave"
      note "systemctl disable --now $svc"
      found=1
    fi
  done
  if (( ! found )); then ok "No TLP, tuned or power-profiles-daemon"; fi
}

step_bin() {
  step "cpu-powersave command"
  tool >"$TMP/cpu-powersave"
  if replace_if_changed "$TMP/cpu-powersave" "$BIN" 755; then ok "Installed ($BIN)"; else ok "Already up to date"; fi
}

step_conf() {
  step "Saved profile"
  if [[ -f $CONF ]]; then
    ok "Kept: $(grep -E '^(TURBO|EPP)=' "$CONF" | paste -sd' ')"
    return
  fi
  # Balanced profile, in the save() format so the menu recognises it.
  write_if_changed "$CONF" 644 <<'EOF' || true
# Written by cpu-powersave - change it with the command: cpu-powersave
TURBO=off
EPP=balance_power
EOF
  ok "Balanced: TURBO=off EPP=balance_power"
}

step_service() {
  step "systemd service"
  if write_if_changed "$UNIT" 644 <<EOF
[Unit]
Description=CPU powersave (turbo, governor, EPP)
After=sysinit.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$BIN apply

[Install]
WantedBy=multi-user.target
EOF
  then
    systemctl daemon-reload
    ok "Unit written"
  else
    ok "Unit already up to date"
  fi
  systemctl enable --quiet cpu-powersave.service
  # restart: an active oneshot with RemainAfterExit does not run again on start.
  run "Applying the profile" systemctl restart cpu-powersave.service
}

check() {
  step "Checks"
  local turbo saved_turbo saved_epp epp gov bad pl1 pl2
  chk "Service running"                  systemctl is-active --quiet cpu-powersave.service
  chk "Service enabled at boot"          systemctl is-enabled --quiet cpu-powersave.service
  # shellcheck source=/dev/null
  saved_turbo=$(. "$CONF" 2>/dev/null && echo "${TURBO:-}" || true)
  # shellcheck source=/dev/null
  saved_epp=$(. "$CONF" 2>/dev/null && echo "${EPP:-}" || true)
  if [[ $(cat "$CPU/intel_pstate/no_turbo") == 1 ]]; then turbo=off; else turbo=on; fi
  # Every core, not just cpu0: a refused write on one core would go unnoticed.
  bad=$( { grep -L -x "$saved_epp" "$CPU"/cpu[0-9]*/cpufreq/energy_performance_preference || true; } | wc -l)
  epp=$(sort -u "$CPU"/cpu[0-9]*/cpufreq/energy_performance_preference | paste -sd' ')
  gov=$(sort -u "$CPU"/cpu[0-9]*/cpufreq/scaling_governor | paste -sd' ')
  chk "Turbo $turbo (profile: $saved_turbo)"   test "$turbo" = "$saved_turbo"
  chk "Governor $gov on every core"            test "$gov" = powersave
  chk "EPP $epp on every core"                 test "$bad" -eq 0
  chk "No refused write since boot"            bash -c "! journalctl -u cpu-powersave -b --no-pager -o cat | grep -q failed"
  pl1=$(rapl_w 0) pl2=$(rapl_w 1)
  if [[ -z $HL_CPU_PL1$HL_CPU_PL2 ]]; then
    note "BIOS: PL1 ${pl1:-?} W, PL2 ${pl2:-?} W"
  elif [[ $pl1 == "$HL_CPU_PL1" && $pl2 == "$HL_CPU_PL2" ]]; then
    ok "BIOS limits: PL1 $pl1 W, PL2 $pl2 W"
  else
    warn "BIOS: PL1 ${pl1:-?} W, PL2 ${pl2:-?} W instead of $HL_CPU_PL1 / $HL_CPU_PL2 W (BIOS reset?)"
  fi
  note "max frequencies: $(sort -nu "$CPU"/cpu[0-9]*/cpufreq/scaling_max_freq | awk '{printf "%s%d", sep, $1/1000; sep=" / "}') MHz"
}

uninstall() {
  step "Uninstall"
  local f
  confirm "Remove cpu-powersave and restore default turbo and EPP?" || die "cancelled, nothing changed"
  systemctl disable --now cpu-powersave.service >>"$LOG" 2>&1 || true
  rm -f "$UNIT" "$BIN" "$CONF"
  systemctl daemon-reload
  ok "Command, profile and service removed"
  if echo 0 >"$CPU/intel_pstate/no_turbo"; then ok "Turbo re-enabled"; else warn "turbo not re-enabled"; fi
  for f in "$CPU"/cpu[0-9]*/cpufreq/energy_performance_preference; do
    echo balance_performance >"$f" 2>/dev/null || warn "EPP not restored on $f"
  done
  ok "EPP back to balance_performance"
  note "the governor returns to the kernel default at next reboot"
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
  start pve/cpu-powersave "CPU throttling"
  require_pve 9
  require_intel_pstate

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
      run_steps step_settings step_conflicts step_bin step_conf step_service check
      mark_done
      finish "Done"
      next_steps "Change profile: cpu-powersave" ;;
  esac
  hl_exit
}

main "$@"
