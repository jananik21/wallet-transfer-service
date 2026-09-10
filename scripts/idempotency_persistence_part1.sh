#!/usr/bin/env bash
# Part 1: create a transfer, save state, then stop so you can restart the app.
#
# Usage:
#   ./scripts/idempotency_persistence_part1.sh
#   # restart the application
#   ./scripts/idempotency_persistence_part2.sh
#
# State file (override with IDEMPOTENCY_STATE_FILE):
#   /tmp/wallet-idempotency-restart.env
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

STATE_FILE="${IDEMPOTENCY_STATE_FILE:-/tmp/wallet-idempotency-restart.env}"
require_app

echo "==> Creating wallets and funding source"
IFS=$'\t' read -r _U1 TOKEN1 < <(create_test_user)
IFS=$'\t' read -r _U2 TOKEN2 < <(create_test_user)
FROM_ID=$(get_or_create_wallet "$TOKEN1")
TO_ID=$(get_or_create_wallet "$TOKEN2")
fund_wallet "$FROM_ID" 50000
fund_wallet "$TO_ID" 0

KEY="restart-test-$(python3 -c 'import uuid; print(uuid.uuid4())')"
BODY=$(python3 -c "import json; print(json.dumps({'from':'$FROM_ID','to':'$TO_ID','amount_paise':1000,'idempotency_key':'$KEY'}))")

echo "==> First transfer (expect 201 COMPLETED)"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/transfers" \
  -H "Authorization: Bearer $TOKEN1" \
  -H "Content-Type: application/json" \
  -d "$BODY")
BODY_JSON=$(echo "$RESP" | sed '$d')
CODE=$(echo "$RESP" | tail -n1)
TID=$(echo "$BODY_JSON" | json_field id)
STATUS=$(echo "$BODY_JSON" | json_field status)
FROM_BAL=$(wallet_balance "$FROM_ID")
TO_BAL=$(wallet_balance "$TO_ID")

echo "    http=$CODE transfer_id=$TID status=$STATUS"
echo "    balances from=$FROM_BAL to=$TO_BAL"

if [[ "$CODE" != "201" || "$STATUS" != "COMPLETED" ]]; then
  echo "FAIL: part1 transfer did not complete" >&2
  exit 1
fi

BODY_FILE="${STATE_FILE}.body.json"
echo "$BODY" > "$BODY_FILE"

cat > "$STATE_FILE" <<EOF
BASE_URL=$BASE_URL
TOKEN1=$TOKEN1
FROM_ID=$FROM_ID
TO_ID=$TO_ID
KEY=$KEY
TRANSFER_ID=$TID
FROM_BAL=$FROM_BAL
TO_BAL=$TO_BAL
BODY_FILE=$BODY_FILE
EOF

echo
echo "PASS part1: state written to $STATE_FILE"
echo
echo "NEXT:"
echo "  1) Restart the application (stop + start)"
echo "  2) Run: ./scripts/idempotency_persistence_part2.sh"
