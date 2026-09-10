#!/usr/bin/env bash
# Concurrency and money-safety checks I used while validating the transfer path.
# Requires: running app, Postgres access, curl, psql, python3
#
# Usage:
#   ./scripts/run_concurrency_tests.sh
#   BASE_URL=http://127.0.0.1:8080 ./scripts/run_concurrency_tests.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

require_app

echo "============================================"
echo "1) Concurrent wallet get-or-create"
echo "============================================"
CONCURRENCY=50
IFS=$'\t' read -r USER_ID TOKEN < <(create_test_user)
echo "user_id=$USER_ID concurrency=$CONCURRENCY"

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

pids=()
for i in $(seq 1 "$CONCURRENCY"); do
  (
    code=$(curl -s -o "$TMP_DIR/$i.json" -w "%{http_code}" \
      -X POST "$BASE_URL/wallets" \
      -H "Authorization: Bearer $TOKEN")
    echo "$code" > "$TMP_DIR/$i.code"
  ) &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid"; done

EVAL=$(python3 - <<PY
import json, pathlib
ids=set(); ok=0; created=0
for p in pathlib.Path("$TMP_DIR").glob("*.json"):
    data=json.loads(p.read_text())
    ids.add(data["id"])
    code=int(p.with_suffix(".code").read_text().strip())
    if 200 <= code < 300:
        ok += 1
    if code == 201:
        created += 1
print(ok, created, len(ids), next(iter(ids)) if ids else "")
PY
)
read -r OK CREATED UNIQUE WALLET_ID <<<"$EVAL"
DB_COUNT=$(psql_wallet -At -c "SELECT COUNT(*) FROM wallets WHERE user_id = '$USER_ID';")
echo "successful=$OK/$CONCURRENCY http_201=$CREATED unique_ids=$UNIQUE db_rows=$DB_COUNT"
if [[ "$OK" -ne "$CONCURRENCY" || "$UNIQUE" -ne 1 || "$DB_COUNT" -ne 1 ]]; then
  echo "FAIL: concurrent get-or-create did not converge on one wallet" >&2
  exit 1
fi
echo "PASS"
rm -rf "$TMP_DIR"
TMP_DIR="$(mktemp -d)"
trap cleanup EXIT

echo
echo "============================================"
echo "2) Concurrent identical transfers (same idempotency key)"
echo "============================================"
STORM=30
AMOUNT=10000
START=100000
IFS=$'\t' read -r _U1 T1 < <(create_test_user)
IFS=$'\t' read -r _U2 T2 < <(create_test_user)
FROM_ID=$(get_or_create_wallet "$T1")
TO_ID=$(get_or_create_wallet "$T2")
fund_wallet "$FROM_ID" "$START"
fund_wallet "$TO_ID" 0
KEY="storm-$(python3 -c 'import uuid; print(uuid.uuid4())')"
BODY=$(python3 -c "import json; print(json.dumps({'from':'$FROM_ID','to':'$TO_ID','amount_paise':$AMOUNT,'idempotency_key':'$KEY'}))")
BEFORE_TOTAL=$(total_balance)
echo "from=$FROM_ID to=$TO_ID key=$KEY"

pids=()
for i in $(seq 1 "$STORM"); do
  (
    code=$(curl -s -o "$TMP_DIR/$i.json" -w "%{http_code}" \
      -X POST "$BASE_URL/transfers" \
      -H "Authorization: Bearer $T1" \
      -H "Content-Type: application/json" \
      -d "$BODY")
    echo "$code" > "$TMP_DIR/$i.code"
  ) &
  pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid"; done

EVAL=$(python3 - <<PY
import json, pathlib
ids=set(); ok=0
for p in pathlib.Path("$TMP_DIR").glob("*.json"):
    data=json.loads(p.read_text())
    ids.add(data["id"])
    code=int(p.with_suffix(".code").read_text().strip())
    if code in (200, 201):
        ok += 1
print(ok, len(ids), next(iter(ids)) if ids else "")
PY
)
read -r OK UNIQUE_TIDS TID <<<"$EVAL"
FROM_BAL=$(wallet_balance "$FROM_ID")
TO_BAL=$(wallet_balance "$TO_ID")
AFTER_TOTAL=$(total_balance)
TX_COUNT=$(psql_wallet -At -c "SELECT COUNT(*) FROM transfers WHERE idempotency_key = '$KEY';")
echo "successful=$OK/$STORM unique_transfer_ids=$UNIQUE_TIDS rows_for_key=$TX_COUNT"
echo "balances from=$FROM_BAL to=$TO_BAL total $BEFORE_TOTAL -> $AFTER_TOTAL"
if [[ "$OK" -ne "$STORM" || "$UNIQUE_TIDS" -ne 1 || "$TX_COUNT" -ne 1 \
   || "$FROM_BAL" -ne $((START - AMOUNT)) || "$TO_BAL" -ne "$AMOUNT" \
   || "$BEFORE_TOTAL" -ne "$AFTER_TOTAL" ]]; then
  echo "FAIL: idempotency storm moved money more than once or lost conservation" >&2
  exit 1
