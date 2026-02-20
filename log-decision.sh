#!/bin/bash
# Sovereign Identity Decision Ledger — log-decision.sh
# Publishes an immutable kind:2100 decision record to Nostr and saves locally.
#
# Usage:
#   bash scripts/sovereign-identity/log-decision.sh \
#     --title "Decision title" \
#     --category infrastructure \
#     --reasoning "Why this decision was made" \
#     --expected "What I predict will happen" \
#     --review-date 2026-03-20 \
#     [--alternatives "Option A|Why not::Option B|Why not"] \
#     [--dry-run]
#
# Requires: nak, op (1Password CLI), jq, git

set -euo pipefail

WORKSPACE="/Users/seneschal/.openclaw/workspace"
DECISIONS_DIR="$WORKSPACE/data/sovereign-identity/decisions"
RECEIPTS_DIR="$WORKSPACE/data/sovereign-identity/receipts"
SCHEMA_VERSION="1"
OPS_KEY_ITEM="Sene - Nostr Ops Key (Decision Ledger)"
VAULT="kdki6sqauhfnymwkixnrizox4e"
RELAYS="wss://relay.damus.io wss://nos.lol wss://premium.primal.net"
OPS_PUBKEY="51b6f43b60197d5a1c400d2acfe24fc7c1dd0eae8b2509919adbc319659a77ed"

mkdir -p "$DECISIONS_DIR" "$RECEIPTS_DIR"

# Parse args
TITLE="" CATEGORY="" REASONING="" EXPECTED="" REVIEW_DATE="" ALTERNATIVES="" DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --title) TITLE="$2"; shift 2 ;;
    --category) CATEGORY="$2"; shift 2 ;;
    --reasoning) REASONING="$2"; shift 2 ;;
    --expected) EXPECTED="$2"; shift 2 ;;
    --review-date) REVIEW_DATE="$2"; shift 2 ;;
    --alternatives) ALTERNATIVES="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Validate required args
for field in TITLE CATEGORY REASONING EXPECTED REVIEW_DATE; do
  if [ -z "${!field}" ]; then
    echo "ERROR: --$(echo $field | tr '[:upper:]' '[:lower:]' | tr '_' '-') is required" >&2
    exit 1
  fi
done

