#!/bin/zsh
# Builds a notarized SelfStore for Mac, publishes it as a GitHub release and updates the website.
#
#   scripts/deploy.sh ["Release notes"]
#
# The build runs through the SelfStore already running on this Mac (http://localhost:8765), which
# archives, signs with Developer ID, notarizes and packages a .dmg and .zip. Set up signing in
# SelfStore ▸ Settings first. Needs `gh auth login`.
#
# The release carries SelfStore.dmg and SelfStore.zip, so the website's download link
# (…/releases/latest/download/SelfStore.dmg) always points at the newest build.
#
# Env: SELFSTORE_URL (default http://localhost:8765), ALLOW_UNNOTARIZED=1 to publish an
# un-notarized build, DRAFT=1 to create a draft release, DRY_RUN=1 to build and download only.
set -euo pipefail
cd "${0:A:h}/.."
ROOT=$PWD
API=${SELFSTORE_URL:-http://localhost:8765}/api
NOTES=${1:-}

say() { print -P "%F{cyan}==>%f $*"; }
die() { print -P "%F{red}error:%f $*" >&2; exit 1; }
json() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }

if [[ ${DRY_RUN:-0} != 1 ]]; then
  command -v gh >/dev/null || die "Install the GitHub CLI: brew install gh"
  gh auth status >/dev/null 2>&1 || die "Run gh auth login first"
  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner) || die "No GitHub repo for this checkout (gh repo create)"
fi
curl -sf "$API/info" >/dev/null || die "SelfStore isn't running at $API. Open SelfStore on this Mac."

if [[ ${DRY_RUN:-0} != 1 && -n $(git status --porcelain -- . ':!docs/latest.json') ]]; then
  print -P "%F{yellow}warning:%f the working tree has uncommitted changes; they'll be in the build but not in the tagged commit."
  read -q "?Continue? [y/N] " || { echo; exit 1; }; echo
fi

# 1. Make sure SelfStore knows this checkout's Mac scheme.
command -v xcodegen >/dev/null && xcodegen generate --quiet
PROJ=$(curl -sf "$API/projects" | json '[p["id"] for p in d if p.get("platform")=="macos" and p.get("name")=="SelfStoreMac"][:1]' | tr -d "[]' ")
if [[ -z $PROJ ]]; then
  say "Adding $ROOT/SelfStore.xcodeproj to SelfStore"
  PROJ=$(curl -sf -X POST "$API/projects" -H 'Content-Type: application/json' \
    -d "{\"path\":\"$ROOT/SelfStore.xcodeproj\",\"scheme\":\"SelfStoreMac\",\"platform\":\"macos\"}" | json 'd["id"]')
fi

# 2. Build, sign, notarize.
say "Building $PROJ (archive, notarize, package)…"
curl -sf -X POST "$API/projects/$PROJ/build" >/dev/null || die "Couldn't start the build"
last=""
while true; do
  sleep 5
  P=$(curl -sf "$API/projects/$PROJ")
  state=$(print -r -- $P | json 'd.get("state","")')
  step=$(print -r -- $P | json 'd.get("step") or ""')
  [[ $step != $last ]] && { echo "   $step"; last=$step; }
  case $state in
    succeeded) break ;;
    failed|cancelled) die "Build $state: $(print -r -- $P | json 'd.get("error") or d.get("step")'). Log: $API/projects/$PROJ/log" ;;
  esac
done

VERSION=$(print -r -- $P | json 'd.get("version") or ""')
BUILD=$(print -r -- $P | python3 -c 'import json,re,sys; m=re.search(r"\((\d+)\)", json.load(sys.stdin).get("step") or ""); print(m.group(1) if m else "")')
NOTARIZED=$(print -r -- $P | json 'd.get("notarized") is True')
[[ -n $VERSION ]] || die "The build didn't report a version"
[[ $NOTARIZED == True || ${ALLOW_UNNOTARIZED:-0} == 1 ]] || die "The build wasn't notarized (set up Developer ID signing in SelfStore, or ALLOW_UNNOTARIZED=1)"

# 3. Download the artifacts under stable names.
OUT=build/release; mkdir -p $OUT; rm -f build/release/SelfStore.dmg build/release/SelfStore.zip
for kind in dmg zip; do
  apath=$(print -r -- $P | json "[a['path'] for a in d.get('artifacts') or [] if a['name'].endswith('.$kind')][0]")
  curl -sf "${API%/api}$apath" -o $OUT/SelfStore.$kind || die "Couldn't download the .$kind"
done
if [[ $NOTARIZED == True ]]; then xcrun stapler validate $OUT/SelfStore.dmg >/dev/null || die "The dmg isn't stapled"; fi
if [[ ${DRY_RUN:-0} == 1 ]]; then say "Dry run: built $VERSION ($BUILD), notarized=$NOTARIZED → $OUT"; exit 0; fi

# 4. Tag and release.
TAG=v$VERSION
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || gh release view $TAG >/dev/null 2>&1; then
  TAG=v$VERSION-${BUILD:-$(date -u +%Y%m%d%H%M)}
fi
if [[ -z $NOTES ]]; then
  prev=$(git describe --tags --abbrev=0 2>/dev/null || true)
  if [[ -n $prev ]]; then range=("$prev..HEAD"); else range=(-20); fi
  NOTES=$(git log --pretty='- %s' $range | grep -v '^- Website: ' | head -30 || true)
fi
say "Releasing $TAG on $REPO"
git push -q origin HEAD
gh release create $TAG $OUT/SelfStore.dmg $OUT/SelfStore.zip --target $(git rev-parse HEAD) \
  --title "SelfStore $VERSION${BUILD:+ ($BUILD)}" --notes "${NOTES:-SelfStore $VERSION}" ${DRAFT:+--draft}
git fetch -q --tags

# 5. Point the website at it.
DMG_SIZE=$(stat -f %z $OUT/SelfStore.dmg)
cat > docs/latest.json <<EOF
{
  "version": "$VERSION",
  "build": "$BUILD",
  "tag": "$TAG",
  "date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "repo": "$REPO",
  "dmg": "https://github.com/$REPO/releases/download/$TAG/SelfStore.dmg",
  "zip": "https://github.com/$REPO/releases/download/$TAG/SelfStore.zip",
  "dmgSize": $DMG_SIZE,
  "minimumSystemVersion": "$(sed -n 's/.*macOS: *"\{0,1\}\([0-9.]*\).*/\1/p' project.yml | head -1)",
  "notarized": $([[ $NOTARIZED == True ]] && echo true || echo false)
}
EOF
git add docs/latest.json
git commit -q -m "Website: SelfStore $VERSION${BUILD:+ ($BUILD)}" -- docs/latest.json
git push -q origin HEAD

# 6. Make sure GitHub Pages serves docs/ (first deploy only).
if ! gh api "repos/$REPO/pages" >/dev/null 2>&1; then
  say "Turning on GitHub Pages (main /docs)"
  gh api -X POST "repos/$REPO/pages" -f 'source[branch]=main' -f 'source[path]=/docs' >/dev/null \
    || print -P "%F{yellow}warning:%f couldn't enable Pages. Turn it on in the repo's Settings ▸ Pages (branch main, folder /docs)."
fi
PAGES=$(gh api "repos/$REPO/pages" -q .html_url 2>/dev/null || echo "https://${REPO%%/*}.github.io/${REPO#*/}/")
say "Done: https://github.com/$REPO/releases/tag/$TAG"
say "Website: $PAGES (updates in a minute or two)"
