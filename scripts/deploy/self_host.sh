#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${ELEKTRINE_ENV_FILE:-$ROOT_DIR/.env.production}"
PRESET_DIR="$ROOT_DIR/env/presets"

# shellcheck source=scripts/lib/module_selection.sh
source "$ROOT_DIR/scripts/lib/module_selection.sh"

usage() {
  cat <<'EOF'
Usage:
  scripts/deploy/self_host.sh init --domain example.com --email admin@example.com [--preset simple-web] [--force]
  scripts/deploy/self_host.sh enable PRESET
  scripts/deploy/self_host.sh presets
  scripts/deploy/self_host.sh doctor
  scripts/deploy/self_host.sh up [docker_deploy args...]
  scripts/deploy/self_host.sh render [docker_deploy args...]
  scripts/deploy/self_host.sh logs [service]
  scripts/deploy/self_host.sh status

Deployment presets: simple-web, web-mail, web-mail-dns, full-stack
Add-on presets: mail dns wildcard-tls s3 vpn tor turn bluesky

Set ELEKTRINE_ENV_FILE=/path/to/.env.production to operate on a non-default env file.
EOF
}

random_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    echo "Error: openssl is required to generate preset secrets securely." >&2
    exit 1
  fi
}

validate_env_file() {
  local env_file="$1"
  local line=""
  local line_no=0
  local value=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue

    if [[ ! "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      echo "Error: invalid env syntax at $env_file:$line_no" >&2
      return 1
    fi

    if [[ "$line" == *'$('* || "$line" == *'`'* || "$line" == *';'* || "$line" == *'&&'* || "$line" == *'||'* ]]; then
      echo "Error: unsafe shell syntax in env file at $env_file:$line_no" >&2
      return 1
    fi

    if [[ "$line" =~ [[:space:]] ]]; then
      value="${line#*=}"

      if [[ ! "$value" =~ ^\"[^\"]*\"$ && ! "$value" =~ ^\'[^\']*\'$ ]]; then
        echo "Error: unquoted whitespace in env file at $env_file:$line_no" >&2
        return 1
      fi
    fi
  done < "$env_file"
}

load_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: env file does not exist: $ENV_FILE" >&2
    echo "Hint: scripts/deploy/self_host.sh init --domain example.com --email admin@example.com" >&2
    exit 1
  fi

  validate_env_file "$ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
}

quote_env_value() {
  local value="$1"

  if [[ "$value" =~ [[:space:]] ]]; then
    printf '"%s"' "${value//\"/\\\"}"
  else
    printf '%s' "$value"
  fi
}

set_env_value() {
  local key="$1"
  local value="$2"
  local rendered=""
  local replacement=""

  rendered="$(quote_env_value "$value")"
  replacement="${rendered//\\/\\\\}"
  replacement="${replacement//&/\\&}"

  if grep -qE "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${replacement}|" "$ENV_FILE"
  else
    printf '\n%s=%s\n' "$key" "$rendered" >> "$ENV_FILE"
  fi
}

merge_profiles() {
  local current="$1"
  shift
  local profile=""
  local wanted=""

  for wanted in "$@"; do
    [[ -z "$wanted" ]] && continue

    for profile in $current; do
      if [[ "$profile" == "$wanted" ]]; then
        wanted=""
        break
      fi
    done

    if [[ -n "$wanted" ]]; then
      current="${current:+$current }$wanted"
    fi
  done

  printf '%s' "$current"
}

merge_modules() {
  local current="$1"
  shift
  local additions=("$@")
  local addition=""
  local raw=""

  if [[ -z "$current" || "$current" == "all" ]]; then
    printf '%s' "${current:-all}"
    return
  fi

  raw="$current"
  for addition in "${additions[@]}"; do
    [[ -z "$addition" ]] && continue
    raw="$raw,$addition"
  done

  normalize_platform_modules "$raw"
  printf '%s' "$NORMALIZED_MODULES"
}

preset_modules() {
  case "$1" in
    mail) printf 'email' ;;
    dns|wildcard-tls) printf 'dns' ;;
    vpn) printf 'vpn' ;;
    *) printf '' ;;
  esac
}

preset_profiles() {
  case "$1" in
    mail) printf 'email' ;;
    dns|wildcard-tls) printf 'dns' ;;
    vpn) printf 'vpn' ;;
    tor) printf 'tor' ;;
    turn) printf 'turn' ;;
    bluesky) printf 'bluesky' ;;
    *) printf '' ;;
  esac
}

