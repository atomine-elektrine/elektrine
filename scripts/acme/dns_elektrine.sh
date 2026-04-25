#!/usr/bin/env sh

# acme.sh DNS API provider for Elektrine DNS.
#
# Required environment for the preferred internal API path:
#   ELEKTRINE_API_BASE  e.g. https://elektrine.com
#   ELEKTRINE_INTERNAL_API_KEY shared internal key, usually PHOENIX_API_KEY or CADDY_EDGE_API_KEY
#
# Legacy external API fallback:
#   ELEKTRINE_DNS_TOKEN personal access token with write:dns scope
#
# acme.sh calls:
#   dns_elektrine_add <full-domain> <txt-value>
#   dns_elektrine_rm  <full-domain> <txt-value>

dns_elektrine_add() {
  fulldomain="$1"
  txtvalue="$2"

  _elektrine_require_config || return 1

  if [ -n "${ELEKTRINE_INTERNAL_API_KEY:-}" ]; then
    _elektrine_internal_request POST "$fulldomain" "$txtvalue" >/dev/null
    return $?
  fi

  zone_json="$(_elektrine_find_zone "$fulldomain")" || return 1
  zone_id="$(_elektrine_json_field "$zone_json" id)" || return 1
  zone_domain="$(_elektrine_json_field "$zone_json" domain)" || return 1
  record_name="$(_elektrine_relative_record_name "$fulldomain" "$zone_domain")" || return 1

  payload="$(_elektrine_record_payload "$record_name" "$txtvalue")"

  _elektrine_request POST \
    "$ELEKTRINE_API_BASE/api/ext/v1/dns/zones/$zone_id/records" \
    "$payload" >/dev/null
}

dns_elektrine_rm() {
  fulldomain="$1"
  txtvalue="$2"

  _elektrine_require_config || return 1

  if [ -n "${ELEKTRINE_INTERNAL_API_KEY:-}" ]; then
    _elektrine_internal_request DELETE "$fulldomain" "$txtvalue" >/dev/null
    return $?
  fi

  zone_json="$(_elektrine_find_zone "$fulldomain")" || return 1
  zone_id="$(_elektrine_json_field "$zone_json" id)" || return 1
  zone_domain="$(_elektrine_json_field "$zone_json" domain)" || return 1
  record_name="$(_elektrine_relative_record_name "$fulldomain" "$zone_domain")" || return 1

  zone_detail="$(_elektrine_request GET "$ELEKTRINE_API_BASE/api/ext/v1/dns/zones/$zone_id")" || return 1
  record_id="$(_elektrine_find_txt_record_id "$zone_detail" "$record_name" "$txtvalue")"

  if [ -z "$record_id" ]; then
    return 0
  fi

  _elektrine_request DELETE \
    "$ELEKTRINE_API_BASE/api/ext/v1/dns/zones/$zone_id/records/$record_id" >/dev/null
}

_elektrine_require_config() {
  ELEKTRINE_API_BASE="${ELEKTRINE_API_BASE%/}"

  if [ -z "$ELEKTRINE_API_BASE" ]; then
    _elektrine_log "ELEKTRINE_API_BASE is required"
    return 1
  fi

  if [ -z "${ELEKTRINE_INTERNAL_API_KEY:-}" ] && [ -z "${ELEKTRINE_DNS_TOKEN:-}" ]; then
    _elektrine_log "ELEKTRINE_INTERNAL_API_KEY or ELEKTRINE_DNS_TOKEN is required"
    return 1
  fi

  _elektrine_save_config

  if ! command -v python3 >/dev/null 2>&1; then
    _elektrine_log "python3 is required by dns_elektrine"
    return 1
  fi

  if ! command -v curl >/dev/null 2>&1; then
    _elektrine_log "curl is required by dns_elektrine"
    return 1
  fi
}

_elektrine_save_config() {
  if command -v _saveaccountconf_mutable >/dev/null 2>&1; then
    _saveaccountconf_mutable ELEKTRINE_API_BASE "$ELEKTRINE_API_BASE"

    if [ -n "${ELEKTRINE_INTERNAL_API_KEY:-}" ]; then
      _saveaccountconf_mutable ELEKTRINE_INTERNAL_API_KEY "$ELEKTRINE_INTERNAL_API_KEY"
    fi

    if [ -n "${ELEKTRINE_DNS_TOKEN:-}" ]; then
      _saveaccountconf_mutable ELEKTRINE_DNS_TOKEN "$ELEKTRINE_DNS_TOKEN"
    fi
  fi
}

