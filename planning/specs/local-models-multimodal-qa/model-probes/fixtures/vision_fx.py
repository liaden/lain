import os
D = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vision")

PAGES = [
 {"id": "v1_clean_settings", "defect": None,
  "spec": "A card titled 'Account Settings' with three label/value rows: Name = Ada Lovelace, Email = ada@example.com, Plan = Pro (annual); below them a blue 'Save changes' button."},
 {"id": "v2_overlap", "defect": "overlap", "kw": ["overlap", "cover", "obscur", "hidden", "badge", "block", "on top", "partially"],
  "spec": "A card titled 'Billing Overview' with a red '3 overdue' badge, and three label/value rows: Balance = $1,240.00, Next invoice = Oct 1, 2026, Payment method = Visa ending 4242. The title must be fully readable."},
 {"id": "v3_truncated", "defect": "truncated", "kw": ["truncat", "clip", "cut", "incomplete", "partial", "overflow", "download inv"],
  "spec": "A card titled 'Invoice #1042' with rows Amount = $310.00 and Status = Paid, and a blue button labelled 'Download invoice PDF'."},
 {"id": "v4_wrong_text", "defect": "wrong_text", "kw": ["august", "september", "month"],
  "spec": "A card titled 'Monthly Report — September 2026' with rows Active users = 12,408, New signups = 1,093, Churned = 211."},
 {"id": "v5_low_contrast", "defect": "low_contrast", "kw": ["contrast", "faint", "invisible", "light", "barely", "hard to read", "not visible", "illegible", "trial", "warning", "missing"],
  "spec": "A card titled 'Subscription' with a clearly readable warning sentence 'Your trial ends in 3 days. Add a payment method to keep your data.', rows Plan = Trial and Seats = 5, and a blue 'Add payment method' button."},
 {"id": "v6_clean_table", "defect": None,
  "spec": "A heading 'Q3 Sales by Region' above a 3-column table (Region, Units, Revenue) with rows: North 1,204 $48,160; South 987 $39,480; East 1,530 $61,200; West 842 $33,680. Numbers right-aligned in their columns."},
 {"id": "v7_misaligned_table", "defect": "misaligned", "kw": ["misalign", "shift", "column", "extra", "empty", "south", "wrong column", "offset", "fourth", "blank"],
  "spec": "A heading 'Q3 Sales by Region' above a 3-column table (Region, Units, Revenue) with rows: North 1,204 $48,160; South 987 $39,480; East 1,530 $61,200; West 842 $33,680. Numbers right-aligned in their columns."},
]

PROMPT = """You are a visual QA checker. Compare the screenshot against the specification and report any VISIBLE defect: overlapping elements, clipped or truncated text, text that differs from the spec, misaligned layout, or text that is unreadable (e.g. too low contrast). Ignore the empty white space around the content.

Specification:
{spec}

Answer with ONLY a JSON object: {{"verdict": "pass|fail", "defects": ["<short description>", ...]}}"""

CONTACT_PROMPT = "This image is a contact sheet of three screenshots of the same web page taken in sequence, left to right. Describe what changes from frame to frame and what the user most likely did or saw happen. Be concise."


def path(pid): return os.path.join(D, pid + ".png")


def score(page, parsed):
    if not isinstance(parsed, dict):
        return {"parsed": False, "verdict": None, "correct_verdict": False, "right_defect": None}
    v = str(parsed.get("verdict", "")).lower()
    defects = " ".join(str(d) for d in (parsed.get("defects") or [])).lower()
    if page["defect"] is None:
        return {"parsed": True, "verdict": v, "correct_verdict": v == "pass", "right_defect": None}
    right = v == "fail" and any(k in defects for k in page["kw"])
    return {"parsed": True, "verdict": v, "correct_verdict": v == "fail", "right_defect": right}
