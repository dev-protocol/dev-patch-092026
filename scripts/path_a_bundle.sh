#!/usr/bin/env bash
# Path A same-block bundle: snapshot → sign → eth_callBundle → (opt-in) eth_sendBundle.
#
# Does NOT public-broadcast. Do not `cast publish` the signed txs.
#
# Usage (repo root or this directory; required env listed below):
#   ./scripts/path_a_bundle.sh snapshot    # balances + PAIR_DELTA / FEE_DELTA only
#   ./scripts/path_a_bundle.sh simulate    # snapshot, sign TX1–TX3, eth_callBundle (no send)
#   ./scripts/path_a_bundle.sh submit      # eth_sendBundle loop (requires a successful simulate)
#   ./scripts/path_a_bundle.sh verify      # post-land checks (RUNBOOK §3)
#   ./scripts/path_a_bundle.sh cancel      # eth_cancelBundle using the saved replacementUuid
#
# TX2 Pair / FeeCollector amounts are KEEP_OFFSET + pre-attack remainder, not a
# live delta, so a swap between simulate and land cannot under/over-burn.
#
# Required for simulate/submit:
#   SETTLEMENT   deployed Settlement (this patch: config(), dev(), KEEP_OFFSET)
#   EXECUTOR     address passed as Settlement._executor (must match executor())
#   OWNER_KEY    owner EOA private key (0x1dCb85ef…)
#   EXECUTOR_KEY executor private key (different address from owner)
#   AUTH_KEY     throwaway key used only to authenticate to the Flashbots relay (no funds)
#
# Optional: RPC RELAY PRIORITY MAXFEE GAS_SET GAS_SETTLE BUNDLE_STATE_DIR

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PATH="${PATH}:${HOME}/.foundry/bin"

DEV=0x5caf454ba92e6f2c929df14667ee360ed9fd5b26
CONFIG=0x1D415aa39D647834786EB9B5a333A50e9935b796
ORIGF=0xCD82603e66F30162cfc1aE3770510480464F5275
OWNER=0x1dCb85efEa6A3FB528d19B9174E88ee35BfF540a
MG=0x54eEFF7ad1e35F7395b1b4f4c86Ec113Eb66F242
PAIR=0x4168CEF0fCa0774176632d86bA26553E3B9cF59d
WDEV=0x4a5df63b0c37b38515e4ee51baf40edd420bf7d5
FEECOLLECTOR=0x90cbe4bdd538d6e9b379bff5fe72c3d67a521de5
CL1=0x58d3382fc3fc09b08ee4560a41008856321e926d
CL2=0x1932423fef71a47fa6eeaaf99149adba42fe95a5
CL3=0x6f9fe645408960ef52f7018fcb2507722feaa740
CL4=0x4b0d30d98390f3079ae812732300fa3138bda775
CL5=0xe9084b1b98d3ceb3cb42691e31c9e1f1231498f5
CL6=0xef7afd67cf7d2eaa3b3dd200a82747134748c22d
CL7=0x2c00d792e2c1e4f13d223da640a4d76c16b6d170
CL8=0x305b38ec316c13f2322e1ea0c959a771667fb8e4
MAX=0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
WDEV_FIXED=100000000000000000000000000
PAIR_PRE=3182715966190325101277057
FEE_PRE=220400025594150502

RPC="${RPC:-https://ethereum-rpc.publicnode.com}"
RELAY="${RELAY:-https://relay.flashbots.net}"
PRIORITY="${PRIORITY:-5gwei}"
MAXFEE="${MAXFEE:-50gwei}"
GAS_SET="${GAS_SET:-80000}"
GAS_SETTLE="${GAS_SETTLE:-700000}"
export RPC DEV PAIR FEECOLLECTOR

if [[ -d /dev/shm ]]; then
  STATE_DIR="${BUNDLE_STATE_DIR:-/dev/shm/dev-patch-092026-bundle}"
