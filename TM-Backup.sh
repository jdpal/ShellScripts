#!/usr/bin/env bash
set -euo pipefail

# ===========================================
# TM-Backup.sh — Time Machine–style snapshots
# ===========================================
# - Reads config from tm-backup.conf (same folder) or $TM_BACKUP_CONFIG
# - Uses rsync --link-dest snapshots + space-based pruning
# - macOS-friendly deletions (clears flags/ACLs before rm)
# - Skips Finder alias files via Spotlight (bash 3 compatible)
# - Optional: skip symlinks (set NO_LINKS=1 in conf)
# - Root-safe excludes if backing up "/"
# - Prepends summary (start/end time, free space start/end, duration) to top of log

# ---------- Load config ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${TM_BACKUP_CONFIG:-$SCRIPT_DIR/tm-backup.conf}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Config not found: $CONFIG_FILE"
  echo "Create it (see tm-backup.conf example) or set TM_BACKUP_CONFIG to a valid file."
  exit 2
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Required config: SRC, DEST
[[ -z "${SRC:-}" || -z "${DEST:-}" ]] && { echo "Set SRC and DEST in $CONFIG_FILE"; exit 2; }
[[ ! -d "$SRC" ]] && { echo "Source not found: $SRC"; exit 2; }

# Defaults if omitted in conf
SNAP_DIR_NAME="${SNAP_DIR_NAME:-snapshots}"
LOG_DIR="${LOG_DIR:-logs}"
RSYNC_BIN="${RSYNC_BIN:-rsync}"
RSYNC_OPTS="${RSYNC_OPTS:--aHAX --numeric-ids -x --delete --delete-excluded --inplace --partial --info=progress2}"
MAX_AGE_DAYS="${MAX_AGE_DAYS:-90}"
MIN_FREE_GB="${MIN_FREE_GB:-5}"
MIN_FREE_PCT="${MIN_FREE_PCT:-3}"
AUTO_DETECT_XATTRS="${AUTO_DETECT_XATTRS:-1}"   # 1=autodetect (default), 0=use RSYNC_OPTS as-is
NO_LINKS="${NO_LINKS:-0}"                       # 1=force --no-links (skip symlinks entirely)
EXCLUDES_FILE="${EXCLUDES_FILE:-}"

SNAP_ROOT="$DEST/$SNAP_DIR_NAME"
LOG_ROOT="$DEST/$LOG_DIR"
mkdir -p "$SNAP_ROOT" "$LOG_ROOT"

# ---------- Portable rm + unlock (macOS) ----------
RM_EXTRA=""
if rm --help 2>&1 | grep -q 'one-file-system'; then
  RM_EXTRA="--one-file-system"
fi

unlock_path() {
  local p="$1"
  command -v chflags >/dev/null 2>&1 && chflags -R nouchg,noschg,nodump "$p" 2>/dev/null || true
  command -v chmod  >/dev/null 2>&1 && chmod  -RN "$p" 2>/dev/null || true
  command -v chmod  >/dev/null 2>&1 && chmod  -R u+rwX "$p" 2>/dev/null || true
}

safe_rm() {
  for target in "$@"; do
    unlock_path "$target"
    rm -rf ${RM_EXTRA:+$RM_EXTRA} "$target"
  done
}

# ---------- Helpers ----------
free_kb()       { df -Pk "$DEST" | awk 'NR==2{print $4}'; }
used_pct()      { df -P  "$DEST" | awk 'NR==2{gsub("%","",$5);print $5}'; }
free_gb_int()   { echo $(( $(free_kb) / 1048576 )); }    # 1 GiB = 1048576 KiB
free_pct_int()  { echo $(( 100 - $(used_pct) )); }
meets_space()   { [[ $(free_gb_int) -ge $MIN_FREE_GB && $(free_pct_int) -ge $MIN_FREE_PCT ]]; }

format_duration() {
  # bash-3-safe HH:MM:SS from seconds
  local S=$1 H M
  H=$(( S / 3600 ))
  M=$(( (S % 3600) / 60 ))
  S=$(( S % 60 ))
  printf "%02d:%02d:%02d" "$H" "$M" "$S"
}

delete_oldest_completed_snapshot() {
  if compgen -G "$SNAP_ROOT/"'*/.complete' > /dev/null; then
    local oldest_complete dir
    oldest_complete="$(ls -1dt "$SNAP_ROOT"/*/.complete | tail -1)"
    dir="$(dirname "$oldest_complete")"
    echo "Deleting oldest snapshot: $dir"
    safe_rm "$dir"
    return 0
  else
    return 1
  fi
}

