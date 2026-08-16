#!/usr/bin/env bash
# =============================================================================
#  Nebosvod — weather proxy service
#  Standalone LXC installer for Proxmox VE (single file, no external includes)
#
#  Usage (on the Proxmox host, as root):
#    bash -c "$(curl -fsSL <URL>)"
#  or locally:
#    bash /root/weather-proxy/install/nebosvod-standalone.sh
#
#  Optional environment variables:
#    NEBO_CTID    — preferred container ID (default: 200, first free >= it)
#    NEBO_STORAGE — rootfs storage override (default: auto-detect a
#                   rootdir-capable storage preferring local*/tank*, else local-lvm)
#    NEBO_GIT_URL — git source URL for the Nebosvod repo (default: GitHub;
#                   use http://192.168.0.100/Amofess/nebosvod.git for local Forgejo)
# =============================================================================

set -Eeuo pipefail

# -----------------------------------------------------------------------------
# Output helpers (community-scripts style colors)
# -----------------------------------------------------------------------------
C_BLUE='\033[1;34m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[1;31m'; C_RESET='\033[0m'
msg_info()  { echo -e "${C_BLUE}[ INFO ]${C_RESET} $*"; }
msg_ok()    { echo -e "${C_GREEN}[  OK  ]${C_RESET} $*"; }
msg_warn()  { echo -e "${C_YELLOW}[ WARN ]${C_RESET} $*" >&2; }
msg_error() { echo -e "${C_RED}[ ERROR ]${C_RESET} $*" >&2; }
die()       { msg_error "$*"; exit 1; }

# -----------------------------------------------------------------------------
# Environment sanity checks
# -----------------------------------------------------------------------------
check_env() {
  [ "$(id -u)" -eq 0 ] || die "This script must be run as root on the Proxmox VE host."
  command -v pct  >/dev/null 2>&1 || die "'pct' not found — are you on a Proxmox VE host?"
  command -v pvesm >/dev/null 2>&1 || die "'pvesm' not found."
  command -v pveam >/dev/null 2>&1 || die "'pveam' not found."
}

# -----------------------------------------------------------------------------
# Detect rootfs storage (--rootfs <storage>:2)
# -----------------------------------------------------------------------------
detect_storage() {
  local stor=""

  if [ -n "${NEBO_STORAGE:-}" ]; then
    stor="${NEBO_STORAGE}"
    msg_info "Using rootfs storage override: ${stor}"
  else
    # Prefer a rootdir-capable storage whose name matches local*/tank*
    stor=$(pvesm status -content rootdir 2>/dev/null \
             | awk 'NR>1 {print $1}' \
             | grep -Ei '^(local|tank)' \
             | head -1)
    # Otherwise take any storage that supports the rootdir content type
    if [ -z "$stor" ]; then
      stor=$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {print $1}' | head -1)
    fi
    # Final fallback
    [ -z "$stor" ] && stor="local-lvm"
    msg_ok "Detected rootfs storage: ${stor}"
  fi

  STORAGE="$stor"
}

# -----------------------------------------------------------------------------
# Detect template storage (local:vztmpl/... by default)
# -----------------------------------------------------------------------------
detect_template_storage() {
  local stor="local"
  if ! pvesm status -content vztmpl 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "local"; then
    stor=$(pvesm status -content vztmpl 2>/dev/null | awk 'NR>1 {print $1}' | head -1)
  fi
  [ -n "$stor" ] || die "No storage with 'vztmpl' content type found."
  TEMPLATE_STORAGE="$stor"
  msg_ok "Template storage: ${TEMPLATE_STORAGE}"
}

# -----------------------------------------------------------------------------
# Container ID selection
# -----------------------------------------------------------------------------
ct_exists() {
  local id="$1"
  [ -f "/etc/pve/lxc/${id}.conf" ] && return 0
  pct status "$id" >/dev/null 2>&1
}

