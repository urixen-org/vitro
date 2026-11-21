#!/usr/bin/env bash
# start.sh <normal|install> - builds the QEMU command line (as an array, never
# through eval), starts QEMU, tracks its PID and handles SIGTERM/SIGINT.

set -uo pipefail
_START_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_DIR=${SCRIPT_DIR:-$_START_DIR}; export SCRIPT_DIR
# shellcheck source=disk.sh
source "${_START_DIR}/disk.sh"

MODE=${1:-normal}
case "$MODE" in normal|install) ;; *) die "usage: start.sh normal|install" ;; esac

STOPPING=0; QEMU_PID=; WATCHER_PID=
QEMU_CMD=()

cleanup() {
  if [ -n "${WATCHER_PID:-}" ]; then kill "$WATCHER_PID" 2>/dev/null; fi
  rm -f -- "$PID_FILE" "$QMP_SOCK" "${RUN_DIR}/vnc.pass"
  return 0
}
trap cleanup EXIT

on_signal() {
  STOPPING=$((STOPPING + 1))
  [ -n "$QEMU_PID" ] || exit 143
  if (( STOPPING == 1 )); then
    log "Stop requested."
    vm_shutdown "$QEMU_PID" "$SHUTDOWN_TIMEOUT"
  else
    warn "Second signal received: killing QEMU immediately"
    kill -KILL "$QEMU_PID" 2>/dev/null
  fi
}
trap on_signal INT TERM

# ---- firmware ---------------------------------------------------------------
find_ovmf() {  # sets OVMF_CODE_FILE / OVMF_VARS_TEMPLATE_FILE
  local codes=(/usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF_CODE.fd /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/ovmf/OVMF_CODE.fd)
  local vars=(/usr/share/OVMF/OVMF_VARS.fd /usr/share/ovmf/OVMF_VARS.fd /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/ovmf/OVMF_VARS.fd)
  local i
  OVMF_CODE_FILE=; OVMF_VARS_TEMPLATE_FILE=
  if [ -n "${OVMF_CODE:-}" ] && [ -n "${OVMF_VARS_TEMPLATE:-}" ] && [ -f "$OVMF_CODE" ] && [ -f "$OVMF_VARS_TEMPLATE" ]; then
    OVMF_CODE_FILE=$OVMF_CODE; OVMF_VARS_TEMPLATE_FILE=$OVMF_VARS_TEMPLATE; return 0
  fi
  for i in "${!codes[@]}"; do
    if [ -f "${codes[$i]}" ] && [ -f "${vars[$i]}" ]; then OVMF_CODE_FILE=${codes[$i]}; OVMF_VARS_TEMPLATE_FILE=${vars[$i]}; return 0; fi
  done
  return 1
}

# The boot mode is pinned the first time a disk is used: switching BIOS<->UEFI later breaks the installed OS.
resolve_boot_mode() {
  local f="${CONFIG_DIR}/boot_mode" saved="" want=$BOOT_MODE
  [ -r "$f" ] && saved=$(<"$f")
  if [ "$want" = auto ]; then
    if [ -n "$saved" ]; then want=$saved
    elif find_ovmf; then want=uefi
    else want=bios; fi
  elif [ -n "$saved" ] && [ "$saved" != "$want" ]; then
    warn "BOOT_MODE=${want} differs from the mode this VM was installed with (${saved}); the installed OS may not boot."
  fi
  if [ "$want" = uefi ] && ! find_ovmf; then
    err "BOOT_MODE=uefi but no OVMF firmware was found in the image. Use BOOT_MODE=bios or rebuild the image with the 'ovmf' package."
    return 1
  fi
  [ -n "$saved" ] || printf '%s\n' "$want" > "$f"
  BOOT_MODE_EFFECTIVE=$want
}

# ---- shared folder ----------------------------------------------------------
prepare_shared() {
  if [ ! -d "$SHARED_DIR" ]; then mkdir -p -- "$SHARED_DIR" && chmod 0750 -- "$SHARED_DIR" || return 1; fi
  SHARED_MODEL=$SHARED_SECURITY
  if [ "$SHARED_MODEL" = mapped-xattr ]; then
    local probe="${SHARED_DIR}/.xattr-probe.$$"
    if ! { : > "$probe" && command -v setfattr >/dev/null 2>&1 && setfattr -n user.virtfs.probe -v 1 -- "$probe"; } 2>/dev/null; then
      warn "extended attributes are not usable in ${SHARED_DIR}; falling back to SHARED_SECURITY=none (guest chown/chmod will not persist)"
      SHARED_MODEL=none
    fi
    rm -f -- "$probe"
  fi
}

