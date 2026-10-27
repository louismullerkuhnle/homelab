# shellcheck shell=bash disable=SC2034  # variables read by the scripts that load this library
# Shared library for the scripts: output, log, settings, helpers.
# Loaded by every script, from the local clone or from GitHub.

HL_CONF=/etc/homelab.conf
HL_STATE=/var/lib/homelab
HL_LOGS=/var/log/homelab
NAME='' LOG=''
APT=(apt-get -yq -o DPkg::Lock::Timeout=600)
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

# --- Output: one line per action, full command output in $LOG ---------------------------------------

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  TTY=1 B=$'\033[1m' DIM=$'\033[2m' GRN=$'\033[32m' YEL=$'\033[33m' RED=$'\033[31m' RST=$'\033[0m' CLR=$'\r\033[K'
else
  TTY=0 B='' DIM='' GRN='' YEL='' RED='' RST='' CLR=''
fi
STEP=0 TOTAL=0 WARNINGS=0 FAILS=0 RUN_PID='' RUN_START=1

step() {
  STEP=$((STEP + 1))
  if (( TOTAL )); then printf '\n%s[%d/%d] %s%s\n' "$B" "$STEP" "$TOTAL" "$*" "$RST"; else printf '\n%s%s%s\n' "$B" "$*" "$RST"; fi
  if [[ -n $LOG ]]; then printf '\n=== %s\n' "$*" >>"$LOG"; fi
}
ok()   { printf '%s  %s✓%s %s\n' "$CLR" "$GRN" "$RST" "$*"; }
skip() { printf '%s  %s– %s%s\n' "$CLR" "$DIM" "$*" "$RST"; }
warn() { WARNINGS=$((WARNINGS + 1)); printf '%s  %s!%s %s\n' "$CLR" "$YEL" "$RST" "$*" >&2; }
ko()   { FAILS=$((FAILS + 1)); printf '%s  %s✗%s %s\n' "$CLR" "$RED" "$RST" "$*" >&2; }
note() { printf '    %s%s%s\n' "$DIM" "$*" "$RST"; }
die()  {
  ko "$*"
  if [[ -n $LOG ]]; then printf '    %slog: %s%s\n' "$DIM" "$LOG" "$RST" >&2; fi
  exit 1
}

# Runs "$@" with its output in $LOG and a spinner on screen; returns the command's exit code.
spin() {
  local desc=$1 rc=0 i=0 frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  shift
  printf -- '--- %s\n$ %s\n' "$desc" "$*" >>"$LOG"
  RUN_START=$(( $(wc -l <"$LOG") + 1 ))
  if (( TTY )); then
    "$@" >>"$LOG" 2>&1 </dev/null &
    RUN_PID=$!
    while kill -0 "$RUN_PID" 2>/dev/null; do
      printf '\r  %s %s' "${frames[i++ % 10]}" "$desc"
      sleep 0.1
    done
    wait "$RUN_PID" || rc=$?
    RUN_PID=''
  else
    "$@" >>"$LOG" 2>&1 </dev/null || rc=$?
  fi
  return "$rc"
}
# Required action: ✓, or the tail of its output and stop.
run() {
  local desc=$1 rc=0
  spin "$@" || rc=$?
  if (( rc == 0 )); then ok "$desc"; return 0; fi
  printf '%s' "$CLR"
  tail -n +"$RUN_START" "$LOG" | tail -n 15 | sed 's/^/    │ /' >&2
  die "$desc (exit $rc)"
}
# Check: ✓ or ✗, without stopping the script.
chk() {
  local desc=$1
  if spin "$@"; then ok "$desc"; else ko "$desc"; fi
}
next_steps() {
  local i=0 s
  printf '\n%sNext%s\n' "$B" "$RST"
  for s in "$@"; do i=$((i + 1)); printf '  %d. %s\n' "$i" "$s"; done
}
# Summary: label if all good, otherwise number of failed checks; duration and warnings.
finish() {
  local extra
  if (( SECONDS < 60 )); then extra="$SECONDS s"; else extra=$(printf '%d min %02d s' $((SECONDS / 60)) $((SECONDS % 60))); fi
  if (( WARNINGS )); then extra+=" · $WARNINGS warning(s)"; fi
  if (( FAILS )); then
    printf '\n%s%s✗ %d issue(s) to fix%s  %s%s%s\n' "$B" "$RED" "$FAILS" "$RST" "$DIM" "$extra" "$RST"
  else
    printf '\n%s%s✓ %s%s  %s%s%s\n' "$B" "$GRN" "$1" "$RST" "$DIM" "$extra" "$RST"
  fi
}

