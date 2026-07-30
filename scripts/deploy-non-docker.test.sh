#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/website/downloads"
printf '<!doctype html><title>FileNest</title>\n' > "$TMP_DIR/website/index.html"
printf 'installer-data\n' > "$TMP_DIR/website/downloads/FileNest-test.dmg"
touch "$TMP_DIR/id_rsa"

bash "$ROOT_DIR/scripts/deploy-non-docker.sh" \
  --host example.com \
  --user deploy \
  --port 2222 \
  --key "$TMP_DIR/id_rsa" \
  --remote-dir /home/deploy/filenest \
  --website-dir "$TMP_DIR/website" \
  --package "$TMP_DIR/website/downloads/FileNest-test.dmg" \
  --r2-prefix releases \
  --goarch arm64 \
  --dry-run \
  > "$TMP_DIR/dry-run.log"

grep -Fq '[Deploy] Target: deploy@example.com:/home/deploy/filenest' "$TMP_DIR/dry-run.log"
grep -Fq '[Deploy] Source mode: direct upload (no Git)' "$TMP_DIR/dry-run.log"
grep -Fq '[Deploy] Backend: local linux/arm64 build -> /usr/local/bin/filenest-update-api' "$TMP_DIR/dry-run.log"
grep -Fq "s3://<R2_BUCKET>/releases/FileNest-test.dmg" "$TMP_DIR/dry-run.log"
if grep -Fq 'git clone' "$TMP_DIR/dry-run.log"; then
  echo "Deployment must not use Git." >&2
  exit 1
fi

if bash "$ROOT_DIR/scripts/deploy-non-docker.sh" \
  --host example.com \
  --website-dir "$TMP_DIR/website" \
  --skip-r2 \
  --goarch unsupported \
  --dry-run > "$TMP_DIR/invalid.log" 2>&1; then
  echo "Unsupported Go architectures must be rejected." >&2
  exit 1
fi
grep -Fq 'unsupported --goarch value' "$TMP_DIR/invalid.log"

bash "$ROOT_DIR/scripts/deploy-non-docker.sh" \
  --host example.com \
  --website-dir "$TMP_DIR/website" \
  --skip-r2 \
  --skip-backend \
  --dry-run \
  > "$TMP_DIR/static-only.log"

grep -Fq '[Deploy] Website:' "$TMP_DIR/static-only.log"
grep -Fq '[Deploy] Backend: skipped' "$TMP_DIR/static-only.log"
grep -Fq '[Deploy] Reverse proxy: configure domains/TLS' "$TMP_DIR/static-only.log"
grep -Fq '[Deploy] R2 upload: skipped' "$TMP_DIR/static-only.log"

printf 'arm64\n' > "$TMP_DIR/architecture.cache"
FILENEST_ARCH_CACHE_FILE="$TMP_DIR/architecture.cache" \
bash "$ROOT_DIR/scripts/deploy-non-docker.sh" \
  --host example.com \
  --website-dir "$TMP_DIR/website" \
  --skip-r2 \
  --goarch auto \
  --dry-run \
  > "$TMP_DIR/cached-architecture.log"

grep -Fq '[Architecture] Using cached server architecture: arm64' "$TMP_DIR/cached-architecture.log"
grep -Fq '[Deploy] Backend: local linux/arm64 build' "$TMP_DIR/cached-architecture.log"

cat > "$TMP_DIR/bin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_SSH_LOG"
if [[ "$*" == *"uname -m"* ]]; then
  printf 'x86_64\n'
else
  cat >/dev/null
fi
SH

cat > "$TMP_DIR/bin/rsync" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_RSYNC_LOG"
SH

cat > "$TMP_DIR/bin/aws" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_AWS_LOG"
if [[ "${1:-}" == "s3api" && "${2:-}" == "head-object" ]]; then
  printf '%s\n' "$FAKE_PACKAGE_SIZE"
fi
SH

chmod +x "$TMP_DIR/bin/ssh" "$TMP_DIR/bin/rsync" "$TMP_DIR/bin/aws"
: > "$TMP_DIR/ssh.log"
: > "$TMP_DIR/rsync.log"
: > "$TMP_DIR/aws.log"
package_size="$(wc -c < "$TMP_DIR/website/downloads/FileNest-test.dmg" | tr -d '[:space:]')"

PATH="$TMP_DIR/bin:$PATH" \
FAKE_SSH_LOG="$TMP_DIR/ssh.log" \
FAKE_RSYNC_LOG="$TMP_DIR/rsync.log" \
FAKE_AWS_LOG="$TMP_DIR/aws.log" \
FAKE_PACKAGE_SIZE="$package_size" \
FILENEST_ARCH_CACHE_FILE="$TMP_DIR/probed-architecture.cache" \
R2_ENDPOINT="https://example.r2.cloudflarestorage.com" \
R2_ACCESS_KEY_ID="test-access-key" \
R2_SECRET_ACCESS_KEY="test-secret-key" \
R2_BUCKET="test-bucket" \
bash "$ROOT_DIR/scripts/deploy-non-docker.sh" \
  --host example.com \
  --user deploy \
  --remote-dir /home/deploy/filenest \
  --skip-website \
  --package "$TMP_DIR/website/downloads/FileNest-test.dmg" \
  --r2-prefix releases \
  > "$TMP_DIR/integration.log"

grep -Fxq 'amd64' "$TMP_DIR/probed-architecture.cache"
grep -Fq 'uname -m' "$TMP_DIR/ssh.log"
grep -Fq 's3 cp' "$TMP_DIR/aws.log"
grep -Fq 's3://test-bucket/releases/FileNest-test.dmg' "$TMP_DIR/aws.log"
grep -Fq 's3api head-object' "$TMP_DIR/aws.log"
grep -Fq '[R2] Verified s3://test-bucket/releases/FileNest-test.dmg' "$TMP_DIR/integration.log"
grep -Fq 'Deploy finished successfully.' "$TMP_DIR/integration.log"

echo "deploy-non-docker script tests passed"
