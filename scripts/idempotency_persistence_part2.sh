#!/usr/bin/env bash
# Part 2: run AFTER restarting the app. Replays the part1 request and checks key reuse.
#
# Usage: ./scripts/idempotency_persistence_part2.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

STATE_FILE="${IDEMPOTENCY_STATE_FILE:-/tmp/wallet-idempotency-restart.env}"
if [[ ! -f "$STATE_FILE" ]]; then
  echo "ERROR: missing $STATE_FILE — run idempotency_persistence_part1.sh first" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$STATE_FILE"
require_app

TMP_CONFLICT="$(mktemp)"
cleanup() {
  rm -f "$TMP_CONFLICT"
  # Leave STATE_FILE for debugging unless CLEAN_STATE=1
  if [[ "${CLEAN_STATE:-0}" == "1" ]]; then
    rm -f "$STATE_FILE" "${BODY_FILE:-}"
  fi
}
trap cleanup EXIT

echo "==> Replay exact same body after restart (expect 200, same transfer id, no second debit)"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/transfers" \
  -H "Authorization: Bearer $TOKEN1" \
  -H "Content-Type: application/json" \
  -d @"$BODY_FILE")
BODY_JSON=$(echo "$RESP" | sed '$d')
CODE=$(echo "$RESP" | tail -n1)
TID=$(echo "$BODY_JSON" | json_field id)
STATUS=$(echo "$BODY_JSON" | json_field status)
FROM_NOW=$(wallet_balance "$FROM_ID")
TO_NOW=$(wallet_balance "$TO_ID")
echo "    http=$CODE transfer_id=$TID status=$STATUS"
echo "    balances from=$FROM_NOW to=$TO_NOW (expect from=$FROM_BAL to=$TO_BAL)"

PASS=1
[[ "$CODE" == "200" ]] || PASS=0
[[ "$TID" == "$TRANSFER_ID" ]] || PASS=0
[[ "$FROM_NOW" == "$FROM_BAL" && "$TO_NOW" == "$TO_BAL" ]] || PASS=0

if [[ "$PASS" -eq 1 ]]; then
  echo "PASS: replay after restart returned same transfer, no second debit"
else
  echo "FAIL: idempotency did not survive restart" >&2
  exit 1
fi

echo
echo "==> Same key + different amount after restart (expect 409)"
BODY2=$(python3 -c "import json; print(json.dumps({'from':'$FROM_ID','to':'$TO_ID','amount_paise':2000,'idempotency_key':'$KEY'}))")
CODE2=$(curl -s -o "$TMP_CONFLICT" -w "%{http_code}" -X POST "$BASE_URL/transfers" \
  -H "Authorization: Bearer $TOKEN1" \
  -H "Content-Type: application/json" \
  -d "$BODY2")
FROM_NOW2=$(wallet_balance "$FROM_ID")
echo "    http=$CODE2 balances_from=$FROM_NOW2"
if [[ "$CODE2" == "409" && "$FROM_NOW2" == "$FROM_BAL" ]]; then
  echo "PASS: different body after restart → 409, no movement"
  CLEAN_STATE=1
  exit 0
fi
echo "FAIL: expected 409 after restart with different body" >&2
exit 1
