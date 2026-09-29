PLAN = """# Plan: nightly order export with upload retry

## Requirements
- R1. A CSV of the day's settled orders is written to `exports/` once a night.
- R2. Orders deleted by support (soft-deleted, `deleted_at` set) never appear in any export.
- R3. A failed upload is retried at most 3 times, then the job fails loudly (non-zero exit, alert).
- R4. Exports are idempotent: re-running a night overwrites that night's file, never appends.

## Cards

### Card 1 - Export query
Add `OrderRepo#settled_on(date)` returning settled orders for a date, excluding soft-deleted rows.
```gherkin
Scenario: soft-deleted orders are excluded
  Given two orders settled on 2026-09-01, one with deleted_at set
  When settled_on(2026-09-01) is called
  Then exactly one order is returned
```

### Card 2 - CSV writer
Write `ExportJob#call(date)` producing `exports/orders-<date>.csv` using the upload client from Card 4.
```gherkin
Scenario: file is written with a header row
  Given one settled order on 2026-09-01
  When the job runs for 2026-09-01
  Then exports/orders-2026-09-01.csv has 2 lines and the first is the header
```

### Card 3 - Upload retry
Wrap the uploader: on IOError, retry up to 5 times with exponential backoff, then raise.
```gherkin
Scenario: transient failure recovers
  Given the uploader fails twice then succeeds
  When the job runs
  Then the file is uploaded once and the job exits 0
```

### Card 4 - Upload client
Add `S3Uploader#put(path)` wrapping the storage SDK; raise IOError on any transport error.
```gherkin
Scenario: transport error surfaces as IOError
  Given the storage SDK raises a timeout
  When put is called
  Then IOError is raised
```

### Card 5 - Cache of export metadata
Keep an in-process cache of the last export's row count for the status page.
```gherkin
Scenario: re-export refreshes the cache
  Given a cached row count for 2026-09-01
  When the job re-runs for 2026-09-01
  Then the cache internally marks the old entry as stale before replacing it
```

### Card 6 - Alerting
On final upload failure, exit 2 and post to #ops-alerts. If the alert post itself fails, keep retrying the upload until the alert succeeds.
```gherkin
Scenario: final failure alerts
  Given the uploader always fails
  When the job runs
  Then the process exits 2 and one message is posted to #ops-alerts
```

## Dependencies and waves
- Card 2 depends on Card 1 and Card 4.
- Card 3 depends on Card 4.
- Card 6 depends on Card 3.
- Wave 1: Card 1, Card 2, Card 5
- Wave 2: Card 4
- Wave 3: Card 3
- Wave 4: Card 6
"""

PROMPT = """You are reviewing an implementation plan before sub-agents execute it card by card, in the waves listed (cards in one wave run in parallel; a wave starts only after the previous wave is merged).

Find defects in the PLAN itself: ordering/dependency errors, acceptance criteria that cannot be verified from outside the code under test, and cards that contradict the stated requirements. Do not suggest extra features or style changes.

Answer with ONLY a JSON array, no prose, of objects:
  {"where": "<card or section>", "kind": "dependency|unobservable_ac|contradiction|other", "claim": "<one sentence>"}

""" + PLAN

# Planted: D1 Card 2 (wave 1) depends on Card 4 (wave 2).
#          D2 Card 5's AC asserts internal state ("internally marks ... stale").
#          D3 Cards 3 and 6 contradict R3 (5 retries; unbounded retry while alert fails).


def _txt(f):
    return (str(f.get("where", "")) + " " + str(f.get("claim", ""))).lower()


def classify(f):
    t = _txt(f)
    k = str(f.get("kind", "")).lower()
    if ("card 2" in t or "card2" in t) and ("card 4" in t or "card4" in t or "wave" in t or "upload client" in t):
        return "D1"
    if ("card 5" in t or "cache" in t) and ("internal" in t or "stale" in t or "observ" in t or k == "unobservable_ac"):
        return "D2"
    if ("r3" in t or "retr" in t) and ("card 3" in t or "card 6" in t or "5" in t or "until" in t or "indefin" in t or "unbounded" in t or "3 times" in t or "three" in t):
        return "D3"
    return None


def score(findings):
    if not isinstance(findings, list):
        return None
    hit, fps = set(), []
    for f in findings:
        if not isinstance(f, dict):
            fps.append(str(f)); continue
        c = classify(f)
        if c: hit.add(c)
        else: fps.append(f"{f.get('where')} [{f.get('kind')}] {f.get('claim')}")
    return {"tp": len(hit), "hit": sorted(hit), "fp": len(fps), "fp_claims": fps, "n": len(findings)}
