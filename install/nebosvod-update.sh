#!/usr/bin/env bash
# =============================================================================
#  Nebosvod — weather proxy service
#  UPDATE script for an ALREADY-INSTALLED LXC container (Proxmox VE host).
#
#  Usage (on the Proxmox host, as root):
#    bash -c "$(curl -fsSL https://raw.githubusercontent.com/AmoFess/nebosvod/main/install/nebosvod-update.sh)"
#
#  The script ASKS for the container ID to update (or honours NEBO_CTID).
#  Every step of the update is printed to the terminal.
#
#  Optional environment variables:
#    NEBO_CTID        — pin the container ID explicitly (skips the prompt)
#    NEBO_GIT_URL     — git source URL (default: https://github.com/AmoFess/nebosvod.git)
#    NEBO_BRANCH      — branch name for the manual/tarball fallback (default: main)
#    NEBO_TARBALL_URL — direct tarball URL override for the manual fallback
#
#  CRITICAL GUARD: this script updates an EXISTING container only. It NEVER
#  calls `pct create` and never creates a container. Wrong/unknown ID → it
#  stops with an error instead of guessing or creating.
#
#  Data safety: config.json (user's cities) and nebosvod.db (registered users)
#  are never overwritten. Both are additionally backed up to
#  $APP_DIR/backup/ before any code change.
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

CTID=""
IP=""
APP_DIR=""
SERVICE=""
BACKUP_TS=""
UPDATE_METHOD=""

# -----------------------------------------------------------------------------
# Environment sanity checks
# -----------------------------------------------------------------------------
check_env() {
  [ "$(id -u)" -eq 0 ] || die "This script must be run as root on the Proxmox VE host."
  command -v pct  >/dev/null 2>&1 || die "'pct' not found — are you on a Proxmox VE host?"
  command -v curl >/dev/null 2>&1 || msg_warn "'curl' not found on host — manual fallback and host-side HTTP check will be unavailable."
}

# -----------------------------------------------------------------------------
# Ask which container to update. No auto-detection.
# -----------------------------------------------------------------------------
ask_ctid() {
  # Explicit pin via env var (for non-interactive use)
  if [ -n "${NEBO_CTID:-}" ]; then
    case "${NEBO_CTID}" in
      ''|*[!0-9]*) die "NEBO_CTID must be a positive integer (got: '${NEBO_CTID}')." ;;
    esac
    pct status "${NEBO_CTID}" >/dev/null 2>&1 || die "Pinned container ${NEBO_CTID} does not exist."
    CTID="${NEBO_CTID}"
    msg_ok "Using pinned container ID (NEBO_CTID): ${CTID}"
    return 0
  fi

  # Interactive prompt
  echo
  msg_info "Available LXC containers on this host:"
  echo "------------------------------------------------------------"
  pct list 2>/dev/null | awk 'NR==1{print} NR>1{printf "%-6s  %-18s  %s\n", $1, $2, $3}'
  echo "------------------------------------------------------------"

  while :; do
    local input
    read -r -p "Container ID to update> " input || die "No input received."
    input=$(echo "$input" | tr -d '[:space:]')
    case "$input" in
      ''|*[!0-9]*)
        msg_error "Invalid container ID: '${input}'. Must be a number."
        continue
        ;;
    esac
    if pct status "$input" >/dev/null 2>&1; then
      CTID="$input"
      msg_ok "Will update container ID: ${CTID}"
      return 0
    else
      msg_error "Container ${input} does not exist (pct status failed). Try again."
    fi
  done
}

# -----------------------------------------------------------------------------
# Determine the app dir inside the container (legacy + standard layouts).
# -----------------------------------------------------------------------------
setup_appdir() {
  if pct exec "$CTID" -- sh -c 'test -f /opt/nebosvod/server.py' >/dev/null 2>&1; then
    APP_DIR="/opt/nebosvod"
  elif pct exec "$CTID" -- sh -c 'test -f /opt/weather-proxy/server.py' >/dev/null 2>&1; then
    APP_DIR="/opt/weather-proxy"
  else
    die "No Nebosvod install found in container ${CTID} (looked for /opt/nebosvod/server.py and /opt/weather-proxy/server.py)."
  fi
  msg_ok "App directory in container: ${APP_DIR}"
}