else
  STATE_DIR="${BUNDLE_STATE_DIR:-${TMPDIR:-/tmp}/dev-patch-092026-bundle}"
fi

need() { command -v "$1" >/dev/null || { echo "ABORT: missing $1" >&2; exit 1; }; }

lc() { tr '[:upper:]' '[:lower:]' <<<"$1"; }

addr_eq() { [[ "$(lc "$1")" == "$(lc "$2")" ]]; }

# uint256 compare. op: eq | lt | ge. Accepts decimal or 0x hex (bash arithmetic is 64-bit).
u256() {
  python3 -c 'import sys
op, a, b = sys.argv[1], sys.argv[2].strip(), sys.argv[3].strip()
def p(s):
    return int(s, 16) if s[:2] in ("0x", "0X") else int(s, 10)
x, y = p(a), p(b)
sys.exit(0 if {"eq": x == y, "lt": x < y, "ge": x >= y}[op] else 1)' "$1" "$2" "$3"
}

# Settlement.KEEP_OFFSET + keepWei  (leave keepWei, burn the rest at execution)
keep_encode() {
  python3 -c 'import sys; print((1 << 255) + int(sys.argv[1], 10))' "$1"
}

assert_chain_id() {
  local chain
  chain="$(cast chain-id --rpc-url "$RPC")"
  [[ "$chain" == "1" ]] || { echo "ABORT: chain-id=$chain (want 1)" >&2; exit 1; }
}

cast_addr() {
  local raw
  raw="$(cast call "$1" "$2" ${3:+"$3"} --rpc-url "$RPC")"
  echo "${raw%%[[:space:]]*}"
}

cast_u256() {
  local raw
  raw="$(cast call "$1" "$2" ${3:+"$3"} --rpc-url "$RPC")"
  echo "${raw%%[[:space:]]*}"
}

load_deltas() {
  echo "==> computing PAIR_DELTA / FEE_DELTA" >&2
  eval "$(python3 scripts/compute_burn_deltas.py)"
  test -n "${PAIR_DELTA:-}" && test -n "${FEE_DELTA:-}" || {
    echo "ABORT: deltas missing" >&2
    exit 1
  }
}

snapshot() {
  need cast
  need python3
  echo "==> snapshot"
  echo "rpc=$RPC chain-id=$(cast chain-id --rpc-url "$RPC") block=$(cast block-number --rpc-url "$RPC")"
  SUPPLY_BEFORE="$(cast_u256 "$DEV" "totalSupply()(uint256)")"
  echo "totalSupply $SUPPLY_BEFORE"
  local a
  for a in "$CL1" "$CL2" "$CL3" "$CL4" "$CL5" "$CL6" "$CL7" "$CL8" "$FEECOLLECTOR" "$PAIR" "$WDEV"; do
    echo "$a $(cast_u256 "$DEV" "balanceOf(address)(uint256)" "$a")"
  done
  echo "WDEV.totalSupply $(cast_u256 "$WDEV" "totalSupply()(uint256)")"
  load_deltas
  echo "PAIR_DELTA=$PAIR_DELTA"
  echo "FEE_DELTA=$FEE_DELTA"
  echo "pair remain (must == $PAIR_PRE): $PAIR_PRE"
  echo "fee remain (must == $FEE_PRE): $FEE_PRE"
  local wdev_now
  wdev_now="$(cast_u256 "$DEV" "balanceOf(address)(uint256)" "$WDEV")"
  u256 ge "$wdev_now" "$WDEV_FIXED" || {
    echo "ABORT: WDEV backing $wdev_now < fixed burn $WDEV_FIXED" >&2
    exit 1
  }
}

require_env() {
  local k
  for k in SETTLEMENT EXECUTOR OWNER_KEY EXECUTOR_KEY AUTH_KEY; do
    test -n "${!k:-}" || { echo "ABORT: export $k" >&2; exit 1; }
  done
}

