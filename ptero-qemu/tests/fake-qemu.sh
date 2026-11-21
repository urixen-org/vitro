#!/usr/bin/env bash
# Fake qemu-system-x86_64 for tests. Behaviour is selected with FAKE_QEMU_MODE:
#   exit (default)  record args, exit FAKE_QEMU_RC
#   confirm         touch $FAKE_CONFIRM_FILE (simulates the guest signalling completion), exit
#   wait            serve a QMP socket and exit when "system_powerdown" arrives
: "${FAKE_QEMU_ARGS_FILE:?}"
printf '%s\n' "$@" > "$FAKE_QEMU_ARGS_FILE"
sock=""
for a in "$@"; do case "$a" in unix:*) sock=${a#unix:}; sock=${sock%%,*} ;; esac; done
case "${FAKE_QEMU_MODE:-exit}" in
  exit) exit "${FAKE_QEMU_RC:-0}" ;;
  confirm) touch "${FAKE_CONFIRM_FILE:?}"; exit 0 ;;
  wait)
    log="${FAKE_QMP_LOG:?}"; : > "$log"
    socat "UNIX-LISTEN:${sock},fork" "SYSTEM:cat >> ${log}" &
    srv=$!
    trap 'kill $srv 2>/dev/null; exit 0' TERM
    until grep -q system_powerdown "$log" 2>/dev/null; do sleep 0.2; done
    kill "$srv" 2>/dev/null; exit 0 ;;
esac