append_preset_block() {
  local preset="$1"
  local preset_file="$PRESET_DIR/$preset.env"

  if [[ ! -f "$preset_file" ]]; then
    echo "Error: unknown preset: $preset" >&2
    echo "Hint: scripts/deploy/self_host.sh presets" >&2
    exit 1
  fi

  if grep -q "^# BEGIN self-host preset: $preset$" "$ENV_FILE"; then
    echo "Preset already present in $ENV_FILE: $preset"
    return
  fi

  {
    printf '\n# BEGIN self-host preset: %s\n' "$preset"
    cat "$preset_file"
    printf '# END self-host preset: %s\n' "$preset"
  } >> "$ENV_FILE"
}

apply_generated_secret_defaults() {
  local preset="$1"

  case "$preset" in
    turn)
      if [[ -z "${TURN_SHARED_SECRET:-}" ]]; then
        set_env_value TURN_SHARED_SECRET "$(random_secret)"
      fi
      ;;
    bluesky)
      if [[ -z "${BLUESKY_PDS_JWT_SECRET:-}" ]]; then
        set_env_value BLUESKY_PDS_JWT_SECRET "$(random_secret)"
      fi

      if [[ -z "${BLUESKY_MANAGED_ADMIN_PASSWORD:-}" ]]; then
        set_env_value BLUESKY_MANAGED_ADMIN_PASSWORD "$(random_secret)"
      fi

      if [[ -z "${BLUESKY_PDS_ROTATION_KEY_HEX:-}" ]]; then
        set_env_value BLUESKY_PDS_ROTATION_KEY_HEX "$(openssl rand -hex 32)"
      fi
      ;;
  esac
}

enable_preset() {
  local preset="$1"
  local modules_to_add=""
  local profiles_to_add=""
  local next_modules=""
  local next_profiles=""

  load_env

  modules_to_add="$(preset_modules "$preset")"
  profiles_to_add="$(preset_profiles "$preset")"

  if [[ -n "$modules_to_add" ]]; then
    read -r -a module_array <<< "${modules_to_add//,/ }"
    next_modules="$(merge_modules "${ELEKTRINE_ENABLED_MODULES:-chat,social,nerve,atomine}" "${module_array[@]}")"
    set_env_value ELEKTRINE_ENABLED_MODULES "$next_modules"
  fi

  if [[ -n "$profiles_to_add" ]]; then
    read -r -a profile_array <<< "$profiles_to_add"
    next_profiles="$(merge_profiles "${DOCKER_PROFILES:-caddy}" "${profile_array[@]}")"
    set_env_value DOCKER_PROFILES "$next_profiles"
  fi

  if [[ "$preset" == "wildcard-tls" ]]; then
    set_env_value TLS_MODE letsencrypt-dns
  fi

  append_preset_block "$preset"
  load_env
  apply_generated_secret_defaults "$preset"

  echo "Enabled preset '$preset' in $ENV_FILE"
  echo "Next: scripts/deploy/self_host.sh doctor"
}

compose_file_path() {
  printf '%s/deploy/generated/generated.docker.yml' "$ROOT_DIR"
}

docker_cmd() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  elif sudo -n docker info >/dev/null 2>&1; then
    sudo -n docker "$@"
  else
    echo "Error: Docker daemon is not accessible" >&2
    exit 1
  fi
}

cmd="${1:-}"
shift || true

case "$cmd" in
  init)
    bash "$ROOT_DIR/scripts/deploy/generate_env.sh" --output "$ENV_FILE" "$@"
    ;;
  enable)
    if [[ $# -ne 1 ]]; then
      usage >&2
      exit 1
    fi
    enable_preset "$1"
    ;;
  presets)
    find "$PRESET_DIR" -maxdepth 1 -type f -name '*.env' -printf '%f\n' | sed 's/\.env$//' | sort
    ;;
  doctor)
    bash "$ROOT_DIR/scripts/deploy/doctor.sh" --env-file "$ENV_FILE" "$@"
    ;;
  up)
    bash "$ROOT_DIR/scripts/deploy/docker_deploy.sh" --env-file "$ENV_FILE" "$@"
    ;;
  render)
    load_env
    bash "$ROOT_DIR/scripts/deploy/render_docker_compose.sh" \
      --modules "${ELEKTRINE_ENABLED_MODULES:-chat,social,nerve,atomine}" \
      --profiles "${DOCKER_PROFILES:-caddy}" \
      "$@"
    ;;
  logs)
    service="${1:-app}"
    docker_cmd compose --project-directory "$ROOT_DIR/deploy/docker" --env-file "$ENV_FILE" -f "$(compose_file_path)" logs -f "$service"
    ;;
  status)
    docker_cmd compose --project-directory "$ROOT_DIR/deploy/docker" --env-file "$ENV_FILE" -f "$(compose_file_path)" ps
    ;;
  -h|--help|"")
    usage
    ;;
  *)
    echo "Unknown command: $cmd" >&2
    usage >&2
    exit 1
    ;;
esac