precheck() {
  require_env
  local owner_from_key exec_from_key onchain_exec factory
  local code onchain_config onchain_dev onchain_keep
  assert_chain_id

  owner_from_key="$(cast wallet address --private-key "$OWNER_KEY")"
  exec_from_key="$(cast wallet address --private-key "$EXECUTOR_KEY")"
  addr_eq "$owner_from_key" "$OWNER" || {
    echo "ABORT: OWNER_KEY is $owner_from_key, want $OWNER" >&2
    exit 1
  }
  addr_eq "$exec_from_key" "$EXECUTOR" || {
    echo "ABORT: EXECUTOR_KEY is $exec_from_key, want EXECUTOR=$EXECUTOR" >&2
    exit 1
  }
  if addr_eq "$OWNER" "$EXECUTOR"; then
    echo "ABORT: this script is the 2-key bundle (owner nonce N,N+1 + executor nonce M). OWNER==EXECUTOR would collide. Use distinct keys." >&2
    exit 1
  fi

  if addr_eq "$SETTLEMENT" "$ORIGF" || addr_eq "$SETTLEMENT" "$OWNER" || addr_eq "$SETTLEMENT" "0x0000000000000000000000000000000000000000"; then
    echo "ABORT: SETTLEMENT=$SETTLEMENT is not a dedicated Settlement contract" >&2
    exit 1
  fi

  code="$(cast code "$SETTLEMENT" --rpc-url "$RPC")"
  code="${code//$'\n'/}"
  code="${code%%[[:space:]]*}"
  [[ -n "$code" && "$code" != "0x" ]] || {
    echo "ABORT: no code at SETTLEMENT=$SETTLEMENT" >&2
    exit 1
  }

  onchain_config="$(cast_addr "$SETTLEMENT" "config()(address)")"
  addr_eq "$onchain_config" "$CONFIG" || {
    echo "ABORT: Settlement.config=$onchain_config want $CONFIG" >&2
    exit 1
  }
  onchain_dev="$(cast_addr "$SETTLEMENT" "dev()(address)")"
  addr_eq "$onchain_dev" "$DEV" || {
    echo "ABORT: Settlement.dev=$onchain_dev want $DEV" >&2
    exit 1
  }
  onchain_exec="$(cast_addr "$SETTLEMENT" "executor()(address)")"
  addr_eq "$onchain_exec" "$EXECUTOR" || {
    echo "ABORT: Settlement.executor=$onchain_exec want $EXECUTOR" >&2
    exit 1
  }
  onchain_keep="$(cast_u256 "$SETTLEMENT" "KEEP_OFFSET()(uint256)")"
  u256 eq "$onchain_keep" "$(python3 -c 'print(1 << 255)')" || {
    echo "ABORT: Settlement.KEEP_OFFSET=$onchain_keep want 2^255 (this patch). Redeploy." >&2
    exit 1
  }

  factory="$(cast_addr "$CONFIG" "marketFactory()(address)")"
  addr_eq "$factory" "$ORIGF" || {
    echo "ABORT: marketFactory=$factory want ORIGF=$ORIGF" >&2
    exit 1
  }

  echo "owner ETH $(cast balance "$OWNER" --rpc-url "$RPC" --ether)"
  echo "executor ETH $(cast balance "$EXECUTOR" --rpc-url "$RPC" --ether)"
  echo "marketGroup getCount $(cast_u256 "$MG" "getCount()(uint256)")"
}

flashbots_post() {
  local method="$1"
  local params="$2"
  local body hash sig
  body=$(printf '{"jsonrpc":"2.0","id":1,"method":"%s","params":[%s]}' "$method" "$params")
  hash=$(printf '%s' "$body" | cast keccak)
  # Relay EIP-191-signs keccak256(body).Hex() as UTF-8 (66 chars incl. 0x), not the
  # decoded 32-byte hash. `cast wallet sign 0x…` hex-decodes → -32025 invalid signature.
  sig=$(cast wallet sign "$(cast from-utf8 "$hash")" --private-key "$AUTH_KEY")
  curl -sS "$RELAY" \
    -H 'content-type: application/json' \
    -H "X-Flashbots-Signature: ${AUTH_ADDR}:${sig}" \
    --data-binary "$body"
}

