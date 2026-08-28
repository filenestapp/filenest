#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  scripts/deploy-non-docker.sh [options]

Build the FileNest update API locally, upload the compiled Linux binary and
the prebuilt static website directly to the production server, then upload
installer packages to Cloudflare R2. Git is not used on the server.

SSH and upload options:
  --host HOST             SSH host (required unless FILENEST_DEPLOY_HOST is set)
  --user USER             SSH user (default: FILENEST_DEPLOY_USER or deploy)
  --port PORT             SSH port (default: FILENEST_DEPLOY_SSH_PORT or 22)
  --key PATH              SSH private key (default: FILENEST_DEPLOY_KEY)
  --remote-dir PATH       Remote staging root (default: FILENEST_REMOTE_DIR)

Website and backend options:
  --website-dir PATH      Prebuilt static website directory (default: website)
  --web-root PATH         Remote website document root
                         (default: /var/www/filenestapp.com)
  --web-owner USER        Remote website file owner (default: www)
  --web-group GROUP       Remote website file group (default: www)
  --site-domain DOMAIN    Website domain (default: filenestapp.com)
  --skip-website          Do not upload or activate the website
  --skip-backend          Do not build, upload, or restart the update API
  --goarch ARCH           Linux architecture: auto, amd64, or arm64 (default: auto)
  --refresh-architecture  Ignore the cached architecture and probe the server again

The server's web stack owns domain, TLS, and reverse-proxy configuration. This
script does not modify the proxy. Configure the update API domain to proxy to
127.0.0.1:8080.

R2 options:
  --env-file PATH         Load deployment and R2 variables from a shell env file
                         (default: FILENEST_DEPLOY_ENV_FILE or configs/deploy.env)
  --package PATH          Installer to upload; may be specified multiple times
                         (default: every file in website/downloads)
  --r2-prefix PREFIX      R2 object prefix (default: downloads)
  --skip-r2               Do not upload installer packages to R2

Other:
  --dry-run               Print planned actions without building or changing anything
  --help                  Show this help

Required R2 variables unless --skip-r2 or --dry-run is used:
  R2_ENDPOINT
  R2_ACCESS_KEY_ID
  R2_SECRET_ACCESS_KEY
  R2_BUCKET

Optional R2 variables:
  R2_REGION               Defaults to auto
  R2_PUBLIC_BASE_URL      Printed as the public URL after upload
  FILENEST_R2_CACHE_CONTROL

Examples:
  scripts/deploy-non-docker.sh
  scripts/deploy-non-docker.sh --package deliverables/FileNest-0.2.0.dmg
  scripts/deploy-non-docker.sh --refresh-architecture --key ~/.ssh/production
  scripts/deploy-non-docker.sh --skip-r2 --dry-run
EOF
}

die() {
  printf 'Deploy failed: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    die "missing required environment variable: $name"
  fi
}

shell_quote() {
  printf '%q' "$1"
}

trim_slashes() {
  local value="${1:-}"
  value="${value#/}"
  value="${value%/}"
  printf '%s' "$value"
}

