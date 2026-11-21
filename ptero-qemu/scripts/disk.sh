#!/usr/bin/env bash
# disk.sh - RAW disk management. Never overwrites, never shrinks.
#   disk.sh info | check | create | expand <SIZE>

_DISK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=check.sh
source "${_DISK_DIR}/check.sh"

disk_magic_hex() { od -An -tx1 -N4 -- "$1" 2>/dev/null | tr -d ' \n'; }

disk_validate() {  # disk_validate <path>
  local p=$1 size magic
  [ -e "$p" ] || { err "disk image not found: $p"; return 1; }
  [ -f "$p" ] || { err "$p is not a regular file"; return 1; }
  if [ ! -r "$p" ] || [ ! -w "$p" ]; then err "$p is not readable/writable by uid $(id -u)"; return 1; fi
  size=$(file_size "$p")
  (( size > 0 )) || { err "$p is empty (0 bytes)"; return 1; }
  magic=$(disk_magic_hex "$p")
  case "$magic" in
    514649fb) err "$p is a QCOW2 image. Only RAW is supported; converting offline: qemu-img convert -f qcow2 -O raw old.qcow2 disk.img"; return 1 ;;
    4b444d56) err "$p is a VMDK image. Only RAW is supported; convert it offline with qemu-img convert -O raw."; return 1 ;;
  esac
  if command -v qemu-img >/dev/null 2>&1; then
    qemu-img info -U -f raw -- "$p" >/dev/null 2>&1 || { err "qemu-img cannot read $p as a RAW image"; return 1; }
  fi
  return 0
}

disk_create() {  # disk_create <path> <size>   (sparse; refuses to clobber)
  local path=$1 size=$2 bytes tmp
  bytes=$(size_to_bytes "$size") || { err "invalid disk size '$size'"; return 1; }
  if [ -e "$path" ] || [ -L "$path" ]; then err "refusing to create: $path already exists"; return 1; fi
  mkdir -p -- "$(dirname "$path")" || return 1
  tmp="${path}.creating.$$"
  truncate -s "$bytes" -- "$tmp" || { rm -f -- "$tmp"; err "could not create $tmp"; return 1; }
  # hard link == atomic "create only if absent"
  if ln -- "$tmp" "$path" 2>/dev/null; then rm -f -- "$tmp"
  else rm -f -- "$tmp"; err "$path appeared while creating it; not overwriting"; return 1; fi
  log "Created sparse RAW disk ${path} (${size}, 0 bytes allocated)"
}

disk_expand() {  # disk_expand <path> <newsize>
  local path=$1 newsize=$2 cur new
  if qemu_running; then err "the VM is running (pid ${QEMU_RUNNING_PID}); stop the server before resizing"; return 1; fi
  disk_validate "$path" || return 1
  new=$(size_to_bytes "$newsize") || { err "invalid size '$newsize' (examples: 40G, 512M)"; return 1; }
  cur=$(file_size "$path")
  if (( new < cur )); then err "refusing to shrink ${path} from ${cur} to ${new} bytes"; return 1; fi
  if (( new == cur )); then log "Disk is already ${newsize}; nothing to do"; return 0; fi
  truncate -s "$new" -- "$path" || return 1
  log "Grew ${path}: ${cur} -> ${new} bytes. Now grow the partition and filesystem inside the guest."
}

disk_ensure() {  # install mode: create when absent, otherwise validate and keep
  if [ -e "$DISK_PATH" ]; then
    disk_validate "$DISK_PATH" || return 1
    log "Using existing disk ${DISK_PATH} ($(file_size "$DISK_PATH") bytes). It is never overwritten."
  else
    disk_create "$DISK_PATH" "$DISK_SIZE"
  fi
}

disk_auto_expand() {  # honours AUTO_EXPAND_DISK / reports mismatches
  local want cur
  want=$(size_to_bytes "$DISK_SIZE") || return 0
  cur=$(file_size "$DISK_PATH")
  if (( want > cur )); then
    if is_true "$AUTO_EXPAND_DISK"; then disk_expand "$DISK_PATH" "$DISK_SIZE" || return 1
    else log "DISK_SIZE (${DISK_SIZE}) is larger than the disk; set AUTO_EXPAND_DISK=true or run 'ptero-vm disk expand ${DISK_SIZE}' to grow it."; fi
  elif (( want < cur )); then
    log "DISK_SIZE (${DISK_SIZE}) is smaller than the existing disk; ignored (disks are never shrunk)."
  fi
}

disk_main() {
  local cmd=${1:-info}
  load_config
  validate_config || die "Configuration invalid"
  case "$cmd" in
    info)   disk_validate "$DISK_PATH" && { log "path: $DISK_PATH"; log "size: $(file_size "$DISK_PATH") bytes"; du -h --apparent-size "$DISK_PATH" | cut -f1 | sed 's/^/[ptero-vm] apparent: /'; du -h "$DISK_PATH" | cut -f1 | sed 's/^/[ptero-vm] allocated: /'; } ;;
    check)  disk_validate "$DISK_PATH" && log "Disk OK" ;;
    create) disk_create "$DISK_PATH" "${2:-$DISK_SIZE}" ;;
    expand) [ -n "${2:-}" ] || die "usage: disk.sh expand <SIZE>"; disk_expand "$DISK_PATH" "$2" ;;
    *)      die "usage: disk.sh info|check|create [SIZE]|expand <SIZE>" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then disk_main "$@"; fi
