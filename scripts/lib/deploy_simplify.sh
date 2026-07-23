#!/bin/bash

admin_host_default() {
  printf 'admin.%s' "${PRIMARY_DOMAIN:-example.com}"
}

disabled_admin_host_default() {
  printf 'disabled-admin.%s' "${PRIMARY_DOMAIN:-example.invalid}"
}

apply_simplified_deploy_env() {
  case "${ADMIN_ACCESS:-}" in
    "")
      ;;
    public)
      export NETBIRD_ENABLED="${NETBIRD_ENABLED:-false}"
      export CADDY_ADMIN_HOST="${CADDY_ADMIN_HOST:-$(disabled_admin_host_default)}"
      ;;
    netbird)
      export NETBIRD_ENABLED="true"
      export CADDY_ADMIN_HOST="${CADDY_ADMIN_HOST:-$(admin_host_default)}"
      ;;
    disabled)
      export NETBIRD_ENABLED="${NETBIRD_ENABLED:-false}"
      export CADDY_ADMIN_HOST="${CADDY_ADMIN_HOST:-$(disabled_admin_host_default)}"
      ;;
  esac

  if [[ -n "${PUBLIC_DNS_BIND_IP:-}" ]]; then
    export DNS_UDP_BIND="${DNS_UDP_BIND:-$PUBLIC_DNS_BIND_IP:53:5300/udp}"
    export DNS_TCP_BIND="${DNS_TCP_BIND:-$PUBLIC_DNS_BIND_IP:53:5300/tcp}"
  fi

  case "${TLS_MODE:-}" in
    "")
      ;;
    caddy-auto)
      ;;
    external-wildcard|letsencrypt-dns)
      export CADDY_CONFIG_PATH="${CADDY_CONFIG_PATH:-../caddy/Caddyfile.baremetal.external-certs}"
      ;;
  esac
}

validate_netbird_allowed_cidrs() {
  if [[ "${ADMIN_ACCESS:-}" == "netbird" && -z "${NETBIRD_ALLOWED_CIDRS:-}" ]]; then
    echo "Error: ADMIN_ACCESS=netbird requires NETBIRD_ALLOWED_CIDRS with exact peer /32 CIDRs." >&2
    echo "Hint: use a quoted, whitespace-separated list, e.g. NETBIRD_ALLOWED_CIDRS=\"100.90.1.10/32 100.90.2.20/32\"." >&2
    return 1
  fi

  if [[ "${NETBIRD_ALLOWED_CIDRS:-}" == *,* ]]; then
    echo "Error: NETBIRD_ALLOWED_CIDRS must be whitespace-separated, not comma-separated." >&2
    echo "Hint: Caddy remote_ip expects: NETBIRD_ALLOWED_CIDRS=\"100.90.1.10/32 100.90.2.20/32\"." >&2
    return 1
  fi

  if [[ "${NETBIRD_ALLOWED_CIDRS:-}" == *"0.0.0.0/0"* || "${NETBIRD_ALLOWED_CIDRS:-}" == *"::/0"* ]]; then
    echo "Error: NETBIRD_ALLOWED_CIDRS must not include 0.0.0.0/0 or ::/0 when Caddy is enabled." >&2
    echo "Hint: set exact VPN/private CIDRs, or leave it unset to deny public admin host access by default." >&2
    return 1
  fi

  if [[ "${NETBIRD_ALLOWED_CIDRS:-}" == *"100.64.0.0/10"* ]]; then
    echo "Error: NETBIRD_ALLOWED_CIDRS must not allow the whole NetBird CGNAT range." >&2
    echo "Hint: allow only your device peer IPs as /32 entries." >&2
    return 1
  fi

  return 0
}

doctor_check_docker_env_file() {
  local docker_env="$ROOT_DIR/deploy/docker/.env"

  if [[ ! -f "$docker_env" ]]; then
    check_ok "no deploy/docker/.env file found"
    return
  fi

  if [[ "$ENV_FILE" == "$docker_env" ]]; then
    check_ok "using deploy/docker/.env explicitly"
    return
  fi

  if cmp -s "$ENV_FILE" "$docker_env"; then
    check_warn "deploy/docker/.env duplicates $ENV_FILE"
    echo "Hint: keep one canonical env file, normally $ROOT_DIR/.env.production." >&2
  else
    check_error "deploy/docker/.env differs from $ENV_FILE"
    echo "Hint: remove deploy/docker/.env or replace it with a symlink/copy of the canonical env." >&2
  fi
}

doctor_check_simplified_deploy_env() {
  case "${DEPLOYMENT_PRESET:-}" in
    ""|simple-web|web-mail|web-mail-dns|full-stack)
      [[ -n "${DEPLOYMENT_PRESET:-}" ]] && check_ok "DEPLOYMENT_PRESET is ${DEPLOYMENT_PRESET}"
      ;;
    *)
      check_error "unknown DEPLOYMENT_PRESET: ${DEPLOYMENT_PRESET}"
      ;;
  esac

  case "${ADMIN_ACCESS:-public}" in
    public|netbird|disabled) check_ok "ADMIN_ACCESS is ${ADMIN_ACCESS:-public}" ;;
    *) check_error "ADMIN_ACCESS must be public, netbird, or disabled" ;;
  esac

  case "${TLS_MODE:-caddy-auto}" in
    caddy-auto|external-wildcard|letsencrypt-dns) check_ok "TLS_MODE is ${TLS_MODE:-caddy-auto}" ;;
    *) check_error "TLS_MODE must be caddy-auto, external-wildcard, or letsencrypt-dns" ;;
  esac

  if [[ -n "${PUBLIC_DNS_BIND_IP:-}" ]]; then
    if [[ -n "${DNS_UDP_BIND:-}" && -n "${DNS_TCP_BIND:-}" ]]; then
      check_ok "PUBLIC_DNS_BIND_IP derives DNS bind settings"
    else
      check_error "PUBLIC_DNS_BIND_IP is set but DNS_UDP_BIND/DNS_TCP_BIND were not derived"
    fi
  fi

  if validate_netbird_allowed_cidrs; then
    if [[ "${ADMIN_ACCESS:-}" == "netbird" ]]; then
      check_ok "NETBIRD_ALLOWED_CIDRS is set for NetBird admin access"
    fi
  else
    check_error "NetBird admin CIDR policy is invalid"
  fi
}

deployment_preset_modules() {
  case "$1" in
    simple-web) printf 'chat,social,nerve,atomine' ;;
    web-mail) printf 'chat,social,email,nerve,atomine' ;;
    web-mail-dns|full-stack) printf 'chat,social,email,nerve,vpn,dns,uptime,atomine,kairo' ;;
    *) return 1 ;;
  esac
}

deployment_preset_profiles() {
  case "$1" in
    simple-web) printf 'caddy' ;;
    web-mail) printf 'caddy email' ;;
    web-mail-dns) printf 'caddy email dns' ;;
    full-stack) printf 'caddy email dns turn bluesky vpn' ;;
    *) return 1 ;;
  esac
}

deployment_preset_admin_access() {
  case "$1" in
    simple-web|web-mail|web-mail-dns) printf 'public' ;;
    full-stack) printf 'netbird' ;;
    *) return 1 ;;
  esac
}