# --- Lifecycle ---------------------------------------------------------------------------------------

TMP=$(mktemp -d)
on_int() {
  printf '%s\n' "$CLR" >&2
  if [[ -n $RUN_PID ]]; then warn "interrupted: the running command (pid $RUN_PID) keeps going in the background"; fi
  exit 130
}
trap on_int INT
trap 'rm -rf "$TMP"' EXIT
trap 'die "failed at line $LINENO: $BASH_COMMAND"' ERR

# start <folder/name> <title>: root, log, header.
start() {
  NAME=$1
  [[ $EUID -eq 0 ]] || die "must run as root (sudo)"
  install -d -m 700 "$HL_LOGS"
  LOG=$HL_LOGS/${NAME//\//-}.log
  [[ -f $LOG ]] || install -m 600 /dev/null "$LOG"
  printf '\n##### %s  %s\n' "$(date '+%F %T')" "$NAME" >>"$LOG"
  printf '%s%s · %s%s  %s%s%s\n' "$B" "$NAME" "$2" "$RST" "$DIM" "$(hostname)" "$RST"
  printf '%slog: %s%s\n' "$DIM" "$LOG" "$RST"
}
# Runs the steps in order, numbered [n/N].
run_steps() {
  local s
  TOTAL=$#
  for s; do "$s"; done
}
mark_done()    { install -d -m 755 "$HL_STATE"; date '+%F' >"$HL_STATE/${NAME//\//-}.done"; }
mark_undone()  { rm -f "$HL_STATE/${NAME//\//-}.done"; }
require_done() { [[ -f $HL_STATE/${1//\//-}.done ]] || die "run $1 first"; }
hl_exit()      { if (( FAILS )); then exit 1; fi; exit 0; }

require_ubuntu() {
  local id ver
  # shellcheck source=/dev/null
  id=$(. /etc/os-release && echo "${ID:-}")
  # shellcheck source=/dev/null
  ver=$(. /etc/os-release && echo "${VERSION_ID:-}")
  [[ $id == ubuntu ]] || die "Ubuntu expected, found: ${id:-?}"
  [[ $ver == "$1" ]] || warn "written for Ubuntu $1, found $ver"
}
require_pve() {
  command -v pveversion >/dev/null || die "Proxmox VE host expected"
  pveversion | grep -q "pve-manager/$1\." || warn "written for Proxmox VE $1, found $(pveversion | cut -d/ -f2)"
}

# --- Settings ----------------------------------------------------------------------------------------
# Priority: environment variable, then /etc/homelab.conf, then a question (with a proposed default).
# The chosen value is saved: the question is asked once, --reconfigure asks again.
# ASK=0 (--check mode): never asks, uses the default when nothing is saved.

ASK=1 RECONFIGURE=0

conf_has() { [[ -f $HL_CONF ]] && grep -q "^$1=" "$HL_CONF"; }
conf_get() { grep -m1 "^$1=" "$HL_CONF" | cut -d= -f2-; }
conf_set() {
  if conf_has "$1" && [[ $(conf_get "$1") == "$2" ]]; then return 0; fi
  [[ -f $HL_CONF ]] || printf '# Settings of the homelab scripts, saved on first run.\n' >"$HL_CONF"
  { grep -v "^$1=" "$HL_CONF" || true; printf '%s=%s\n' "$1" "$2"; } >"$TMP/conf"
  install -m 644 -o root -g root "$TMP/conf" "$HL_CONF"
}

# setting <VAR> <question> <default> [<regex>]: answering "-" clears the value.
setting() {
  local var=$1 question=$2 default=$3 re=${4:-} value
  if [[ -n ${!var+x} ]]; then
    value=${!var}
  elif conf_has "$var" && (( ! RECONFIGURE || ! ASK )); then
    value=$(conf_get "$var")
  else
    if conf_has "$var"; then default=$(conf_get "$var"); fi
    value=$default
    if (( ASK )) && has_tty; then
      while :; do
        ask value "$question [${default:-empty}]"
        if [[ -z $value ]]; then value=$default; elif [[ $value == - ]]; then value=''; fi
        if [[ -z $re || $value =~ $re ]]; then break; fi
        warn "rejected value: $value"
      done
    fi
  fi
  [[ -z $re || $value =~ $re ]] || die "invalid $var: $value"
  printf -v "$var" '%s' "$value"
  if (( ASK )); then conf_set "$var" "$value"; fi
}

# --- Helpers -----------------------------------------------------------------------------------------

# With `curl | bash`, stdin is the script itself: answers are read from /dev/tty.
has_tty() { { : </dev/tty; } 2>/dev/null; }

# ask / ask_secret <variable> <question>: the input line is cleared afterwards.
ask() {
  local __answer
  has_tty || die "input required: run from a terminal (ssh -t)"
  read -rp "  $2: " __answer </dev/tty
  if (( TTY )); then printf '\033[1A\033[2K' >&2; fi
  printf -v "$1" '%s' "$__answer"
}
ask_secret() {
  local __answer
  has_tty || die "input required: run from a terminal (ssh -t)"
  read -rsp "  $2: " __answer </dev/tty
  echo >&2
  if (( TTY )); then printf '\033[1A\033[2K' >&2; fi
  printf -v "$1" '%s' "$__answer"
}
confirm() {
  local answer
  ask answer "$1 Type \"yes\""
  [[ $answer == yes ]]
}

# replace_if_changed <source> <destination> <mode>: replaces only if content differs; 0 if replaced.
replace_if_changed() {
  if [[ -f $2 ]] && cmp -s "$1" "$2"; then return 1; fi
  # Explicit die: called inside an if, where set -e does not apply.
  install -m "$3" -o root -g root "$1" "$2" || die "cannot write $2"
}
# write_if_changed <destination> <mode> <<content
write_if_changed() {
  local tmp
  tmp=$(mktemp -p "$TMP")
  cat >"$tmp"
  replace_if_changed "$tmp" "$1" "$2"
}

is_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'ok installed'; }

# add_apt_repo <label> <key url> <key file> <sources file> <sources content> <fingerprint>...
# Every primary key in the downloaded file must be one of the expected fingerprints.
add_apt_repo() {
  local label=$1 key_url=$2 keyring=$3 sources=$4 content=$5 fprs f
  shift 5
  if ! command -v gpg >/dev/null; then run "Installing gnupg" "${APT[@]}" install gnupg; fi
  run "$label repository key" curl -fsSL "$key_url" -o "$TMP/key"
  fprs=$(gpg --show-keys --with-colons "$TMP/key" 2>/dev/null | awk -F: '$1=="pub"{p=1; next} $1=="fpr" && p {print $10; p=0}')
  [[ -n $fprs ]] || die "$label repository key is unreadable"
  for f in $fprs; do
    [[ " $* " == *" $f "* ]] || die "unexpected $label repository key ($f): check the official source"
  done
  install -d -m 755 "${keyring%/*}"
  replace_if_changed "$TMP/key" "$keyring" 644 || true
  write_if_changed "$sources" 644 <<<"$content" || true
  ok "$label repository, key verified"
}
