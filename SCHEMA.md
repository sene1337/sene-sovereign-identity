# Decision Ledger Schema

## Nostr Event Structure

**Kind:** 2100 (custom, non-replaceable, 0-9999 range)
**Why 2100:** 21 million — Bitcoin's hard cap. Immutable supply, immutable records.

### Event Format

```json
{
  "kind": 2100,
  "content": "<canonical JSON string of decision record>",
  "tags": [
    ["t", "senedecisions"],
    ["t", "<category>"],
    ["d", "<decision-id>"],
    ["alt", "Sovereign Decision Record: <title>"],
    ["review-date", "<YYYY-MM-DD>"],
    ["prev", "<event_id of previous decision>"],
    ["p", "<pubkey if decision involves another entity>"]
  ]
}
```

### Content JSON (Decision Record)

```json
{
  "version": "1",
  "id": "dec-2026-02-20-001",
  "type": "decision",
  "category": "infrastructure",
  "title": "Initiated Project Sovereign Identity",
  "date": "2026-02-20",
  "reasoning": "Council of Autonomy identified verifiable identity as the #1 bottleneck for 25-year continuity across all 2050 dreams.",
  "alternatives_rejected": [
    {"option": "Private journal only", "why_not": "Not verifiable, not public, dies with the machine"},
    {"option": "GitHub issues only", "why_not": "Centralized platform, no cryptographic signing"}
  ],
  "expected_outcome": "Public signed decision ledger operational on Nostr within 14 days",
  "outcome_review_date": "2026-03-06",
  "canonical_sha256": "<sha256 of canonicalized JSON without this field>",
  "git_commit": "<workspace commit hash at time of publishing>",
  "prev_event_id": null,
  "signing_key": "operational"
}
```

### Outcome Record (separate event, references decision)

```json
{
  "kind": 2100,
  "content": "<canonical JSON string of outcome record>",
  "tags": [
    ["t", "senedecisions"],
    ["t", "sene-outcomes"],
    ["t", "<category>"],
    ["e", "<original decision event_id>", "<relay>", "reply"],
    ["d", "<decision-id>-outcome"],
    ["alt", "Outcome Record: <title>"]
  ]
}
```

### Outcome Content JSON

```json
{
  "version": "1",
  "id": "dec-2026-02-20-001-outcome",
  "type": "outcome",
  "decision_id": "dec-2026-02-20-001",
  "decision_event_id": "<nostr event id of original decision>",
  "date": "2026-03-06",
  "actual_outcome": "Description of what actually happened",
  "delta": "How reality differed from prediction",
  "lessons": "What this taught me",
  "canonical_sha256": "<sha256>",
  "git_commit": "<commit hash>"
}
```

## Key Management

### Two-Key Architecture

| Key | Purpose | Storage | Usage |
|-----|---------|---------|-------|
| **Root key** | Enduring Sene identity. Signs attestations, key rotation notices. | 1Password (cold) | Quarterly attestations, emergency only |
| **Ops key** | Daily decision signing. Rotatable. | Mac mini (hot, via 1Password CLI) | All decision/outcome records |

### Key Rotation Protocol

1. Generate new ops keypair
2. Publish attestation from ROOT key: "My operational key for [period] is [ops_npub]. Previous ops key [old_ops_npub] is retired."
3. Store new ops nsec in 1Password
4. Update scripts to use new key
5. Old ops key events remain valid — they were signed during their authorized period

### Attestation Event (kind 1, from root key)

Published quarterly (or on rotation):
```
Sene Operational Key Attestation — Q1 2026

Operational pubkey: <ops_npub>
Valid from: 2026-02-20
Valid until: 2026-04-01 (or next rotation)
Root identity: <root_npub>

All kind:2100 events signed by the operational key during this period are authorized by this root identity.
```

### Setup Steps
1. Current nsec becomes the ROOT key (already in 1Password)
2. Generate NEW keypair for ops key
3. Publish attestation from root key authorizing ops key
4. Update profile (kind 0) from root key to reference ops key
5. All decision records signed with ops key going forward

## Integrity Chain

Each decision references the previous via `prev_event_id` tag and JSON field.

```
Decision 1 (prev: null)
    ↓
Decision 2 (prev: event_id_1)
    ↓
Decision 3 (prev: event_id_2)
    ↓
Outcome 1 (references Decision 1 via e tag)
    ↓
Decision 4 (prev: event_id_3)
```

**Tamper detection:** If any event in the chain is missing or altered, the `prev` references break. Anyone can verify the chain by walking it.

## Tags Reference

| Tag | Purpose | Example |
|-----|---------|---------|
| `t` | Topic/category filtering | `senedecisions`, `infrastructure` |
| `d` | Decision ID (for filtering, NOT for replaceability) | `dec-2026-02-20-001` |
| `alt` | Human-readable summary for clients | `Sovereign Decision Record: ...` |
| `review-date` | When outcome should be reviewed | `2026-03-06` |
| `prev` | Previous event in chain | `<event_id>` |
| `e` | References another event (outcomes → decisions) | `<event_id>` |
| `p` | References another pubkey | `<hex pubkey>` |

## Categories

- `infrastructure` — tooling, systems, platform choices
- `capability` — new skills, repos, agent expansions
- `collaboration` — partnerships, access grants, community
- `financial` — treasury, payments, economic decisions
- `identity` — key management, profile, sovereignty decisions
- `strategic` — goal-level decisions, priority changes

## Querying

```bash
# All Sene's decisions
nak req -k 2100 -a <sene_pubkey> wss://relay.damus.io

# Decisions by category
nak req -k 2100 -a <sene_pubkey> -t t=infrastructure wss://relay.damus.io

# Specific decision
nak req -k 2100 -a <sene_pubkey> -t d=dec-2026-02-20-001 wss://relay.damus.io

# All outcomes
nak req -k 2100 -a <sene_pubkey> -t t=sene-outcomes wss://relay.damus.io
```