fi
echo "PASS"
rm -rf "$TMP_DIR"
TMP_DIR="$(mktemp -d)"
trap cleanup EXIT

echo
echo "============================================"
echo "3) Concurrent A↔B transfers + intentional overdrafts"
echo "============================================"
N=200
PARALLEL=25
SEED=50000
IFS=$'\t' read -r _UA TA < <(create_test_user)
IFS=$'\t' read -r _UB TB < <(create_test_user)
IFS=$'\t' read -r _UC TC < <(create_test_user)
A=$(get_or_create_wallet "$TA")
B=$(get_or_create_wallet "$TB")
C=$(get_or_create_wallet "$TC")
fund_wallet "$A" "$SEED"
fund_wallet "$B" "$SEED"
fund_wallet "$C" "$SEED"
BEFORE=$(psql_wallet -At -c "SELECT COALESCE(SUM(balance_paise),0) FROM wallets WHERE id IN ('$A','$B','$C');")
RUN_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
echo "A=$A B=$B C=$C before_sum=$BEFORE"

python3 - <<PY
import json, pathlib, urllib.request, urllib.error, concurrent.futures

base = "$BASE_URL".rstrip("/")
tmp = pathlib.Path("$TMP_DIR")
n = int("$N")
parallel = int("$PARALLEL")
run_id = "$RUN_ID"
A, B, C = "$A", "$B", "$C"
TA, TB, TC = "$TA", "$TB", "$TC"

work = []
for i in range(1, n + 1):
    r = i % 5
    if r == 0:
        frm, to, token, amt = A, B, TA, 1000
    elif r == 1:
        frm, to, token, amt = B, A, TB, 1000
    elif r == 2:
        frm, to, token, amt = A, C, TA, 500
    elif r == 3:
        frm, to, token, amt = C, B, TC, 500
    else:
        frm, to, token, amt = A, B, TA, 999999999
    work.append({
        "i": i, "from": frm, "to": to, "token": token,
        "amount_paise": amt, "idempotency_key": f"cont-{run_id}-{i}",
    })