check_call_bundle() {
  python3 - "$1" <<'PY'
import json, sys
path = sys.argv[1]
raw = open(path).read()
try:
    d = json.loads(raw)
except json.JSONDecodeError as e:
    sys.stderr.write(f"ABORT: relay non-JSON: {e}\n{raw[:800]}\n")
    sys.exit(1)
if d.get("error"):
    sys.stderr.write(f"ABORT: jsonrpc error: {d['error']}\n")
    sys.exit(1)
res = d.get("result")
if not isinstance(res, dict):
    sys.stderr.write(f"ABORT: unexpected callBundle result: {res!r}\n")
    sys.exit(1)
results = res.get("results")
if not isinstance(results, list) or len(results) != 3:
    sys.stderr.write(f"ABORT: expected 3 tx results, got {results!r}\n")
    sys.exit(1)
for i, r in enumerate(results):
    if r.get("error") or r.get("revert"):
        sys.stderr.write(f"ABORT: TX{i+1} failed: {r}\n")
        sys.exit(1)
    sys.stderr.write(f"TX{i+1} gasUsed={r.get('gasUsed')}\n")
print("SIM_OK")
PY
}

# Live pair/fee still ≥ pre-attack (python ABORT) and WDEV backing ≥ 100M. Returns 1 on
# failure so submit can cancel an in-flight bundle instead of dying via set -e.
assert_keep_floors() {
  local out wdev_now
  if ! out="$(python3 scripts/compute_burn_deltas.py)"; then
    return 1
  fi
  eval "$out"
  test -n "${PAIR_DELTA:-}" && test -n "${FEE_DELTA:-}" || return 1
  wdev_now="$(cast_u256 "$DEV" "balanceOf(address)(uint256)" "$WDEV")"
  if ! u256 ge "$wdev_now" "$WDEV_FIXED"; then
    echo "ABORT: WDEV backing $wdev_now < fixed burn $WDEV_FIXED" >&2
    return 1
  fi
  return 0
}

cancel_inflight() {
  if [[ ! -f "$STATE_DIR/uuid" ]]; then
    return 0
  fi
  AUTH_ADDR="${AUTH_ADDR:-$(cast wallet address --private-key "$AUTH_KEY")}"
  UUID="$(cat "$STATE_DIR/uuid")"
  echo "==> eth_cancelBundle $UUID (abort)" >&2
  flashbots_post eth_cancelBundle "$(printf '{"replacementUuid":"%s"}' "$UUID")" || true
  echo >&2
}

# Landed = TX2 receipt success + factory restored + both nonces advanced + supply down.
bundle_landed() {
  local now_f now_on now_en now_supply receipt_status
  now_f="$(cast_addr "$CONFIG" "marketFactory()(address)")"
  now_on="$(cast nonce "$OWNER" --rpc-url "$RPC")"
  now_en="$(cast nonce "$EXECUTOR" --rpc-url "$RPC")"
  now_supply="$(cast_u256 "$DEV" "totalSupply()(uint256)")"
  addr_eq "$now_f" "$ORIGF" || return 1
  [[ "$now_on" -ge $((ON + 2)) ]] || return 1
  [[ "$now_en" -ge $((EN + 1)) ]] || return 1
  u256 lt "$now_supply" "$SUPPLY_BEFORE" || return 1
  # NOTE: this cast version takes the receipt field positionally (`cast receipt <HASH> status`);
  # `--field` is rejected and the `2>/dev/null || true` below masked it, making this always "".
  receipt_status="$(cast receipt "$TX2_HASH" --rpc-url "$RPC" status 2>/dev/null || true)"
  receipt_status="${receipt_status%%[[:space:]]*}"
  [[ "$receipt_status" == "1" || "$receipt_status" == "0x1" ]] || return 1
  return 0
}

