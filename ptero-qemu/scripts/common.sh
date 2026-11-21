#!/usr/bin/env bash
# common.sh - shared helpers (meant to be sourced).
# Every environment value is treated as DATA. Nothing in this runtime uses eval.

[ -n "${_PTERO_COMMON:-}" ] && return 0
_PTERO_COMMON=1

: "${DATA_DIR:=/home/container}"
: "${RUN_DIR:=/tmp/ptero-vm}"
: "${CGROUP_ROOT:=/sys/fs/cgroup}"
: "${KVM_DEVICE:=/dev/kvm}"
: "${SCRIPT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
: "${PTERO_ROOT:=$(dirname "$SCRIPT_DIR")}"

DATA_DIR=${DATA_DIR%/}
DATA_REAL=$(realpath -m -- "$DATA_DIR")
CONFIG_DIR="${DATA_DIR}/config"
INSTALLED_MARKER="${DATA_DIR}/.installed"
PID_FILE="${RUN_DIR}/qemu.pid"
QMP_SOCK="${RUN_DIR}/qmp.sock"

log()  { printf '[ptero-vm] %s\n' "$*"; }
warn() { printf '[ptero-vm] WARNING: %s\n' "$*" >&2; }
err()  { printf '[ptero-vm] ERROR: %s\n' "$*" >&2; }
die()  { err "$*"; exit "${DIE_CODE:-1}"; }

is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
is_true() { case "${1,,}" in true|1|yes|on) return 0 ;; *) return 1 ;; esac; }
is_bool() { case "${1,,}" in true|false|1|0|yes|no|on|off) return 0 ;; *) return 1 ;; esac; }

file_size() { stat -c %s -- "$1"; }

# "20G" -> bytes. Accepts M, G, T suffixes only.
size_to_bytes() {
  local n u
  [[ "${1:-}" =~ ^([1-9][0-9]*)([MGT])$ ]] || return 1
  n=${BASH_REMATCH[1]}; u=${BASH_REMATCH[2]}
  case "$u" in
    M) echo $((n * 1048576)) ;;
    G) echo $((n * 1073741824)) ;;
    T) echo $((n * 1099511627776)) ;;
  esac
}

# Resolve a path and make sure it lives strictly inside DATA_DIR (symlinks resolved).
safe_path() {
  local p=${1:-} r
  [[ "$p" == /* ]] || return 1
  [[ "$p" == *'/../'* || "$p" == */.. ]] && return 1
  r=$(realpath -m -- "$p") || return 1
  [[ "$r" == "$DATA_REAL"/* ]] || return 1
  printf '%s' "$r"
}

# ---- cgroup limits (v2 first, then v1) -------------------------------------
cgroup_mem_limit_mb() {
  local f v
  for f in "$CGROUP_ROOT/memory.max" "$CGROUP_ROOT/memory/memory.limit_in_bytes"; do
    [ -r "$f" ] || continue
    v=$(<"$f")
    [[ "$v" =~ ^[0-9]+$ ]] || continue            # "max" => unlimited
    (( v >= 1125899906842624 )) && continue       # v1 "unlimited" is a huge number
    echo $(( v / 1048576 )); return 0
  done
  return 0
}

cgroup_cpu_limit() {  # whole cores (rounded up), empty when unlimited
  local q="" p=""
  if [ -r "$CGROUP_ROOT/cpu.max" ]; then
    read -r q p < "$CGROUP_ROOT/cpu.max"
  elif [ -r "$CGROUP_ROOT/cpu/cpu.cfs_quota_us" ]; then
    q=$(<"$CGROUP_ROOT/cpu/cpu.cfs_quota_us")
    p=$(<"$CGROUP_ROOT/cpu/cpu.cfs_period_us")
  fi
  [[ "$q" =~ ^[0-9]+$ && "$p" =~ ^[0-9]+$ ]] || return 0
  (( p > 0 )) || return 0
  echo $(( (q + p - 1) / p ))
}

kvm_usable() { [ -e "$KVM_DEVICE" ] && ( exec 3<>"$KVM_DEVICE" ) 2>/dev/null; }

port_in_use() { ( exec 3<>"/dev/tcp/127.0.0.1/$1" ) 2>/dev/null; }

# ---- process helpers ---------------------------------------------------------
pid_alive() {  # alive and not a zombie
  local s
  [ -r "/proc/$1/stat" ] || return 1
  s=$(sed 's/^.*) //' "/proc/$1/stat" | cut -c1)
  [ "$s" != "Z" ]
}

qemu_running() {  # sets QEMU_RUNNING_PID
  QEMU_RUNNING_PID=
  [ -r "$PID_FILE" ] || return 1
  local pid; pid=$(<"$PID_FILE")
  is_uint "$pid" || return 1
  pid_alive "$pid" || return 1
  tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q qemu || return 1
  QEMU_RUNNING_PID=$pid
}

qmp_send() {  # qmp_send <command-name>
  [ -S "$QMP_SOCK" ] || return 1
  command -v socat >/dev/null 2>&1 || return 1
  { printf '{"execute":"qmp_capabilities"}\n{"execute":"%s"}\n' "$1"; sleep 1; } \
    | socat -T3 - "UNIX-CONNECT:${QMP_SOCK}" >/dev/null 2>&1
}

# ACPI power button -> wait -> QMP quit -> SIGKILL as the very last resort.
vm_shutdown() {  # vm_shutdown <pid> <timeout-seconds>
  local pid=$1 timeout=${2:-60} i
  log "Requesting guest shutdown via ACPI (waiting up to ${timeout}s)..."
  qmp_send system_powerdown || warn "could not reach the QMP socket"
  for ((i = 0; i < timeout; i++)); do
    pid_alive "$pid" || { log "Guest powered off cleanly."; return 0; }
    sleep 1
  done
  warn "Guest did not power off in time; asking QEMU to quit (disk may need a fsck)"
  qmp_send quit || true
  for i in 1 2 3 4 5; do pid_alive "$pid" || return 0; sleep 1; done
  warn "QEMU still running; sending SIGKILL"
  kill -KILL "$pid" 2>/dev/null || true
}

# ---- installation marker -----------------------------------------------------
write_marker() {  # write_marker <reason>
  local tmp="${INSTALLED_MARKER}.tmp.$$"
  printf 'installed %s (%s)\n' "$(date -u +%FT%TZ)" "$1" > "$tmp" && mv -f "$tmp" "$INSTALLED_MARKER"
}

install_confirmed() {
  [ -e "${CONFIG_DIR}/install-complete" ] || [ -e "${SHARED_DIR:-${DATA_DIR}/shared}/.install-complete" ]
}

confirm_install() {
  local disk=${DISK_PATH:-${DATA_DIR}/disk.img}
  if [ ! -s "$disk" ]; then err "refusing to confirm: disk $disk is missing or empty"; return 1; fi
  write_marker "confirmed" || return 1
  rm -f "${CONFIG_DIR}/install-complete" "${SHARED_DIR:-${DATA_DIR}/shared}/.install-complete" 2>/dev/null || true
  log "Installation confirmed. .installed created; the next start boots from the disk only."
}
