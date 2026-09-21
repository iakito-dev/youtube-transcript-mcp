#!/usr/bin/env bash
#
# Makes sure the TRANSCRIPT_CACHE KV namespace exists and writes its id into
# wrangler.toml, so a fresh clone can deploy without anyone editing the file
# by hand. Idempotent: reuses the namespace when it is already there.

set -euo pipefail

BINDING="TRANSCRIPT_CACHE"
CONFIG="wrangler.toml"
TITLE="$(awk -F'"' '/^name *=/ {print $2; exit}' "$CONFIG")-${BINDING}"

id_for_title() {
  npx wrangler kv namespace list 2>/dev/null \
    | jq -r --arg t "$TITLE" '.[] | select(.title == $t) | .id' \
    | head -n1
}

id="$(id_for_title)"

if [[ -z "$id" ]]; then
  echo "creating KV namespace: $TITLE"
  npx wrangler kv namespace create "$BINDING" >/dev/null
  id="$(id_for_title)"
fi

if [[ -z "$id" ]]; then
  echo "could not resolve a KV namespace id for $TITLE" >&2
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