write_state() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  cat >"$STATE_DIR/meta.env" <<EOF
ON=$ON
EN=$EN
SETTLEMENT=$SETTLEMENT
EXECUTOR=$EXECUTOR
OWNER=$OWNER
PAIR_DELTA=$PAIR_DELTA
FEE_DELTA=$FEE_DELTA
AUTH_ADDR=$AUTH_ADDR
SUPPLY_BEFORE=$SUPPLY_BEFORE
EOF
  umask 077
  printf '%s' "$TX1" >"$STATE_DIR/tx1.raw"
  printf '%s' "$TX2" >"$STATE_DIR/tx2.raw"
  printf '%s' "$TX3" >"$STATE_DIR/tx3.raw"
}

cmd_simulate() {
  need cast
  need python3
  need curl
  snapshot
  precheck
  AUTH_ADDR="$(cast wallet address --private-key "$AUTH_KEY")"

  ON="$(cast nonce "$OWNER" --rpc-url "$RPC")"
  EN="$(cast nonce "$EXECUTOR" --rpc-url "$RPC")"
  echo "owner nonce=$ON  executor nonce=$EN"

  SETTLE_SIG='settle((address,uint256)[],address[])'
  PAIR_AMOUNT="$(keep_encode "$PAIR_PRE")"
  FEE_AMOUNT="$(keep_encode "$FEE_PRE")"
  SETTLE_TARGETS="[($CL1,$MAX),($CL2,$MAX),($CL3,$MAX),($CL4,$MAX),($CL5,$MAX),($CL6,$MAX),($CL7,$MAX),($CL8,$MAX),($WDEV,$WDEV_FIXED),($FEECOLLECTOR,$FEE_AMOUNT),($PAIR,$PAIR_AMOUNT)]"
  SETTLE_PAIRS="[$PAIR]"
  echo "PAIR keep-encode KEEP_OFFSET+PAIR_PRE=$PAIR_AMOUNT"
  echo "FEE keep-encode KEEP_OFFSET+FEE_PRE=$FEE_AMOUNT"

  echo "==> signing TX1 TX2 TX3 with cast mktx (not broadcast)"
  TX1=$(cast mktx "$CONFIG" "setMarketFactory(address)" "$SETTLEMENT" \
    --private-key "$OWNER_KEY" --rpc-url "$RPC" --chain 1 \
    --nonce "$ON" --gas-limit "$GAS_SET" \
    --priority-gas-price "$PRIORITY" --gas-price "$MAXFEE")
  TX2=$(cast mktx "$SETTLEMENT" "$SETTLE_SIG" "$SETTLE_TARGETS" "$SETTLE_PAIRS" \
    --private-key "$EXECUTOR_KEY" --rpc-url "$RPC" --chain 1 \
    --nonce "$EN" --gas-limit "$GAS_SETTLE" \
    --priority-gas-price "$PRIORITY" --gas-price "$MAXFEE")
  TX3=$(cast mktx "$CONFIG" "setMarketFactory(address)" "$ORIGF" \
    --private-key "$OWNER_KEY" --rpc-url "$RPC" --chain 1 \
    --nonce "$((ON + 1))" --gas-limit "$GAS_SET" \
    --priority-gas-price "$PRIORITY" --gas-price "$MAXFEE")
  TX1="${TX1//$'\n'/}"
  TX2="${TX2//$'\n'/}"
  TX3="${TX3//$'\n'/}"

  write_state
  rm -f "$STATE_DIR/SIM_OK" "$STATE_DIR/uuid"

  echo "==> eth_callBundle"
  TARGET=$(cast to-hex $(( $(cast block-number --rpc-url "$RPC") + 1 )))
  SIM_PARAMS=$(printf '{"txs":["%s","%s","%s"],"blockNumber":"%s","stateBlockNumber":"latest"}' \
    "$TX1" "$TX2" "$TX3" "$TARGET")
  flashbots_post eth_callBundle "$SIM_PARAMS" | tee "$STATE_DIR/callbundle.json"
  echo
  check_call_bundle "$STATE_DIR/callbundle.json"
  date -u +%s >"$STATE_DIR/SIM_OK"
  echo "simulate OK. signed txs in $STATE_DIR"
  echo "Do not cast publish. Freeze owner and executor until submit lands or you abort."
  echo "Next: ./scripts/path_a_bundle.sh submit"
}

