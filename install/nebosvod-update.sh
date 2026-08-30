#!/usr/bin/env bash
# =============================================================================
#  Nebosvod — weather proxy service
#  UPDATE script for an ALREADY-INSTALLED LXC container (Proxmox VE host).
#
#  Usage (on the Proxmox host, as root):
#    bash /root/weather-proxy/install/nebosvod-update.sh
#
#  Optional environment variables:
#    NEBO_CTID        — pin the container ID explicitly (skips auto-detection)
#    NEBO_GIT_URL     — git source URL (default: https://github.com/AmoFess/nebosvod.git)
#    NEBO_BRANCH      — branch name for the manual/tarball fallback (default: main)
#    NEBO_TARBALL_URL — direct tarball URL override for the manual fallback
#
#  CRITICAL GUARD: this script updates an EXISTING container only. It NEVER
#  calls `pct create` and never creates a container. If the target container
#  cannot be found, it stops with an error instead of guessing or creating.
#
#  Data safety: config.json (user's cities) and nebosvod.db (registered users)
#  are gitignored inside /opt/nebosvod, so a git fast-forward update does not
#  touch them. As belt-and-suspenders, both are additionally backed up to
#  /opt/nebosvod/backup/ before any code change.
# =============================================================================

set -Eeuo pipefail

# -----------------------------------------------------------------------------
# Output helpers (community-scripts style colors, same as nebosvod-standalone.sh)
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
# Detect the Nebosvod container.
# Recognises both the legacy /opt/weather-proxy layout (hostname "weather")
# and the standard /opt/nebosvod layout (hostname "nebosvod").
# If detection is ambiguous or fails, ASKS the user for the container ID.
# Never creates a container.
# -----------------------------------------------------------------------------

# In a candidate container, find the app root (where server.py lives).
resolve_app_dir() {
  local id="$1"
  for d in /opt/nebosvod /opt/weather-proxy; do
    if pct exec "$id" -- sh -c "test -f $d/server.py" >/dev/null 2>&1; then
      printf '%s' "$d"
      return 0
    fi
  done
  return 1
}

# Ask the user to type a container ID; validate it is a real,
# Nebosvod-running container.
ask_ctid() {
  msg_warn "Auto-detection could not pick a unique container."
  msg_warn "Please type the container ID of the Nebosvod install (e.g. 1200)."
  msg_info "Current LXC containers:"
  pct list 2>/dev/null | awk 'NR==1 || /nebosvod|weather/'
  printf 'Container ID> '
  read -r USER_CTID || { echo; die "No input given — aborting."; }
  case "${USER_CTID}" in
    ''|*[!0-9]*) die "Invalid container ID: '${USER_CTID}'." ;;
  esac
  pct status "${USER_CTID}" >/dev/null 2>&1 || die "Container ${USER_CTID} does not exist (pct status failed)."
  local dir
  dir=$(resolve_app_dir "$USER_CTID")
  [ -n "$dir" ] || die "Container ${USER_CTID} has no Nebosvod install (no server.py in /opt/nebosvod or /opt/weather-proxy)."
  CTID="$USER_CTID"
  APP_DIR="$dir"
  msg_ok "Using container ID from user input: ${CTID} (app dir: ${APP_DIR})"
}