# -----------------------------------------------------------------------------
# Ensure the container is running (update + service restart need a live CT)
# -----------------------------------------------------------------------------
ensure_running() {
  local status
  status=$(pct status "$CTID" 2>/dev/null | awk '{print $2}')
  case "$status" in
    running)
      return 0
      ;;
    stopped)
      msg_warn "Container ${CTID} is stopped — starting it to perform the update ..."
      pct start "$CTID" || die "pct start failed."
      msg_info "Waiting for container to boot (up to 60s) ..."
      local ready=0
      for _ in $(seq 1 60); do
        if pct exec "$CTID" -- sh -c 'command -v sh' >/dev/null 2>&1; then
          ready=1
          break
        fi
        sleep 1
      done
      [ "$ready" -eq 1 ] || die "Container ${CTID} did not become ready within 60s."
      msg_ok "Container ${CTID} is up."
      ;;
    *)
      die "Unknown container status '${status}' for CT ${CTID}."
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Belt-and-suspenders backup of DB and config (old backups are never deleted)
# -----------------------------------------------------------------------------
backup_data() {
  pct exec "$CTID" -- test -d "$APP_DIR" \
    || die "$APP_DIR not found in container ${CTID} — this does not look like a Nebosvod install."

  BACKUP_TS=$(date +%Y%m%d-%H%M%S)
  msg_info "Backing up nebosvod.db and config.json (timestamp ${BACKUP_TS}) ..."

  msg_info "  - mkdir -p $APP_DIR/backup"
  pct exec "$CTID" -- mkdir -p "$APP_DIR/backup" \
    || die "Failed to create $APP_DIR/backup."

  if pct exec "$CTID" -- test -f "$APP_DIR/nebosvod.db"; then
    msg_info "  - copying nebosvod.db -> backup/"
    pct exec "$CTID" -- cp -a "$APP_DIR/nebosvod.db" "$APP_DIR/backup/nebosvod.db.${BACKUP_TS}" \
      || die "Backup of nebosvod.db failed."
    msg_ok "Backed up nebosvod.db -> $APP_DIR/backup/nebosvod.db.${BACKUP_TS}"
  else
    msg_warn "$APP_DIR/nebosvod.db not found — skipping its backup."
  fi

  if pct exec "$CTID" -- test -f "$APP_DIR/config.json"; then
    msg_info "  - copying config.json -> backup/"
    pct exec "$CTID" -- cp -a "$APP_DIR/config.json" "$APP_DIR/backup/config.json.${BACKUP_TS}" \
      || die "Backup of config.json failed."
    msg_ok "Backed up config.json -> $APP_DIR/backup/config.json.${BACKUP_TS}"
  else
    msg_warn "$APP_DIR/config.json not found — skipping its backup."
  fi
}

# -----------------------------------------------------------------------------
# Derive a GitHub/Gitea/Forgejo-style tarball URL from a git clone URL
# -----------------------------------------------------------------------------
derive_tarball_url() {
  local url="$1" branch="${2:-main}"
  local clean
  clean=$(printf '%s' "$url" | sed -E 's#^([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@]+@#\1#; s#\.git/?$##')
  case "$clean" in
    *github.com*)
      printf '%s/archive/refs/heads/%s.tar.gz' "$clean" "$branch" ;;
    *)
      printf '%s/archive/%s.tar.gz' "$clean" "$branch" ;;
  esac
}

