#!/bin/bash

set -euo pipefail

# === Logging Setup ===
LOG_DIR="$HOME/MyApp_Logs"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_DIR/SafariActiveBookmarks_success.log") 2> >(tee -a "$LOG_DIR/SafariActiveBookmarks_error.log" >&2)

# === Paths ===
TMP_DIR="$HOME/Temp"
mkdir -p "$TMP_DIR"

BOOKMARKS="$HOME/Library/Safari/Bookmarks.plist"
URL_LIST="$TMP_DIR/all_urls.txt"
INVALID_URLS="$TMP_DIR/dead_urls.txt"
BOOKMARKS_PKL="$TMP_DIR/bookmarks.pkl"
TRUSTED_DOMAINS="$TMP_DIR/trusted_domains.txt"
SKIPPED_URLS="$TMP_DIR/skipped_urls.txt"

# Create placeholder files
touch "$TRUSTED_DOMAINS"
> "$URL_LIST" > "$INVALID_URLS" > "$SKIPPED_URLS"

echo "[$(date)] Extracting URLs from Safari bookmarks..."

# === Step 1: Extract URLs ===
/usr/bin/python3 <<EOF
import plistlib
import pickle
from pathlib import Path

def extract_bookmarks(node, collected):
    if "Children" in node:
        for child in node["Children"]:
            extract_bookmarks(child, collected)
    elif node.get("WebBookmarkType") == "WebBookmarkTypeLeaf":
        url = node.get("URLString")
        if url:
            collected.append((url, node))

plist_path = Path.home() / "Library/Safari/Bookmarks.plist"
with plist_path.open("rb") as f:
    plist = plistlib.load(f)

bookmarks = []
for child in plist.get("Children", []):
    extract_bookmarks(child, bookmarks)

with open("$URL_LIST", "w") as f:
    for url, _ in bookmarks:
        f.write(url + "\n")

with open("$BOOKMARKS_PKL", "wb") as f:
    pickle.dump(bookmarks, f)
EOF

TOTAL=$(wc -l < "$URL_LIST" | tr -d ' ')
COUNT=0

echo "[$(date)] Checking $TOTAL URLs..."

# === Step 2: Check URLs ===
while IFS= read -r url; do
    ((COUNT++))

    domain=$(echo "$url" | awk -F/ '{print $3}' | awk -F: '{print $1}')

    # Skip local/private IPs and .local
    if [[ "$domain" =~ ^(localhost|127\.0\.0\.1|10\..*|192\.168\..*|172\.(1[6-9]|2[0-9]|3[01])\..*|.*\.local)$ ]]; then
        echo "Skipping local/private: $url"
        echo "$url" >> "$SKIPPED_URLS"
        continue
    fi

    # Skip trusted domains
    if grep -qF "$domain" "$TRUSTED_DOMAINS"; then
        echo "Whitelisted: $url"
        echo "$url" >> "$SKIPPED_URLS"
        continue
    fi

    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$url" || echo "000")
    if [[ "$code" == "404" ]]; then
        echo "[404] Not Found: $url"
        echo "$url" >> "$INVALID_URLS"
    fi

done < "$URL_LIST"

echo "[$(date)] Processing Safari bookmarks..."

# === Step 3: Process and Clean Bookmarks ===
/usr/bin/python3 <<EOF
import plistlib, pickle
from pathlib import Path
from datetime import datetime, timedelta
import subprocess
import os

plist_path = Path.home() / "Library/Safari/Bookmarks.plist"
log_path = Path.home() / "MyApp_Logs/404_cleanup.log"

with plist_path.open("rb") as f:
    plist = plistlib.load(f)

with open(os.path.expanduser("$BOOKMARKS_PKL"), "rb") as f:
    all_bookmarks = pickle.load(f)

with open(os.path.expanduser("$INVALID_URLS")) as f:
    dead_urls = set(line.strip() for line in f if line.strip())

def find_or_create_folder(plist, name):
    for child in plist["Children"]:
        if child.get("WebBookmarkType") == "WebBookmarkTypeList" and child.get("Title") == name:
            return child
    folder = {
        "Title": name,
        "WebBookmarkType": "WebBookmarkTypeList",
        "Children": [],
        "UUID": f"com.apple.bookmarkgroup.{datetime.now().timestamp()}"
    }
    plist["Children"].append(folder)
    return folder

def remove_dead(node):
    if "Children" not in node:
        return
    node["Children"] = [
        c for c in node["Children"]
        if not (c.get("WebBookmarkType") == "WebBookmarkTypeLeaf" and c.get("URLString") in dead_urls)
    ]
    for c in node["Children"]:
        if c.get("WebBookmarkType") == "WebBookmarkTypeList":
            remove_dead(c)

for child in plist["Children"]:
    remove_dead(child)

folder_name = "404 - " + datetime.now().strftime("%Y-%m-%d")
folder_404 = find_or_create_folder(plist, folder_name)

for url, node in all_bookmarks:
    if url in dead_urls:
        folder_404["Children"].append(node)

def purge_old_404_folders(plist, max_age_days=30):
    cutoff = datetime.now() - timedelta(days=max_age_days)
    retained = []
    removed_titles = []

    for child in plist["Children"]:
        if child.get("WebBookmarkType") == "WebBookmarkTypeList":
            title = child.get("Title", "")
            is_404 = title.startswith("404 - ")
            is_empty = not child.get("Children")
            try:
                folder_date = datetime.strptime(title[6:], "%Y-%m-%d")
                is_old = folder_date < cutoff
            except ValueError:
                is_old = False

            if is_404 and (is_old or is_empty):
                removed_titles.append(f"{title} (empty)" if is_empty else title)
                continue

        retained.append(child)

    plist["Children"] = retained

    if removed_titles:
        with open(log_path, "a") as log:
            for title in removed_titles:
                log.write(f"[{datetime.now().isoformat()}] Deleted folder: {title}\n")

purge_old_404_folders(plist)

with plist_path.open("wb") as f:
    plistlib.dump(plist, f)

opened = 0
for item in folder_404["Children"]:
    if item.get("WebBookmarkType") == "WebBookmarkTypeLeaf" and "URLString" in item:
        subprocess.run(["open", "-a", "Safari", item["URLString"]])
        opened += 1
        if opened >= 10:
            break

print(f"[Python] Moved {len(dead_urls)} bookmarks to '{folder_name}' and opened {opened}.")
EOF

osascript -e 'display notification "404 bookmarks moved and opened in Safari." with title "Safari Bookmark Cleanup"'
echo "[$(date)] ✅ Safari bookmark check complete."
