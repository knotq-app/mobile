#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run-mobile-ws-integration.sh — mobile-core sync over a real Worker socket.
#
# Starts a test-mode KnotQ Worker in an isolated local Wrangler state, runs the
# mobile core's production WebSocket integration test against it, then tears
# the Worker down. The script lives with mobile because mobile CI checks out
# the desktop/shared and backend repositories as siblings.
#
# Run from the mobile checkout. Requires ../backend/cloudflare with pnpm
# dependencies installed, plus cargo, pnpm, wrangler, and curl on PATH.
# ---------------------------------------------------------------------------
set -euo pipefail

MOBILE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_ROOT="${KNOTQ_APP_DIR:-$(cd "${MOBILE_ROOT}/.." && pwd)}"
BACKEND_DIR="${KNOTQ_BACKEND_DIR:-${APP_ROOT}/backend/cloudflare}"
PORT="${KNOTQ_MOBILE_STRESS_PORT:-8789}"
BACKEND_URL="http://127.0.0.1:${PORT}"
PERSIST="${KNOTQ_MOBILE_STRESS_PERSIST:-${APP_ROOT}/.wrangler/mobile-integration-test-state}"

if [ ! -d "${BACKEND_DIR}" ]; then
  echo "run-mobile-ws-integration: ${BACKEND_DIR} not found" >&2
  exit 1
fi

# Build before starting workerd: the linker can briefly consume several GB on
# a small CI runner, which otherwise makes an idle Worker look flaky.
echo "run-mobile-ws-integration: pre-building mobile test binary…"
cargo test --manifest-path "${MOBILE_ROOT}/Cargo.toml" \
  -p knotq-mobile-core --features accounts --release --lib --no-run

WRANGLER_PID=""
cleanup() {
  if [ -n "${WRANGLER_PID}" ]; then
    kill "${WRANGLER_PID}" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
      kill -0 "${WRANGLER_PID}" 2>/dev/null || break
      sleep 1
    done
    kill -9 "${WRANGLER_PID}" 2>/dev/null || true
  fi
  return 0
}
trap cleanup EXIT INT TERM

echo "run-mobile-ws-integration: applying D1 migrations…"
( cd "${BACKEND_DIR}" && CI=1 pnpm wrangler d1 migrations apply knotq-auth \
    --local --persist-to "${PERSIST}" )

echo "run-mobile-ws-integration: starting wrangler dev on :${PORT}…"
if [ -f "${BACKEND_DIR}/.dev.vars" ]; then
  ( cd "${BACKEND_DIR}" && pnpm wrangler dev --local --port "${PORT}" \
      --var KNOTQ_TEST_MODE:1 --persist-to "${PERSIST}" --log-level warn ) &
else
  # Pass throwaway test values as CLI vars instead of creating or overwriting
  # a local secrets file.
  ( cd "${BACKEND_DIR}" && pnpm wrangler dev --local --port "${PORT}" \
      --var KNOTQ_TEST_MODE:1 \
      --var PASETO_LOCAL_KEY:k4.local.Cu1j1l3ySqVlVF5_DPNsB71Ra_sKFH9RSVMw9GQ2VaM \
      --var EXPOSE_EMAIL_TOKENS:1 --var ALLOWED_ORIGINS:* \
      --persist-to "${PERSIST}" --log-level warn ) &
fi
WRANGLER_PID=$!

ready=0
for attempt in $(seq 1 60); do
  if curl -sf "${BACKEND_URL}/readyz" >/dev/null 2>&1; then
    echo "run-mobile-ws-integration: backend ready after ${attempt} attempts."
    ready=1
    break
  fi
  kill -0 "${WRANGLER_PID}" 2>/dev/null || {
    echo "run-mobile-ws-integration: wrangler exited early" >&2
    exit 1
  }
  sleep 0.5
done
if [ "${ready}" -ne 1 ]; then
  echo "run-mobile-ws-integration: backend never became ready" >&2
  exit 1
fi

# Prove test mode and the migrated D1 schema are usable before two background
# WebSocket clients start. Otherwise a bad local persist path becomes opaque
# bootstrap failures in the Rust test.
probe_email="mobile-ws-probe-$(date +%s)@example.com"
probe_status="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  -H 'content-type: application/json' \
  -d "{\"email\":\"${probe_email}\"}" \
  "${BACKEND_URL}/__test/bootstrap")"
if [ "${probe_status}" != "200" ]; then
  echo "run-mobile-ws-integration: bootstrap probe returned ${probe_status}" >&2
  exit 1
fi

echo "run-mobile-ws-integration: running mobile real-WebSocket convergence test…"
KNOTQ_SYNC_BACKEND_URL="${BACKEND_URL}" \
  cargo test --manifest-path "${MOBILE_ROOT}/Cargo.toml" \
    -p knotq-mobile-core --features accounts --release --lib -- --nocapture \
    mobile_two_device_convergence_over_real_websocket

echo "run-mobile-ws-integration: PASSED."
