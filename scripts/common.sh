#!/usr/bin/env bash
# Shared helpers for local/manual verification scripts.
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-wallet}"
DB_USER="${DB_USER:-wallet}"
DB_PASSWORD="${DB_PASSWORD:-wallet}"

psql_wallet() {
  PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 "$@"
}

sha256_hex() {
  python3 -c 'import sys,hashlib; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$1"
}

json_field() {
  local field="$1"
  python3 -c 'import sys,json; print(json.load(sys.stdin)["'"$field"'"])'
}

require_app() {
  if ! curl -sf "$BASE_URL/actuator/health" >/dev/null; then
    echo "ERROR: app not healthy at $BASE_URL/actuator/health" >&2
    exit 1
  fi
}

# Inserts a fresh api_tokens row and prints: user_id<TAB>token
create_test_user() {
  local user_id="test-user-$(python3 -c 'import uuid; print(uuid.uuid4())')"
  local token="test-token-$(python3 -c 'import uuid; print(uuid.uuid4())')"
  local hash
  hash="$(sha256_hex "$token")"
  psql_wallet -c "INSERT INTO api_tokens (token_hash, user_id) VALUES ('$hash', '$user_id');" >/dev/null
  printf '%s\t%s\n' "$user_id" "$token"
}

get_or_create_wallet() {
  local token="$1"
  curl -sf -X POST "$BASE_URL/wallets" -H "Authorization: Bearer $token" | json_field id
}

fund_wallet() {
  local wallet_id="$1"
  local amount="$2"
  psql_wallet -c "UPDATE wallets SET balance_paise = $amount WHERE id = '$wallet_id';" >/dev/null
}

wallet_balance() {
  local wallet_id="$1"
  psql_wallet -At -c "SELECT balance_paise FROM wallets WHERE id = '$wallet_id';"
}

total_balance() {
  psql_wallet -At -c "SELECT COALESCE(SUM(balance_paise),0) FROM wallets;"
}