validate_absolute_path() {
  local label="$1"
  local value="$2"
  if [[ "$value" != /* || "$value" == "/" || "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    die "$label must be a safe absolute path other than /: $value"
  fi
}

validate_domain() {
  local label="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[A-Za-z0-9.-]+$ ]]; then
    die "$label contains unsupported characters: $value"
  fi
}

architecture_cache_file() {
  if [[ -n "${FILENEST_ARCH_CACHE_FILE:-}" ]]; then
    printf '%s' "$FILENEST_ARCH_CACHE_FILE"
    return
  fi

  local cache_key
  cache_key="$(printf '%s' "$REMOTE_USER@$REMOTE_HOST-$SSH_PORT" | tr -c 'A-Za-z0-9._-' '_')"
  printf '%s/.deploy-cache/architecture-%s' "$ROOT_DIR" "$cache_key"
}

DEPLOY_ENV_FILE="${FILENEST_DEPLOY_ENV_FILE:-$ROOT_DIR/configs/deploy.env}"
raw_args=("$@")
index=0
while [[ $index -lt ${#raw_args[@]} ]]; do
  case "${raw_args[$index]}" in
    --env-file)
      DEPLOY_ENV_FILE="${raw_args[$((index + 1))]:-}"
      index=$((index + 2))
      ;;
    *)
      index=$((index + 1))
      ;;
  esac
done

if [[ -f "$DEPLOY_ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$DEPLOY_ENV_FILE"
  set +a
fi

REMOTE_HOST="${FILENEST_DEPLOY_HOST:-}"
REMOTE_USER="${FILENEST_DEPLOY_USER:-deploy}"
SSH_PORT="${FILENEST_DEPLOY_SSH_PORT:-22}"
SSH_KEY="${FILENEST_DEPLOY_KEY:-}"
REMOTE_DIR="${FILENEST_REMOTE_DIR:-/srv/filenest}"
GOARCH="${FILENEST_DEPLOY_GOARCH:-auto}"
WEBSITE_DIR="${FILENEST_WEBSITE_DIR:-$ROOT_DIR/website}"
WEB_ROOT="${FILENEST_WEB_ROOT:-/var/www/filenestapp.com}"
WEB_OWNER="${FILENEST_WEB_OWNER:-www}"
WEB_GROUP="${FILENEST_WEB_GROUP:-www}"
SITE_DOMAIN="${FILENEST_SITE_DOMAIN:-filenestapp.com}"
REMOTE_BINARY="${FILENEST_UPDATE_BINARY:-/usr/local/bin/filenest-update-api}"
REMOTE_DATA_DIR="${FILENEST_UPDATE_DATA_DIR:-/var/lib/filenest-update-api}"
REMOTE_OMP_MANIFEST_FILE="${FILENEST_OMP_MANIFEST_FILE:-$REMOTE_DATA_DIR/omp-agent-manifest.json}"
REMOTE_ENV_FILE="${FILENEST_UPDATE_ENV_FILE:-/etc/filenest-update-api.env}"
SYSTEMD_SERVICE="${FILENEST_UPDATE_SERVICE:-filenest-update-api}"
R2_PREFIX="${FILENEST_R2_PREFIX:-downloads}"
R2_CACHE_CONTROL="${FILENEST_R2_CACHE_CONTROL:-public,max-age=31536000,immutable}"
DEPLOY_WEBSITE=1
DEPLOY_BACKEND=1
UPLOAD_R2=1
DRY_RUN=0
REFRESH_ARCHITECTURE=0
PACKAGES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      REMOTE_HOST="${2:-}"
      shift 2
      ;;
    --user)
      REMOTE_USER="${2:-}"
      shift 2
      ;;
    --port)
      SSH_PORT="${2:-}"
      shift 2
      ;;
    --key)
      SSH_KEY="${2:-}"
      shift 2
      ;;
    --remote-dir)
      REMOTE_DIR="${2:-}"
      shift 2
      ;;
    --goarch)
      GOARCH="${2:-}"
      shift 2
      ;;
    --website-dir)
      WEBSITE_DIR="${2:-}"
      shift 2
      ;;
    --web-root)
      WEB_ROOT="${2:-}"
      shift 2
      ;;
    --web-owner)
      WEB_OWNER="${2:-}"
      shift 2
      ;;
    --web-group)
      WEB_GROUP="${2:-}"
      shift 2
      ;;
    --site-domain)
      SITE_DOMAIN="${2:-}"
      shift 2
      ;;
    --package)
      PACKAGES+=("${2:-}")
      shift 2
      ;;
    --r2-prefix)
      R2_PREFIX="${2:-}"
      shift 2
      ;;
    --skip-website)
      DEPLOY_WEBSITE=0
      shift
      ;;
    --skip-backend)
      DEPLOY_BACKEND=0
      shift
      ;;
    --refresh-architecture)
      REFRESH_ARCHITECTURE=1
      shift
      ;;
    --skip-r2)
      UPLOAD_R2=0
      shift
      ;;
    --env-file)
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$REMOTE_HOST" ]] || die "SSH host is required"
[[ -n "$REMOTE_USER" ]] || die "SSH user is required"
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "SSH port must be numeric: $SSH_PORT"
case "$GOARCH" in
  auto|amd64|arm64) ;;
  *) die "unsupported --goarch value: $GOARCH" ;;
esac

validate_absolute_path "Remote staging directory" "$REMOTE_DIR"
validate_absolute_path "Remote website root" "$WEB_ROOT"
validate_absolute_path "Remote update API binary" "$REMOTE_BINARY"
validate_absolute_path "Remote update API data directory" "$REMOTE_DATA_DIR"
validate_absolute_path "Remote update API environment file" "$REMOTE_ENV_FILE"
validate_domain "Website domain" "$SITE_DOMAIN"
if [[ ! "$WEB_OWNER" =~ ^[A-Za-z0-9_.-]+$ || ! "$WEB_GROUP" =~ ^[A-Za-z0-9_.-]+$ ]]; then
  die "website owner and group must be valid Unix account names"
fi
if [[ ! "$SYSTEMD_SERVICE" =~ ^[A-Za-z0-9@_.-]+$ ]]; then
  die "systemd service name contains unsupported characters: $SYSTEMD_SERVICE"
fi

if [[ -n "$SSH_KEY" && ! -f "$SSH_KEY" ]]; then
  die "SSH private key not found: $SSH_KEY"
fi
if [[ "$DEPLOY_WEBSITE" == 1 ]]; then
  [[ -d "$WEBSITE_DIR" ]] || die "website directory not found: $WEBSITE_DIR"
  [[ -f "$WEBSITE_DIR/index.html" ]] || die "prebuilt website is missing index.html: $WEBSITE_DIR"
fi
if [[ "$DEPLOY_BACKEND" == 1 ]]; then
  [[ -f "$ROOT_DIR/update-server/go.mod" ]] || die "update-server/go.mod was not found"
fi

if [[ "$UPLOAD_R2" == 1 && ${#PACKAGES[@]} -eq 0 ]]; then
  DEFAULT_DOWNLOADS_DIR="$WEBSITE_DIR/downloads"
  if [[ -d "$DEFAULT_DOWNLOADS_DIR" ]]; then
    while IFS= read -r -d '' package_path; do
      PACKAGES+=("$package_path")
    done < <(find "$DEFAULT_DOWNLOADS_DIR" -maxdepth 1 -type f ! -name '.*' -print0)
  fi
fi

if [[ "$UPLOAD_R2" == 1 ]]; then
  [[ ${#PACKAGES[@]} -gt 0 ]] || die "no installer packages found; use --package or --skip-r2"
  for package_path in "${PACKAGES[@]}"; do
    [[ -f "$package_path" ]] || die "installer package not found: $package_path"
  done
fi

SSH_OPTIONS=(-p "$SSH_PORT" -o StrictHostKeyChecking=accept-new)
if [[ -n "$SSH_KEY" ]]; then
  SSH_OPTIONS+=(-i "$SSH_KEY")
fi
SSH_TARGET="$REMOTE_USER@$REMOTE_HOST"

RSYNC_SSH_COMMAND="ssh"
for ssh_option in "${SSH_OPTIONS[@]}"; do
  RSYNC_SSH_COMMAND+=" $(shell_quote "$ssh_option")"
done

detect_remote_architecture() {
  local cache_file cached_arch machine
  require_cmd ssh
  cache_file="$(architecture_cache_file)"

  if [[ "$REFRESH_ARCHITECTURE" == 0 && -f "$cache_file" ]]; then
    cached_arch="$(tr -d '[:space:]' < "$cache_file")"
    case "$cached_arch" in
      amd64|arm64)
        GOARCH="$cached_arch"
        printf '[Architecture] Using cached server architecture: %s (%s)\n' "$GOARCH" "$cache_file"
        return
        ;;
      *)
        printf '[Architecture] Ignoring invalid cache value in %s\n' "$cache_file" >&2
        ;;
    esac
  fi

  if [[ "$DRY_RUN" == 1 ]]; then
    printf '[Architecture] Server architecture would be probed with uname -m.\n'
    return
  fi

  printf '[Architecture] Probing %s with uname -m\n' "$SSH_TARGET"
  machine="$(ssh "${SSH_OPTIONS[@]}" "$SSH_TARGET" uname -m)"
  machine="$(printf '%s' "$machine" | tr -d '[:space:]')"
  case "$machine" in
    x86_64|amd64)
      GOARCH=amd64
      ;;
    aarch64|arm64)
      GOARCH=arm64
      ;;
    *)
      die "unsupported remote machine architecture: $machine"
      ;;
  esac

  mkdir -p "$(dirname "$cache_file")"
  printf '%s\n' "$GOARCH" > "$cache_file"
  printf '[Architecture] Detected linux/%s and cached it in %s\n' "$GOARCH" "$cache_file"
}

r2_aws() {
  AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
  AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
  AWS_DEFAULT_REGION="${R2_REGION:-auto}" \
    aws "$@"
}

sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    die "missing sha256sum or shasum"
  fi
}

upload_packages_to_r2() {
  local prefix
  prefix="$(trim_slashes "$R2_PREFIX")"

  if [[ "$DRY_RUN" == 0 ]]; then
    require_cmd aws
    require_env R2_ENDPOINT
    require_env R2_ACCESS_KEY_ID
    require_env R2_SECRET_ACCESS_KEY
    require_env R2_BUCKET
  fi

  local package_path
  for package_path in "${PACKAGES[@]}"; do
    local file_name object_key file_size digest remote_size
    file_name="$(basename "$package_path")"
    object_key="$file_name"
    if [[ -n "$prefix" ]]; then
      object_key="$prefix/$file_name"
    fi

    if [[ "$DRY_RUN" == 1 ]]; then
      printf '[Dry run] Upload %s to s3://%s/%s\n' \
        "$package_path" "${R2_BUCKET:-<R2_BUCKET>}" "$object_key"
      continue
    fi

    file_size="$(wc -c < "$package_path" | tr -d '[:space:]')"
    digest="$(sha256_file "$package_path")"
    printf '[R2] Uploading %s to s3://%s/%s\n' "$package_path" "$R2_BUCKET" "$object_key"
    r2_aws s3 cp "$package_path" "s3://$R2_BUCKET/$object_key" \
      --endpoint-url "$R2_ENDPOINT" \
      --cache-control "$R2_CACHE_CONTROL" \
      --metadata "sha256=$digest" \
      --only-show-errors

    remote_size="$(r2_aws s3api head-object \
      --endpoint-url "$R2_ENDPOINT" \
      --bucket "$R2_BUCKET" \
      --key "$object_key" \
      --query ContentLength \
      --output text)"
    [[ "$remote_size" == "$file_size" ]] || {
      die "R2 size verification failed for $object_key: local=$file_size remote=$remote_size"
    }

    if [[ -n "${R2_PUBLIC_BASE_URL:-}" ]]; then
      printf '[R2] Public URL: %s/%s\n' "${R2_PUBLIC_BASE_URL%/}" "$object_key"
    else
      printf '[R2] Verified s3://%s/%s (%s bytes)\n' "$R2_BUCKET" "$object_key" "$file_size"
    fi
  done
}

PAYLOAD_DIR=""
cleanup_payload() {
  if [[ -n "${PAYLOAD_DIR:-}" && -d "$PAYLOAD_DIR" ]]; then
    rm -rf "$PAYLOAD_DIR"
  fi
}
trap cleanup_payload EXIT

build_payload() {
  require_cmd rsync
  PAYLOAD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/filenest-deploy.XXXXXX")"

  if [[ "$DEPLOY_WEBSITE" == 1 ]]; then
    mkdir -p "$PAYLOAD_DIR/website"
    printf '[Build] Staging prebuilt website from %s\n' "$WEBSITE_DIR"
    rsync -a --delete \
      --exclude '.DS_Store' \
      --exclude '.well-known/' \
      "$WEBSITE_DIR/" "$PAYLOAD_DIR/website/"
  fi

  if [[ "$DEPLOY_BACKEND" == 1 ]]; then
    require_cmd go
    printf '[Build] Compiling update API for linux/%s\n' "$GOARCH"
    (
      cd "$ROOT_DIR/update-server"
      CGO_ENABLED=0 GOOS=linux GOARCH="$GOARCH" \
        go build -trimpath -ldflags="-s -w" -o "$PAYLOAD_DIR/filenest-update-api" ./cmd/server
    )
  fi
}

write_remote_activate_script() {
  cat <<'REMOTE'
set -euo pipefail

REMOTE_DIR="$1"
STAGE_DIR="$2"
WEB_ROOT="$3"
REMOTE_BINARY="$4"
REMOTE_DATA_DIR="$5"
REMOTE_OMP_MANIFEST_FILE="$6"
REMOTE_ENV_FILE="$7"
SYSTEMD_SERVICE="$8"
DEPLOY_USER="$9"
DEPLOY_WEBSITE="${10}"
DEPLOY_BACKEND="${11}"
SITE_DOMAIN="${12}"
WEB_OWNER="${13}"
WEB_GROUP="${14}"

case "$REMOTE_DIR" in
  /*) ;;
  *) echo "Remote staging directory must be absolute." >&2; exit 1 ;;
esac
case "$STAGE_DIR" in
  "$REMOTE_DIR"/releases/*) ;;
  *) echo "Unexpected remote release directory: $STAGE_DIR" >&2; exit 1 ;;
esac
case "$REMOTE_DATA_DIR" in
  /*) ;;
  *) echo "Remote data directory must be absolute." >&2; exit 1 ;;
esac
case "$REMOTE_OMP_MANIFEST_FILE" in
  /*) ;;
  *) echo "Remote OMP manifest path must be absolute." >&2; exit 1 ;;
esac
if [ "$REMOTE_DIR" = "/" ] || [ "$WEB_ROOT" = "/" ] || [ "$REMOTE_DATA_DIR" = "/" ] || [ "$REMOTE_OMP_MANIFEST_FILE" = "/" ]; then
  echo "Refusing to deploy to a root directory." >&2
  exit 1
fi

if [ "$DEPLOY_WEBSITE" = "1" ]; then
  command -v rsync >/dev/null 2>&1 || {
    echo "rsync is required on the remote server." >&2
    exit 1
  }
  id "$WEB_OWNER" >/dev/null 2>&1 || {
    echo "Remote website owner does not exist: $WEB_OWNER" >&2
    exit 1
  }
  getent group "$WEB_GROUP" >/dev/null 2>&1 || {
    echo "Remote website group does not exist: $WEB_GROUP" >&2
    exit 1
  }
  [ -f "$STAGE_DIR/website/index.html" ] || {
    echo "Uploaded website is missing index.html." >&2
    exit 1
  }

  echo "[Remote] Activating static website in $WEB_ROOT"
  sudo install -d -m 0755 "$WEB_ROOT"
  sudo rsync -a --delete \
    --exclude '.well-known/' \
    --exclude '.user.ini' \
    "$STAGE_DIR/website/" "$WEB_ROOT/"
  sudo find "$WEB_ROOT" ! -name '.user.ini' -exec chown "$WEB_OWNER:$WEB_GROUP" {} +
  sudo find "$WEB_ROOT" -type d -exec chmod 0755 {} +
  sudo find "$WEB_ROOT" -type f ! -name '.user.ini' -exec chmod 0644 {} +
fi

if [ "$DEPLOY_BACKEND" = "1" ]; then
  [ -x "$STAGE_DIR/filenest-update-api" ] || {
    echo "Uploaded update API binary is missing or not executable." >&2
    exit 1
  }

  echo "[Remote] Installing update API binary"
  sudo install -m 0755 "$STAGE_DIR/filenest-update-api" "$REMOTE_BINARY"
  DEPLOY_GROUP="$(id -gn "$DEPLOY_USER")"
  sudo install -d -m 0750 -o "$DEPLOY_USER" -g "$WEB_GROUP" "$REMOTE_DATA_DIR"

  if ! sudo test -f "$REMOTE_ENV_FILE"; then
    ENV_TMP="$(mktemp)"
    {
      printf 'FILENEST_UPDATE_ADDR=127.0.0.1:8080\n'
      printf 'FILENEST_UPDATE_DATA_FILE=%s/releases.json\n' "$REMOTE_DATA_DIR"
      printf 'FILENEST_OMP_MANIFEST_FILE=%s\n' "$REMOTE_OMP_MANIFEST_FILE"
      printf 'FILENEST_UPDATE_ADMIN_TOKEN=\n'
      printf 'FILENEST_UPDATE_ALLOWED_ORIGINS=https://%s\n' "$SITE_DOMAIN"
    } > "$ENV_TMP"
    sudo install -m 0600 -o root -g root "$ENV_TMP" "$REMOTE_ENV_FILE"
    rm -f "$ENV_TMP"
    echo "[Remote] Created $REMOTE_ENV_FILE with the admin API disabled."
  fi
  if ! sudo grep -q '^FILENEST_OMP_MANIFEST_FILE=' "$REMOTE_ENV_FILE"; then
    ENV_TMP="$(mktemp)"
    sudo cat "$REMOTE_ENV_FILE" > "$ENV_TMP"
    printf 'FILENEST_OMP_MANIFEST_FILE=%s\n' "$REMOTE_OMP_MANIFEST_FILE" >> "$ENV_TMP"
    sudo install -m 0600 -o root -g root "$ENV_TMP" "$REMOTE_ENV_FILE"
    rm -f "$ENV_TMP"
    echo "[Remote] Added the OMP manifest path to $REMOTE_ENV_FILE."
  fi

  SERVICE_TMP="$(mktemp)"
  cat > "$SERVICE_TMP" <<EOF
[Unit]
Description=FileNest Update API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$DEPLOY_USER
Group=$DEPLOY_GROUP
EnvironmentFile=$REMOTE_ENV_FILE
ExecStart=$REMOTE_BINARY
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=$REMOTE_DATA_DIR

[Install]
WantedBy=multi-user.target
EOF
  sudo install -m 0644 -o root -g root "$SERVICE_TMP" "/etc/systemd/system/$SYSTEMD_SERVICE.service"
  rm -f "$SERVICE_TMP"

  sudo systemctl daemon-reload
  sudo systemctl enable "$SYSTEMD_SERVICE.service" >/dev/null
  sudo systemctl restart "$SYSTEMD_SERVICE.service"

  echo "[Remote] Waiting for update API health check"
  HEALTHY=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if command -v curl >/dev/null 2>&1; then
      if curl --fail --silent --show-error http://127.0.0.1:8080/healthz >/dev/null; then
        HEALTHY=1
        break
      fi
    elif command -v wget >/dev/null 2>&1; then
      if wget -q -O /dev/null http://127.0.0.1:8080/healthz; then
        HEALTHY=1
        break
      fi
    else
      echo "curl or wget is required for the remote health check." >&2
      exit 1
    fi
    sleep 1
  done
  if [ "$HEALTHY" != "1" ]; then
    sudo systemctl --no-pager --full status "$SYSTEMD_SERVICE.service" || true
    exit 1
  fi
fi

rm -rf "$STAGE_DIR"
echo "[Remote] Deployment activated successfully."
REMOTE
}

prepare_remote_stage() {
  local stage_dir="$1"
  local prepare_script
  prepare_script='
set -euo pipefail
remote_dir="$1"
stage_dir="$2"
case "$remote_dir" in /*) ;; *) exit 1 ;; esac
case "$stage_dir" in "$remote_dir"/releases/*) ;; *) exit 1 ;; esac
[ "$remote_dir" != "/" ] || exit 1
mkdir -p "$stage_dir"
'
  printf '%s\n' "$prepare_script" | \
    ssh "${SSH_OPTIONS[@]}" "$SSH_TARGET" bash -s -- "$REMOTE_DIR" "$stage_dir"
}

upload_payload() {
  local stage_dir="$1"
  printf '[Upload] Sending compiled payload to %s:%s\n' "$SSH_TARGET" "$stage_dir"
  rsync -az --delete \
    -e "$RSYNC_SSH_COMMAND" \
    "$PAYLOAD_DIR/" "$SSH_TARGET:$stage_dir/"
}

activate_remote_release() {
  local stage_dir="$1"
  write_remote_activate_script | \
    ssh "${SSH_OPTIONS[@]}" "$SSH_TARGET" bash -s -- \
      "$REMOTE_DIR" \
      "$stage_dir" \
      "$WEB_ROOT" \
      "$REMOTE_BINARY" \
      "$REMOTE_DATA_DIR" \
      "$REMOTE_OMP_MANIFEST_FILE" \
      "$REMOTE_ENV_FILE" \
      "$SYSTEMD_SERVICE" \
      "$REMOTE_USER" \
      "$DEPLOY_WEBSITE" \
      "$DEPLOY_BACKEND" \
      "$SITE_DOMAIN" \
      "$WEB_OWNER" \
      "$WEB_GROUP"
}

print_plan() {
  printf '[Deploy] Target: %s:%s\n' "$SSH_TARGET" "$REMOTE_DIR"
  printf '[Deploy] Source mode: direct upload (no Git)\n'
  if [[ "$DEPLOY_WEBSITE" == 1 ]]; then
    printf '[Deploy] Website: %s -> %s (%s:%s)\n' "$WEBSITE_DIR" "$WEB_ROOT" "$WEB_OWNER" "$WEB_GROUP"
  else
    printf '[Deploy] Website: skipped\n'
  fi
  if [[ "$DEPLOY_BACKEND" == 1 ]]; then
    printf '[Deploy] Backend: local linux/%s build -> %s\n' "$GOARCH" "$REMOTE_BINARY"
    printf '[Deploy] OMP manifest: %s\n' "$REMOTE_OMP_MANIFEST_FILE"
  else
    printf '[Deploy] Backend: skipped\n'
  fi
  printf '[Deploy] Reverse proxy: configure domains/TLS and proxy the update API to 127.0.0.1:8080\n'
  if [[ "$UPLOAD_R2" == 1 ]]; then
    printf '[Deploy] R2 packages: %s\n' "${#PACKAGES[@]}"
  else
    printf '[Deploy] R2 upload: skipped\n'
  fi
}

main() {
  if [[ "$DEPLOY_BACKEND" == 1 && "$GOARCH" == auto ]]; then
    detect_remote_architecture
  fi
  print_plan

  if [[ "$DRY_RUN" == 1 ]]; then
    if [[ "$UPLOAD_R2" == 1 ]]; then
      upload_packages_to_r2
    fi
    printf '[Dry run] Would stage the website and compile the Go API locally.\n'
    printf '[Dry run] Would upload the payload with rsync and activate it over SSH.\n'
    exit 0
  fi

  require_cmd ssh
  require_cmd rsync
  build_payload

  if [[ "$UPLOAD_R2" == 1 ]]; then
    upload_packages_to_r2
  fi

  RELEASE_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  REMOTE_STAGE="$REMOTE_DIR/releases/$RELEASE_ID"
  prepare_remote_stage "$REMOTE_STAGE"
  upload_payload "$REMOTE_STAGE"
  activate_remote_release "$REMOTE_STAGE"

  printf 'Deploy finished successfully.\n'
}

main
