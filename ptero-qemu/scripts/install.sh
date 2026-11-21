#!/usr/bin/env bash
# install.sh - installation mode: pick/download/validate an ISO, make sure a
# disk exists, then hand over to start.sh in "install" mode.
# Nothing from the ISO is ever executed or mounted on the container side.

set -uo pipefail
_INST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_DIR=${SCRIPT_DIR:-$_INST_DIR}; export SCRIPT_DIR
# shellcheck source=disk.sh
source "${_INST_DIR}/disk.sh"

DL_PID=
CURL_OPTS=(--proto '=http,https' --proto-redir '=http,https' --connect-timeout 20)

print_os_list() {
  log "Predefined operating systems (a convenience, NOT an allowlist):"
  log "  OS_CHOICE=alpine  Alpine Linux (virt)   https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/"
  log "  OS_CHOICE=debian  Debian netinst        https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/"
  log "  OS_CHOICE=ubuntu  Ubuntu Server 24.04   https://releases.ubuntu.com/24.04/"
  log "  OS_CHOICE=arch    Arch Linux            https://geo.mirror.pkgbuild.com/iso/latest/"
  log "  OS_CHOICE=rocky   Rocky Linux 9 minimal https://download.rockylinux.org/pub/rocky/9/isos/x86_64/"
  log "  Custom ISO: set ISO_URL to any direct http(s) link, or upload an .iso and set ISO_PATH."
}

# Resolves the newest matching file name from the vendor's directory listing.
os_resolve() {  # os_resolve <key>  -> RESOLVED_URL, RESOLVED_SHA_SOURCE, RESOLVED_SHA_MODE
  local key=$1 base re sums="" mode=none listing name
  case "$key" in
    alpine) base="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/"; re='alpine-virt-[0-9.]+-x86_64\.iso'; mode=sidecar ;;
    debian) base="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/"; re='debian-[0-9.]+-amd64-netinst\.iso'; sums=SHA256SUMS; mode=sums ;;
    ubuntu) base="https://releases.ubuntu.com/24.04/"; re='ubuntu-24\.04(\.[0-9]+)?-live-server-amd64\.iso'; sums=SHA256SUMS; mode=sums ;;
    arch)   base="https://geo.mirror.pkgbuild.com/iso/latest/"; re='archlinux-x86_64\.iso'; sums=sha256sums.txt; mode=sums ;;
    rocky)  base="https://download.rockylinux.org/pub/rocky/9/isos/x86_64/"; re='Rocky-9\.[0-9]+-x86_64-minimal\.iso' ;;
    *) err "unknown OS_CHOICE '$key' (valid: alpine debian ubuntu arch rocky). Use ISO_URL for anything else."; return 1 ;;
  esac
  log "Resolving latest '${key}' image from ${base}"
  listing=$(curl -fsSL "${CURL_OPTS[@]}" --max-time 60 "$base") || { err "could not fetch ${base}"; return 1; }
  name=$(printf '%s' "$listing" | grep -oE "$re" | sort -uV | tail -n1)
  [ -n "$name" ] || { err "no file matching ${re} found at ${base}; use ISO_URL instead"; return 1; }
  RESOLVED_URL="${base}${name}"; RESOLVED_SHA_MODE=$mode; RESOLVED_SHA_SOURCE=
  case "$mode" in
    sidecar) RESOLVED_SHA_SOURCE="${RESOLVED_URL}.sha256" ;;
    sums)    RESOLVED_SHA_SOURCE="${base}${sums}" ;;
  esac
  RESOLVED_NAME=$name
}

# Fetches the vendor checksum when ISO_SHA256 is not provided. Failure => warn, continue.
fetch_vendor_sha() {
  local body
  [ -n "${RESOLVED_SHA_SOURCE:-}" ] || return 0
  body=$(curl -fsSL "${CURL_OPTS[@]}" --max-time 60 "$RESOLVED_SHA_SOURCE" 2>/dev/null) || { warn "could not fetch vendor checksum; continuing without it"; return 0; }
  case "$RESOLVED_SHA_MODE" in
    sidecar) ISO_SHA256=$(printf '%s\n' "$body" | awk 'NR==1{print tolower($1)}') ;;
    sums)    ISO_SHA256=$(printf '%s\n' "$body" | awk -v f="$RESOLVED_NAME" '{n=$2; sub(/^\*/,"",n); if (n==f) {print tolower($1); exit}}') ;;
  esac
  [[ "$ISO_SHA256" =~ ^[0-9a-f]{64}$ ]] || { warn "vendor checksum unreadable; continuing without it"; ISO_SHA256=; return 0; }
  log "Using vendor SHA-256 ${ISO_SHA256}"
}

validate_iso() {  # ISO9660/UDF volume descriptor check
  local f=$1 size sig
  [ -f "$f" ] && [ -r "$f" ] || { err "ISO not readable: $f"; return 1; }
  size=$(file_size "$f")
  (( size >= 1048576 )) || { err "$f is only ${size} bytes - not an ISO image"; return 1; }
  sig=$(dd if="$f" bs=1 skip=32769 count=5 2>/dev/null)
  case "$sig" in
    CD001|BEA01) return 0 ;;
    *) err "$f has no ISO 9660/UDF signature (an HTML error page or wrong file?)"; return 1 ;;
  esac
}

