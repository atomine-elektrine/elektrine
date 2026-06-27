#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env.production}"
HARAKA_DEPLOY_DIR="${HARAKA_DEPLOY_DIR:-}"
HARAKA_COMPOSE_FILES="${HARAKA_COMPOSE_FILES:-}"
OUTPUT_PATH="${OUTPUT_PATH:-}"
CERT_DOMAIN="${CERT_DOMAIN:-}"
CERT_DIR="${CERT_DIR:-}"
CERT_PATH="${CERT_PATH:-}"
KEY_PATH="${KEY_PATH:-}"
DOCKER_CMD="${DOCKER_CMD:-docker}"
FORCE=false
APPLY=false
CLI_HARAKA_DEPLOY_DIR=""
CLI_HARAKA_COMPOSE_FILES=()
CLI_CERT_DOMAIN=""
CLI_CERT_DIR=""
CLI_CERT_PATH=""
CLI_KEY_PATH=""
CLI_OUTPUT_PATH=""
CLI_DOCKER_CMD=""
CLI_FORCE=false
CLI_APPLY=false
HARAKA_SERVICES=(haraka-inbound haraka-submission haraka-outbound haraka-worker)

usage() {
  cat <<'USAGE'
Usage: scripts/deploy/configure_haraka_wildcard_tls.sh [options]

Writes a Haraka compose.override.yml that bind-mounts Elektrine's wildcard
certificate directly into Haraka's expected /app/ssl/cert.crt and cert.key.

Options:
  --env-file PATH       Optional env file to read for existing PRIMARY_DOMAIN
                        and CADDY_TLS_MOUNT_DIR values.
  --haraka-dir PATH     Haraka deployment dir. Defaults to /opt/elektrine-haraka
                        when present, else /opt/elektrine/haraka.
  --compose-file PATH   Haraka base compose file. May be repeated. Relative
                        paths resolve from HARAKA_DIR. Prefer setting this, or
                        HARAKA_COMPOSE_FILES, for reproducible separate repos.
  --domain DOMAIN       Cert basename, e.g. elektrine.com
  --cert-dir PATH       Host cert dir. Defaults to CADDY_TLS_MOUNT_DIR or
                        /opt/elektrine/certs.
  --cert-path PATH      Fullchain cert path. Usually not needed.
  --key-path PATH       Private key path. Usually not needed.
  --output PATH         Override file. Defaults to HARAKA_DIR/compose.override.yml.
  --apply               After writing the override, recreate Haraka services.
  --docker-cmd CMD      Docker command for --apply. Defaults to docker.
                        Example: --docker-cmd "sudo -n docker"
  --force               Replace an existing non-generated override file.
USAGE
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --env-file)
      ENV_FILE="$2"
      shift 2
      ;;
    --env-file=*)
      ENV_FILE="${1#*=}"
      shift
      ;;
    --haraka-dir)
      HARAKA_DEPLOY_DIR="$2"
      CLI_HARAKA_DEPLOY_DIR="$2"
      shift 2
      ;;
    --haraka-dir=*)
      HARAKA_DEPLOY_DIR="${1#*=}"
      CLI_HARAKA_DEPLOY_DIR="${1#*=}"
      shift
      ;;
    --compose-file)
      CLI_HARAKA_COMPOSE_FILES+=("$2")
      shift 2
      ;;
    --compose-file=*)
      CLI_HARAKA_COMPOSE_FILES+=("${1#*=}")
      shift
      ;;
    --domain)
      CERT_DOMAIN="$2"
      CLI_CERT_DOMAIN="$2"
      shift 2
      ;;
    --domain=*)
      CERT_DOMAIN="${1#*=}"
      CLI_CERT_DOMAIN="${1#*=}"
      shift
      ;;
    --cert-dir)
      CERT_DIR="$2"
      CLI_CERT_DIR="$2"
      shift 2
      ;;
    --cert-dir=*)
      CERT_DIR="${1#*=}"
      CLI_CERT_DIR="${1#*=}"
      shift
      ;;
    --cert-path)
      CERT_PATH="$2"
      CLI_CERT_PATH="$2"
      shift 2
      ;;
    --cert-path=*)
      CERT_PATH="${1#*=}"
      CLI_CERT_PATH="${1#*=}"
      shift
      ;;
    --key-path)
      KEY_PATH="$2"
      CLI_KEY_PATH="$2"
      shift 2
      ;;
    --key-path=*)
      KEY_PATH="${1#*=}"
      CLI_KEY_PATH="${1#*=}"
      shift
      ;;
    --output)
      OUTPUT_PATH="$2"
      CLI_OUTPUT_PATH="$2"
      shift 2
      ;;
    --output=*)
      OUTPUT_PATH="${1#*=}"
      CLI_OUTPUT_PATH="${1#*=}"
      shift
      ;;
    --docker-cmd)
      DOCKER_CMD="$2"
      CLI_DOCKER_CMD="$2"
      shift 2
      ;;
    --docker-cmd=*)
      DOCKER_CMD="${1#*=}"
      CLI_DOCKER_CMD="${1#*=}"
      shift
      ;;
    --force)
      FORCE=true
      CLI_FORCE=true
      shift
      ;;
    --apply)
      APPLY=true
      CLI_APPLY=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

