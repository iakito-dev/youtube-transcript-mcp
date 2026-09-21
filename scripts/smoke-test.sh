#!/usr/bin/env bash
#
# Verifies a deployed instance end to end.
#
#   ./scripts/smoke-test.sh https://youtube-transcript-mcp.<subdomain>.workers.dev
#
# Checks the MCP handshake first, then a real transcript fetch — the handshake
# passing while the fetch fails is the signature of YouTube blocking the
# Workers IP, which is the one failure mode that only shows up in production.

set -uo pipefail

BASE="${1:-}"
if [[ -z "$BASE" ]]; then
  echo "usage: $0 <worker-url>" >&2
  exit 2
fi
BASE="${BASE%/}"

VIDEO="${2:-https://www.youtube.com/watch?v=jNQXAC9IVRw}" # "Me at the zoo", captioned
failures=0

rpc() {
  curl -sS --max-time 90 -X POST "$BASE/mcp" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d "$1"
}

check() {
  local label="$1" got="$2" want="$3"
  if [[ "$got" == *"$want"* ]]; then
    echo "  ok    $label"
  else
    echo "  FAIL  $label"
    echo "        expected to contain: $want"
    echo "        got: ${got:0:300}"
    failures=$((failures + 1))
  fi
}

echo "target: $BASE"
echo
echo "MCP handshake"

check "initialize" \
  "$(rpc '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}')" \
  '"protocolVersion":"2025-06-18"'

# A notification must be acknowledged with 202 and no body.
status=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 -X POST "$BASE/mcp" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}')
check "notifications/initialized returns 202" "$status" "202"

check "tools/list advertises get_transcript" \
  "$(rpc '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')" \
  '"name":"get_transcript"'

echo
echo "transcript fetch"

result=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"get_transcript\",\"arguments\":{\"url\":\"$VIDEO\"}}}")

if [[ "$result" == *'"isError":true'* ]]; then
  echo "  FAIL  get_transcript returned an error"
  echo "        $(echo "$result" | head -c 400)"
  echo
  echo "  The handshake works, so the server is deployed correctly."
  echo "  A failure here usually means YouTube is refusing the Workers IP."
  failures=$((failures + 1))
elif [[ "$result" == *'"text"'* ]]; then
  echo "  ok    get_transcript returned a transcript"
  echo "        $(echo "$result" | head -c 200)..."
else
  echo "  FAIL  unexpected response"
  echo "        $(echo "$result" | head -c 400)"
  failures=$((failures + 1))
fi

echo
if [[ $failures -eq 0 ]]; then
  echo "all checks passed"
else
  echo "$failures check(s) failed"
fi
exit $((failures > 0))
