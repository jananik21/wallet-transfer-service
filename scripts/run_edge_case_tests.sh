#!/usr/bin/env bash
# Transfer correctness and API edge cases I used while hardening the service.
# Requires: running app, Postgres access, curl, psql, python3
#
# Usage:
#   ./scripts/run_edge_case_tests.sh
#   BASE_URL=http://127.0.0.1:8080 ./scripts/run_edge_case_tests.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_app

pass=0
fail=0
assert_http() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS  $name (HTTP $actual)"
    pass=$((pass + 1))
  else
    echo "FAIL  $name (expected HTTP $expected, got $actual)" >&2
    fail=$((fail + 1))
  fi
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS  $name ($actual)"
    pass=$((pass + 1))
  else
    echo "FAIL  $name (expected $expected, got $actual)" >&2
    fail=$((fail + 1))
  fi
}

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

echo "============================================"
echo "Setup: two funded wallets"
echo "============================================"
IFS=$'\t' read -r _U1 T1 < <(create_test_user)
IFS=$'\t' read -r _U2 T2 < <(create_test_user)
W1=$(get_or_create_wallet "$T1")
W2=$(get_or_create_wallet "$T2")
fund_wallet "$W1" 100000
fund_wallet "$W2" 50000
BEFORE_TOTAL=$(total_balance)
echo "w1=$W1 (100000) w2=$W2 (50000) total=$BEFORE_TOTAL"

echo
echo "============================================"
echo "1) Happy-path transfer + balance check"
echo "============================================"
KEY_OK="ok-$(python3 -c 'import uuid; print(uuid.uuid4())')"
CODE=$(curl -s -o "$TMP_DIR/ok.json" -w "%{http_code}" \
  -X POST "$BASE_URL/transfers" \
  -H "Authorization: Bearer $T1" -H "Content-Type: application/json" \
  -d "{\"from\":\"$W1\",\"to\":\"$W2\",\"amount_paise\":2500,\"idempotency_key\":\"$KEY_OK\"}")
STATUS=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$TMP_DIR/ok.json")
TID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$TMP_DIR/ok.json")
B1=$(wallet_balance "$W1")
B2=$(wallet_balance "$W2")
assert_http "successful transfer" "201" "$CODE"
assert_eq "status COMPLETED" "COMPLETED" "$STATUS"
assert_eq "source balance after debit" "97500" "$B1"
assert_eq "dest balance after credit" "52500" "$B2"

echo
echo "============================================"
echo "2) Insufficient funds (no negative balance)"
echo "============================================"
KEY_IF="if-$(python3 -c 'import uuid; print(uuid.uuid4())')"
CODE=$(curl -s -o "$TMP_DIR/if.json" -w "%{http_code}" \
  -X POST "$BASE_URL/transfers" \
  -H "Authorization: Bearer $T1" -H "Content-Type: application/json" \
  -d "{\"from\":\"$W1\",\"to\":\"$W2\",\"amount_paise\":999999999,\"idempotency_key\":\"$KEY_IF\"}")
STATUS=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$TMP_DIR/if.json")
B1_AFTER=$(wallet_balance "$W1")
assert_http "insufficient funds response" "422" "$CODE"
assert_eq "declined status" "DECLINED_INSUFFICIENT_FUNDS" "$STATUS"
assert_eq "source balance unchanged" "$B1" "$B1_AFTER"

echo
echo "============================================"
echo "3) Idempotent replay (same key + body)"
echo "============================================"
CODE=$(curl -s -o "$TMP_DIR/replay.json" -w "%{http_code}" \
  -X POST "$BASE_URL/transfers" \
  -H "Authorization: Bearer $T1" -H "Content-Type: application/json" \
  -d "{\"from\":\"$W1\",\"to\":\"$W2\",\"amount_paise\":2500,\"idempotency_key\":\"$KEY_OK\"}")
TID2=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$TMP_DIR/replay.json")
B1_R=$(wallet_balance "$W1")
assert_http "idempotent replay" "200" "$CODE"
assert_eq "same transfer id" "$TID" "$TID2"
assert_eq "balance unchanged on replay" "$B1" "$B1_R"

echo
echo "============================================"
echo "4) Same key, different body → 409"
echo "============================================"
CODE=$(curl -s -o "$TMP_DIR/conflict.json" -w "%{http_code}" \
  -X POST "$BASE_URL/transfers" \
  -H "Authorization: Bearer $T1" -H "Content-Type: application/json" \
  -d "{\"from\":\"$W1\",\"to\":\"$W2\",\"amount_paise\":1,\"idempotency_key\":\"$KEY_OK\"}")
