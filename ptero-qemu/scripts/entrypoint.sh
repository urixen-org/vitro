#!/usr/bin/env bash
# entrypoint.sh - image entrypoint. Decides install vs. normal start.
# The Pterodactyl STARTUP string is deliberately NOT evaluated.
#   entrypoint.sh [run|check|disk ...|stop|confirm-install|shell|help]

set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); export SCRIPT_DIR
source "${SCRIPT_DIR}/check.sh"
umask 027

cmd=${1:-run}; (( $# )) && shift

case "$cmd" in
  run)
    load_config
    validate_config || die "Configuration invalid (${CFG_ERRORS} error(s)); see messages above"
    mkdir -p -- "$CONFIG_DIR" "${DATA_DIR}/iso" "$SHARED_DIR" 2>/dev/null || true
    decide_mode || exit 1
    if [ "$MODE" = normal ]; then exec "${SCRIPT_DIR}/start.sh" normal
    else exec "${SCRIPT_DIR}/install.sh"; fi ;;
  check)           exec "${SCRIPT_DIR}/check.sh" ;;
  disk)            exec "${SCRIPT_DIR}/disk.sh" "$@" ;;
  stop)            exec "${SCRIPT_DIR}/stop.sh" ;;
  confirm-install) load_config; validate_config || exit 1; confirm_install ;;
  shell)           exec bash ;;
  help|-h|--help)  echo "usage: ptero-vm [run|check|disk info|disk check|disk expand SIZE|stop|confirm-install|shell]" ;;
  *)               die "unknown command '$cmd' (try: ptero-vm help)" ;;
esac
