#!/usr/bin/env python3
"""
Verify a Google Photos -> Immich migration against an INDEPENDENT inventory.

Lesson from the Akita article: his copy tool reported success while silently skipping
~900 GB. Don't trust the importer; count the source yourself and diff it.

Usage:
  python3 -I scripts/verify-takeout.py /path/to/extracted/Takeout [--env /etc/obento/.env]

What it does:
  1. Walks the extracted Takeout, collects unique media files (by filename + size; Takeout
     duplicates photos across "Photos from YYYY" and album folders).
  2. Pulls every asset's original filename from the Immich API.
  3. Prints totals per year and writes missing.txt listing files Immich doesn't have.
Do NOT cancel Google One until missing.txt is empty (or every entry is explained) AND one
full off-site backup has completed.
"""
import argparse, json, os, re, sys, urllib.request
from collections import Counter

MEDIA = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".gif", ".webp", ".tif", ".tiff", ".bmp",
         ".dng", ".cr2", ".nef", ".arw", ".raf", ".orf", ".rw2",
         ".mp4", ".mov", ".m4v", ".3gp", ".avi", ".mkv", ".mts", ".m2ts", ".webm", ".mpg"}

def load_env(path):
    env = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip().strip('"').strip("'")
    return env

def takeout_inventory(root):
    seen, per_year, total_bytes = {}, Counter(), 0
    for d, _, files in os.walk(root):
        m = re.search(r"Photos from (\d{4})", d)
        year = m.group(1) if m else None
        for fn in files:
            ext = os.path.splitext(fn)[1].lower()
            if ext not in MEDIA:
                continue
            p = os.path.join(d, fn)
            try:
                size = os.path.getsize(p)
            except OSError:
                continue
            key = (fn.lower(), size)
            if key in seen:
                if year and not seen[key][1]:
                    seen[key] = (p, year)
                continue
            seen[key] = (p, year)
            total_bytes += size
    for _, y in seen.values():
        per_year[y or "albums-only"] += 1
    return seen, per_year, total_bytes

def immich_assets(url, key):
    names, page = Counter(), 1
    while page:
        body = json.dumps({"page": page, "size": 1000, "withDeleted": False}).encode()
        req = urllib.request.Request(f"{url.rstrip('/')}/api/search/metadata", data=body,
                                     headers={"x-api-key": key, "Content-Type": "application/json",
                                              "Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as r:
            data = json.load(r)
        assets = data.get("assets", {})
        for a in assets.get("items", []):
            names[(a.get("originalFileName") or "").lower()] += 1
        nxt = assets.get("nextPage")
        page = int(nxt) if nxt else 0
        print(f"\r  fetched {sum(names.values())} assets from Immich", end="", flush=True)
    print()
    return names

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("takeout")
    ap.add_argument("--env", default="/etc/obento/.env")
    ap.add_argument("--out", default="missing.txt")
    a = ap.parse_args()
    env = load_env(a.env)
    url, key = env.get("IMMICH_URL", "http://localhost:2283"), env.get("IMMICH_API_KEY")
    if not key:
        sys.exit("Set IMMICH_API_KEY in your .env (Immich > Account Settings > API Keys).")

    print(f"Scanning Takeout at {a.takeout} ...")
    seen, per_year, total_bytes = takeout_inventory(a.takeout)
    print(f"  {len(seen)} unique media files, {total_bytes/1e9:.1f} GB")
    print("Querying Immich ...")
    names = immich_assets(url, key)

    remaining = Counter(names)
    missing = []
    for (fn, _size), (path, _y) in sorted(seen.items(), key=lambda kv: kv[1][0]):
        if remaining[fn] > 0:
            remaining[fn] -= 1
        else:
            missing.append(path)

    print("\nTakeout files per year:")
    for y in sorted(per_year):
        print(f"  {y}: {per_year[y]}")
    print(f"\nTakeout unique media : {len(seen)}")
    print(f"Immich assets        : {sum(names.values())}")
    print(f"Missing from Immich  : {len(missing)}")
    with open(a.out, "w") as f:
        f.write("\n".join(missing))
    print(f"Wrote {a.out}")
    if missing:
        print("Re-run immich-go for these, or inspect them (corrupt? unsupported format?).")
        sys.exit(2)
    print("All Takeout media accounted for. Next: confirm one full B2 backup, then cancel Google One.")

if __name__ == "__main__":
    main()