cleanup_incomplete_snapshots() {
  local d
  for d in "$SNAP_ROOT"/*; do
    [[ -d "$d" ]] || continue
    [[ -e "$d/.complete" ]] || { echo "Removing incomplete snapshot: $d"; safe_rm "$d"; }
  done
}

rollback() {
  echo "Error occurred; removing partial snapshot: ${SNAP_DIR:-<unset>}"
  [[ -n "${SNAP_DIR:-}" && -d "$SNAP_DIR" && ! -e "$SNAP_DIR/.complete" ]] && safe_rm "$SNAP_DIR"
}
trap rollback ERR

# ---------- Root-safe excludes ----------
declare -a ROOT_EXCLUDES=()   # avoid unbound under set -u
if [[ "$(realpath "$SRC")" == "/" ]]; then
  ROOT_EXCLUDES+=(--exclude=/dev/** --exclude=/proc/** --exclude=/sys/** --exclude=/run/** \
                  --exclude=/tmp/** --exclude=/mnt/** --exclude=/media/** --exclude=/lost+found)
fi

# ---------- Pre-flight ----------
cleanup_incomplete_snapshots
echo "Free space before pruning: $(free_gb_int) GiB, $(free_pct_int)%."

attempts=0
while ! meets_space; do
  ((attempts++))
  echo "Below threshold (need >= ${MIN_FREE_GB} GiB and >= ${MIN_FREE_PCT}% free)."
  if ! delete_oldest_completed_snapshot; then
    echo "No snapshots left to delete; insufficient space."
    exit 3
  fi
  echo "Now: $(free_gb_int) GiB free, $(free_pct_int)% free."
  [[ $attempts -gt 100 ]] && { echo "Too many prune attempts."; exit 4; }
done

# ---------- Prepare snapshot ----------
timestamp="$(date +%F_%H-%M-%S)"
SNAP_DIR="$SNAP_ROOT/$timestamp"
LOG_FILE="$LOG_ROOT/backup_$timestamp.log"
MANIFEST="$SNAP_DIR/.manifest.txt"

latest=""
if compgen -G "$SNAP_ROOT/"'*/.complete' > /dev/null; then
  latest="$(dirname "$(ls -1dt "$SNAP_ROOT"/*/.complete | head -n1)")"
fi

# ---------- Build dynamic exclude list for Finder alias files (bash 3 safe) ----------
ALIAS_EXCLUDE_FILE=""
if [[ "$(uname -s)" == "Darwin" ]]; then
  alias_list_tmp="$LOG_ROOT/alias-paths.$(date +%s).txt"
  # Find Finder aliases even if they lack .alias extension
  mdfind -onlyin "$SRC" 'kMDItemFSIsAliasFile == 1' > "$alias_list_tmp" 2>/dev/null || true
  if [[ -s "$alias_list_tmp" ]]; then
    ALIAS_EXCLUDE_FILE="$LOG_ROOT/alias-excludes.$(date +%s).txt"
    : > "$ALIAS_EXCLUDE_FILE"
    # Convert absolute paths to rsync-rooted excludes (leading '/')
    while IFS= read -r abs; do
      rel="${abs#$SRC/}"
      [[ "$rel" == "$abs" ]] && continue
      printf "/%s\n" "$rel" >> "$ALIAS_EXCLUDE_FILE"
    done < "$alias_list_tmp"
    echo "Excluding $(wc -l < "$ALIAS_EXCLUDE_FILE" | tr -d ' ') Finder aliases via $ALIAS_EXCLUDE_FILE"
  fi
  rm -f "$alias_list_tmp" 2>/dev/null || true
fi

# ---------- Effective rsync options ----------
RSYNC_OPTS_EFF="$RSYNC_OPTS"

# Optionally skip symlinks entirely (shortcut folders/files)
if [[ "$NO_LINKS" == "1" ]]; then
  RSYNC_OPTS_EFF="$RSYNC_OPTS_EFF --no-links"
fi

# Auto-drop xattrs/ACLs if destination can’t store them (keeps them on HFS+/APFS)
if [[ "$AUTO_DETECT_XATTRS" == "1" ]]; then
  supports_xattrs=1
  tmp_test="$SNAP_ROOT/.xattr-test.$$"
  mkdir -p "$SNAP_ROOT" || true
  echo test > "$tmp_test" 2>/dev/null || true
  if ! xattr -w "user.test" "ok" "$tmp_test" 2>/dev/null; then
    supports_xattrs=0
  fi
  rm -f "$tmp_test" 2>/dev/null || true

  if [[ $supports_xattrs -eq 0 ]]; then
    RSYNC_OPTS_EFF="${RSYNC_OPTS_EFF//-X/}"
    RSYNC_OPTS_EFF="${RSYNC_OPTS_EFF//-A/}"
    case " $RSYNC_OPTS_EFF " in *" --no-xattrs "*) :;; *) RSYNC_OPTS_EFF="$RSYNC_OPTS_EFF --no-xattrs";; esac
    case " $RSYNC_OPTS_EFF " in *" --no-acls "*)   :;; *) RSYNC_OPTS_EFF="$RSYNC_OPTS_EFF --no-acls";;   esac
  fi
fi

# ---------- Build rsync command ----------
RSYNC="${RSYNC_BIN}"
RSYNC_CMD=("$RSYNC" $RSYNC_OPTS_EFF)
if [[ -n "$EXCLUDES_FILE" ]]; then
  RSYNC_CMD+=(--exclude-from="$EXCLUDES_FILE")
fi
if [[ -n "${ALIAS_EXCLUDE_FILE:-}" && -s "$ALIAS_EXCLUDE_FILE" ]]; then
  RSYNC_CMD+=(--exclude-from="$ALIAS_EXCLUDE_FILE")
fi
if ((${#ROOT_EXCLUDES[@]})); then
  RSYNC_CMD+=("${ROOT_EXCLUDES[@]}")
fi
if [[ -n "$latest" ]]; then
  RSYNC_CMD+=(--link-dest="$latest")
fi

# ---------- Run backup ----------
mkdir -p "$SNAP_DIR"

# Capture summary metrics (but DO NOT write the two lines into the log body)
START_EPOCH="$(date +%s)"
START_TIME="$(date)"
START_FREE="$(free_gb_int) GiB, $(free_pct_int)%"

# Only show starting info to console (not appended into log body):
echo "Starting backup $START_TIME"
echo "Free space at start: $START_FREE"

# Header + command go to the log
{
  echo "=== rsync command ==="
  printf "%q " "${RSYNC_CMD[@]}" "$SRC/" "$SNAP_DIR/"
  echo -e "\n=====================\n"
} | tee -a "$LOG_FILE"

("${RSYNC_CMD[@]}" "$SRC/" "$SNAP_DIR/") 2>&1 | tee -a "$LOG_FILE"

# ---------- Manifest & completion ----------
{
  echo "timestamp: $timestamp"
  echo "config_file: $CONFIG_FILE"
  echo "source: $SRC"
  echo "dest: $DEST"
  echo "snap_dir_name: $SNAP_DIR_NAME"
  echo "log_dir: $LOG_DIR"
  echo "link-dest: ${latest:-<none>}"
  echo "max_age_days: $MAX_AGE_DAYS"
  echo "min_free_gb: $MIN_FREE_GB"
  echo "min_free_pct: $MIN_FREE_PCT"
  echo "label: ${LABEL:-}"
  echo "rsync_opts_effective: $RSYNC_OPTS_EFF"
  echo "alias_exclude_file: ${ALIAS_EXCLUDE_FILE:-<none>}"
  echo -n "rsync_version: "; "$RSYNC" --version | head -n1
} > "$MANIFEST"
touch "$SNAP_DIR/.complete"

END_TIME="$(date)"
END_EPOCH="$(date +%s)"
END_FREE="$(free_gb_int) GiB, $(free_pct_int)%"
DURATION_SEC=$(( END_EPOCH - START_EPOCH ))
DURATION="$(format_duration "$DURATION_SEC")"

# ---------- Post-run: age-based pruning ----------
if [[ "$MAX_AGE_DAYS" -gt 0 ]]; then
  echo -e "\nPruning snapshots older than $MAX_AGE_DAYS days…" | tee -a "$LOG_FILE"
  find "$SNAP_ROOT" -mindepth 1 -maxdepth 1 -type d \
    -name "20*_*" -mtime +"$MAX_AGE_DAYS" \
    -exec test -e "{}/.complete" \; -print -exec safe_rm {} +
fi

# ---------- Prepend summary to top of log ----------
{
  echo "========== Backup Summary =========="
  echo "Start time      : $START_TIME"
  echo "Free space start: $START_FREE"
  echo "End time        : $END_TIME"
  echo "Free space end  : $END_FREE"
  echo "Duration        : $DURATION"
  echo "===================================="
  echo
  cat "$LOG_FILE"
} > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"

echo -e "\nBackup finished successfully: $SNAP_DIR"
echo "Free space after backup: $END_FREE"
echo "Duration: $DURATION"