select_ctid() {
  local start=200

  if [ -n "${NEBO_CTID:-}" ]; then
    case "${NEBO_CTID}" in
      ''|*[!0-9]*) die "NEBO_CTID must be a positive integer (got: '${NEBO_CTID}')." ;;
    esac
    start="${NEBO_CTID}"
    msg_info "Requested CTID via NEBO_CTID: ${start}"
  fi

  local ctid="$start"
  local warned=0
  while ct_exists "$ctid"; do
    if [ "$warned" -eq 0 ] && [ -n "${NEBO_CTID:-}" ]; then
      msg_warn "CTID ${NEBO_CTID} is already in use — using the next free ID."
      warned=1
    fi
    ctid=$((ctid + 1))
    [ "$ctid" -gt 999999 ] && die "No free container ID found (searched up to 999999)."
  done

  CTID="$ctid"
  msg_ok "Selected container ID: ${CTID}"
}

# -----------------------------------------------------------------------------
# Ensure the Alpine template is present (download if missing)
# -----------------------------------------------------------------------------
ensure_template() {
  local tpl=""

  # 1) Prefer an already-downloaded alpine template on the host (no download).
  tpl=$(pveam list "${TEMPLATE_STORAGE}" 2>/dev/null \
          | grep -oE 'alpine-[0-9.]+-default_[0-9]+_amd64\.tar\.xz' \
          | sort -V | tail -1)
  if [ -n "$tpl" ]; then
    msg_ok "Using already-downloaded template: ${tpl}"
    TEMPLATE="${tpl}"
    return 0
  fi

  # 2) Otherwise pick the latest available alpine template and download it.
  tpl=$(pveam available 2>/dev/null \
          | grep -E 'alpine-[0-9.]+-default_.*_amd64\.tar\.xz' \
          | awk '{print $2}' \
          | sort -V | tail -1)
  if [ -n "$tpl" ]; then
    msg_info "No alpine template downloaded — downloading ${tpl} into '${TEMPLATE_STORAGE}' ..."
    pveam update >/dev/null 2>&1 || msg_warn "pveam update failed (continuing with cached list)."
    pveam download "${TEMPLATE_STORAGE}" "${tpl}" || die "Failed to download template ${tpl}."
    msg_ok "Template ${tpl} downloaded."
    TEMPLATE="${tpl}"
    return 0
  fi

  # 3) Neither downloaded nor available — report the catalog contents and bail out.
  msg_error "Unable to resolve an alpine-*-default_*_amd64.tar.xz template."
  msg_error "Already downloaded (pveam list ${TEMPLATE_STORAGE}):"
  pveam list "${TEMPLATE_STORAGE}" 2>/dev/null || true
  msg_error "Available in catalog (pveam available):"
  pveam available 2>/dev/null || true
  die "No alpine template could be found or downloaded."
}

# -----------------------------------------------------------------------------
# Create the LXC container
# -----------------------------------------------------------------------------
create_container() {
  msg_info "Creating LXC container ${CTID} (hostname=nebosvod, 1 core, 512MB, 2GB rootfs on '${STORAGE}') ..."
  pct create "${CTID}" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname nebosvod \
    --cores 1 \
    --memory 512 \
    --swap 0 \
    --rootfs "${STORAGE}:2" \
    --net0 "name=eth0,bridge=vmbr0,ip=dhcp" \
    --unprivileged 1 \
    --features nesting=1 \
    --ostype alpine || die "pct create failed."
  msg_ok "Container ${CTID} created."
}

# -----------------------------------------------------------------------------
# Start the container and wait until it is ready
# -----------------------------------------------------------------------------
start_container() {
  msg_info "Starting container ${CTID} ..."
  pct start "${CTID}" || die "pct start failed."

  msg_info "Waiting for container to boot (up to 60s) ..."
  local ready=0
  for _ in $(seq 1 60); do
    if pct exec "${CTID}" -- sh -c 'command -v apk' >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  [ "$ready" -eq 1 ] || die "Container ${CTID} did not become ready within 60s."
  msg_ok "Container ${CTID} is up."
}