verify_sha256() {  # verify_sha256 <file> <hex>
  log "Verifying SHA-256 (this can take a while for large ISOs)..."
  if printf '%s  %s\n' "$2" "$1" | sha256sum -c - >/dev/null 2>&1; then log "Checksum OK"; return 0; fi
  err "SHA-256 mismatch for $1 (expected $2)"; return 1
}

download_iso() {  # download_iso <url> <target>
  local url=$1 target=$2 part="${2}.part" total="" cur pct attempt rc
  mkdir -p -- "$(dirname "$target")" || return 1
  total=$(curl -fsSIL "${CURL_OPTS[@]}" --max-time 60 "$url" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="content-length:"{v=$2} END{print v}')
  [[ "$total" =~ ^[0-9]+$ ]] || total=""
  log "Downloading ${url}"
  [ -n "$total" ] && log "Size: $((total / 1048576)) MiB"
  [ -s "$part" ] && log "Resuming partial download ($(file_size "$part") bytes already present)"
  for attempt in 1 2; do
    curl -fL -sS "${CURL_OPTS[@]}" --retry 3 --retry-delay 5 -C - -o "$part" "$url" &
    DL_PID=$!
    while kill -0 "$DL_PID" 2>/dev/null; do
      sleep 10
      cur=$(file_size "$part" 2>/dev/null || echo 0)
      if [ -n "$total" ] && (( total > 0 )); then
        pct=$(( cur * 100 / total )); log "Progress: $((cur / 1048576)) / $((total / 1048576)) MiB (${pct}%)"
      else log "Progress: $((cur / 1048576)) MiB"; fi
    done
    wait "$DL_PID"; rc=$?; DL_PID=
    if [ "$rc" -eq 0 ]; then break; fi
    cur=$(file_size "$part" 2>/dev/null || echo 0)
    if [ "$rc" -eq 33 ] && [ -n "$total" ] && [ "$cur" = "$total" ]; then rc=0; break; fi   # already complete
    if [ "$rc" -eq 33 ] && [ "$attempt" -eq 1 ]; then warn "server refused to resume; restarting this temporary download"; rm -f -- "$part"; continue; fi
    err "download failed (curl exit ${rc}). The partial file is kept at ${part} and will be resumed on the next start."
    return 1
  done
  if ! validate_iso "$part"; then rm -f -- "$part"; return 1; fi
  if [ -n "$ISO_SHA256" ] && ! verify_sha256 "$part" "$ISO_SHA256"; then rm -f -- "$part"; return 1; fi
  if [ -e "$target" ]; then err "$target appeared during the download; not overwriting"; return 1; fi
  mv -n -- "$part" "$target" && [ ! -e "$part" ] || { err "could not move download into place"; return 1; }
  log "ISO saved to ${target}"
}

prepare_iso() {  # sets ISO_FILE
  local url=""
  if [ -e "$ISO_PATH" ]; then
    log "Using existing ISO ${ISO_PATH} (kept untouched)"
    validate_iso "$ISO_PATH" || return 1
    if [ -n "$ISO_SHA256" ]; then verify_sha256 "$ISO_PATH" "$ISO_SHA256" || return 1; fi
    ISO_FILE=$ISO_PATH; return 0
  fi
  if [ -n "$ISO_URL" ]; then
    url=$ISO_URL
    if [ -n "$OS_CHOICE" ] && [ "$OS_CHOICE" != custom ]; then log "ISO_URL is set; ignoring OS_CHOICE=${OS_CHOICE}"; fi
  elif [ -n "$OS_CHOICE" ] && [ "$OS_CHOICE" != custom ]; then
    os_resolve "$OS_CHOICE" || return 1
    url=$RESOLVED_URL
    [ -n "$ISO_SHA256" ] || fetch_vendor_sha
  else
    err "No ISO available: ${ISO_PATH} does not exist and neither ISO_URL nor OS_CHOICE is set."
    err "Fix: set OS_CHOICE (see list above), set ISO_URL to a direct .iso link, or upload an ISO via the File Manager to ${ISO_PATH} (or set ISO_PATH)."
    return 1
  fi
  download_iso "$url" "$ISO_PATH" || return 1
  ISO_FILE=$ISO_PATH
}

on_term() {
  warn "interrupted"
  if [ -n "$DL_PID" ]; then kill "$DL_PID" 2>/dev/null; fi
  exit 143
}

install_main() {
  load_config
  validate_config || die "Configuration invalid (${CFG_ERRORS} error(s))"
  compute_resources >/dev/null || exit 1       # fail before downloading gigabytes
  mkdir -p -- "$CONFIG_DIR" "${DATA_DIR}/iso" || die "cannot create state directories under ${DATA_DIR}"
  trap on_term INT TERM
  log "=== Installation mode (.installed not present or INSTALL_MODE=install) ==="
  print_os_list
  prepare_iso || exit 1
  disk_ensure || exit 1
  [ -e "${CONFIG_DIR}/install.state" ] || printf 'started %s\n' "$(date -u +%FT%TZ)" > "${CONFIG_DIR}/install.state"
  trap - INT TERM
  export ISO_FILE
  exec "${_INST_DIR}/start.sh" install
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then install_main "$@"; fi
