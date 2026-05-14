#!/usr/bin/env python3
"""
Recursively fetches a single model folder from `argmaxinc/whisperkit-coreml`
on HuggingFace and writes it into the project under
`Dictly/Dictly/Resources/BundledModels/<MODEL>/`.

We don't ship the analytics/ subdirectories (they're profiling data, not
needed for inference) — that trims the bundle a bit.

Usage:  python3 scripts/fetch_bundled_model.py <model_id>
        e.g.  python3 scripts/fetch_bundled_model.py large-v3-v20240930_547MB
"""
import json
import os
import sys
import urllib.request
from pathlib import Path
from urllib.error import HTTPError

REPO = "argmaxinc/whisperkit-coreml"
API_TREE = f"https://huggingface.co/api/models/{REPO}/tree/main"
RAW = f"https://huggingface.co/{REPO}/resolve/main"
SKIP_DIRS = {"analytics"}


def list_tree(rel_path: str):
    url = f"{API_TREE}/{rel_path}"
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.load(r)


def walk(rel_path: str):
    """Yield ('file' | 'directory', relpath, size_bytes)."""
    for entry in list_tree(rel_path):
        path = entry["path"]
        typ = entry["type"]
        leaf = path.split("/")[-1]
        if typ == "directory":
            if leaf in SKIP_DIRS:
                continue
            yield from walk(path)
        else:
            size = entry.get("size") or (entry.get("lfs") or {}).get("size") or 0
            yield "file", path, size


def download(rel_path: str, target: Path):
    url = f"{RAW}/{rel_path}"
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        return False  # already present
    req = urllib.request.Request(url, headers={"User-Agent": "Dictly-bundler"})
    try:
        with urllib.request.urlopen(req, timeout=120) as r, open(target, "wb") as f:
            while True:
                chunk = r.read(1 << 20)
                if not chunk:
                    break
                f.write(chunk)
    except HTTPError as e:
        target.unlink(missing_ok=True)
        raise SystemExit(f"HTTP {e.code} downloading {rel_path}: {e.reason}")
    return True


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: fetch_bundled_model.py <model_id>")
    model_id = sys.argv[1]
    folder = f"openai_whisper-{model_id}"
    project_root = Path(__file__).resolve().parent.parent
    # BundledModels lives at the Xcode project root (alongside Dictly.xcodeproj).
    # The "Copy bundled models" Run Script build phase rsyncs from there into
    # Dictly.app/Contents/Resources/BundledModels at build time.
    out_root = project_root / "Dictly" / "BundledModels" / folder
    out_root.mkdir(parents=True, exist_ok=True)

    print(f"Fetching {folder} → {out_root.relative_to(project_root)}")
    files = list(walk(folder))
    total = sum(s for _, _, s in files)
    print(f"{len(files)} files, ~{total / 1024 / 1024:.1f} MB")

    for i, (_typ, rel, size) in enumerate(files, 1):
        rel_in_model = "/".join(rel.split("/")[1:])  # strip the folder prefix
        target = out_root / rel_in_model
        size_mb = size / 1024 / 1024
        print(f"  [{i:>3}/{len(files)}] {rel_in_model} ({size_mb:.2f} MB)")
        downloaded = download(rel, target)
        if not downloaded:
            print(f"        already present, skipped")

    print("Done.")


if __name__ == "__main__":
    main()
