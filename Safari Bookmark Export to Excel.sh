#!/bin/bash

# === CONFIG ===
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M")
VENV="$HOME/.venvs/safari-bookmarks"
PYTHON="$VENV/bin/python3"
PIP="$VENV/bin/pip"
export OUTPUT_XLSX="$HOME/Desktop/Safari_Bookmarks_Export_$TIMESTAMP.xlsx"

# === SETUP VIRTUALENV ===
if [ ! -x "$PYTHON" ]; then
    echo "📦 Creating virtual environment..."
    /usr/bin/env python3 -m venv "$VENV"
fi

"$PIP" install --quiet --disable-pip-version-check requests beautifulsoup4 openpyxl

# === RUN PYTHON ===
"$PYTHON" - <<EOF
import os, re, urllib.parse, requests, plistlib
from bs4 import BeautifulSoup
from concurrent.futures import ThreadPoolExecutor, as_completed
from openpyxl import Workbook
from openpyxl.utils import get_column_letter

BOOKMARKS_PATH = os.path.expanduser("~/Library/Safari/Bookmarks.plist")
OUTPUT_PATH = os.path.expanduser(os.environ["OUTPUT_XLSX"])
MAX_WORKERS = 10

def is_local_url(url):
    host = urllib.parse.urlparse(url).hostname or ''
    return host.startswith(("127.", "192.168.", "10.", "localhost")) or \
           re.match(r"^172\\.(1[6-9]|2[0-9]|3[0-1])\\.", host)

def fetch_description(url):
    try:
        r = requests.get(url, headers={"User-Agent": "Mozilla/5.0"}, timeout=5)
        s = BeautifulSoup(r.content, "html.parser")
        tag = s.find("meta", attrs={"name": "description"}) or \
              s.find("meta", attrs={"property": "og:description"})
        return tag["content"].strip() if tag and tag.get("content") else ""
    except Exception:
        return ""

def extract(children, path=None):
    path = path or []
    entries = []
    for child in children:
        if child.get("WebBookmarkType") == "WebBookmarkTypeList":
            entries += extract(child.get("Children", []), path + [child.get("Title", "Untitled Folder")])
        elif child.get("WebBookmarkType") == "WebBookmarkTypeLeaf":
            url = child.get("URLString", "")
            if url and not is_local_url(url):
                title = child.get("URIDictionary", {}).get("title", "")
                entries.append((" > ".join(path), title, url))
    return entries

def parse_url_parts(url):
    try:
        parsed = urllib.parse.urlparse(url)
        return parsed.netloc, parsed.path or "/"
    except:
        return "", "/"

with open(BOOKMARKS_PATH, "rb") as f:
    data = plistlib.load(f)

entries = extract(data.get("Children", []))
results = []

with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
    future_map = {executor.submit(fetch_description, url): (p, t, url) for p, t, url in entries}
    for future in as_completed(future_map):
        folder, title, url = future_map[future]
        desc = future.result()
        domain, path = parse_url_parts(url)
        results.append((folder, title, domain, path, url, desc))

wb = Workbook()
ws = wb.active
ws.title = "Safari Bookmarks"
ws.append(["Folder Path", "Bookmark Title", "Domain", "Path", "URL", "Website Description"])

for row in results:
    ws.append(row)

for col in ws.columns:
    width = max(len(str(cell.value)) if cell.value else 0 for cell in col)
    ws.column_dimensions[get_column_letter(col[0].column)].width = min(width + 2, 60)

wb.save(OUTPUT_PATH)
print(f"✅ Bookmarks exported to: {OUTPUT_PATH}")
EOF

# === OPEN RESULT FILE ===
[ -f "$OUTPUT_XLSX" ] && open "$OUTPUT_XLSX" || echo "❌ Export failed"
