#!/usr/bin/env bash
# Test suite for the runtime. Uses a fake QEMU, temp dirs and fake cgroup/KVM paths;
# needs only bash + coreutils (+ socat for the graceful-shutdown test).
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
ENTRY="$ROOT/scripts/entrypoint.sh"
PASS=0; FAIL=0; SKIP=0

setup() {
  T=$(mktemp -d)
  mkdir -p "$T/data/iso" "$T/data/config" "$T/run" "$T/cg" "$T/bin"
  cp "$HERE/fake-qemu.sh" "$T/bin/qemu-system-x86_64"; chmod +x "$T/bin/qemu-system-x86_64"
  export PATH="$T/bin:$PATH" DATA_DIR="$T/data" RUN_DIR="$T/run" CGROUP_ROOT="$T/cg" KVM_DEVICE="$T/kvm"
  export FAKE_QEMU_ARGS_FILE="$T/qemu.args" FAKE_QMP_LOG="$T/qmp.log" FAKE_QEMU_MODE=exit
  export SERVER_MEMORY=1024 RESERVED_RAM_MB=100 CPU_CORES=1 DISK_SIZE=64M ACCELERATION=tcg
  export BOOT_MODE=bios VNC_ENABLED=false SHUTDOWN_TIMEOUT=10 INSTALL_WATCH_INTERVAL=1
  unset SERVER_PORT PRIMARY_PORT ISO_URL OS_CHOICE ISO_SHA256 ISO_FILENAME INSTALL_MODE ENABLE_SSH
  export SHARED_SECURITY=none
}
mk_iso() { dd if=/dev/zero of="$1" bs=1M count=2 status=none; printf 'CD001' | dd of="$1" bs=1 seek=32769 conv=notrunc status=none; }
mk_installed() { dd if=/dev/zero of="$DATA_DIR/disk.img" bs=1M count=1 status=none; echo installed > "$DATA_DIR/.installed"; }
run_entry() { "$ENTRY" run >"$T/out.log" 2>&1 </dev/null; RC=$?; }

fail() { echo "    FAIL: $*"; echo "    --- output ---"; sed 's/^/    | /' "$T/out.log" 2>/dev/null | tail -n 25; exit 1; }
assert_rc()      { [ "$RC" -eq "$1" ] || fail "expected exit $1, got $RC"; }
assert_rc_nz()   { [ "$RC" -ne 0 ] || fail "expected non-zero exit"; }
assert_file()    { [ -e "$1" ] || fail "missing $1"; }
assert_nofile()  { [ ! -e "$1" ] || fail "unexpected $1"; }
assert_out()     { grep -qE -- "$1" "$T/out.log" || fail "output lacks /$1/"; }
assert_arg()     { grep -qE -- "$1" "$FAKE_QEMU_ARGS_FILE" || fail "qemu args lack /$1/"; }
assert_noarg()   { ! grep -qE -- "$1" "$FAKE_QEMU_ARGS_FILE" || fail "qemu args unexpectedly match /$1/"; }

