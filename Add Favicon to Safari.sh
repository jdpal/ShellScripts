#!/bin/bash

BOOKMARKS_PLIST=~/Library/Safari/Bookmarks.plist
TMP_FILE=$(mktemp)

# Convert plist to XML for parsing
plutil -convert xml1 -o "$TMP_FILE" "$BOOKMARKS_PLIST"

# Extract URLs
URLS=$(xmllint --xpath "//string[starts-with(text(),'http')]/text()" "$TMP_FILE" 2>/dev/null | tr ' ' '\n' | grep -E '^http(s)?://')

echo "Triggering Safari to fetch favicons..."

for url in $URLS; do
/usr/bin/osascript <<EOF
tell application "Safari"
    activate
    set theTab to make new tab at end of tabs of front window
    set URL of theTab to "$url"
    delay 5
    try
        close theTab
    end try
end tell
EOF
done

rm "$TMP_FILE"

echo "[✓] Attempted favicon preloading via Safari tabs."
