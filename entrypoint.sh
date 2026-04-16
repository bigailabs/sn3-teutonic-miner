#!/usr/bin/env bash
# SN3 Teutonic miner entrypoint.
# Validates env + wallet, registers if allowed, then hands off to miner_wrapper.py
# which drives the single-shot miner.py in a poll loop.
set -euo pipefail

LOG_PREFIX="[teutonic-miner]"
log()   { printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${LOG_PREFIX}" "$*"; }
fatal() { log "FATAL: $*"; exit 1; }

TAOSTATS_AUTH="${TAOSTATS_AUTH:-tao-29ffa04c-3dc6-4aab-ac0a-5c660068f5bc:2a802116}"
NETUID="${TEUTONIC_NETUID:-3}"
NETWORK="${TEUTONIC_NETWORK:-finney}"
MAX_REGISTER_TAO="${MAX_REGISTER_TAO:-1.0}"
REGISTER="${REGISTER:-false}"
TEUTONIC_NOISE="${TEUTONIC_NOISE:-0.001}"
TEUTONIC_SUFFIX="${TEUTONIC_SUFFIX:-}"
TEUTONIC_FORCE="${TEUTONIC_FORCE:-true}"
POLL_INTERVAL_SEC="${POLL_INTERVAL_SEC:-60}"
MIN_SUBMIT_GAP_SEC="${MIN_SUBMIT_GAP_SEC:-600}"

log "starting SN3 Teutonic miner"
log "teutonic commit pinned: $(cat /opt/teutonic/.pinned-sha 2>/dev/null || echo unknown)"

# 1. Validate required env vars
missing=()
for v in HF_TOKEN HF_USER BT_WALLET_NAME BT_WALLET_HOTKEY; do
    if [ -z "${!v:-}" ]; then missing+=("$v"); fi
done
if [ ${#missing[@]} -gt 0 ]; then
    fatal "missing required env vars: ${missing[*]}"
fi
log "env validated | wallet=${BT_WALLET_NAME} hotkey=${BT_WALLET_HOTKEY} hf_user=${HF_USER}"

# 2. Validate wallet files at /wallet
WALLET_SRC="/wallet"
HOTKEY_FILE=""
COLDKEY_FILE=""
COLDKEYPUB_FILE=""

if [ -d "${WALLET_SRC}/hotkeys" ] && [ -f "${WALLET_SRC}/hotkeys/${BT_WALLET_HOTKEY}" ]; then
    HOTKEY_FILE="${WALLET_SRC}/hotkeys/${BT_WALLET_HOTKEY}"
elif [ -f "${WALLET_SRC}/${BT_WALLET_HOTKEY}" ]; then
    # hotkey-only mount style: /wallet/<hotkey-name>
    HOTKEY_FILE="${WALLET_SRC}/${BT_WALLET_HOTKEY}"
else
    fatal "hotkey file not found. Looked at ${WALLET_SRC}/hotkeys/${BT_WALLET_HOTKEY} and ${WALLET_SRC}/${BT_WALLET_HOTKEY}"
fi

[ -f "${WALLET_SRC}/coldkey" ]        && COLDKEY_FILE="${WALLET_SRC}/coldkey"
[ -f "${WALLET_SRC}/coldkeypub.txt" ] && COLDKEYPUB_FILE="${WALLET_SRC}/coldkeypub.txt"

if [ -z "${COLDKEY_FILE}" ] && [ -z "${COLDKEYPUB_FILE}" ]; then
    fatal "neither coldkey nor coldkeypub.txt found under ${WALLET_SRC} — mount at least coldkeypub.txt"
fi

log "wallet files ok | hotkey=${HOTKEY_FILE} coldkey=${COLDKEY_FILE:-<absent>} coldkeypub=${COLDKEYPUB_FILE:-<absent>}"

# 3. Stage wallet at ~/.bittensor/wallets/$BT_WALLET_NAME
BT_DIR="${HOME}/.bittensor/wallets/${BT_WALLET_NAME}"
mkdir -p "${BT_DIR}/hotkeys"
cp -f "${HOTKEY_FILE}" "${BT_DIR}/hotkeys/${BT_WALLET_HOTKEY}"
chmod 600 "${BT_DIR}/hotkeys/${BT_WALLET_HOTKEY}"
[ -n "${COLDKEY_FILE}" ]    && { cp -f "${COLDKEY_FILE}"    "${BT_DIR}/coldkey";        chmod 600 "${BT_DIR}/coldkey"; }
[ -n "${COLDKEYPUB_FILE}" ] && { cp -f "${COLDKEYPUB_FILE}" "${BT_DIR}/coldkeypub.txt"; chmod 644 "${BT_DIR}/coldkeypub.txt"; }
log "wallet staged at ${BT_DIR}"

# 4. Extract hotkey ss58 for registration check
HOTKEY_SS58="$(python3 -c "
import json,sys
with open('${BT_DIR}/hotkeys/${BT_WALLET_HOTKEY}') as f:
    d = json.load(f)
print(d.get('ss58Address') or d.get('ss58_address') or '')
")"
[ -n "${HOTKEY_SS58}" ] || fatal "could not extract ss58 from hotkey file"
log "hotkey ss58: ${HOTKEY_SS58}"

# 5. Check registration via metagraph (source of truth, taostats lags)
check_registration() {
    python3 - <<PYEOF
import sys
try:
    import bittensor as bt
    sub = bt.subtensor(network="${NETWORK}")
    meta = sub.metagraph(${NETUID})
    if "${HOTKEY_SS58}" in meta.hotkeys:
        uid = meta.hotkeys.index("${HOTKEY_SS58}")
        print(f"REGISTERED uid={uid}")
        sys.exit(0)
    sys.exit(2)
except SystemExit:
    raise
except Exception as e:
    print(f"ERROR {e}", file=sys.stderr)
    sys.exit(3)
PYEOF
}

REG_OUT=""
if REG_OUT="$(check_registration)"; then
    log "registration check ok — ${REG_OUT}"
else
    rc=$?
    if [ $rc -eq 2 ]; then
        log "hotkey NOT registered on netuid ${NETUID}"
        if [ "${REGISTER}" != "true" ]; then
            fatal "REGISTER != true, not auto-registering. Register the hotkey manually with: btcli subnet register --netuid ${NETUID} --wallet.name ${BT_WALLET_NAME} --wallet.hotkey ${BT_WALLET_HOTKEY} --subtensor.network ${NETWORK}"
        fi

        # Pull current reg cost from taostats
        REG_COST_RAO="$(curl -sS -H "Authorization: ${TAOSTATS_AUTH}" \
            "https://api.taostats.io/api/subnet/latest/v1?netuid=${NETUID}" \
            | python3 -c "import json,sys;print(json.load(sys.stdin)['data'][0]['neuron_registration_cost'])")"
        REG_COST_TAO="$(python3 -c "print(${REG_COST_RAO}/1e9)")"
        log "current registration cost: ${REG_COST_TAO} TAO (MAX_REGISTER_TAO=${MAX_REGISTER_TAO})"

        EXCEEDS="$(python3 -c "print(1 if float('${REG_COST_TAO}') > float('${MAX_REGISTER_TAO}') else 0)")"
        if [ "${EXCEEDS}" = "1" ]; then
            fatal "reg cost ${REG_COST_TAO} TAO exceeds MAX_REGISTER_TAO=${MAX_REGISTER_TAO}, refusing to register"
        fi

        [ -f "${BT_DIR}/coldkey" ] || fatal "auto-register requested but coldkey not mounted — mount /wallet with the coldkey to sign the registration tx"

        log "attempting registration..."
        btcli subnet register \
            --netuid "${NETUID}" \
            --wallet.name "${BT_WALLET_NAME}" \
            --wallet.hotkey "${BT_WALLET_HOTKEY}" \
            --subtensor.network "${NETWORK}" \
            --no-prompt \
            || fatal "registration failed"
        log "registration submitted — re-checking metagraph"
        sleep 20
        REG_OUT="$(check_registration)" || fatal "still not registered after attempt: ${REG_OUT}"
        log "registration confirmed — ${REG_OUT}"
    else
        fatal "registration check errored: ${REG_OUT}"
    fi
fi

# 6. Export runtime env
export HF_TOKEN HF_HOME="${HF_HOME:-/opt/hf_cache}"
export TEUTONIC_NETUID="${NETUID}"
export TEUTONIC_NETWORK="${NETWORK}"
export BT_WALLET_NAME
export HOTKEY_SS58

mkdir -p "${HF_HOME}"

# 7. Hand off to wrapper (runs miner.py in a loop, keyed on dashboard king hash)
log "launching miner loop | noise=${TEUTONIC_NOISE} poll=${POLL_INTERVAL_SEC}s min_gap=${MIN_SUBMIT_GAP_SEC}s"
exec python3 /opt/teutonic/miner_wrapper.py \
    --hotkey "${BT_WALLET_HOTKEY}" \
    --noise "${TEUTONIC_NOISE}" \
    ${TEUTONIC_SUFFIX:+--suffix "${TEUTONIC_SUFFIX}"} \
    $([ "${TEUTONIC_FORCE}" = "true" ] && echo "--force") \
    --poll-interval "${POLL_INTERVAL_SEC}" \
    --min-submit-gap "${MIN_SUBMIT_GAP_SEC}"