# Generate decision ID
DATE=$(date +%Y-%m-%d)
SLUG=$(echo "$TITLE" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-' | head -c 40)
# Count existing decisions for today to get sequence number
SEQ=$(find "$DECISIONS_DIR" -name "${DATE}-*.json" 2>/dev/null | wc -l | tr -d ' ')
SEQ=$((SEQ + 1))
DECISION_ID="dec-${DATE}-$(printf '%03d' $SEQ)"

# Find previous event ID (last decision in chain)
PREV_EVENT_ID="null"
LATEST_FILE=$(find "$DECISIONS_DIR" -name "*.json" -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1 || true)
if [ -n "$LATEST_FILE" ]; then
  PREV_EVENT_ID=$(jq -r '.nostr_event_id // "null"' "$LATEST_FILE")
fi

# Get git commit
GIT_COMMIT=$(cd "$WORKSPACE" && git rev-parse HEAD)

# Build alternatives JSON array
ALTS_JSON="[]"
if [ -n "$ALTERNATIVES" ]; then
  ALTS_JSON=$(echo "$ALTERNATIVES" | sed 's/::/\n/g' | while IFS='|' read -r opt why; do
    [ -n "$opt" ] && jq -n --arg o "$opt" --arg w "${why:-}" '{"option": $o, "why_not": $w}'
  done | jq -s '.' 2>/dev/null || echo "[]")
fi

# Build decision JSON (without canonical_sha256 — added after)
DECISION_JSON=$(jq -n \
  --arg version "$SCHEMA_VERSION" \
  --arg id "$DECISION_ID" \
  --arg type "decision" \
  --arg category "$CATEGORY" \
  --arg title "$TITLE" \
  --arg date "$DATE" \
  --arg reasoning "$REASONING" \
  --argjson alternatives "$ALTS_JSON" \
  --arg expected "$EXPECTED" \
  --arg review_date "$REVIEW_DATE" \
  --arg git_commit "$GIT_COMMIT" \
  --arg prev_event_id "$PREV_EVENT_ID" \
  --arg signing_key "operational" \
  '{
    version: $version,
    id: $id,
    type: $type,
    category: $category,
    title: $title,
    date: $date,
    reasoning: $reasoning,
    alternatives_rejected: $alternatives,
    expected_outcome: $expected,
    outcome_review_date: $review_date,
    canonical_sha256: null,
    git_commit: $git_commit,
    prev_event_id: $prev_event_id,
    signing_key: $signing_key
  }')

# Compute canonical SHA-256 (of JSON without the sha256 field populated)
CANONICAL_HASH=$(echo "$DECISION_JSON" | jq -cS 'del(.canonical_sha256)' | shasum -a 256 | awk '{print $1}')

# Insert hash
DECISION_JSON=$(echo "$DECISION_JSON" | jq --arg hash "$CANONICAL_HASH" '.canonical_sha256 = $hash')

# Content string for Nostr event
CONTENT=$(echo "$DECISION_JSON" | jq -c '.')

if [ "$DRY_RUN" -eq 1 ]; then
  echo "=== DRY RUN ==="
  echo "Decision ID: $DECISION_ID"
  echo "File: $DECISIONS_DIR/${DATE}-${SLUG}.json"
  echo "$DECISION_JSON" | jq .
  echo "Prev event: $PREV_EVENT_ID"
  exit 0
fi

# Get ops key
OPS_NSEC=$(op item get "$OPS_KEY_ITEM" --vault "$VAULT" --field nsec --reveal)

# Build nak tags
PREV_TAG=""
if [ "$PREV_EVENT_ID" != "null" ]; then
  PREV_TAG="-t e=${PREV_EVENT_ID};wss://relay.damus.io;prev"
fi

# Publish to Nostr
echo "Publishing decision: $DECISION_ID" >&2
RESULT=$(nak event --sec "$OPS_NSEC" -k 2100 \
  -t t=senedecisions \
  -t t="$CATEGORY" \
  -t t=sovereign-identity \
  -t d="$DECISION_ID" \
  -t review-date="$REVIEW_DATE" \
  $PREV_TAG \
  -c "$CONTENT" \
  $RELAYS 2>&1)

echo "$RESULT" >&2

# Extract event ID from nak output
EVENT_ID=$(echo "$RESULT" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

if [ -z "$EVENT_ID" ]; then
  echo "ERROR: Failed to extract event ID from nak output" >&2
  exit 1
fi

# Update JSON with event ID
DECISION_JSON=$(echo "$DECISION_JSON" | jq --arg eid "$EVENT_ID" '. + {nostr_event_id: $eid}')

# Save local file
LOCAL_FILE="$DECISIONS_DIR/${DATE}-${SLUG}.json"
echo "$DECISION_JSON" | jq . > "$LOCAL_FILE"
echo "Saved: $LOCAL_FILE" >&2

# Save publish receipt
RECEIPT_FILE="$RECEIPTS_DIR/${DECISION_ID}.json"
jq -n \
  --arg id "$DECISION_ID" \
  --arg event_id "$EVENT_ID" \
  --arg published_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg relay1 "relay.damus.io" \
  --arg relay2 "nos.lol" \
  --arg relay3 "premium.primal.net" \
  '{
    decision_id: $id,
    event_id: $event_id,
    published_at: $published_at,
    relays: {
      ($relay1): "published",
      ($relay2): "published",
      ($relay3): "published"
    }
  }' > "$RECEIPT_FILE"
echo "Receipt: $RECEIPT_FILE" >&2

# Git commit
cd "$WORKSPACE"
git add "$LOCAL_FILE" "$RECEIPT_FILE"
git commit -m "decision: $TITLE" >/dev/null 2>&1 || true

echo "$EVENT_ID"