prepare_ssh_files() {  # guest-side helper + authorized key, published through the shared folder
  local d="${SHARED_DIR}/ptero-ssh"
  mkdir -p -- "$d" || return 1
  cp -f -- "${PTERO_ROOT}/guest/provision-ssh.sh" "$d/provision-ssh.sh" && chmod 0755 -- "$d/provision-ssh.sh"
  printf '%s\n' "$SSH_USER" > "$d/user"
  if [ -n "$SSH_PUBLIC_KEY" ]; then printf '%s\n' "$SSH_PUBLIC_KEY" > "$d/authorized_keys"; fi
}

# ---- VNC --------------------------------------------------------------------
prepare_vnc() {
  local pw=$VNC_PASSWORD f="${CONFIG_DIR}/vnc-password"
  VNC_DISPLAY=$((VNC_PORT - 5900)); VNC_GENERATED=false
  if [ -z "$pw" ]; then
    if [ -s "$f" ]; then pw=$(<"$f")
    else
      pw=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 8) || true
      [ "${#pw}" -eq 8 ] || { err "could not generate a VNC password"; return 1; }
      ( umask 077; printf '%s' "$pw" > "$f" ) || return 1
    fi
    VNC_GENERATED=true
  fi
  VNC_PASSWORD_EFFECTIVE=$pw
  ( umask 077; printf '%s' "$pw" > "${RUN_DIR}/vnc.pass" ) || return 1
}

# ---- command line -----------------------------------------------------------
build_qemu_args() {
  local netdev disk_dev cd_bus=ide.1
  QEMU_CMD=(qemu-system-x86_64
    -name "${VM_NAME},process=qemu-vm"
    -machine "q35,accel=${ACCEL}"
    -cpu "$CPU_MODEL"
    -smp "${CPUS},sockets=1,cores=${CPUS},threads=1"
    -m "${VM_RAM_MB}M"
    -nodefaults -no-user-config
    -display none
    -serial mon:stdio
    -qmp "unix:${QMP_SOCK},server=on,wait=off"
    -object rng-random,id=rng0,filename=/dev/urandom
    -device virtio-rng-pci,rng=rng0)

  if is_true "$QEMU_SANDBOX"; then
    QEMU_CMD+=(-sandbox "on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny")
  fi

  if [ "$BOOT_MODE_EFFECTIVE" = uefi ]; then
    local vars="${CONFIG_DIR}/OVMF_VARS.fd"
    [ -e "$vars" ] || cp -- "$OVMF_VARS_TEMPLATE_FILE" "$vars" || return 1
    QEMU_CMD+=(-drive "if=pflash,format=raw,unit=0,readonly=on,file=${OVMF_CODE_FILE}"
               -drive "if=pflash,format=raw,unit=1,file=${vars}")
  fi

  # Root disk always has bootindex=1. In install mode the ISO is bootindex=2, so an
  # empty disk falls through to the installer and an installed disk wins afterwards.
  QEMU_CMD+=(-drive "file=${DISK_PATH},format=raw,if=none,id=disk0,cache=${DISK_CACHE},discard=unmap,detect-zeroes=unmap")
  case "$DISK_BUS" in
    virtio) QEMU_CMD+=(-device "virtio-blk-pci,drive=disk0,bootindex=1") ;;
    nvme)   QEMU_CMD+=(-device "nvme,drive=disk0,serial=ptero0,bootindex=1") ;;
    ide)    QEMU_CMD+=(-device "ide-hd,drive=disk0,bus=ide.0,bootindex=1") ;;
  esac
  if [ "$MODE" = install ]; then
    QEMU_CMD+=(-drive "file=${ISO_FILE},format=raw,if=none,id=cd0,media=cdrom,readonly=on"
               -device "ide-cd,drive=cd0,bus=${cd_bus},bootindex=2")
  fi

  netdev="user,id=net0"
  if is_true "$NET_RESTRICT"; then netdev+=",restrict=on"; fi
  if is_true "$ENABLE_SSH"; then netdev+=",hostfwd=tcp::${PRIMARY_PORT}-:22"; fi
  QEMU_CMD+=(-netdev "$netdev" -device "${NET_MODEL},netdev=net0")

  local ro=off; is_true "$SHARED_READONLY" && ro=on
  QEMU_CMD+=(-fsdev "local,id=fsdev0,path=${SHARED_DIR},security_model=${SHARED_MODEL},readonly=${ro}"
             -device "virtio-9p-pci,fsdev=fsdev0,mount_tag=${SHARED_TAG}")

  if is_true "$VNC_ENABLED"; then
    QEMU_CMD+=(-object "secret,id=vncsec,file=${RUN_DIR}/vnc.pass"
               -vnc "0.0.0.0:${VNC_DISPLAY},password-secret=vncsec"
               -device VGA -device qemu-xhci,id=xhci -device usb-tablet,bus=xhci.0)
  fi
}

watch_install() {
  while :; do
    sleep "$INSTALL_WATCH_INTERVAL"
    if install_confirmed; then confirm_install; return 0; fi
  done
}

