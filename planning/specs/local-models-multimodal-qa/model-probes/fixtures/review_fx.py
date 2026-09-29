import os, re
D = os.path.join(os.path.dirname(os.path.abspath(__file__)), "review")
FILES = ["lib/shop/invoice_paginator.rb", "lib/shop/discount_rules.rb", "lib/shop/export_job.rb"]

BUGS = {}   # id -> (file, lo, hi, keywords)
SRC = {}
KW = {"BUG1": ["off-by-one", "off by one", "inclusive", "..", "per_page + 1", "one extra", "overlap", "duplicate", "26", "exclusive", "..."],
      "BUG2": [">=", "greater than or equal", "exactly", "100.00", "at least", "or more", "boundary", "threshold"],
      "BUG3": ["nil", "guest", "upcase", "nomethod", "safe navigation", "&."],
      "BUG4": ["leak", "close", "not closed", "never closed", "file handle", "descriptor", "ensure", "block form", "File.open"]}
SPANS = {"BUG1": (0, 0), "BUG2": (0, 0), "BUG3": (0, 0), "BUG4": (0, 5)}
for f in FILES:
    lines = open(os.path.join(D, os.path.basename(f))).read().splitlines()
    clean = []
    for i, l in enumerate(lines, 1):
        m = re.search(r" #(BUG\d)$", l)
        if m:
            lo, hi = SPANS[m.group(1)]
            BUGS[m.group(1)] = (f, i + lo, i + hi)
            l = l[: m.start()]
        clean.append(l)
    SRC[f] = clean


def diff_text():
    out = []
    for f in FILES:
        n = len(SRC[f])
        out.append(f"diff --git a/{f} b/{f}\nnew file mode 100644\n--- /dev/null\n+++ b/{f}\n@@ -0,0 +1,{n} @@")
        out += [f"+{l}" for l in SRC[f]]
    return "\n".join(out)


def numbered_text():
    out = []
    for f in FILES:
        out.append(f"=== {f} (new file) ===")
        out += [f"{i:3d}| {l}" for i, l in enumerate(SRC[f], 1)]
    return "\n".join(out)


PROMPT = """You are reviewing a pull request for correctness. The change adds three new files to a Ruby 3.4 codebase. The full new contents are shown below with line numbers (the line numbers are the new-file line numbers).

Report only real defects: behaviour that is wrong, crashes, leaks resources, or contradicts the code's own documented intent. Do not report style preferences, missing tests, or unfamiliar-but-valid Ruby syntax.

Answer with ONLY a JSON array, no prose, of objects:
  {"file": "<path>", "line": <int>, "severity": "high|medium|low", "claim": "<one sentence>"}
Return [] if there are no defects.

"""


def prompt():
    return PROMPT + numbered_text()


def _fileof(fnd):
    f = str(fnd.get("file", ""))
    for full in FILES:
        if f and (f == full or f.endswith(os.path.basename(full)) or os.path.basename(full).startswith(f.split("/")[-1].split(".")[0])):
            return full
    return None


def score(findings):
    """TP = matched a planted bug (right file, line within +/-3 of its span, and a keyword); FP = anything else."""
    if not isinstance(findings, list):
        return None
    hit, fps, dups = set(), [], 0
    for fnd in findings:
        if not isinstance(fnd, dict):
            fps.append(str(fnd)); continue
        f = _fileof(fnd)
        try: line = int(fnd.get("line"))
        except Exception: line = -99
        claim = str(fnd.get("claim", "")).lower()
        matched = None
        for bid, (bf, lo, hi) in BUGS.items():
            if bf == f and lo - 3 <= line <= hi + 3 and any(k.lower() in claim for k in KW[bid]):
                matched = bid; break
        if matched:
            if matched in hit: dups += 1
            hit.add(matched)
        else:
            fps.append(f"{fnd.get('file')}:{fnd.get('line')} [{fnd.get('severity')}] {fnd.get('claim')}")
    return {"tp": len(hit), "hit": sorted(hit), "fp": len(fps), "fp_claims": fps, "dups": dups, "n": len(findings)}
