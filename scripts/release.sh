#!/usr/bin/env bash
# MoMa Android release: bump version, analyze + test, build APK, publish a GitHub Release.
# Usage: scripts/release.sh <minor|patch|X.Y.Z> [--notes "text" | --notes-file path] [--dry-run]
# Policy (docs/RELEASE.md): every release gets a new version; 0.MINOR.PATCH until 1.0.0;
# MINOR = new features, PATCH = fixes only; +BUILD always increments by 1 and never resets.
set -euo pipefail

die() { echo "Loi: $*" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/apps/android"
PUBSPEC="$APP/pubspec.yaml"

BUMP=""
NOTES_TEXT=""
NOTES_FILE=""
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --notes) NOTES_TEXT="${2:-}"; shift 2 ;;
    --notes-file) NOTES_FILE="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    *) [ -z "$BUMP" ] || die "thua tham so: $1"; BUMP="$1"; shift ;;
  esac
done
[ -n "$BUMP" ] || die "can chi dinh minor, patch hoac X.Y.Z (moi lan phat hanh phai co phien ban moi)"
[ -z "$NOTES_FILE" ] || [ -f "$NOTES_FILE" ] || die "khong thay file ghi chu: $NOTES_FILE"

cd "$ROOT"
command -v gh >/dev/null || die "chua cai gh CLI"
command -v flutter >/dev/null || die "khong tim thay flutter trong PATH"
gh auth status >/dev/null 2>&1 || die "gh chua dang nhap (gh auth login)"

# 1. Clean tree
[ -z "$(git status --porcelain)" ] || die "cay git chua sach; commit hoac stash truoc khi phat hanh"

# 2. Next version
CUR_LINE="$(grep -E '^version:' "$PUBSPEC")"
[[ "$CUR_LINE" =~ ^version:[[:space:]]*([0-9]+)\.([0-9]+)\.([0-9]+)\+([0-9]+)[[:space:]]*$ ]] \
  || die "khong doc duoc 'version: X.Y.Z+N' trong pubspec.yaml"
MA="${BASH_REMATCH[1]}"; MI="${BASH_REMATCH[2]}"; PA="${BASH_REMATCH[3]}"; BUILD="${BASH_REMATCH[4]}"
CUR="$MA.$MI.$PA"
case "$BUMP" in
  minor) NEW="$MA.$((MI + 1)).0" ;;
  patch) NEW="$MA.$MI.$((PA + 1))" ;;
  *)
    [[ "$BUMP" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "phien ban khong hop le: $BUMP"
    NEW="$BUMP"
    newest="$(printf '%s\n%s\n' "$CUR" "$NEW" | sort -V | tail -1)"
    { [ "$NEW" != "$CUR" ] && [ "$newest" = "$NEW" ]; } || die "$NEW phai lon hon phien ban hien tai $CUR"
    ;;
esac
NEW_BUILD=$((BUILD + 1))
FULL="$NEW+$NEW_BUILD"
TAG="v$FULL"
echo "Phat hanh: $CUR+$BUILD -> $FULL (tag $TAG)"

# 3. Version / tag must not exist yet
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG da ton tai (local)"
git fetch --tags --quiet origin || die "khong fetch duoc tag tu origin"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG da ton tai tren origin"
if git tag --list "v$NEW+*" | grep -q .; then die "phien ban $NEW da duoc phat hanh ($(git tag --list "v$NEW+*" | tr '\n' ' '))"; fi
gh release view "$TAG" >/dev/null 2>&1 && die "GitHub Release $TAG da ton tai"

# 4. Analyze + tests
( cd "$APP" && flutter analyze ) || die "flutter analyze that bai"
( cd "$APP" && flutter test ) || die "flutter test that bai"

# 5. Bump every versioned file (scripts/check-versions.mjs keeps them in sync)
FILES=(VERSION apps/api/package.json apps/api/src/shared/version.ts apps/android/pubspec.yaml)
restore() { git checkout -- "${FILES[@]}" 2>/dev/null || true; }
trap 'echo "That bai, khoi phuc file phien ban"; restore' ERR
printf '%s\n' "$NEW" > VERSION
sed -i.bak -E "0,/\"version\": \"[^\"]+\"/s//\"version\": \"$NEW\"/" apps/api/package.json && rm -f apps/api/package.json.bak
sed -i.bak -E "s/API_VERSION = \"[^\"]+\"/API_VERSION = \"$NEW\"/" apps/api/src/shared/version.ts && rm -f apps/api/src/shared/version.ts.bak
sed -i.bak -E "s/^version:.*/version: $FULL/" "$PUBSPEC" && rm -f "$PUBSPEC.bak"
if command -v node >/dev/null; then node scripts/check-versions.mjs; fi

# 6. Build
( cd "$APP" && flutter build apk --release --target-platform android-arm64 )
mkdir -p dist
APK="dist/MoMa-$FULL.apk"
cp "$APP/build/app/outputs/flutter-apk/app-release.apk" "$APK"
echo "APK: $APK ($(sha256sum "$APK" | cut -d' ' -f1))"

if [ "$DRY_RUN" = 1 ]; then
  trap - ERR
  restore
  echo "Dry run: da build, khong commit/push/phat hanh; da khoi phuc file phien ban."
  exit 0
fi

# 7. Release notes
NOTES_TMP="$(mktemp)"
if [ -n "$NOTES_FILE" ]; then
  cp "$NOTES_FILE" "$NOTES_TMP"
elif [ -n "$NOTES_TEXT" ]; then
  printf '%s\n' "$NOTES_TEXT" > "$NOTES_TMP"
else
  LAST_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
  {
    echo "## Thay doi"
    if [ -n "$LAST_TAG" ]; then git log --no-merges --pretty='- %s' "$LAST_TAG..HEAD"; else git log --no-merges --pretty='- %s' -n 30; fi
  } > "$NOTES_TMP"
fi

# 8. Commit, push, publish
trap - ERR
git add "${FILES[@]}"
git commit -m "release: MoMa $FULL"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git push origin "$BRANCH"
gh release create "$TAG" "$APK" --target "$(git rev-parse HEAD)" --title "MoMa $NEW (build $NEW_BUILD)" --notes-file "$NOTES_TMP"
rm -f "$NOTES_TMP"
echo "Da phat hanh $TAG"
