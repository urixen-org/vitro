#!/usr/bin/env bash
# check.sh - configuration loading, validation and resource calculation.
# Source it for the functions, or run it for a dry-run report.

_CHECK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${_CHECK_DIR}/common.sh"

CFG_ERRORS=0
cfg_error() { err "config: $*"; CFG_ERRORS=$((CFG_ERRORS + 1)); }

check_enum() {  # check_enum VARNAME allowed...
  local n=$1 val=${!1} x; shift
  for x in "$@"; do [ "$val" = "$x" ] && return 0; done
  cfg_error "$n must be one of: $* (got '$val')"
}

resolve_path_var() {
  local n=$1 r
  if r=$(safe_path "${!n}"); then printf -v "$n" '%s' "$r"
  else cfg_error "$n must be an absolute path inside ${DATA_DIR} (got '${!n}')"; fi
}

load_config() {
  : "${RESERVED_RAM_MB:=100}"    "${MIN_GUEST_RAM_MB:=256}"  "${CPU_CORES:=2}"
  : "${DISK_SIZE:=20G}"          "${DISK_FORMAT:=raw}"       "${DISK_PATH:=${DATA_DIR}/disk.img}"
  : "${DISK_BUS:=virtio}"        "${DISK_CACHE:=writeback}"  "${AUTO_EXPAND_DISK:=false}"
  : "${ISO_URL:=}"               "${ISO_PATH:=${DATA_DIR}/iso/installer.iso}"
  : "${ISO_FILENAME:=}"          "${ISO_SHA256:=}"           "${OS_CHOICE:=}"
  : "${VM_NAME:=Linux VM}"       "${BOOT_MODE:=auto}"
  : "${ACCELERATION:=kvm}"       "${ALLOW_TCG_FALLBACK:=true}"
  : "${VNC_ENABLED:=true}"       "${VNC_PORT:=5900}"         "${VNC_PASSWORD:=}"
  : "${SHARED_DIR:=${DATA_DIR}/shared}" "${SHARED_TAG:=ptero_shared}"
  : "${SHARED_SECURITY:=mapped-xattr}"  "${SHARED_READONLY:=false}"
  : "${INSTALL_MODE:=auto}"      "${INSTALL_WATCH_INTERVAL:=5}"
  : "${ENABLE_SSH:=false}"       "${SSH_USER:=ptero}"        "${SSH_PUBLIC_KEY:=}"
  : "${NET_MODEL:=virtio-net-pci}" "${NET_RESTRICT:=false}"
  : "${QEMU_SANDBOX:=false}"     "${SHUTDOWN_TIMEOUT:=60}"
  : "${SERVER_MEMORY:=}"         "${PRIMARY_PORT:=}"
  # Pterodactyl always exports the primary allocation as SERVER_PORT; it wins over PRIMARY_PORT.
  if [ -n "${SERVER_PORT:-}" ]; then PRIMARY_PORT=$SERVER_PORT; fi
  ISO_SHA256=${ISO_SHA256,,}
  local v
  for v in DISK_FORMAT DISK_BUS DISK_CACHE BOOT_MODE ACCELERATION SHARED_SECURITY \
           INSTALL_MODE NET_MODEL OS_CHOICE; do printf -v "$v" '%s' "${!v,,}"; done
}