load_env_file() {
  local env_file="$1"
  [[ -f "$env_file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      ""|"#"*) continue ;;
    esac
    if [[ ! "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      echo "Invalid env syntax in $env_file: $line" >&2
      exit 1
    fi
    if [[ "$line" == *'$('* || "$line" == *'`'* || "$line" == *';'* || "$line" == *'&&'* || "$line" == *'||'* ]]; then
      echo "Unsafe shell syntax in $env_file: $line" >&2
      exit 1
    fi
  done < "$env_file"

  set +u
  set -a
  # shellcheck disable=SC1090
  . "$env_file"
  set +a
  set -u
}

load_env_file "$ENV_FILE"

# Env files provide deployment defaults, but explicit command-line options must
# win. Re-apply them after sourcing because the env file may contain the same
# variable names.
[[ -n "$CLI_HARAKA_DEPLOY_DIR" ]] && HARAKA_DEPLOY_DIR="$CLI_HARAKA_DEPLOY_DIR"
if [[ "${#CLI_HARAKA_COMPOSE_FILES[@]}" -gt 0 ]]; then
  HARAKA_COMPOSE_FILES="$(IFS=,; printf '%s' "${CLI_HARAKA_COMPOSE_FILES[*]}")"
fi
[[ -n "$CLI_CERT_DOMAIN" ]] && CERT_DOMAIN="$CLI_CERT_DOMAIN"
[[ -n "$CLI_CERT_DIR" ]] && CERT_DIR="$CLI_CERT_DIR"
[[ -n "$CLI_CERT_PATH" ]] && CERT_PATH="$CLI_CERT_PATH"
[[ -n "$CLI_KEY_PATH" ]] && KEY_PATH="$CLI_KEY_PATH"
[[ -n "$CLI_OUTPUT_PATH" ]] && OUTPUT_PATH="$CLI_OUTPUT_PATH"
[[ -n "$CLI_DOCKER_CMD" ]] && DOCKER_CMD="$CLI_DOCKER_CMD"
[[ "$CLI_FORCE" == true ]] && FORCE=true
[[ "$CLI_APPLY" == true ]] && APPLY=true

docker_cmd() {
  local docker_args=()
  # Intentionally split a simple command string such as "sudo -n docker".
  # shellcheck disable=SC2206
  docker_args=($DOCKER_CMD)
  "${docker_args[@]}" "$@"
}

find_existing_haraka_container() {
  local service_name
  local container_name
  local container_id

  for service_name in "${HARAKA_SERVICES[@]}"; do
    container_id="$(
      docker_cmd ps \
        --filter "label=com.docker.compose.service=$service_name" \
        --format '{{.ID}}' \
        | head -n 1
    )"

    if [[ -n "$container_id" ]]; then
      printf '%s' "$container_id"
      return 0
    fi
  done

  for container_name in \
    deployment-haraka-inbound-1 \
    deployment-haraka-submission-1 \
    deployment-haraka-outbound-1 \
    deployment-haraka-worker-1 \
    haraka-inbound \
    haraka-submission \
    haraka-outbound \
    haraka-worker; do
    container_id="$(docker_cmd ps --filter "name=^/${container_name}$" --format '{{.ID}}' | head -n 1)"

    if [[ -n "$container_id" ]]; then
      printf '%s' "$container_id"
      return 0
    fi
  done

  return 1
}

compose_label() {
  local container_id="$1"
  local label_name="$2"

  docker_cmd inspect "$container_id" \
    --format "{{ index .Config.Labels \"$label_name\" }}" 2>/dev/null || true
}

append_compose_file_arg() {
  local args_name="$1"
  local -n compose_file_args_ref="$args_name"
  local file_path="$2"

  [[ -f "$file_path" ]] || return 1
  compose_file_args_ref+=("-f" "$file_path")
}

append_existing_default_compose_files() {
  local args_name="$1"
  local -n default_compose_args_ref="$args_name"
  local compose_dir="$2"
  local before_count="${#default_compose_args_ref[@]}"
  local file_name

  for file_name in compose.yml compose.yaml docker-compose.yml docker-compose.yaml; do
    append_compose_file_arg "$args_name" "$compose_dir/$file_name" || true
  done

  [[ "${#default_compose_args_ref[@]}" -gt "$before_count" ]]
}

normalize_compose_file() {
  local compose_file="$1"

  case "$compose_file" in
    /*) printf '%s' "$compose_file" ;;
    *) printf '%s' "$HARAKA_DEPLOY_DIR/$compose_file" ;;
  esac
}

append_explicit_compose_files() {
  local args_name="$1"
  local -n explicit_compose_args_ref="$args_name"
  local compose_files="$2"
  local compose_file=""
  local resolved_file=""
  local before_count="${#explicit_compose_args_ref[@]}"

  [[ -n "$compose_files" ]] || return 1

  compose_files="${compose_files//:/,}"
  IFS=',' read -r -a explicit_compose_file_list <<< "$compose_files"

  for compose_file in "${explicit_compose_file_list[@]}"; do
    compose_file="$(printf '%s' "$compose_file" | xargs)"
    [[ -n "$compose_file" ]] || continue

    resolved_file="$(normalize_compose_file "$compose_file")"

    if [[ ! -f "$resolved_file" ]]; then
      echo "Configured Haraka compose file does not exist: $resolved_file" >&2
      exit 1
    fi

    append_compose_file_arg "$args_name" "$resolved_file"
  done

  [[ "${#explicit_compose_args_ref[@]}" -gt "$before_count" ]]
}

compose_apply_args() {
  local args_name="$1"
  local -n apply_compose_args_ref="$args_name"
  local container_id=""
  local project_dir=""
  local config_files=""
  local config_file=""
  local resolved_file=""
  local before_file_count=0

  if [[ -n "$HARAKA_COMPOSE_FILES" ]]; then
    apply_compose_args_ref=("--project-directory" "$HARAKA_DEPLOY_DIR")
    append_explicit_compose_files "$args_name" "$HARAKA_COMPOSE_FILES"
    apply_compose_args_ref+=("-f" "$OUTPUT_PATH")
    return 0
  fi

  if container_id="$(find_existing_haraka_container)"; then
    project_dir="$(compose_label "$container_id" "com.docker.compose.project.working_dir")"
    config_files="$(compose_label "$container_id" "com.docker.compose.project.config_files")"

    if [[ -n "$project_dir" && "$project_dir" != "<no value>" ]]; then
      apply_compose_args_ref+=("--project-directory" "$project_dir")
    fi

    if [[ -n "$config_files" && "$config_files" != "<no value>" ]]; then
      before_file_count="${#apply_compose_args_ref[@]}"

      IFS=',' read -r -a config_file_list <<< "$config_files"
      for config_file in "${config_file_list[@]}"; do
        config_file="$(printf '%s' "$config_file" | xargs)"
        [[ -n "$config_file" ]] || continue

        case "$config_file" in
          /*) resolved_file="$config_file" ;;
          *) resolved_file="${project_dir:-$HARAKA_DEPLOY_DIR}/$config_file" ;;
        esac

        append_compose_file_arg "$args_name" "$resolved_file" || true
      done

      if [[ "${#apply_compose_args_ref[@]}" -gt "$before_file_count" ]]; then
        apply_compose_args_ref+=("-f" "$OUTPUT_PATH")
        return 0
      fi
    fi

    if [[ -n "$project_dir" && "$project_dir" != "<no value>" ]]; then
      before_file_count="${#apply_compose_args_ref[@]}"
      append_existing_default_compose_files "$args_name" "$project_dir" || true

      if [[ "${#apply_compose_args_ref[@]}" -gt "$before_file_count" ]]; then
        apply_compose_args_ref+=("-f" "$OUTPUT_PATH")
        return 0
      fi
    fi
  fi

  apply_compose_args_ref=()
  apply_compose_args_ref+=("--project-directory" "$HARAKA_DEPLOY_DIR")
  before_file_count="${#apply_compose_args_ref[@]}"
  append_existing_default_compose_files "$args_name" "$HARAKA_DEPLOY_DIR" || true

  if [[ "${#apply_compose_args_ref[@]}" -gt "$before_file_count" ]]; then
    apply_compose_args_ref+=("-f" "$OUTPUT_PATH")
    return 0
  fi

  return 1
}

ensure_writable_output_path() {
  local output_path="$1"
  local output_dir=""
  local owner=""

  output_dir="$(dirname "$output_path")"
  owner="$(id -u):$(id -g)"

  if [[ -d "$output_path" ]]; then
    echo "Error: Haraka override path is a directory: $output_path" >&2
    echo "Hint: set OUTPUT_PATH to a file path, usually HARAKA_DEPLOY_DIR/compose.override.yml." >&2
    return 1
  fi

  if [[ ! -d "$output_dir" ]]; then
    if ! mkdir -p "$output_dir" 2>/dev/null; then
      if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        sudo -n mkdir -p "$output_dir"
        sudo -n chown "$owner" "$output_dir"
      else
        echo "Error: Haraka override directory does not exist: $output_dir" >&2
        echo "Hint: create it or set HARAKA_DEPLOY_DIR to a writable path." >&2
        return 1
      fi
    fi
  fi

  if [[ ! -w "$output_dir" ]]; then
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      sudo -n chown "$owner" "$output_dir"
    fi

    if [[ ! -w "$output_dir" ]]; then
      echo "Error: Haraka override directory is not writable: $output_dir" >&2
      echo "Hint: chown the Haraka deployment directory to the SSH deploy user." >&2
      return 1
    fi
  fi

  if [[ -e "$output_path" && ! -w "$output_path" ]]; then
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      sudo -n chown "$owner" "$output_path"
    fi

    if [[ ! -w "$output_path" ]]; then
      echo "Error: Haraka override file is not writable: $output_path" >&2
      echo "Hint: remove the generated file or chown it to the SSH deploy user." >&2
      return 1
    fi
  fi
}

write_override_file() {
  local output_path="$1"
  local cert_path="$2"
  local key_path="$3"
  local tmp_file=""
  local owner_gid=""
  local owner_uid=""

  tmp_file="$(mktemp)"
  owner_uid="$(id -u)"
  owner_gid="$(id -g)"

  cat > "$tmp_file" <<YAML
# Generated by scripts/deploy/configure_haraka_wildcard_tls.sh.
# Haraka reads /app/ssl/cert.crt and /app/ssl/cert.key. Bind-mount the
# Elektrine wildcard certificate directly so renewal does not require copying
# files into the deployment_ssl-certs Docker volume.

x-haraka-wildcard-tls-volumes: &haraka_wildcard_tls_volumes
  - type: bind
    source: "$cert_path"
    target: /app/ssl/cert.crt
    read_only: true
  - type: bind
    source: "$key_path"
    target: /app/ssl/cert.key
    read_only: true

services:
  haraka-inbound:
    volumes: *haraka_wildcard_tls_volumes
  haraka-submission:
    volumes: *haraka_wildcard_tls_volumes
  haraka-outbound:
    volumes: *haraka_wildcard_tls_volumes
  haraka-worker:
    volumes: *haraka_wildcard_tls_volumes
YAML

  if install -m 0644 "$tmp_file" "$output_path" 2>/dev/null; then
    rm -f "$tmp_file"
    return 0
  fi

  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    if sudo -n install -o "$owner_uid" -g "$owner_gid" -m 0644 "$tmp_file" "$output_path"; then
      rm -f "$tmp_file"
      return 0
    fi
  fi

  rm -f "$tmp_file"
  echo "Error: could not write Haraka override file: $output_path" >&2
  echo "Hint: remove the generated file or chown the Haraka deployment directory to the SSH deploy user." >&2
  return 1
}

recreate_haraka_services() {
  local args_name="$1"
  local -n compose_args_ref="$args_name"
  local service_name

  for service_name in "${HARAKA_SERVICES[@]}"; do
    if docker_cmd compose "${compose_args_ref[@]}" up -d --no-deps --force-recreate "$service_name"; then
      continue
    fi

    echo "Warn: retrying Haraka service recreate after clearing stale Compose state: $service_name" >&2
    docker_cmd compose "${compose_args_ref[@]}" rm -sf "$service_name" >/dev/null 2>&1 || true
    docker_cmd compose "${compose_args_ref[@]}" up -d --no-deps --force-recreate "$service_name"
  done
}

if [[ -z "$HARAKA_DEPLOY_DIR" ]]; then
  if [[ -d /opt/elektrine-haraka ]]; then
    HARAKA_DEPLOY_DIR=/opt/elektrine-haraka
  else
    HARAKA_DEPLOY_DIR=/opt/elektrine/haraka
  fi
fi

if [[ -z "$CERT_DOMAIN" ]]; then
  CERT_DOMAIN="${PRIMARY_DOMAIN:-${PHX_HOST:-}}"
fi

if [[ -z "$CERT_DOMAIN" ]]; then
  echo "Could not infer cert domain. Pass --domain=example.com or set PRIMARY_DOMAIN." >&2
  exit 1
fi

CERT_DIR="${CERT_DIR:-${CADDY_TLS_MOUNT_DIR:-/opt/elektrine/certs}}"
CERT_PATH="${CERT_PATH:-$CERT_DIR/$CERT_DOMAIN.fullchain.pem}"
KEY_PATH="${KEY_PATH:-$CERT_DIR/$CERT_DOMAIN.key.pem}"
OUTPUT_PATH="${OUTPUT_PATH:-$HARAKA_DEPLOY_DIR/compose.override.yml}"

if [[ ! -f "$CERT_PATH" ]]; then
  echo "Cert not found: $CERT_PATH" >&2
  exit 1
fi

if [[ ! -f "$KEY_PATH" ]]; then
  echo "Key not found: $KEY_PATH" >&2
  exit 1
fi

if command -v openssl >/dev/null 2>&1; then
  openssl x509 -in "$CERT_PATH" -noout -checkend 604800 >/dev/null
fi

ensure_writable_output_path "$OUTPUT_PATH"

if [[ -f "$OUTPUT_PATH" ]] && ! grep -q "Generated by scripts/deploy/configure_haraka_wildcard_tls.sh" "$OUTPUT_PATH"; then
  if [[ "$FORCE" != true ]]; then
    echo "Refusing to overwrite non-generated override: $OUTPUT_PATH" >&2
    echo "Re-run with --force after reviewing the existing file." >&2
    exit 1
  fi
fi

validate_compose_path() {
  local name="$1"
  local value="$2"

  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* || "$value" == *'"'* ]]; then
    echo "$name contains characters that cannot be safely written to compose YAML: $value" >&2
    exit 1
  fi
}

validate_compose_path "CERT_PATH" "$CERT_PATH"
validate_compose_path "KEY_PATH" "$KEY_PATH"

write_override_file "$OUTPUT_PATH" "$CERT_PATH" "$KEY_PATH"

if [[ "$APPLY" == true ]]; then
  if ! docker_cmd info >/dev/null 2>&1; then
    echo "Docker daemon is not accessible through: $DOCKER_CMD" >&2
    exit 1
  fi

  compose_args=()

  if compose_apply_args compose_args; then
    recreate_haraka_services compose_args
  else
    echo "Warn: could not infer Haraka Docker Compose base file; wrote $OUTPUT_PATH but did not apply it." >&2
    echo "      Recreate Haraka with its normal compose file plus -f $OUTPUT_PATH." >&2
  fi
fi

cat <<MSG
Wrote $OUTPUT_PATH

Next on the Haraka host:
  cd "$HARAKA_DEPLOY_DIR"
  docker compose up -d --force-recreate haraka-inbound haraka-submission haraka-outbound haraka-worker

Then verify inbound SMTP:
  openssl s_client -starttls smtp -connect localhost:25 -servername mail.$CERT_DOMAIN -verify_hostname mail.$CERT_DOMAIN
MSG
