#!/usr/bin/env bash
set -euo pipefail

UNPATCHED_BIN="${1:-/Volumes/WorkSSD/src/llama.cpp/build/bin/llama-server}"
PATCHED_BIN="${2:-/Volumes/WorkSSD/src/llama.cpp-atomic/build-shared-cache/bin/llama-server}"
MODEL_PATH="${3:-/Volumes/WorkSSD/ai-models/llama.cpp/models/granite-4.1-3b-GGUF/granite-4.1-3b-Q6_K.gguf}"

PORT=18888
PORT_STEP=1
N_PROMPTS=24
WARMUP_PROMPTS=(
  '{"model":"local","messages":[{"role":"user","content":"Say the sequence: A B C D E F G A B C D E F G"}],"max_tokens":64}'
  '{"model":"local","messages":[{"role":"user","content":"Say the sequence: 1 2 3 4 5 6 7 8 9 10"}],"max_tokens":64}'
)
PROMPT_TEMPLATE='{"model":"local","messages":[{"role":"user","content":"Now repeat exactly what you wrote in the same sequence pattern from the sequence: A B C D E F G; keep going until 20 tokens."}],"max_tokens":64}'

log() {
  echo "[mtp-lcd-roundtrip] $*" >&2
}

run_server_once() {
  local binary="$1"
  local log_file="$2"
  local cache_file="$3"
  local pid_file="$4"
  local port="$5"

  > "$cache_file"
  > "${cache_file}0"
  > "${cache_file}1"

  "$binary" \
    --model "$MODEL_PATH" \
    --spec-type ngram-cache \
    --lookup-cache-dynamic "$cache_file" \
    -np 2 \
    --ctx-size 2048 \
    --port "$port" \
    --log-verbose \
    >"$log_file" 2>&1 &
  local pid=$!
  echo "$pid" > "$pid_file"

  for _ in $(seq 1 180); do
    if curl -fsS "http://127.0.0.1:${port}/health" >/dev/null; then
      return 0
    fi
    sleep 1
  done

  return 1
}

send_with_retry() {
  local url="$1"
  local body="$2"

  for _ in $(seq 1 30); do
    if curl -fsS -X POST "$url" \
      -H 'Content-Type: application/json' \
      -d "$body" >/dev/null; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

send_prompts() {
  local port="$1"
  local warmup_requests="$2"
  local i
  local pids=()
  local max_parallel=2

  for i in $(seq 1 "$warmup_requests"); do
    local body="${WARMUP_PROMPTS[$(( (i - 1) % ${#WARMUP_PROMPTS[@]} ))]}"
    send_with_retry "http://127.0.0.1:${port}/v1/chat/completions" "$body" &
    pids+=("$!")
    if (( ${#pids[@]} >= max_parallel )); then
      wait "${pids[0]}"
      pids=("${pids[@]:1}")
    fi
  done

  local main_requests=$((N_PROMPTS - warmup_requests))
  if (( main_requests < 0 )); then
    main_requests=0
  fi

  for i in $(seq 1 "$main_requests"); do
    send_with_retry "http://127.0.0.1:${port}/v1/chat/completions" "$PROMPT_TEMPLATE" &
    pids+=("$!")
    if (( ${#pids[@]} >= max_parallel )); then
      wait "${pids[0]}"
      pids=("${pids[@]:1}")
    fi
  done

  if (( ${#pids[@]} > 0 )); then
    wait "${pids[@]}"
  fi
}

parse_slot_hit_count() {
  local log_file="$1"
  local slot="$2"
  local line

  line="$(awk "/slot ${slot} speculative counters:/ {line=\$0} END {print line}" "$log_file" || true)"
  if [ -z "$line" ]; then
    echo "missing"
    return 0
  fi

  echo "$line" | sed -nE 's/.*n_lookup_dynamic_hits=([0-9]+).*/\1/p'
}

run_case() {
  local binary="$1"
  local label="$2"
  local port="$3"
  local warmup="$4"
  local log_file
  local cache_file
  local pid_file
  local pid

  log_file="/tmp/mtp-lcd-roundtrip-${label}.log"
  cache_file="$(mktemp /tmp/mtp-lcd-roundtrip-cache-XXXXXX.bin)"
  pid_file="$(mktemp)"
  slot0_hits="missing"
  slot1_hits="missing"

  log "starting ${label} server (${binary}) on port ${port}"
  run_server_once "$binary" "$log_file" "$cache_file" "$pid_file" "$port" || {
    echo "${label} server failed to become healthy; log: ${log_file}" >&2
    echo "----- ${label} server log -----" >&2
    cat "$log_file" >&2
    rm -f "$pid_file" "$cache_file" "${cache_file}0" "${cache_file}1"
    exit 1
  }
  pid="$(cat "$pid_file")"

  if ! kill -0 "$pid" >/dev/null 2>&1; then
    echo "${label} server process exited early; log: ${log_file}" >&2
    echo "----- ${label} server log -----" >&2
    cat "$log_file" >&2
    rm -f "$pid_file" "$cache_file" "${cache_file}0" "${cache_file}1"
    exit 1
  fi

  send_prompts "$port" "$warmup"

  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" >/dev/null 2>&1 || true

  slot0_hits="$(parse_slot_hit_count "$log_file" 0)"
  slot1_hits="$(parse_slot_hit_count "$log_file" 1)"

  rm -f "$pid_file" "$cache_file" "${cache_file}0" "${cache_file}1"

  echo "$slot0_hits $slot1_hits"
}

BASELINE_PORT="$PORT"
PATCHED_PORT=$((PORT + PORT_STEP))

BASELINE_HITS="$(run_case "$UNPATCHED_BIN" "unpatched" "$BASELINE_PORT" 24)"
log "baseline counter values: ${BASELINE_HITS}"

if [ "$BASELINE_HITS" != "missing missing" ] \
    && [ "$BASELINE_HITS" != "0 0" ] \
    && [ "$BASELINE_HITS" != "0 missing" ] \
    && [ "$BASELINE_HITS" != "missing 0" ]; then
  echo "unpatched baseline unexpectedly reported shared dynamic hits: ${BASELINE_HITS}" >&2
  exit 1
fi

PATCHED_HITS="$(run_case "$PATCHED_BIN" "patched" "$PATCHED_PORT" 16)"
log "patched counter values: ${PATCHED_HITS}"

set -- $PATCHED_HITS
PATCHED_SLOT0="$1"
PATCHED_SLOT1="$2"

if [ "$PATCHED_SLOT1" = "missing" ]; then
  echo "patched run did not emit slot 1 speculative counters" >&2
  exit 1
fi

if [ "$PATCHED_SLOT1" = "" ] || [ "$PATCHED_SLOT1" -le 0 ]; then
  echo "patched slot 1 shared-dynamic hits is not greater than 0: ${PATCHED_SLOT1}" >&2
  exit 1
fi

log "round-trip check passed: slot0=${PATCHED_SLOT0} slot1=${PATCHED_SLOT1}"