# -----------------------------------------------------------------------------
# Install dependencies, clone the app, create config
# -----------------------------------------------------------------------------
install_app() {
  msg_info "Installing python3 and git inside the container ..."
  pct exec "${CTID}" -- apk add --no-cache python3 git || die "apk add failed."

  msg_info "Cloning Nebosvod into /opt/nebosvod ..."
  local repo_url="${NEBO_GIT_URL:-https://github.com/AmoFess/nebosvod.git}"
  pct exec "${CTID}" -- env GIT_TERMINAL_PROMPT=0 git clone "$repo_url" /opt/nebosvod \
    || die "git clone failed (check network access inside the container)."

  msg_info "Creating config.json from config.json.example ..."
  pct exec "${CTID}" -- cp /opt/nebosvod/config.json.example /opt/nebosvod/config.json \
    || die "Failed to create config.json."
  msg_ok "Application installed."
}

# -----------------------------------------------------------------------------
# Create and enable the OpenRC service
# -----------------------------------------------------------------------------
install_service() {
  msg_info "Writing OpenRC service /etc/init.d/nebosvod ..."
  pct exec "${CTID}" -- sh -c 'cat > /etc/init.d/nebosvod' <<'EOF'
#!/sbin/openrc-run

name="nebosvod"
description="Nebosvod weather proxy service"

command="/usr/bin/python3"
command_args="/opt/nebosvod/server.py"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"

depend() {
    need net
}
EOF
  pct exec "${CTID}" -- chmod +x /etc/init.d/nebosvod || die "chmod failed."
  pct exec "${CTID}" -- rc-update add nebosvod default || die "rc-update add failed."

  msg_info "Starting nebosvod service ..."
  pct exec "${CTID}" -- rc-service nebosvod start || die "rc-service start failed."
  sleep 2
  if pct exec "${CTID}" -- rc-service nebosvod status >/dev/null 2>&1; then
    msg_ok "Service 'nebosvod' is running and enabled at boot."
  else
    msg_warn "Service status unknown — check: pct exec ${CTID} -- rc-service nebosvod status"
  fi
}

# -----------------------------------------------------------------------------
# Determine the container IP address
# -----------------------------------------------------------------------------
get_ip() {
  msg_info "Determining container IP address ..."
  local ip=""

  # Primary: parse `ip -4 addr show eth0` (grep runs on the host => GNU grep -P)
  for _ in $(seq 1 20); do
    ip=$(pct exec "${CTID}" -- ip -4 addr show eth0 2>/dev/null \
           | grep -oPm1 'inet \K[\d.]+' || true)
    [ -n "$ip" ] && break
    sleep 1
  done

  # Fallback 1: hostname -I (busybox)
  if [ -z "$ip" ]; then
    ip=$(pct exec "${CTID}" -- hostname -I 2>/dev/null | awk '{print $1; exit}' || true)
  fi

  # Fallback 2: read from pct config
  if [ -z "$ip" ]; then
    ip=$(pct config "${CTID}" 2>/dev/null | grep -oPm1 'ip=\K[\d.]+' || true)
  fi

  IP="$ip"
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
print_summary() {
  echo
  msg_ok "Nebosvod installation finished!"
  if [ -n "$IP" ] && [ "$IP" != "dhcp" ]; then
    msg_ok "Service URL: http://${IP}:8080"
  else
    msg_warn "Could not auto-detect the IP. Find it with:"
    msg_warn "  pct exec ${CTID} -- ip -4 addr show eth0"
    msg_warn "Then open: http://<container-ip>:8080"
  fi
  echo
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  check_env
  detect_storage
  detect_template_storage
  select_ctid
  ensure_template
  create_container
  start_container
  install_app
  install_service
  get_ip
  print_summary
}

main "$@"