detect_container() {
  # Explicit pin via env var
  if [ -n "${NEBO_CTID:-}" ]; then
    case "${NEBO_CTID}" in
      ''|*[!0-9]*) die "NEBO_CTID must be a positive integer (got: '${NEBO_CTID}')." ;;
    esac
    pct status "${NEBO_CTID}" >/dev/null 2>&1 || die "Pinned container ${NEBO_CTID} does not exist."
    CTID="${NEBO_CTID}"
    local d; d="$(resolve_app_dir "$CTID")"
    [ -n "$d" ] || die "Pinned container ${NEBO_CTID} has no Nebosvod install in /opt/nebosvod or /opt/weather-proxy."
    APP_DIR="$d"
    msg_ok "Using pinned container ID (NEBO_CTID): ${CTID} (app dir: ${APP_DIR})"
    return 0
  fi

  msg_info "Detecting the Nebosvod container (hostname 'nebosvod'/'weather' OR server.py in /opt/nebosvod or /opt/weather-proxy) ..."

  local ids=() id name found=()
  local candidates=""
  mapfile -t ids < <(pct list 2>/dev/null | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1}')

  for id in "${ids[@]}"; do
    [ -n "$id" ] || continue
    name=$(pct config "$id" 2>/dev/null | awk -F': ' 'tolower($1)=="hostname" {gsub(/[[:space:]]/,"",$2); print $2; exit}')
    local dir
    dir="$(resolve_app_dir "$id")"
    local matched=0
    if [ "$name" = "nebosvod" ] || [ "$name" = "weather" ] || [ -n "$dir" ]; then
      matched=1
    fi
    if [ "$matched" -eq 1 ]; then
      found+=("$id")
      candidates+="  - CT ${id}: hostname=${name:-<unknown>}, app_dir=${dir:-<none>}\n"
    fi
  done

  # Nothing found -> ask the user rather than dying.
  if [ "${#found[@]}" -eq 0 ]; then
    msg_error "No Nebosvod container auto-detected (hostname 'nebosvod'/'weather' or server.py in a known location)."
    ask_ctid
    return 0
  fi

  # Exactly one -> use it.
  if [ "${#found[@]}" -eq 1 ]; then
    CTID="${found[0]}"
    APP_DIR="$(resolve_app_dir "$CTID")"
    msg_ok "Detected Nebosvod container: ${CTID} (app dir: ${APP_DIR:-/opt/nebosvod})"
    return 0
  fi

  # Multiple -> show them, ask the user to pick.
  msg_warn "Multiple candidate containers found:"
  printf "${candidates}" >&2
  ask_ctid
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

  pct exec "$CTID" -- mkdir -p "$APP_DIR/backup" \
    || die "Failed to create $APP_DIR/backup."

  if pct exec "$CTID" -- test -f "$APP_DIR/nebosvod.db"; then
    pct exec "$CTID" -- cp -a "$APP_DIR/nebosvod.db" "$APP_DIR/backup/nebosvod.db.${BACKUP_TS}" \
      || die "Backup of nebosvod.db failed."
    msg_ok "Backed up nebosvod.db -> $APP_DIR/backup/nebosvod.db.${BACKUP_TS}"
  else
    msg_warn "$APP_DIR/nebosvod.db not found — skipping its backup."
  fi

  if pct exec "$CTID" -- test -f "$APP_DIR/config.json"; then
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
# Update via git fast-forward. Returns 1 only when /opt/nebosvod is NOT a git
# repo (caller falls back to manual file replacement). Dies on real failures.
# -----------------------------------------------------------------------------
update_via_git() {
  if ! pct exec "$CTID" -- sh -c "cd $APP_DIR && git rev-parse --is-inside-work-tree" >/dev/null 2>&1; then
    msg_warn "$APP_DIR is not a git working tree — falling back to manual file replacement."
    return 1
  fi

  msg_info "Updating code via git fast-forward (git fetch + git merge --ff-only) ..."

  local inline
  inline="
set -e
cd $APP_DIR
git fetch origin
branch=\$(git rev-parse --abbrev-ref HEAD)
[ -n \"\$branch\" ] || branch=main
git merge --ff-only \"origin/\$branch\"
"

  if pct exec "$CTID" -- sh -c "$inline"; then
    UPDATE_METHOD="git fast-forward pull (fetch + merge --ff-only)"
    msg_ok "Fast-forward update succeeded."
    return 0
  fi

  msg_warn "Fast-forward failed (local changes to tracked files or diverged history). Trying git stash ..."

  local inline2
  inline2="
set -e
cd $APP_DIR
git stash push -m \"nebosvod-update autostash\"
branch=\$(git rev-parse --abbrev-ref HEAD)
[ -n \"\$branch\" ] || branch=main
git merge --ff-only \"origin/\$branch\"
"
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

  msg_info "Pushing archive into container ..."
  pct push "$CTID" "$tmp_tar" /tmp/nebosvod-update.tar.gz || { rm -f "$tmp_tar"; die "pct push failed."; }
  rm -f "$tmp_tar"

  local inline
  inline="
set -e
cd /tmp
rm -rf nebosvod-update-src
mkdir -p nebosvod-update-src
tar -xzf /tmp/nebosvod-update.tar.gz -C nebosvod-update-src --strip-components=1
if [ ! -f nebosvod-update-src/server.py ]; then
  echo \"archive is missing server.py\" >&2
  exit 1
fi
cp nebosvod-update-src/server.py $APP_DIR/server.py
rm -rf $APP_DIR/static
cp -a nebosvod-update-src/static $APP_DIR/static
rm -rf nebosvod-update-src /tmp/nebosvod-update.tar.gz
"

  pct exec "$CTID" -- sh -c "$inline" || die "Manual file replacement failed."
  UPDATE_METHOD="manual (tarball replace of server.py + static/)"
  msg_ok "Manual file replacement complete — config.json and nebosvod.db untouched."
}

# -----------------------------------------------------------------------------
# Restart the OpenRC service
# -----------------------------------------------------------------------------
restart_service() {
  msg_info "Restarting 'nebosvod' service ..."
  if pct exec "$CTID" -- rc-service nebosvod restart; then
    msg_ok "Service restarted."
  else
    msg_warn "rc-service restart failed — trying stop/start ..."
    pct exec "$CTID" -- rc-service nebosvod stop  || msg_warn "rc-service stop failed."
    pct exec "$CTID" -- rc-service nebosvod start || die "rc-service start failed."
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

  # Primary: parse `ip -4 addr show eth0`
  for _ in $(seq 1 20); do
    ip=$(pct exec "$CTID" -- ip -4 addr show eth0 2>/dev/null \
           | grep -oPm1 'inet \K[\d.]+' || true)
    [ -n "$ip" ] && break
    sleep 1
  done

  # Fallback 1: hostname -I (busybox)
  if [ -z "$ip" ]; then
    ip=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1; exit}' || true)
  fi

  # Fallback 2: read from pct config
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
  pct exec "$CTID" -- rc-service nebosvod status || msg_warn "rc-service status reported non-zero."

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
  msg_info "Update method : ${UPDATE_METHOD}"
  msg_info "DB + cities   : preserved (nebosvod.db and config.json are gitignored, never overwritten)"
  msg_info "Backup        : $APP_DIR/backup/nebosvod.db.${BACKUP_TS} and config.json.${BACKUP_TS}"
  echo
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  check_env
  detect_container
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
