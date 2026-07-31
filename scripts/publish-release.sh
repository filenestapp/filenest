#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/publish-release.sh VERSION [--prerelease] [--dry-run]

Validates the macOS and Windows version numbers, creates (or reuses) the
matching vVERSION tag, and starts the signed release workflow on GitHub.
The workflow signs, notarizes, uploads GitHub assets, and publishes the
Sparkle update archive and appcast metadata.
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

version="$1"
shift
prerelease=false
dry_run=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prerelease) prerelease=true ;;
    --dry-run) dry_run=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "VERSION must use semantic version format, such as 0.2.6." >&2
  exit 2
fi

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root_dir"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Refusing to publish from a dirty working tree." >&2
  exit 1
fi

macos_version="$(awk -F ' = ' '/MARKETING_VERSION = / { print $2; exit }' FileNest.xcodeproj/project.pbxproj | tr -d ';')"
windows_version="$(node -p "require('./FileNestWindows/package.json').version")"
if [[ "$macos_version" != "$version" || "$windows_version" != "$version" ]]; then
  echo "Version mismatch: macOS=$macos_version, Windows=$windows_version, requested=$version" >&2
  exit 1
fi

tag="v$version"
tag_created=false
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  tag_commit="$(git rev-list -n 1 "$tag")"
  head_commit="$(git rev-parse HEAD)"
  if [[ "$tag_commit" != "$head_commit" ]]; then
    echo "$tag already exists and does not point to HEAD; refusing to move a release tag." >&2
    exit 1
  fi
else
  if [[ "$dry_run" == true ]]; then
    echo "[dry-run] Would create and push $tag"
  else
    git tag -a "$tag" -m "FileNest $version"
    git push origin "$tag"
    tag_created=true
  fi
fi

if [[ "$dry_run" == true ]]; then
  echo "[dry-run] Would dispatch release.yml for $tag"
  exit 0
fi

if [[ "$tag_created" == true ]]; then
  echo "Tag push started the release workflow automatically."
  echo "Monitor it with: gh run list --repo filenestapp/filenest --workflow release.yml"
  exit 0
fi

gh workflow run release.yml \
  --repo filenestapp/filenest \
  --ref main \
  -f "release_tag=$tag" \
  -f publish_release=true \
  -f "prerelease=$prerelease"

echo "Release workflow dispatched. Monitor with: gh run list --repo filenestapp/filenest --workflow release.yml"
