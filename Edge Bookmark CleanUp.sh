#!/bin/bash

# === Log setup ===
LOG_DIR="$HOME/MyApp_Logs"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_DIR/EdgeBookmarksCleanUp_success.log") 2> >(tee -a "$LOG_DIR/EdgeBookmarksCleanUp_error.log" >&2)

echo "[$(date)] ====== Script started ======"

# Config
EDGE_BASE="$HOME/Library/Application Support/Microsoft Edge"
BACKUP_DIR="$HOME/Bookmark_Backups/Edge"
TEMP_DIR="$HOME/Temp"
SESSION_BACKUP="$TEMP_DIR/Edge_Session_Backup.json"
PY_SORTER="$TEMP_DIR/edge_sort.py"
TIMESTAMP=$(date "+%Y-%m-%d")
LOG_PREFIX="[Edge Bookmark Cleanup]"

mkdir -p "$BACKUP_DIR" "$TEMP_DIR"

# Create Python sorting script
cat > "$PY_SORTER" <<'EOF'
import json
import sys

def sort_and_dedupe_children(children):
    folders = []
    links = {}
    for item in children:
        if "children" in item:
            folders.append(item)
        elif "url" in item:
            links[item["url"]] = item  # dedupe by URL

    # Recursively sort subfolders
    for folder in folders:
        if "children" in folder:
            folder["children"] = sort_and_dedupe_children(folder["children"])

    folders_sorted = sorted(folders, key=lambda x: x.get("name", "").lower())
    links_sorted = sorted(links.values(), key=lambda x: x.get("name", "").lower())
    return folders_sorted + links_sorted

def sort_roots(data):
    for root in ["bookmark_bar", "other", "synced"]:
        try:
            node = data["roots"][root]
            if "children" in node:
                node["children"] = sort_and_dedupe_children(node["children"])
        except Exception:
            continue

if __name__ == "__main__":
    in_file, out_file = sys.argv[1], sys.argv[2]
    with open(in_file, 'r') as f:
        data = json.load(f)
    sort_roots(data)
    with open(out_file, 'w') as f:
        json.dump(data, f, indent=2)
EOF

# Backup tabs
echo "$LOG_PREFIX Backing up current tabs (if Edge is running)..."
if pgrep -xq "Microsoft Edge"; then
  osascript <<EOF > "$SESSION_BACKUP"
tell application "Microsoft Edge"
  set tabList to {}
  repeat with w in windows
    repeat with t in tabs of w
      set end of tabList to URL of t
    end repeat
  end repeat
  return tabList as string
end tell
EOF
else
  echo "$LOG_PREFIX Edge not running, skipping tab backup."
fi

echo "$LOG_PREFIX Closing Edge..."
osascript -e 'tell application "Microsoft Edge" to quit'
sleep 3

for PROFILE_PATH in "$EDGE_BASE"/Default "$EDGE_BASE"/Profile*; do
  BOOKMARKS_PATH="$PROFILE_PATH/Bookmarks"
  if [ -f "$BOOKMARKS_PATH" ]; then
    PROFILE_NAME=$(basename "$PROFILE_PATH")
    TMP_JSON="$TEMP_DIR/Bookmarks_Cleaned_${PROFILE_NAME}.json"
    BACKUP_FILE="$BACKUP_DIR/Bookmarks_${PROFILE_NAME}_$TIMESTAMP.json"

    echo "$LOG_PREFIX Processing profile: $PROFILE_NAME"
    cp "$BOOKMARKS_PATH" "$BACKUP_FILE"

    python3 "$PY_SORTER" "$BOOKMARKS_PATH" "$TMP_JSON"

    if [ $? -eq 0 ]; then
      cp "$TMP_JSON" "$BOOKMARKS_PATH"
      echo "$LOG_PREFIX Cleaned and updated $PROFILE_NAME"
    else
      echo "$LOG_PREFIX Failed to clean $PROFILE_NAME" >&2
    fi
  fi
done

echo "$LOG_PREFIX Reopening Edge..."
open -a "Microsoft Edge"
sleep 5

if [ -f "$SESSION_BACKUP" ]; then
  echo "$LOG_PREFIX Restoring saved tabs..."
  tr ',' '\n' < "$SESSION_BACKUP" | sed 's/^ *"//;s/" *$//' | while read -r url; do
    open -a "Microsoft Edge" "$url"
    sleep 0.5
  done
  rm "$SESSION_BACKUP"
fi

echo "$LOG_PREFIX Cleaning up timestamped folders older than 30 days..."
find "$TEMP_DIR" -type d -name "Check - *" -mtime +30 -exec rm -rf {} +
find "$TEMP_DIR" -type d -name "Duplicate - *" -mtime +30 -exec rm -rf {} +

rm -f "$PY_SORTER"

echo "$LOG_PREFIX Done."