validate_config() {
  CFG_ERRORS=0
  local v re
  is_uint "$RESERVED_RAM_MB" || cfg_error "RESERVED_RAM_MB must be a non-negative integer (got '$RESERVED_RAM_MB')"
  { is_uint "$MIN_GUEST_RAM_MB" && (( MIN_GUEST_RAM_MB >= 64 )); } || cfg_error "MIN_GUEST_RAM_MB must be an integer >= 64"
  if [ -n "$SERVER_MEMORY" ]; then is_uint "$SERVER_MEMORY" || cfg_error "SERVER_MEMORY must be an integer (MB)"; fi
  { is_uint "$CPU_CORES" && (( CPU_CORES >= 1 && CPU_CORES <= 128 )); } || cfg_error "CPU_CORES must be 1-128 (got '$CPU_CORES')"
  size_to_bytes "$DISK_SIZE" >/dev/null || cfg_error "DISK_SIZE must look like 512M, 20G or 1T (got '$DISK_SIZE')"
  [ "$DISK_FORMAT" = raw ] || cfg_error "DISK_FORMAT must be 'raw' (QCOW2 and other formats are not supported)"
  check_enum DISK_BUS virtio ide nvme
  check_enum DISK_CACHE none writeback writethrough directsync
  check_enum BOOT_MODE auto bios uefi
  check_enum ACCELERATION kvm tcg auto
  check_enum SHARED_SECURITY mapped-xattr none
  check_enum INSTALL_MODE auto install installed
  check_enum NET_MODEL virtio-net-pci e1000 e1000e rtl8139
  for v in VNC_ENABLED ENABLE_SSH ALLOW_TCG_FALLBACK AUTO_EXPAND_DISK SHARED_READONLY NET_RESTRICT QEMU_SANDBOX; do
    is_bool "${!v}" || cfg_error "$v must be true or false (got '${!v}')"
  done
  { is_uint "$SHUTDOWN_TIMEOUT" && (( SHUTDOWN_TIMEOUT >= 1 && SHUTDOWN_TIMEOUT <= 3600 )); } || cfg_error "SHUTDOWN_TIMEOUT must be 1-3600"
  { is_uint "$INSTALL_WATCH_INTERVAL" && (( INSTALL_WATCH_INTERVAL >= 1 )); } || cfg_error "INSTALL_WATCH_INTERVAL must be >= 1"

  [[ "$VM_NAME" =~ ^[A-Za-z0-9._\ -]{1,64}$ ]] || cfg_error "VM_NAME may only contain letters, digits, space, '.', '_' and '-' (max 64)"
  [[ "$SHARED_TAG" =~ ^[A-Za-z0-9_]{1,31}$ ]] || cfg_error "SHARED_TAG must be 1-31 characters of [A-Za-z0-9_]"
  [[ "$OS_CHOICE" =~ ^[a-z0-9_-]*$ ]] || cfg_error "OS_CHOICE contains invalid characters"
  if [ -n "$ISO_SHA256" ]; then [[ "$ISO_SHA256" =~ ^[0-9a-f]{64}$ ]] || cfg_error "ISO_SHA256 must be 64 hex characters"; fi
  if [ -n "$ISO_FILENAME" ]; then
    [[ "$ISO_FILENAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.iso$ ]] || cfg_error "ISO_FILENAME must be a plain file name ending in .iso"
  fi
  if [ -n "$ISO_URL" ]; then
    [[ "$ISO_URL" =~ ^https?://[^[:space:]]+$ ]] || cfg_error "ISO_URL must be a direct http(s) URL without spaces"
    case "$ISO_URL" in *\"*|*\'*|*\`*|*\\*|*'<'*|*'>'*) cfg_error "ISO_URL contains forbidden characters" ;; esac
  fi

  resolve_path_var DISK_PATH
  resolve_path_var ISO_PATH
  resolve_path_var SHARED_DIR
  if [ -n "$ISO_FILENAME" ]; then ISO_PATH="${DATA_REAL}/iso/${ISO_FILENAME}"; fi

  if [ -n "$SHARED_DIR" ]; then
    case "${DISK_PATH}/" in "${SHARED_DIR}"/*) cfg_error "DISK_PATH must not be inside SHARED_DIR (the guest would see its own root disk)" ;; esac
    case "${CONFIG_DIR}/" in "${SHARED_DIR}"/*) cfg_error "SHARED_DIR must not contain ${CONFIG_DIR}" ;; esac
  fi

  if is_true "$VNC_ENABLED"; then
    { is_uint "$VNC_PORT" && (( VNC_PORT >= 5900 && VNC_PORT <= 65535 )); } || cfg_error "VNC_PORT must be 5900-65535 (QEMU maps display N to port 5900+N)"
    if [ -n "$VNC_PASSWORD" ]; then
      [[ "$VNC_PASSWORD" =~ ^[[:graph:]]{1,8}$ ]] || cfg_error "VNC_PASSWORD must be 1-8 printable characters without spaces (VNC limit)"
    fi
  fi
  if is_true "$ENABLE_SSH"; then
    { is_uint "$PRIMARY_PORT" && (( PRIMARY_PORT >= 1 && PRIMARY_PORT <= 65535 )); } \
      || cfg_error "ENABLE_SSH=true but no valid primary allocation port (SERVER_PORT is not set; got '${PRIMARY_PORT}')"
    if is_true "$VNC_ENABLED" && [ "$PRIMARY_PORT" = "$VNC_PORT" ]; then
      cfg_error "VNC_PORT must differ from the primary allocation port ($PRIMARY_PORT) used for SSH"
    fi
    [[ "$SSH_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || cfg_error "SSH_USER must be a valid lowercase Unix user name"
    if [ -n "$SSH_PUBLIC_KEY" ]; then
      re='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com) [A-Za-z0-9+/]+=*( [^[:cntrl:]]*)?$'
      [[ "$SSH_PUBLIC_KEY" =~ $re ]] || cfg_error "SSH_PUBLIC_KEY must be a single-line OpenSSH public key"
    fi
  fi
  (( CFG_ERRORS == 0 ))
}

compute_resources() {
  local cg_mb cg_cpu host_cpu
  EFFECTIVE_MEM_MB=
  if [ -n "$SERVER_MEMORY" ] && (( SERVER_MEMORY > 0 )); then EFFECTIVE_MEM_MB=$SERVER_MEMORY; fi
  cg_mb=$(cgroup_mem_limit_mb)
  if [ -n "$cg_mb" ] && { [ -z "$EFFECTIVE_MEM_MB" ] || (( cg_mb < EFFECTIVE_MEM_MB )); }; then
    if [ -n "$EFFECTIVE_MEM_MB" ]; then
      warn "container cgroup limit (${cg_mb} MB) is below SERVER_MEMORY (${EFFECTIVE_MEM_MB} MB); using the cgroup limit"
    fi
    EFFECTIVE_MEM_MB=$cg_mb
  fi
  if [ -z "$EFFECTIVE_MEM_MB" ]; then
    EFFECTIVE_MEM_MB=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)
    warn "no memory limit found (SERVER_MEMORY unset/0, no cgroup limit); using host MemTotal=${EFFECTIVE_MEM_MB} MB"
  fi
  VM_RAM_MB=$(( EFFECTIVE_MEM_MB - RESERVED_RAM_MB ))
  if (( VM_RAM_MB < MIN_GUEST_RAM_MB )); then
    err "Insufficient memory: limit ${EFFECTIVE_MEM_MB} MB - reserved ${RESERVED_RAM_MB} MB = ${VM_RAM_MB} MB, but MIN_GUEST_RAM_MB is ${MIN_GUEST_RAM_MB}. Raise the server's memory limit or lower RESERVED_RAM_MB/MIN_GUEST_RAM_MB."
    return 1
  fi
  if (( RESERVED_RAM_MB < 200 )); then
    warn "RESERVED_RAM_MB=${RESERVED_RAM_MB} is small: QEMU itself, 9p and page cache need headroom. If the container is OOM-killed, raise it (256+ recommended)."
  fi

  CPUS=$CPU_CORES
  host_cpu=$(nproc 2>/dev/null || echo 1)
  cg_cpu=$(cgroup_cpu_limit)
  if [ -n "$cg_cpu" ] && (( CPUS > cg_cpu )); then
    warn "CPU_CORES=${CPUS} exceeds the container CPU limit (${cg_cpu} core(s)); using ${cg_cpu}"; CPUS=$cg_cpu
  fi
  if (( CPUS > host_cpu )); then
    warn "CPU_CORES=${CPUS} exceeds available CPUs (${host_cpu}); using ${host_cpu}"; CPUS=$host_cpu
  fi
  return 0
}

select_acceleration() {
  case "$ACCELERATION" in
    tcg) ACCEL=tcg ;;
    kvm|auto)
      if kvm_usable; then ACCEL=kvm
      elif [ "$ACCELERATION" = auto ] || is_true "$ALLOW_TCG_FALLBACK"; then
        warn "KVM is not accessible (${KVM_DEVICE}); falling back to TCG software emulation (much slower)"
        ACCEL=tcg
      else
        err "ACCELERATION=kvm but ${KVM_DEVICE} is not accessible, and ALLOW_TCG_FALLBACK=false. See README: KVM passthrough."
        return 1
      fi ;;
  esac
  if [ "$ACCEL" = kvm ]; then CPU_MODEL=host; else CPU_MODEL=max; fi
}

decide_mode() {  # sets MODE=normal|install
  MODE=
  case "$INSTALL_MODE" in
    auto)    if [ -e "$INSTALLED_MARKER" ]; then MODE=normal; else MODE=install; fi ;;
    install) MODE=install
             if [ -e "$INSTALLED_MARKER" ]; then warn "INSTALL_MODE=install: entering installation mode although .installed exists (the disk is not touched)"; fi ;;
    installed)
      if [ ! -f "$DISK_PATH" ]; then err "INSTALL_MODE=installed requires an existing disk at ${DISK_PATH}"; return 1; fi
      if [ ! -e "$INSTALLED_MARKER" ]; then write_marker "declared by INSTALL_MODE=installed"; fi
      MODE=normal ;;
  esac
}

print_summary() {
  log "VM name        : ${VM_NAME}"
  log "Memory         : limit ${EFFECTIVE_MEM_MB} MB - reserved ${RESERVED_RAM_MB} MB = guest ${VM_RAM_MB} MB (min ${MIN_GUEST_RAM_MB})"
  log "vCPUs          : ${CPUS} (requested ${CPU_CORES})"
  log "Acceleration   : ${ACCEL} (cpu ${CPU_MODEL})"
  log "Disk           : ${DISK_PATH} (raw, bus ${DISK_BUS}, cache ${DISK_CACHE})"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  load_config
  validate_config || die "Configuration invalid (${CFG_ERRORS} error(s))"
  compute_resources || exit 1
  select_acceleration || exit 1
  print_summary
  log "Configuration OK"
fi