_elektrine_find_zone() {
  fulldomain="$1"
  zones="$(_elektrine_request GET "$ELEKTRINE_API_BASE/api/ext/v1/dns/zones")" || return 1

  ELEKTRINE_FULLDOMAIN="$fulldomain" python3 -c '
import json, os, sys

full = os.environ["ELEKTRINE_FULLDOMAIN"].strip(".").lower()
payload = json.load(sys.stdin)
zones = payload.get("zones", [])

matches = []
for zone in zones:
    domain = str(zone.get("domain", "")).strip(".").lower()
    if domain and (full == domain or full.endswith("." + domain)):
        matches.append((len(domain), zone))

if not matches:
    sys.exit(1)

print(json.dumps(sorted(matches, key=lambda item: item[0], reverse=True)[0][1]))
' <<EOF
$zones
EOF
}

_elektrine_relative_record_name() {
  fulldomain="$1"
  zone_domain="$2"

  ELEKTRINE_FULLDOMAIN="$fulldomain" ELEKTRINE_ZONE_DOMAIN="$zone_domain" python3 -c '
import os, sys

full = os.environ["ELEKTRINE_FULLDOMAIN"].strip(".").lower()
zone = os.environ["ELEKTRINE_ZONE_DOMAIN"].strip(".").lower()

if full == zone:
    print("@")
elif full.endswith("." + zone):
    name = full[:-(len(zone) + 1)]
    if not name:
        print("@")
    else:
        print(name)
else:
    sys.exit(1)
'
}

_elektrine_record_payload() {
  record_name="$1"
  txtvalue="$2"

  ELEKTRINE_RECORD_NAME="$record_name" ELEKTRINE_TXT_VALUE="$txtvalue" python3 -c '
import json, os

print(json.dumps({
    "record": {
        "name": os.environ["ELEKTRINE_RECORD_NAME"],
        "type": "TXT",
        "ttl": 60,
        "content": os.environ["ELEKTRINE_TXT_VALUE"],
    }
}))
'
}

_elektrine_find_txt_record_id() {
  zone_detail="$1"
  record_name="$2"
  txtvalue="$3"

  ELEKTRINE_RECORD_NAME="$record_name" ELEKTRINE_TXT_VALUE="$txtvalue" python3 -c '
import json, os, sys

payload = json.load(sys.stdin)
zone = payload.get("zone", {})
records = zone.get("records", []) or []
name = os.environ["ELEKTRINE_RECORD_NAME"]
value = os.environ["ELEKTRINE_TXT_VALUE"]

for record in records:
    if record.get("name") == name and record.get("type") == "TXT" and record.get("content") == value:
        print(record.get("id"))
        sys.exit(0)
  ' <<EOF
$zone_detail
EOF
}

_elektrine_json_field() {
  json="$1"
  field="$2"

  ELEKTRINE_FIELD="$field" python3 -c '
import json, os, sys

payload = json.load(sys.stdin)
value = payload.get(os.environ["ELEKTRINE_FIELD"])
if value is None:
    sys.exit(1)
print(value)
' <<EOF
$json
EOF
}

_elektrine_request() {
  method="$1"
  url="$2"
  body="${3:-}"

  if [ -n "$body" ]; then
    curl -fsS \
      -X "$method" \
      -H "Authorization: Bearer $ELEKTRINE_DNS_TOKEN" \
      -H "Content-Type: application/json" \
      --data "$body" \
      "$url"
  else
    curl -fsS \
      -X "$method" \
      -H "Authorization: Bearer $ELEKTRINE_DNS_TOKEN" \
      -H "Content-Type: application/json" \
      "$url"
  fi
}

_elektrine_internal_request() {
  method="$1"
  fulldomain="$2"
  txtvalue="$3"
  payload="$(_elektrine_internal_payload "$fulldomain" "$txtvalue")"

  curl -fsS \
    -X "$method" \
    -H "X-API-Key: $ELEKTRINE_INTERNAL_API_KEY" \
    -H "Content-Type: application/json" \
    --data "$payload" \
    "$ELEKTRINE_API_BASE/_edge/acme/dns/v1/txt"
}

_elektrine_internal_payload() {
  fulldomain="$1"
  txtvalue="$2"

  ELEKTRINE_FULLDOMAIN="$fulldomain" ELEKTRINE_TXT_VALUE="$txtvalue" python3 -c '
import json, os

print(json.dumps({
    "domain": os.environ["ELEKTRINE_FULLDOMAIN"],
    "value": os.environ["ELEKTRINE_TXT_VALUE"],
}))
'
}

_elektrine_log() {
  if command -v _err >/dev/null 2>&1; then
    _err "$1"
  else
    printf '%s\n' "$1" >&2
  fi
}