banner() {
  print_summary
  log "Boot mode      : ${BOOT_MODE_EFFECTIVE}   mode: ${MODE}"
  [ "$MODE" = install ] && log "Installer ISO  : ${ISO_FILE}"
  log "Shared folder  : ${SHARED_DIR} (tag ${SHARED_TAG}, security ${SHARED_MODEL}, readonly ${SHARED_READONLY})"
  log "  guest mount  : mkdir -p /mnt/ptero && mount -t 9p -o trans=virtio,version=9p2000.L ${SHARED_TAG} /mnt/ptero"
  if is_true "$VNC_ENABLED"; then
    log "VNC            : port ${VNC_PORT} (must be an allocation of this server)"
    [ "$VNC_GENERATED" = true ] && log "VNC password   : ${VNC_PASSWORD_EFFECTIVE} (generated; stored in ${CONFIG_DIR}/vnc-password)"
  else log "VNC            : disabled (serial console only)"; fi
  if is_true "$ENABLE_SSH"; then
    log "SSH            : ${SERVER_IP:-<server-ip>}:${PRIMARY_PORT} -> guest TCP 22 (guest must run sshd; see ${SHARED_DIR}/ptero-ssh/)"
  else log "SSH            : disabled"; fi
  if [ "$MODE" = install ]; then
    log "To finish installation: after the installed OS boots, run  touch /mnt/ptero/.install-complete  in the guest,"
    log "  or create the empty file config/install-complete in the File Manager. Until then .installed is NOT written."
  fi
}

main() {
  load_config
  validate_config || die "Configuration invalid (${CFG_ERRORS} error(s))"
  compute_resources || exit 1
  select_acceleration || exit 1
  command -v qemu-system-x86_64 >/dev/null 2>&1 || die "qemu-system-x86_64 not found in PATH"

  mkdir -p -- "$RUN_DIR" "$CONFIG_DIR" || die "cannot create runtime directories"
  chmod 0700 -- "$RUN_DIR"
  if qemu_running; then die "A QEMU process is already running (pid ${QEMU_RUNNING_PID}); refusing to start a second one"; fi
  rm -f -- "$PID_FILE" "$QMP_SOCK"

  if [ "$MODE" = normal ]; then
    [ -e "$INSTALLED_MARKER" ] || die "Not installed (.installed missing); run in install mode instead"
    if [ ! -e "$DISK_PATH" ]; then
      die "Disk image ${DISK_PATH} is missing although .installed exists. Refusing to create a blank disk over an installed VM. Restore the disk, or remove ${INSTALLED_MARKER} and set INSTALL_MODE=install to reinstall."
    fi
    disk_validate "$DISK_PATH" || exit 1
    disk_auto_expand || exit 1
  else
    [ -n "${ISO_FILE:-}" ] && [ -f "$ISO_FILE" ] || die "install mode needs ISO_FILE (run through install.sh)"
    disk_validate "$DISK_PATH" || exit 1
  fi

  prepare_shared || die "cannot prepare shared folder ${SHARED_DIR}"
  if is_true "$ENABLE_SSH"; then prepare_ssh_files || warn "could not write guest SSH helper files"; fi
  resolve_boot_mode || exit 1
  is_true "$VNC_ENABLED" && { prepare_vnc || exit 1; }

  if is_true "$VNC_ENABLED" && port_in_use "$VNC_PORT"; then die "VNC port ${VNC_PORT} is already in use inside the container"; fi
  if is_true "$ENABLE_SSH" && port_in_use "$PRIMARY_PORT"; then die "Primary port ${PRIMARY_PORT} is already in use inside the container"; fi

  build_qemu_args || exit 1
  banner

  "${QEMU_CMD[@]}" <&0 &
  QEMU_PID=$!
  printf '%s\n' "$QEMU_PID" > "$PID_FILE"
  log "QEMU started (pid ${QEMU_PID})"
  if [ "$MODE" = install ]; then watch_install & WATCHER_PID=$!; fi

  local rc=0
  while :; do
    wait "$QEMU_PID"; rc=$?
    pid_alive "$QEMU_PID" || break
  done
  if (( STOPPING > 0 )); then rc=0; fi
  log "QEMU exited with status ${rc}"
  if (( rc != 0 )) && [ "$ACCEL" = kvm ]; then log "Hint: if the error mentions KVM, check ${KVM_DEVICE} permissions or set ACCELERATION=tcg."; fi

  if [ "$MODE" = install ]; then
    if install_confirmed; then confirm_install; fi
    if [ ! -e "$INSTALLED_MARKER" ]; then
      log "Installation NOT confirmed: .installed was not created. The next start resumes installation (disk and ISO are preserved)."
    fi
  fi
  exit "$rc"
}

main
