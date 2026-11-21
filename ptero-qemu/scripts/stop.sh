#!/usr/bin/env bash
# stop.sh - gracefully stop a running VM (ACPI powerdown, then quit, then kill).
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/common.sh"
qemu_running || { log "No running VM found."; exit 0; }
vm_shutdown "$QEMU_RUNNING_PID" "${SHUTDOWN_TIMEOUT:-60}"
