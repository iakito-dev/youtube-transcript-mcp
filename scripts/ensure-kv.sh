#!/usr/bin/env bash
#
# Makes sure the TRANSCRIPT_CACHE KV namespace exists and writes its id into
# wrangler.toml, so a fresh clone can deploy without anyone editing the file
# by hand. Idempotent: reuses the namespace when it is already there.

set -uo pipefail

BINDING="TRANSCRIPT_CACHE"
CONFIG="wrangler.toml"
TITLE="$(awk -F'"' '/^name *=/ {print $2; exit}' "$CONFIG")-${BINDING}"

# wrangler prints a version banner before the payload, so drop everything
# ahead of the first JSON bracket before handing it to jq.
json_only() {
  sed -n '/[[{]/,$p'
}

id_for_title() {
  local raw
  raw="$(npx wrangler kv namespace list 2>/dev/null | json_only)"
  jq -r --arg t "$TITLE" '.[]? | select(.title == $t) | .id' <<<"$raw" 2>/dev/null | head -n1
}

id="$(id_for_title)"

if [[ -z "$id" ]]; then
  echo "creating KV namespace: $TITLE"
  create_out="$(npx wrangler kv namespace create "$BINDING" 2>&1)"
  echo "$create_out"

  # wrangler prints the new binding as JSON; take the id straight from it and
  # fall back to a fresh listing if the output format differs.
  id="$(json_only <<<"$create_out" | jq -r '.id? // empty' 2>/dev/null | head -n1)"
  [[ -z "$id" ]] && id="$(grep -oE '[0-9a-f]{32}' <<<"$create_out" | head -n1)"
  [[ -z "$id" ]] && id="$(id_for_title)"
fi

if [[ -z "$id" ]]; then
  echo "could not resolve a KV namespace id for $TITLE" >&2
  echo "--- wrangler kv namespace list ---" >&2
  npx wrangler kv namespace list >&2 2>&1 || true
  echo "--- wrangler whoami ---" >&2
  npx wrangler whoami >&2 2>&1 || true
  exit 1
fi

echo "using KV namespace $TITLE ($id)"

# Replace the id on the line following the TRANSCRIPT_CACHE binding.
python3 - "$CONFIG" "$BINDING" "$id" <<'PY'
import re, sys

path, binding, kv_id = sys.argv[1], sys.argv[2], sys.argv[3]
config = open(path).read()

pattern = re.compile(
    r'(binding\s*=\s*"%s"\s*\n\s*id\s*=\s*")[^"]*(")' % re.escape(binding)
)
config, count = pattern.subn(r'\g<1>%s\g<2>' % kv_id, config)

if count != 1:
    sys.exit("expected exactly one %s id in %s, patched %d" % (binding, path, count))

open(path, 'w').write(config)
PY

grep -A2 "$BINDING" "$CONFIG"