# -----------------------------------------------------------------------------
# Update via git fast-forward. Returns 1 only when the app dir is NOT a git
# repo (caller falls back to manual file replacement). Dies on real failures.
# -----------------------------------------------------------------------------
update_via_git() {
  if ! pct exec "$CTID" -- sh -c "cd $APP_DIR && git rev-parse --is-inside-work-tree" >/dev/null 2>&1; then
    msg_warn "$APP_DIR is not a git working tree — falling back to manual file replacement."
    return 1
  fi

  msg_info "Updating code via git fast-forward (git fetch + git merge --ff-only) ..."

  local inline='
set -e
cd '"$APP_DIR"'
echo "  Working dir: '"$APP_DIR"'"
echo "  git fetch origin"
git fetch origin
branch=$(git rev-parse --abbrev-ref HEAD)
[ -n "$branch" ] || branch=main
echo "  On branch: ${branch}"
echo "  git merge --ff-only origin/${branch}"
git merge --ff-only "origin/$branch"
echo "  Updated to: $(git rev-parse --short HEAD)"
'

  if pct exec "$CTID" -- sh -c "$inline"; then
    UPDATE_METHOD="git fast-forward pull (fetch + merge --ff-only)"
    msg_ok "Fast-forward update succeeded."
    return 0
  fi

  msg_warn "Fast-forward failed (local changes to tracked files or diverged history). Trying git stash ..."

  local inline2='
set -e
cd '"$APP_DIR"'
echo "  git stash push"
git stash push -m "nebosvod-update autostash"
branch=$(git rev-parse --abbrev-ref HEAD)
[ -n "$branch" ] || branch=main
echo "  git merge --ff-only origin/${branch}"
git merge --ff-only "origin/$branch"
'
  local merge_ok=0
  if pct exec "$CTID" -- sh -c "$inline2"; then
    merge_ok=1
  fi

  if pct exec "$CTID" -- sh -c "cd $APP_DIR && git stash pop"; then
    msg_ok "Stashed local changes restored."
  else
    msg_warn "git stash pop failed — local changes kept in the stash (check: pct exec ${CTID} -- sh -c 'cd $APP_DIR && git stash list')."
  fi

  if [ "$merge_ok" -eq 1 ]; then
    UPDATE_METHOD="git fast-forward pull (with stash)"
    msg_ok "Fast-forward update succeeded after stashing local changes."
    return 0
  fi

  msg_error "Git update failed even after stash (diverged history or conflict)."
  msg_error "Inspect manually: pct exec ${CTID} -- sh -c 'cd $APP_DIR && git status'"
  die "Aborting update."
}