def one(item):
    body = json.dumps({
        "from": item["from"], "to": item["to"],
        "amount_paise": item["amount_paise"],
        "idempotency_key": item["idempotency_key"],
    }).encode()
    req = urllib.request.Request(
        base + "/transfers", data=body, method="POST",
        headers={"Authorization": f"Bearer {item['token']}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw, code = resp.read(), resp.status
    except urllib.error.HTTPError as e:
        raw, code = e.read(), e.code
    (tmp / f"{item['i']}.json").write_bytes(raw)
    (tmp / f"{item['i']}.code").write_text(str(code))

with concurrent.futures.ThreadPoolExecutor(max_workers=parallel) as pool:
    list(pool.map(one, work))

completed = declined = other = errors = 0
for item in work:
    code = int((tmp / f"{item['i']}.code").read_text().strip())
    data = json.loads((tmp / f"{item['i']}.json").read_text() or "{}")
    if code >= 500:
        errors += 1
        continue
    st = data.get("status")
    if st == "COMPLETED":
        completed += 1
    elif st == "DECLINED_INSUFFICIENT_FUNDS":
        declined += 1
    else:
        other += 1
(tmp / "counts.txt").write_text(f"{completed} {declined} {other} {errors}\n")
PY

read -r COMPLETED DECLINED OTHER ERRORS < "$TMP_DIR/counts.txt"
AFTER=$(psql_wallet -At -c "SELECT COALESCE(SUM(balance_paise),0) FROM wallets WHERE id IN ('$A','$B','$C');")
NEG=$(psql_wallet -At -c "SELECT COUNT(*) FROM wallets WHERE id IN ('$A','$B','$C') AND balance_paise < 0;")
echo "completed=$COMPLETED declined=$DECLINED other=$OTHER http_5xx=$ERRORS"
echo "after_sum=$AFTER negative_rows=$NEG"
if [[ "$AFTER" -ne "$BEFORE" || "$NEG" -ne 0 || "$ERRORS" -ne 0 || "$DECLINED" -le 0 || "$COMPLETED" -le 0 ]]; then
  echo "FAIL: contention invariants broken" >&2
  exit 1
fi
echo "PASS"
rm -rf "$TMP_DIR"
TMP_DIR="$(mktemp -d)"
trap cleanup EXIT

echo
echo "============================================"
echo "4) Concurrent overdraft against one wallet"
echo "============================================"
IFS=$'\t' read -r _UO TOKO < <(create_test_user)
IFS=$'\t' read -r _UD TOD < <(create_test_user)
WO=$(get_or_create_wallet "$TOKO")
WD=$(get_or_create_wallet "$TOD")
fund_wallet "$WO" 10000
fund_wallet "$WD" 0
BEFORE_T=$(total_balance)
RUN=$(python3 -c 'import uuid; print(uuid.uuid4())')
for i in $(seq 1 20); do
  (
    curl -s -o "$TMP_DIR/$i.json" -w "%{http_code}" -X POST "$BASE_URL/transfers" \
      -H "Authorization: Bearer $TOKO" -H "Content-Type: application/json" \
      -d "{\"from\":\"$WO\",\"to\":\"$WD\",\"amount_paise\":1000,\"idempotency_key\":\"od-$RUN-$i\"}" \
      > "$TMP_DIR/$i.code"
  ) &
done
wait
EVAL=$(python3 - <<PY
import json, pathlib
comp=dec=err=0
for p in pathlib.Path("$TMP_DIR").glob("*.json"):
    code=int(p.with_suffix(".code").read_text().strip())
    data=json.loads(p.read_text())
    if code >= 500:
        err += 1
        continue
    st=data.get("status")
    if st == "COMPLETED":
        comp += 1
    elif st == "DECLINED_INSUFFICIENT_FUNDS":
        dec += 1
print(comp, dec, err)
PY
)
read -r COMP DEC ERR <<<"$EVAL"
AFTER_O=$(wallet_balance "$WO")
AFTER_T=$(total_balance)
echo "completed=$COMP declined=$DEC http_5xx=$ERR final_source_balance=$AFTER_O"
if [[ "$COMP" -ne 10 || "$DEC" -ne 10 || "$ERR" -ne 0 || "$AFTER_O" -ne 0 || "$BEFORE_T" -ne "$AFTER_T" ]]; then
  echo "FAIL: concurrent overdraft allowed too many successes or broke conservation" >&2
  exit 1
fi
echo "PASS"
rm -rf "$TMP_DIR"
TMP_DIR="$(mktemp -d)"
trap cleanup EXIT

echo
echo "============================================"
echo "5) Higher load A↔B (500 transfers)"
echo "============================================"
N=500
PARALLEL=50
SEED=100000
IFS=$'\t' read -r _UA TA < <(create_test_user)
IFS=$'\t' read -r _UB TB < <(create_test_user)
A=$(get_or_create_wallet "$TA")
B=$(get_or_create_wallet "$TB")
fund_wallet "$A" "$SEED"
fund_wallet "$B" "$SEED"
BEFORE=$(psql_wallet -At -c "SELECT COALESCE(SUM(balance_paise),0) FROM wallets WHERE id IN ('$A','$B');")
RUN_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
echo "A=$A B=$B before_sum=$BEFORE"

python3 - <<PY
import json, pathlib, urllib.request, urllib.error, concurrent.futures

base = "$BASE_URL".rstrip("/")
tmp = pathlib.Path("$TMP_DIR")
n, parallel, run_id = int("$N"), int("$PARALLEL"), "$RUN_ID"
A, B, TA, TB = "$A", "$B", "$TA", "$TB"
work = []
for i in range(1, n + 1):
    if i % 2 == 0:
        frm, to, token = A, B, TA
    else:
        frm, to, token = B, A, TB
    work.append({
        "i": i, "from": frm, "to": to, "token": token,
        "amount_paise": 100, "idempotency_key": f"hi-{run_id}-{i}",
    })

def one(item):
    body = json.dumps({
        "from": item["from"], "to": item["to"],
        "amount_paise": item["amount_paise"],
        "idempotency_key": item["idempotency_key"],
    }).encode()
    req = urllib.request.Request(
        base + "/transfers", data=body, method="POST",
        headers={"Authorization": f"Bearer {item['token']}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw, code = resp.read(), resp.status
    except urllib.error.HTTPError as e:
        raw, code = e.read(), e.code
    (tmp / f"{item['i']}.json").write_bytes(raw)
    (tmp / f"{item['i']}.code").write_text(str(code))

with concurrent.futures.ThreadPoolExecutor(max_workers=parallel) as pool:
    list(pool.map(one, work))

completed = declined = other = errors = 0
for item in work:
    code = int((tmp / f"{item['i']}.code").read_text().strip())
    data = json.loads((tmp / f"{item['i']}.json").read_text() or "{}")
    if code >= 500:
        errors += 1
        continue
    st = data.get("status")
    if st == "COMPLETED":
        completed += 1
    elif st == "DECLINED_INSUFFICIENT_FUNDS":
        declined += 1
    else:
        other += 1
(tmp / "counts.txt").write_text(f"{completed} {declined} {other} {errors}\n")
PY

read -r COMPLETED DECLINED OTHER ERRORS < "$TMP_DIR/counts.txt"
AFTER=$(psql_wallet -At -c "SELECT COALESCE(SUM(balance_paise),0) FROM wallets WHERE id IN ('$A','$B');")
NEG=$(psql_wallet -At -c "SELECT COUNT(*) FROM wallets WHERE id IN ('$A','$B') AND balance_paise < 0;")
echo "completed=$COMPLETED declined=$DECLINED other=$OTHER http_5xx=$ERRORS"
echo "after_sum=$AFTER negative_rows=$NEG"
if [[ "$AFTER" -ne "$BEFORE" || "$NEG" -ne 0 || "$ERRORS" -ne 0 || "$OTHER" -ne 0 ]]; then
  echo "FAIL: high-load contention invariants broken" >&2
  exit 1
fi
echo "PASS"

echo
echo "ALL CONCURRENCY TESTS PASSED"
