#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
# Sync the private dev repo (~/dictly) → the public GitHub mirror
# (~/dictly_github), excluding internal docs, design source-of-truth,
# bundled model binary, and Xcode/SwiftPM build mess.
#
# Workflow:
#   1. You work as usual in ~/dictly (private remote on Bitbucket).
#   2. When you're ready to publish a release on GitHub, run:
#        ./scripts/sync_to_public.sh
#      It mirrors the public files into ~/dictly_github.
#   3. cd ~/dictly_github && git add . && git commit && git push
#
# Notes:
#   • Uses rsync --delete so the mirror stays clean. Files unique
#     to the public repo (README.md, LICENSE, .github/, CONTRIBUTING,
#     CODE_OF_CONDUCT, .gitignore) are protected from deletion via
#     --exclude — edit them in ~/dictly_github directly.
#   • Doesn't touch git state. Doesn't commit. Doesn't push. You
#     review the diff and ship at your own pace.
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

SRC="${SRC:-$HOME/dictly}"
DST="${DST:-$HOME/dictly_github}"

if [[ ! -d "$SRC" ]]; then
  echo "ERROR: source directory not found: $SRC" >&2
  exit 1
fi
if [[ ! -d "$DST" ]]; then
  echo "ERROR: destination directory not found: $DST" >&2
  echo "Create it first and `git init` inside." >&2
  exit 1
fi
if [[ ! -d "$DST/.git" ]]; then
  echo "ERROR: $DST is not a git repository — refusing to sync." >&2
  exit 1
fi

echo "Source:      $SRC"
echo "Destination: $DST"
echo

rsync -av --delete \
  --exclude='.git/' \
  --exclude='.DS_Store' \
  --exclude='**/.DS_Store' \
  --exclude='.claude/' \
  \
  --exclude='.gitignore' \
  --exclude='README.md' \
  --exclude='LICENSE' \
  --exclude='CONTRIBUTING.md' \
  --exclude='CODE_OF_CONDUCT.md' \
  --exclude='SECURITY.md' \
  --exclude='.github/' \
  \
  --exclude='CLAUDE.md' \
  --exclude='ARCHITECTURE.md' \
  --exclude='handoff/' \
  --exclude='docs/' \
  \
  --include='Dictly/' \
  --include='Dictly/BundledModels/' \
  --include='Dictly/BundledModels/openai_whisper-base/' \
  --include='Dictly/BundledModels/openai_whisper-base/***' \
  --exclude='Dictly/BundledModels/*' \
  --exclude='Dictly-AppStore.entitlements' \
  --exclude='*App Store*.xcscheme' \
  \
  --exclude='build/' \
  --exclude='DerivedData/' \
  --exclude='xcuserdata/' \
  --exclude='*.xcuserstate' \
  --exclude='.swiftpm/' \
  --exclude='.build/' \
  --exclude='Package.resolved' \
  --exclude='*.xcarchive' \
  \
  --exclude='Dictly-*.zip' \
  --exclude='*.app' \
  --exclude='*.dSYM' \
  --exclude='*.dSYM.zip' \
  \
  "$SRC"/ "$DST"/

# ── Strip App-Store-only bits and personal Team ID from the synced
#    pbxproj. The dev repo's project file contains:
#      • two `Release-AppStore` XCBuildConfiguration blocks (one project-
#        level, one target-level), each ending with
#        `name = "Release-AppStore";` and the matching `};` closer
#      • reference lines in `buildConfigurations` arrays
#      • `DEVELOPMENT_TEAM = L8VY5GY44N` lines
#    None of these belong in a public repo. We post-process the file
#    here so contributors get a clean, team-agnostic Direct build.
PBX="$DST/Dictly/Dictly.xcodeproj/project.pbxproj"
if [[ -f "$PBX" ]]; then
  awk '
    BEGIN { skip = 0; depth = 0 }
    # Enter skip mode on the opening line of either Release-AppStore block.
    /^[ \t]*1AB4B2C[AB][0-9A-F]+ \/\* Release-AppStore \*\/ = \{/ {
      skip = 1
      depth = 1
      next
    }
    # While inside a skipped block, count braces to know when it closes.
    skip {
      n_open = gsub(/\{/, "{", $0)
      n_close = gsub(/\}/, "}", $0)
      depth += n_open - n_close
      if (depth <= 0) { skip = 0 }
      next
    }
    # Strip the inline references in `buildConfigurations = (...)` arrays.
    /^[ \t]+1AB4B2C[AB][0-9A-F]+ \/\* Release-AppStore \*\/,[ \t]*$/ { next }
    # Strip the personal Apple Team ID — public repo should let each
    # contributor set their own via Xcode UI.
    /DEVELOPMENT_TEAM = / { next }
    { print }
  ' "$PBX" > "$PBX.cleaned" && mv "$PBX.cleaned" "$PBX"

  # Sanity check
  if grep -q "Release-AppStore\|Dictly-AppStore\|DEVELOPMENT_TEAM" "$PBX"; then
    echo "WARNING: pbxproj cleanup left residue — inspect $PBX manually:" >&2
    grep -n "Release-AppStore\|Dictly-AppStore\|DEVELOPMENT_TEAM" "$PBX" >&2
  fi
fi

# rsync's `--exclude='.DS_Store'` protects .DS_Store entries from being
# `--delete`'d in the destination, which means any Finder-spawned ones
# linger forever. Sweep them out explicitly.
find "$DST" -name '.DS_Store' -not -path '*/.git/*' -delete 2>/dev/null

# Belt-and-braces: even with rsync exclude patterns, the App Store scheme
# file (which has a literal space in its name) sometimes slips through
# depending on rsync version. Nuke any *App Store*.xcscheme directly.
find "$DST" -name '*App Store*.xcscheme' -not -path '*/.git/*' -delete 2>/dev/null

# Same for the App Store entitlements file — defence in depth.
find "$DST" -name 'Dictly-AppStore.entitlements' -not -path '*/.git/*' -delete 2>/dev/null

# Wipe per-user Xcode state — `xcuserdata/` directories carry the macOS
# username in their path (e.g. `valery.xcuserdatad`) and the .xcuserstate
# binary inside includes window-position / focus state. None of it should
# leak into a public repo. rsync's --exclude protects these from --delete,
# so we sweep them explicitly here.
find "$DST" -type d -name 'xcuserdata' -not -path '*/.git/*' -exec rm -rf {} + 2>/dev/null
find "$DST" -name '*.xcuserstate' -not -path '*/.git/*' -delete 2>/dev/null
find "$DST" -name 'Package.resolved' -not -path '*/.git/*' -delete 2>/dev/null

echo
echo "── Mirror complete (AppStore config + Team ID stripped) ─────"
echo

# Show the user what's changed in the public repo
( cd "$DST" && {
    echo "Changes ready to commit in $DST:"
    git status -s
    echo
    if git diff --quiet --exit-code && [[ -z "$(git ls-files --others --exclude-standard)" ]]; then
      echo "(nothing to commit — working tree clean)"
    else
      echo "Next steps:"
      echo "  cd $DST"
      echo "  git diff --stat"
      echo "  git add ."
      echo "  git commit -m 'Sync from internal repo'"
      echo "  git push"
    fi
  } )