# -----------------------------------------------------------------------------
# Manual fallback: re-download tarball, replace ONLY server.py and static/.
# config.json and nebosvod.db are never touched.
# -----------------------------------------------------------------------------
update_manual() {
  msg_info "Performing manual file replacement (server.py + static/ only) ..."

  local branch="${NEBO_BRANCH:-main}"
  local git_url="${NEBO_GIT_URL:-https://github.com/AmoFess/nebosvod.git}"
  local tarball="${NEBO_TARBALL_URL:-}"

  if [ -z "$tarball" ]; then
    tarball=$(derive_tarball_url "$git_url" "$branch")
  fi

  command -v curl >/dev/null 2>&1 || die "Manual fallback requires 'curl' on the host (or set NEBO_TARBALL_URL and provide curl)."

  msg_info "Downloading ${tarball} ..."
  local tmp_tar
  tmp_tar=$(mktemp /tmp/nebosvod-update-XXXXXX.tar.gz) || die "mktemp failed."
  curl -fsSL --max-time 120 "$tarball" -o "$tmp_tar" || { rm -f "$tmp_tar"; die "Download failed: ${tarball}"; }
  msg_ok "Downloaded $(du -h "$tmp_tar" | cut -f1)"

  msg_info "Pushing archive into container ..."
  pct push "$CTID" "$tmp_tar" /tmp/nebosvod-update.tar.gz || { rm -f "$tmp_tar"; die "pct push failed."; }
  rm -f "$tmp_tar"

  local inline
  inline="
set -e
echo '  Extracting archive'
cd /tmp
rm -rf nebosvod-update-src
mkdir -p nebosvod-update-src
tar -xzf /tmp/nebosvod-update.tar.gz -C nebosvod-update-src --strip-components=1
if [ ! -f nebosvod-update-src/server.py ]; then
  echo 'archive is missing server.py' >&2
  exit 1
fi
APP='$APP_DIR'
echo '  Backing up current server.py into backup/'
mkdir -p \"\$APP/backup\"
[ -f \"\$APP/server.py\" ] && cp -a \"\$APP/server.py\" \"\$APP/backup/server.py.$(date +%Y%m%d-%H%M%S)\"
echo '  Installing server.py'
cp -a nebosvod-update-src/server.py \"\$APP/server.py\"
echo '  Installing static/ (full replace)'
rm -rf \"\$APP/static-new\"
cp -r nebosvod-update-src/static \"\$APP/static-new\"
rm -rf \"\$APP/static.old\"
[ -d \"\$APP/static\" ] && mv \"\$APP/static\" \"\$APP/static.old\"
mv \"\$APP/static-new\" \"\$APP/static\"
rm -rf \"\$APP/static.old\"
rm -f /tmp/nebosvod-update.tar.gz
rm -rf nebosvod-update-src
"
  msg_info "Replacing files inside the container ..."
  pct exec "$CTID" -- sh -c "$inline"

  msg_ok "Manual file replacement complete — config.json and nebosvod.db untouched."
}

# -----------------------------------------------------------------------------
# Determine the actual OpenRC service name for Nebosvod in the container.
# Some installs use "nebosvod", others "weather" or "weather-proxy".
# -----------------------------------------------------------------------------
detect_service() {
  local s
  for s in nebosvod weather weather-proxy; do
    if pct exec "$CTID" -- test -x "/etc/init.d/$s" >/dev/null 2>&1; then
      SERVICE="$s"
      msg_ok "Service name in container: ${SERVICE}"
      return 0
    fi
  done
  die "No Nebosvod OpenRC service found (looked for /etc/init.d/nebosvod, weather, weather-proxy)."
}

# -----------------------------------------------------------------------------
# Restart the OpenRC service
# -----------------------------------------------------------------------------
restart_service() {
  msg_info "Restarting '${SERVICE}' service ..."
  if pct exec "$CTID" -- rc-service "$SERVICE" restart; then
    msg_ok "Service restarted."
  else
    msg_warn "rc-service restart failed — trying stop/start ..."
    pct exec "$CTID" -- rc-service "$SERVICE" stop  || msg_warn "rc-service stop failed."
    pct exec "$CTID" -- rc-service "$SERVICE" start || die "rc-service start failed."
    msg_ok "Service started via stop/start."
  fi
  sleep 2
}

# -----------------------------------------------------------------------------
# Determine the container IP address
# -----------------------------------------------------------------------------
get_ip() {
  msg_info "Determining container IP address ..."
  local ip=""

  for _ in $(seq 1 20); do
    ip=$(pct exec "$CTID" -- ip -4 addr show eth0 2>/dev/null \
           | grep -oPm1 'inet \K[\d.]+' || true)
    [ -n "$ip" ] && break
    sleep 1
  done

  if [ -z "$ip" ]; then
    ip=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1; exit}' || true)
  fi

  if [ -z "$ip" ]; then
    ip=$(pct config "$CTID" 2>/dev/null | grep -oPm1 'ip=\K[\d.]+' || true)
  fi

  IP="$ip"
}

# -----------------------------------------------------------------------------
# Verify the service is up and responding
# -----------------------------------------------------------------------------
verify_service() {
  msg_info "Verifying service is up ..."
  pct exec "$CTID" -- rc-service "$SERVICE" status || msg_warn "rc-service status reported non-zero."

  local ok=0
  if [ -n "$IP" ] && [ "$IP" != "dhcp" ] && command -v curl >/dev/null 2>&1; then
    if curl -fsS --max-time 10 "http://${IP}:8080/api/cities" -o /dev/null 2>/dev/null; then
      msg_ok "Endpoint http://${IP}:8080/api/cities responds OK."
      ok=1
    fi
  fi

  if [ "$ok" -eq 0 ]; then
    if pct exec "$CTID" -- sh -c 'wget -q -O /dev/null http://127.0.0.1:8080/api/cities' >/dev/null 2>&1; then
      msg_ok "Endpoint http://127.0.0.1:8080/api/cities responds inside the container."
    else
      msg_warn "Could not confirm an HTTP response — check: pct exec ${CTID} -- rc-service nebosvod status"
    fi
  fi
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
print_summary() {
  echo
  msg_ok "Nebosvod update finished."
  msg_info "Container ID  : ${CTID}"
  if [ -n "$IP" ] && [ "$IP" != "dhcp" ]; then
    msg_info "Container IP  : ${IP}"
    msg_info "Service URL   : http://${IP}:8080"
  else
    msg_info "Container IP  : (not auto-detected; find with: pct exec ${CTID} -- ip -4 addr show eth0)"
  fi
  msg_info "App directory : ${APP_DIR}"
  msg_info "Service name  : ${SERVICE}"
  msg_info "Update method : ${UPDATE_METHOD}"
  msg_info "DB + cities   : preserved (nebosvod.db and config.json are never overwritten)"
  msg_info "Backup        : $APP_DIR/backup/ (timestamp ${BACKUP_TS})"
  echo
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  check_env
  ask_ctid
  setup_appdir
  detect_service
  ensure_running
  backup_data

  if update_via_git; then
    :
  else
    update_manual
  fi

  restart_service
  get_ip
  verify_service
  print_summary
}

main "$@"