assert_http "key reuse with different body" "409" "$CODE"

echo
echo "============================================"
echo "5) Self-transfer rejected"
echo "============================================"
KEY_SELF="self-$(python3 -c 'import uuid; print(uuid.uuid4())')"
CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "$BASE_URL/transfers" \
  -H "Authorization: Bearer $T1" -H "Content-Type: application/json" \
  -d "{\"from\":\"$W1\",\"to\":\"$W1\",\"amount_paise\":1,\"idempotency_key\":\"$KEY_SELF\"}")
assert_http "self-transfer" "400" "$CODE"

echo
echo "============================================"
echo "6) Invalid amounts"
echo "============================================"
KEY_Z="zero-$(python3 -c 'import uuid; print(uuid.uuid4())')"
CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "$BASE_URL/transfers" \
  -H "Authorization: Bearer $T1" -H "Content-Type: application/json" \
  -d "{\"from\":\"$W1\",\"to\":\"$W2\",\"amount_paise\":0,\"idempotency_key\":\"$KEY_Z\"}")
assert_http "zero amount" "400" "$CODE"

KEY_N="neg-$(python3 -c 'import uuid; print(uuid.uuid4())')"
CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "$BASE_URL/transfers" \
  -H "Authorization: Bearer $T1" -H "Content-Type: application/json" \
  -d "{\"from\":\"$W1\",\"to\":\"$W2\",\"amount_paise\":-5,\"idempotency_key\":\"$KEY_N\"}")
assert_http "negative amount" "400" "$CODE"

# App max is Long.MAX_VALUE for @Max; use a value that fails Bean Validation if configured,
# or skip if the service accepts all positive longs. Prefer a clearly absurd oversize string via JSON.
# If validation only rejects via @Positive/@Max, try amount larger than typical config (1e15).
KEY_BIG="big-$(python3 -c 'import uuid; print(uuid.uuid4())')"
CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "$BASE_URL/transfers" \
  -H "Authorization: Bearer $T1" -H "Content-Type: application/json" \
  -d "{\"from\":\"$W1\",\"to\":\"$W2\",\"amount_paise\":1000000000000001,\"idempotency_key\":\"$KEY_BIG\"}")
assert_http "amount above configured maximum" "400" "$CODE"

echo
echo "============================================"
echo "7) Missing wallet / auth"
echo "============================================"
MISSING="$(python3 -c 'import uuid; print(uuid.uuid4())')"
KEY_MW="mw-$(python3 -c 'import uuid; print(uuid.uuid4())')"
CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "$BASE_URL/transfers" \
  -H "Authorization: Bearer $T1" -H "Content-Type: application/json" \
  -d "{\"from\":\"$MISSING\",\"to\":\"$W2\",\"amount_paise\":1,\"idempotency_key\":\"$KEY_MW\"}")
assert_http "missing source wallet" "404" "$CODE"

CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "$BASE_URL/transfers" \
  -H "Content-Type: application/json" \
  -d "{\"from\":\"$W1\",\"to\":\"$W2\",\"amount_paise\":1,\"idempotency_key\":\"noauth-$(python3 -c 'import uuid; print(uuid.uuid4())')\"}")
assert_http "missing Authorization" "401" "$CODE"

CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "$BASE_URL/transfers" \
  -H "Authorization: Bearer not-a-real-token" -H "Content-Type: application/json" \
  -d "{\"from\":\"$W1\",\"to\":\"$W2\",\"amount_paise\":1,\"idempotency_key\":\"badtok-$(python3 -c 'import uuid; print(uuid.uuid4())')\"}")
assert_http "invalid token" "401" "$CODE"

CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "$BASE_URL/transfers" \
  -H "Authorization: NotBearer $T1" -H "Content-Type: application/json" \
  -d "{\"from\":\"$W1\",\"to\":\"$W2\",\"amount_paise\":1,\"idempotency_key\":\"mal-$(python3 -c 'import uuid; print(uuid.uuid4())')\"}")
assert_http "malformed Authorization" "401" "$CODE"

AFTER_TOTAL=$(total_balance)
assert_eq "money conserved across edge cases" "$BEFORE_TOTAL" "$AFTER_TOTAL"

echo
echo "passed=$pass failed=$fail"
if [[ "$fail" -ne 0 ]]; then
  echo "SOME EDGE CASE TESTS FAILED" >&2
  exit 1
fi
echo "ALL EDGE CASE TESTS PASSED"
