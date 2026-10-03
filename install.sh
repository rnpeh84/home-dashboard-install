#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

registry=hub.v.cller.com
repository="$registry/home_dashboard/home-dashboard"
version="${HOME_DASHBOARD_VERSION:-}"
directory="${HOME_DASHBOARD_DIR:-$PWD}"
directory_explicit=false
[[ -z "${HOME_DASHBOARD_DIR:-}" ]] || directory_explicit=true
bind_address="${HOME_DASHBOARD_BIND:-}"
port="${HOME_DASHBOARD_PORT:-}"
public_url="${HOME_DASHBOARD_URL:-}"
while (($#)); do
  case "$1" in
    --version|--dir|--port|--bind|--url)
      (($# >= 2)) || { echo "Missing value for $1" >&2; exit 1; }
      case "$1" in
        --version) version="$2";; --dir) directory="$2"; directory_explicit=true;; --port) port="$2";;
        --bind) bind_address="$2";; --url) public_url="$2";;
      esac
      shift 2;;
    --help) echo "Usage: install.sh [--version x.x.x] [--dir /absolute/path (default: current directory)] [--bind 0.0.0.0] [--port 7575] [--url https://dashboard.example.com]"; exit 0;;
    *) echo "Unknown option: $1" >&2; exit 1;;
  esac
done
if [[ "$directory_explicit" = false ]]; then
  # Read from the terminal, not stdin: stdin may contain a curl | bash script.
  if ! { exec 3<> /dev/tty; } 2>/dev/null; then
    echo 'No interactive terminal. Specify --dir /absolute/path.' >&2
    exit 1
  fi
  printf '설치 경로 [%s]: ' "$directory" >&3
  if ! IFS= read -r selected_directory <&3; then
    echo 'Installation directory input was cancelled.' >&2
    exit 1
  fi
  exec 3>&-
  [[ -z "$selected_directory" ]] || directory="$selected_directory"
fi
printf 'Installation directory: %s\nCompose file: %s/compose.yaml\n' "$directory" "$directory"
if [[ -f "$directory/.env" ]]; then
  while IFS= read -r setting; do
    case "$setting" in
      HOME_DASHBOARD_PORT=*) [[ -n "$port" ]] || port="${setting#*=}";;
      HOME_DASHBOARD_BIND=*) [[ -n "$bind_address" ]] || bind_address="${setting#*=}";;
      HOME_DASHBOARD_URL=*) [[ -n "$public_url" ]] || public_url="${setting#*=}";;
    esac
  done < "$directory/.env"
fi
port="${port:-7575}"
bind_address="${bind_address:-0.0.0.0}"
for command in docker curl openssl; do
  command -v "$command" >/dev/null || { echo "$command is required; install it first." >&2; exit 1; }
done
docker compose version >/dev/null || { echo 'Docker Compose v2 is required.' >&2; exit 1; }
docker info >/dev/null
if [[ -z "$version" ]]; then
  version=$(curl --fail --silent --show-error --location https://raw.githubusercontent.com/rnpeh84/home-dashboard-install/main/VERSION)
fi
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Version must be x.x.x.' >&2; exit 1; }
[[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || { echo 'Invalid port.' >&2; exit 1; }
[[ "$bind_address" =~ ^[0-9.]+$ ]] || { echo 'Bind address must be an IPv4 address.' >&2; exit 1; }
[[ "$directory" = /* ]] && [[ "$directory" != / ]] || { echo 'Installation directory must be an absolute path other than /.' >&2; exit 1; }
[[ "$directory" != *$'\n'* && "$directory" != *:* ]] || { echo 'Invalid installation directory.' >&2; exit 1; }
[[ -z "$public_url" || "$public_url" =~ ^https?://[^[:space:]\"\']+$ ]] || { echo 'URL must be HTTP(S) without whitespace or quotes.' >&2; exit 1; }
image="$repository:$version"
if ! docker pull "$image"; then
  echo "Image pull failed. For a private Harbor project, run: docker login $registry" >&2
  exit 1
fi
mkdir -p "$directory"
cd "$directory"
mkdir -p appdata backups
if [[ -e .env ]]; then
  grep -Eq '^SECRET_ENCRYPTION_KEY=[0-9a-fA-F]{64}$' .env || { echo 'Existing encryption key is missing/invalid; refusing to replace it.' >&2; exit 1; }
else
  [[ -z "$(find appdata -mindepth 1 -print -quit)" ]] || { echo 'Existing appdata has no encryption key; refusing to generate a replacement.' >&2; exit 1; }
  printf 'SECRET_ENCRYPTION_KEY=%s\n' "$(openssl rand -hex 32)" > .env
fi
compose=(docker compose --project-name home-dashboard --env-file .env -f compose.yaml)
temporary=$(mktemp "$PWD/.compose.XXXXXX")
trap 'rm -f "$temporary"' EXIT
cat > "$temporary" <<EOF
services:
  dashboard:
    image: "$image"
    restart: unless-stopped
    ports:
      - "$bind_address:$port:7575"
    volumes:
      - ./appdata:/appdata
    env_file:
      - .env
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--spider", "http://127.0.0.1:7575/api/health/ready"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 30s
    environment:
      HOME_DASHBOARD_VERSION: "$version"
      AUTH_TRUST_HOST: "true"
EOF
if [[ -n "$public_url" ]]; then
  printf '      AUTH_URL: "%s"\n' "$public_url" >> "$temporary"
fi
docker compose --project-name home-dashboard --env-file .env -f "$temporary" config --quiet
if [[ -e compose.yaml ]]; then
  stamp=$(date -u +%Y%m%dT%H%M%SZ)-$$
  backup="$PWD/backups/$stamp"
  mkdir "$backup"
  cp .env compose.yaml "$backup/"
  [[ ! -e VERSION ]] || cp VERSION "$backup/"
  "${compose[@]}" stop
  # A stopped application gives SQLite and Redis a consistent disk backup.
  if ! docker run --rm --entrypoint tar -v "$PWD/appdata:/data:ro" -v "$backup:/backup" "$image" -czf /backup/appdata.tar.gz -C /data .; then
    "${compose[@]}" up -d
    echo 'Backup failed; original configuration restarted.' >&2
    exit 1
  fi
  echo "Pre-update backup: $backup"
fi
grep -vE '^HOME_DASHBOARD_(PORT|BIND|URL)=' .env > .env.next
printf 'HOME_DASHBOARD_PORT=%s\nHOME_DASHBOARD_BIND=%s\nHOME_DASHBOARD_URL=%s\n' "$port" "$bind_address" "$public_url" >> .env.next
mv .env.next .env
mv "$temporary" compose.yaml
"${compose[@]}" up -d --wait --wait-timeout 180
printf '%s\n' "$version" > VERSION
echo "Installed Home Dashboard $version ($image)"
echo "Data: $PWD/appdata; configuration: $PWD/compose.yaml"
echo "Open ${public_url:-http://SERVER_IP:$port} and finish onboarding."