t_fresh_install() {
  mk_iso "$DATA_DIR/iso/installer.iso"; run_entry
  assert_rc 0; assert_file "$DATA_DIR/disk.img"; assert_nofile "$DATA_DIR/.installed"
  assert_arg 'installer.iso'; assert_arg 'bootindex=2'; assert_out 'Installation NOT confirmed'
}
t_install_confirmed_by_guest() {
  mk_iso "$DATA_DIR/iso/installer.iso"
  FAKE_QEMU_MODE=confirm FAKE_CONFIRM_FILE="$DATA_DIR/shared/.install-complete" run_entry
  assert_rc 0; assert_file "$DATA_DIR/.installed"; assert_nofile "$DATA_DIR/shared/.install-complete"
}
t_interrupted_install_resumes() {
  mk_iso "$DATA_DIR/iso/installer.iso"; run_entry; assert_rc 0
  local before; before=$(sha256sum "$DATA_DIR/disk.img" | cut -d' ' -f1)
  run_entry; assert_rc 0; assert_nofile "$DATA_DIR/.installed"; assert_arg 'installer.iso'
  [ "$before" = "$(sha256sum "$DATA_DIR/disk.img" | cut -d' ' -f1)" ] || fail "disk changed"
}
t_existing_marker_boots_disk() {
  mk_iso "$DATA_DIR/iso/installer.iso"; mk_installed; run_entry
  assert_rc 0; assert_arg 'disk.img'; assert_noarg 'installer.iso'; assert_noarg 'media=cdrom'; assert_file "$DATA_DIR/iso/installer.iso"
}
t_missing_iso() {
  run_entry; assert_rc_nz; assert_out 'No ISO available'; assert_nofile "$DATA_DIR/disk.img"; assert_nofile "$DATA_DIR/.installed"
}
t_invalid_iso_rejected() {
  head -c 3000000 /dev/zero > "$DATA_DIR/iso/installer.iso"; run_entry
  assert_rc_nz; assert_out 'no ISO 9660'; assert_file "$DATA_DIR/iso/installer.iso"
}
t_iso_checksum_mismatch() {
  mk_iso "$DATA_DIR/iso/installer.iso"
  ISO_SHA256=$(printf 'x' | sha256sum | cut -d' ' -f1) run_entry
  assert_rc_nz; assert_out 'mismatch'; assert_file "$DATA_DIR/iso/installer.iso"
}
t_missing_disk() {
  echo installed > "$DATA_DIR/.installed"; run_entry
  assert_rc_nz; assert_out 'Disk image .* is missing'; assert_nofile "$DATA_DIR/disk.img"
}
t_existing_disk_preserved() {
  mk_iso "$DATA_DIR/iso/installer.iso"
  printf 'precious-data' > "$DATA_DIR/disk.img"; truncate -s 8M "$DATA_DIR/disk.img"
  local before; before=$(sha256sum "$DATA_DIR/disk.img" | cut -d' ' -f1)
  DISK_SIZE=1G run_entry
  assert_rc 0; [ "$before" = "$(sha256sum "$DATA_DIR/disk.img" | cut -d' ' -f1)" ] || fail "existing disk modified"
  [ "$(stat -c %s "$DATA_DIR/disk.img")" -eq 8388608 ] || fail "disk size changed without AUTO_EXPAND/disk expand"
}
t_qcow2_refused() {
  mk_iso "$DATA_DIR/iso/installer.iso"; printf '\x51\x46\x49\xfb' > "$DATA_DIR/disk.img"; truncate -s 4M "$DATA_DIR/disk.img"
  run_entry; assert_rc_nz; assert_out 'QCOW2'
}
t_disk_expand_and_no_shrink() {
  mk_installed; truncate -s 8M "$DATA_DIR/disk.img"
  "$ENTRY" disk expand 16M >"$T/out.log" 2>&1; RC=$?; assert_rc 0
  [ "$(stat -c %s "$DATA_DIR/disk.img")" -eq 16777216 ] || fail "not grown"
  "$ENTRY" disk expand 8M >"$T/out.log" 2>&1; RC=$?; assert_rc_nz; assert_out 'refusing to shrink'
}
t_insufficient_memory() {
  mk_iso "$DATA_DIR/iso/installer.iso"; SERVER_MEMORY=300 run_entry
  assert_rc_nz; assert_out 'Insufficient memory'; assert_nofile "$DATA_DIR/disk.img"
}
t_cgroup_limit_respected() {
  mk_installed; echo $((512 * 1048576)) > "$T/cg/memory.max"; run_entry
  assert_rc 0; assert_out 'guest 412 MB'; assert_arg '^412M$'
}
t_reserved_ram_configurable() {
  mk_installed; RESERVED_RAM_MB=324 run_entry; assert_rc 0; assert_arg '^700M$'
}
t_kvm_unavailable_falls_back() {
  mk_installed; ACCELERATION=kvm run_entry
  assert_rc 0; assert_out 'falling back to TCG'; assert_arg 'accel=tcg'
}
t_kvm_unavailable_strict() {
  mk_installed; ACCELERATION=kvm ALLOW_TCG_FALLBACK=false run_entry
  assert_rc_nz; assert_out 'not accessible'
}
t_kvm_used_when_available() {
  mk_installed; : > "$KVM_DEVICE"; ACCELERATION=kvm run_entry
  assert_rc 0; assert_arg 'accel=kvm'; assert_arg '^host$'
}
t_container_restart() {
  mk_iso "$DATA_DIR/iso/installer.iso"; mk_installed
  local before; before=$(sha256sum "$DATA_DIR/disk.img" | cut -d' ' -f1)
  run_entry; assert_rc 0; assert_nofile "$RUN_DIR/qemu.pid"
  run_entry; assert_rc 0
  [ "$before" = "$(sha256sum "$DATA_DIR/disk.img" | cut -d' ' -f1)" ] || fail "disk changed across restarts"
  assert_file "$DATA_DIR/.installed"
}
t_duplicate_process_refused() {
  mk_installed; sleep 300 & local p=$!
  # emulate a live qemu by naming the pid file's process via a qemu-looking command
  cp "$(command -v sleep)" "$T/bin/qemu-fake-sleep"; "$T/bin/qemu-fake-sleep" 300 & p=$!
  mkdir -p "$RUN_DIR"; echo "$p" > "$RUN_DIR/qemu.pid"
  run_entry; kill "$p" 2>/dev/null; assert_rc_nz; assert_out 'already running'
}
t_cpu_cgroup_clamp() {
  mk_installed; echo "100000 100000" > "$T/cg/cpu.max"; CPU_CORES=4 run_entry
  assert_rc 0; assert_arg '^1,sockets=1,cores=1,threads=1$'
}
t_ssh_forward_uses_server_port() {
  mk_installed; ENABLE_SSH=true SERVER_PORT=24999 run_entry
  assert_rc 0; assert_arg 'hostfwd=tcp::24999-:22'
  assert_file "$DATA_DIR/shared/ptero-ssh/provision-ssh.sh"
}
t_ssh_disabled_no_forward() {
  mk_installed; ENABLE_SSH=false SERVER_PORT=24999 run_entry
  assert_rc 0; assert_noarg 'hostfwd'
}
t_ssh_needs_port() {
  mk_installed; ENABLE_SSH=true run_entry; assert_rc_nz; assert_out 'primary allocation port'
}
t_shared_9p_args() {
  mk_installed; run_entry
  assert_arg 'mount_tag=ptero_shared'; assert_arg 'virtio-9p-pci'; assert_arg 'security_model=none'; assert_arg 'path=.*/shared'
}
t_shared_dir_cannot_hold_disk() {
  mk_installed; SHARED_DIR="$DATA_DIR" run_entry; assert_rc_nz
  SHARED_DIR="/etc" run_entry; assert_rc_nz; assert_out 'inside'
}
t_bad_env_rejected() {
  mk_installed; DISK_FORMAT=qcow2 run_entry; assert_rc_nz; assert_out 'raw'
  CPU_CORES='2;touch /tmp/pwned' run_entry; assert_rc_nz; assert_nofile /tmp/pwned
}
t_graceful_shutdown() {
  command -v socat >/dev/null || { echo "    (skipped: socat missing)"; return 77; }
  mk_installed
  FAKE_QEMU_MODE=wait "$ENTRY" run >"$T/out.log" 2>&1 </dev/null & local p=$!
  local i; for i in $(seq 1 50); do [ -S "$RUN_DIR/qmp.sock" ] && break; sleep 0.2; done
  [ -S "$RUN_DIR/qmp.sock" ] || { kill "$p" 2>/dev/null; fail "QMP socket never appeared"; }
  kill -TERM "$p"; wait "$p"; RC=$?
  assert_rc 0; grep -q system_powerdown "$FAKE_QMP_LOG" || fail "no system_powerdown sent"
  assert_out 'Guest powered off cleanly'; assert_nofile "$RUN_DIR/qemu.pid"
}

run_one() {
  local t=$1 rc
  printf '%-40s ' "$t"
  ( setup; "$t" ) >"${TMPDIR:-/tmp}/ptero-test.out" 2>&1; rc=$?
  case $rc in
    0)  echo PASS; PASS=$((PASS + 1)) ;;
    77) echo SKIP; SKIP=$((SKIP + 1)) ;;
    *)  echo FAIL; sed 's/^/  /' "${TMPDIR:-/tmp}/ptero-test.out"; FAIL=$((FAIL + 1)) ;;
  esac
}

TESTS=$(declare -F | awk '{print $3}' | grep '^t_')
for t in $TESTS; do run_one "$t"; done
echo; echo "passed=$PASS failed=$FAIL skipped=$SKIP"
[ "$FAIL" -eq 0 ]