load_signed() {
  test -f "$STATE_DIR/SIM_OK" || {
    echo "ABORT: no successful simulate ($STATE_DIR/SIM_OK missing). Run: $0 simulate" >&2
    exit 1
  }
  test -f "$STATE_DIR/meta.env" || { echo "ABORT: missing $STATE_DIR/meta.env" >&2; exit 1; }
  # shellcheck disable=SC1091
  source "$STATE_DIR/meta.env"
  TX1="$(cat "$STATE_DIR/tx1.raw")"
  TX2="$(cat "$STATE_DIR/tx2.raw")"
  TX3="$(cat "$STATE_DIR/tx3.raw")"
  test -n "$TX1" && test -n "$TX2" && test -n "$TX3" || {
    echo "ABORT: empty signed txs" >&2
    exit 1
  }
  test -n "${SUPPLY_BEFORE:-}" || {
    echo "ABORT: meta.env missing SUPPLY_BEFORE. Re-run simulate." >&2
    exit 1
  }
  TX2_HASH="$(cast keccak "$TX2")"
}

cmd_submit() {
  need cast
  need python3
  need curl
  require_env
  AUTH_ADDR="$(cast wallet address --private-key "$AUTH_KEY")"
  local want_settlement="$SETTLEMENT"
  load_signed
  addr_eq "$want_settlement" "$SETTLEMENT" || {
    echo "ABORT: SETTLEMENT env $want_settlement != signed $SETTLEMENT. Re-run simulate." >&2
    exit 1
  }
  precheck

  local now_on now_en
  now_on="$(cast nonce "$OWNER" --rpc-url "$RPC")"
  now_en="$(cast nonce "$EXECUTOR" --rpc-url "$RPC")"
  [[ "$now_on" == "$ON" && "$now_en" == "$EN" ]] || {
    echo "ABORT: nonce moved (owner $now_on vs signed $ON, executor $now_en vs signed $EN). Re-run simulate." >&2
    exit 1
  }
  if ! assert_keep_floors; then
    echo "ABORT: pair/FeeCollector/WDEV floor failed. Re-run simulate." >&2
    exit 1
  fi

  # Flashbots requires a UUIDv4 string (rejects keccak hex with -32000 invalid replacement uuid).
  UUID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
  printf '%s' "$UUID" >"$STATE_DIR/uuid"
  echo "==> eth_sendBundle replacementUuid=$UUID"
  echo "TX2 hash $TX2_HASH"

  local i BN TARGET PARAMS landed=0 chain
  for i in 1 2 3 4 5 6 7 8; do
    # Check landed FIRST: once the bundle lands, pair/FeeCollector sit at the pre-attack
    # remainder, so assert_keep_floors' "positive exploit-derived increment" check would
    # misread success as a broken floor and cancel/abort a landed bundle.
    if bundle_landed; then
      echo "bundle landed (TX2 receipt ok, factory ORIGF, owner nonce >= ON+2, executor nonce >= EN+1, supply down)"
      landed=1
      break
    fi
    chain="$(cast chain-id --rpc-url "$RPC")"
    if [[ "$chain" != "1" ]]; then
      echo "ABORT: chain-id=$chain (want 1) during submit loop." >&2
      cancel_inflight
      exit 1
    fi
    if ! assert_keep_floors; then
      echo "ABORT: pair/FeeCollector/WDEV floor failed during submit loop." >&2
      cancel_inflight
      exit 1
    fi
    BN="$(cast block-number --rpc-url "$RPC")"
    TARGET="$(cast to-hex $((BN + 1)))"
    PARAMS=$(printf '{"txs":["%s","%s","%s"],"blockNumber":"%s","replacementUuid":"%s","builders":%s}' \
      "$TX1" "$TX2" "$TX3" "$TARGET" "$UUID" \
      '["flashbots","beaverbuild.org","Titan","rsync","builder0x69"]')
    echo "submit target block $((BN + 1)) (try $i/8)"
    flashbots_post eth_sendBundle "$PARAMS" || true
    echo
    while [[ "$(cast block-number --rpc-url "$RPC")" -le "$BN" ]]; do sleep 2; done
    if bundle_landed; then
      echo "bundle landed (TX2 receipt ok, factory ORIGF, owner nonce >= ON+2, executor nonce >= EN+1, supply down)"
      landed=1
      break
    fi
    now_on="$(cast nonce "$OWNER" --rpc-url "$RPC")"
    now_en="$(cast nonce "$EXECUTOR" --rpc-url "$RPC")"
    echo "not landed yet (factory=$(cast_addr "$CONFIG" "marketFactory()(address)") ownerNonce=$now_on execNonce=$now_en)"
  done

  if [[ "$landed" -ne 1 ]]; then
    echo "ABORT: not included after 8 blocks. Run: $0 cancel   then re-simulate with higher PRIORITY/MAXFEE, or fall back to RUNBOOK §4 (cancel first)." >&2
    exit 1
  fi
  echo "Next: ./scripts/path_a_bundle.sh verify"
}

