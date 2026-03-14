#!/bin/bash

normalize_platform_modules() {
  local raw="$1"
  local trimmed="${raw//[[:space:]]/}"

  NORMALIZED_MODULES=""
  BUILD_SLUG=""
  NORMALIZED_MODULE_ARRAY=()

  if [[ -z "$trimmed" || "$trimmed" == "all" || "$trimmed" == "*" ]]; then
    NORMALIZED_MODULES="all"
    BUILD_SLUG="all"
    NORMALIZED_MODULE_ARRAY=(chat social email vault vpn)
    return
  fi

  if [[ "$trimmed" == "none" ]]; then
    NORMALIZED_MODULES="none"
    BUILD_SLUG="none"
    NORMALIZED_MODULE_ARRAY=()
    return
  fi

  IFS=',' read -r -a requested <<< "$trimmed"

  local canonical_requested=()
  local normalized=()
  local token=""

  append_unique_module() {
    local value="$1"
    local existing=""

    for existing in "${canonical_requested[@]:-}"; do
      if [[ "$existing" == "$value" ]]; then
        return
      fi
    done

    canonical_requested+=("$value")
  }

  for token in "${requested[@]}"; do
    token="$(printf '%s' "$token" | tr '[:upper:]' '[:lower:]')"

    case "$token" in
      chat|social|email|vault|vpn)
        append_unique_module "$token"
        ;;
      password-manager|password_manager)
        append_unique_module "vault"
        ;;
      all|none|'')
        echo "ELEKTRINE_RELEASE_MODULES cannot mix special values with explicit modules: $raw" >&2
        return 1
        ;;
      *)
        echo "Unknown platform module in ELEKTRINE_RELEASE_MODULES: $token" >&2
        return 1
        ;;
    esac
  done

  local candidate=""
  for candidate in chat social email vault vpn; do
    for token in "${canonical_requested[@]:-}"; do
      if [[ "$token" == "$candidate" ]]; then
        normalized+=("$candidate")
        break
      fi
    done
  done

  if [[ "${#normalized[@]}" -eq 0 ]]; then
    echo "ELEKTRINE_RELEASE_MODULES did not include any supported modules: $raw" >&2
    return 1
  fi

  NORMALIZED_MODULE_ARRAY=("${normalized[@]}")
  NORMALIZED_MODULES="$(IFS=,; echo "${normalized[*]}")"
  BUILD_SLUG="$(IFS=-; echo "${normalized[*]}")"
}

platform_module_selected() {
  local wanted="$1"
  local module=""

  for module in "${NORMALIZED_MODULE_ARRAY[@]:-}"; do
    if [[ "$module" == "$wanted" ]]; then
      return 0
    fi
  done

  return 1
}
