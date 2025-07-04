#!/bin/bash

set -euo pipefail

# === Log setup ===
LOG_DIR="$HOME/MyApp_Logs"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_DIR/SafariBookmarksCleanUp_success.log") 2> >(tee -a "$LOG_DIR/SafariBookmarksCleanUp_error.log" >&2)

echo "[$(date)] ====== Script started ======"

# === Config ===
BOOKMARKS="$HOME/Library/Safari/Bookmarks.plist"
BACKUP_DIR="$HOME/Library/CloudStorage/OneDrive-Personal/Backup/Safari_Bookmarks/"
TAB_SAVE_PATH="$HOME/Temp/safari_tabs.txt"
TODAY=$(date +%Y-%m-%d)
BACKUP_FILE="$BACKUP_DIR/bookmarks-backup-$TODAY.plist"

mkdir -p "$BACKUP_DIR" "$(dirname "$TAB_SAVE_PATH")"

# === Function: Wait for iCloud Sync ===
wait_for_icloud_sync() {
    echo "[$(date)] Checking for iCloud sync..."
    local retries=10
    while lsof "$BOOKMARKS" &>/dev/null && [ $retries -gt 0 ]; do
        echo "[$(date)] iCloud sync active. Waiting..."
        sleep 3
        ((retries--))
    done

    if [ $retries -eq 0 ]; then
        echo "[$(date)] iCloud sync may be stuck. Proceeding cautiously."
    else
        echo "[$(date)] iCloud sync idle. Continuing."
    fi
}

# === Step 1: Save Tabs ===
echo "[$(date)] Saving open and pinned tabs..."
osascript <<EOF > "$TAB_SAVE_PATH"
tell application "Safari"
    set tabURLs to ""
    repeat with w in windows
        repeat with t in tabs of w
            set tabURLs to tabURLs & (URL of t) & linefeed
        end repeat
    end repeat
    return tabURLs
end tell
EOF

# === Step 2: Close Safari ===
echo "[$(date)] Closing Safari..."
osascript -e 'tell application "Safari" to quit'
sleep 2

# === Step 3: Wait for iCloud Sync ===
wait_for_icloud_sync

# === Step 4: Backup Bookmarks Once Per Day ===
if [ ! -f "$BACKUP_FILE" ]; then
    echo "[$(date)] Backing up bookmarks to $BACKUP_FILE"
    cp "$BOOKMARKS" "$BACKUP_FILE"
else
    echo "[$(date)] Backup already exists for today."
fi

# === Step 5: Sort and Deduplicate Bookmarks ===
/usr/bin/python3 <<EOF

import plistlib
from pathlib import Path
from urllib.parse import urlparse, urlunparse
from datetime import datetime

def normalize_url(url):
    if not url:
        return ""
    parsed = urlparse(url)
    cleaned = parsed._replace(fragment="", query="")
    return urlunparse(cleaned).rstrip("/")

def process_node(node, seen_urls, duplicates, empties):
    if "Children" not in node:
        return False  # not a folder

    cleaned_children = []
    for child in node["Children"]:
        if child.get("WebBookmarkType") == "WebBookmarkTypeList":
            has_content = process_node(child, seen_urls, duplicates, empties)
            if has_content:
                cleaned_children.append(child)
            else:
                empties.append(child)
        elif child.get("WebBookmarkType") == "WebBookmarkTypeLeaf":
            url = normalize_url(child.get("URLString"))
            if url and url not in seen_urls:
                seen_urls.add(url)
                cleaned_children.append(child)
            else:
                duplicates.append(child)
        else:
            cleaned_children.append(child)

    # Sort folders then bookmarks
    folders = [c for c in cleaned_children if c.get("WebBookmarkType") == "WebBookmarkTypeList"]
    bookmarks = [c for c in cleaned_children if c.get("WebBookmarkType") == "WebBookmarkTypeLeaf"]

    folders.sort(key=lambda x: x.get("Title", "").lower())
    bookmarks.sort(key=lambda x: x.get("URIDictionary", {}).get("title", "").lower())

    node["Children"] = folders + bookmarks
    return len(node["Children"]) > 0

def find_or_create_folder(plist, folder_name):
    for child in plist.get("Children", []):
        if child.get("Title") == folder_name and child.get("WebBookmarkType") == "WebBookmarkTypeList":
            return child
    folder = {
        "Title": folder_name,
        "WebBookmarkType": "WebBookmarkTypeList",
        "Children": [],
        "UUID": f"com.apple.bookmarkgroup.{datetime.now().timestamp()}"
    }
    plist["Children"].append(folder)
    return folder

# === Load plist
plist_path = Path.home() / "Library/Safari/Bookmarks.plist"

with plist_path.open("rb") as f:
    plist = plistlib.load(f)

seen = set()
duplicates = []
empties = []

# Clean main roots
for root in plist.get("Children", []):
    process_node(root, seen, duplicates, empties)

# Add duplicates to "Duplicates" folder
duplicates_folder = find_or_create_folder(plist, "Duplicates")
duplicates_folder.setdefault("Children", []).extend(duplicates)

# Add empty folders to "Blanks" folder
check_folder = find_or_create_folder(plist, "Blanks")
check_folder.setdefault("Children", []).extend(empties)

# Save
with plist_path.open("wb") as f:
    plistlib.dump(plist, f)

print(f"[Python] Done: {len(duplicates)} duplicates → Duplicates, {len(empties)} empty folders → Blanks.")


EOF

# === Step 6: Restart Safari and Restore Tabs ===
echo "[$(date)] Restarting Safari and reopening tabs..."
open -a Safari
sleep 3

while IFS= read -r url; do
    [[ -n "$url" ]] && open -a Safari "$url"
done < "$TAB_SAVE_PATH"

echo "[$(date)] Script completed successfully."