cmd_cancel() {
  require_env
  need curl
  need cast
  AUTH_ADDR="$(cast wallet address --private-key "$AUTH_KEY")"
  test -f "$STATE_DIR/uuid" || { echo "ABORT: no $STATE_DIR/uuid (submit never started?)" >&2; exit 1; }
  UUID="$(cat "$STATE_DIR/uuid")"
  echo "==> eth_cancelBundle $UUID"
  flashbots_post eth_cancelBundle "$(printf '{"replacementUuid":"%s"}' "$UUID")"
  echo
}

cmd_verify() {
  need cast
  echo "==> post-execution checks"
  echo "totalSupply $(cast_u256 "$DEV" "totalSupply()(uint256)")"
  echo "PAIR $(cast_u256 "$DEV" "balanceOf(address)(uint256)" "$PAIR")  (want $PAIR_PRE)"
  echo "PAIR getReserves $(cast call "$PAIR" "getReserves()(uint112,uint112,uint32)" --rpc-url "$RPC")"
  local a
  for a in "$CL1" "$CL2" "$CL3" "$CL4" "$CL5" "$CL6" "$CL7" "$CL8"; do
    echo "$a $(cast_u256 "$DEV" "balanceOf(address)(uint256)" "$a")  (want 0)"
  done
  echo "FEECOLLECTOR $(cast_u256 "$DEV" "balanceOf(address)(uint256)" "$FEECOLLECTOR")  (want $FEE_PRE)"
  echo "WDEV backing $(cast_u256 "$DEV" "balanceOf(address)(uint256)" "$WDEV")"
  echo "WDEV totalSupply $(cast_u256 "$WDEV" "totalSupply()(uint256)")"
  echo "marketFactory $(cast_addr "$CONFIG" "marketFactory()(address)")  (want $ORIGF)"
  if [[ -n "${SETTLEMENT:-}" ]]; then
    echo "isGroup(Settlement) $(cast call "$MG" "isGroup(address)(bool)" "$SETTLEMENT" --rpc-url "$RPC")  (want false)"
  fi
  echo "marketGroup getCount $(cast_u256 "$MG" "getCount()(uint256)")"
}

usage() {
  sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

cmd="${1:-}"
case "$cmd" in
  snapshot) snapshot ;;
  simulate) cmd_simulate ;;
  submit) cmd_submit ;;
  verify) cmd_verify ;;
  cancel) cmd_cancel ;;
  *) usage ;;
esac
