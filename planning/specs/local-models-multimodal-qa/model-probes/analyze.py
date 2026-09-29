#!/usr/bin/env python3
"""Score raw/*.jsonl into tables (markdown to stdout, details to scored/*.json)."""
import sys, os, json, statistics as st
from collections import defaultdict, Counter
H = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, H); sys.path.insert(0, os.path.join(H, "fixtures"))
import olib, tools_fx, review_fx, plan_fx, qa_fx, vision_fx

os.makedirs(os.path.join(H, "scored"), exist_ok=True)


def load(probe):
    p = os.path.join(H, "raw", probe + ".jsonl")
    return [json.loads(l) for l in open(p)] if os.path.exists(p) else []


def f(x, d=1):
    return "-" if x is None else (f"{x:.{d}f}" if isinstance(x, float) else str(x))


def sec(ns): return (ns or 0) / 1e9


def tokstats(rs):
    ev = [r["eval_count"] or 0 for r in rs]
    wall = [r["wall_s"] for r in rs]
    th = [r["thinking_chars"] / max(1, r["thinking_chars"] + len(r["content"] or "")) for r in rs]
    return {"ev_mean": st.mean(ev), "ev_max": max(ev), "wall_mean": st.mean(wall), "wall_max": max(wall),
            "think_share": st.mean(th), "truncated": sum(r["done_reason"] == "length" for r in rs),
            "contended": sum(bool(r["contended"]) for r in rs), "errors": sum(bool(r["error"]) for r in rs)}


def models_in(rs):
    seen = []
    for r in rs:
        if r["model"] not in seen: seen.append(r["model"])
    return seen


out = []
P = out.append

# ---- speed
rs = load("speed")
P("## Speed / residency (num_ctx 16384, num_batch 2048)\n")
P("| model | load_s (first req) | prefill tok/s (cold prefix, ~7.6k tok) | decode tok/s (512-tok gen) | decode tok/s across all probe requests (mean / min) | VRAM @16k | VRAM @32k | contended |")
P("|---|---|---|---|---|---|---|---|")
allrecs = [r for p in ("tools", "review", "plan", "qa", "vision") for r in load(p)]
for m in models_in(rs):
    mr = [r for r in rs if r["model"] == m]
    load_ = next((r for r in mr if r["item"] == "load"), None)
    pf = [olib.rates(r)[0] for r in mr if r["item"].startswith("prefill")]
    dec = next((olib.rates(r)[1] for r in mr if r["item"] == "decode"), None)
    alld = [olib.rates(r)[1] for r in allrecs if r["model"] == m and (r["eval_count"] or 0) > 50 and olib.rates(r)[1]]

    def vram(item_pred):
        for r in mr:
            if item_pred(r):
                for x in r["ps_after"]:
                    if x["name"].startswith(m.split(":")[0]):
                        return f"{x['size_vram']/2**30:.1f}/{x['size']/2**30:.1f} GiB" + ("" if x["fully_vram"] else " **PARTIAL**")
        return "-"
    P(f"| {m} | {f(sec(load_['load_duration']) if load_ else None)} | {' / '.join(f(x,0) for x in pf if x)} | {f(dec)} | "
      f"{f(st.mean(alld)) if alld else '-'} / {f(min(alld)) if alld else '-'} | {vram(lambda r: r['item']=='decode')} | "
      f"{vram(lambda r: r['item']=='ctx32k_residency')} | {sum(bool(r['contended']) for r in mr)}/{len(mr)} |")

# ---- tools
rs = load("tools")
P("\n## Tool-call fidelity (8 tasks x n runs)\n")
P("| model | n | tool called | valid args | right tool | exact path/cmd | edit old_string verbatim (2 tasks) | all-correct rate | worst task (all-correct over its runs) | mean eval tok | mean wall s | max wall s |")
P("|---|---|---|---|---|---|---|---|---|---|---|---|")
detail = defaultdict(list)
for m in models_in(rs):
    mr = [r for r in rs if r["model"] == m]
    sc = []
    per_task = defaultdict(list)
    for r in mr:
        t = next(t for t in tools_fx.TASKS if t["id"] == r["item"])
        s = tools_fx.score(t, r)
        s["all"] = s["called"] and s["valid_args"] and s["right_tool"] and s["exact_path"] and (s["edit_ok"] in (None, True))
        sc.append(s); per_task[r["item"]].append(s["all"])
        detail[m].append({"item": r["item"], "run": r["run"], **s, "tool_calls": r["tool_calls"], "content": (r["content"] or "")[:300]})
    rate = lambda k: sum(bool(s[k]) for s in sc) / len(sc)
    eds = [s["edit_ok"] for s in sc if s["edit_ok"] is not None or False]
    edit_n = [s for s, r in zip(sc, mr) if r["item"].startswith("edit")]
    edit_ok = sum(bool(s["edit_ok"]) for s in edit_n)
    worst = min(per_task.items(), key=lambda kv: sum(kv[1]) / len(kv[1]))
    ts = tokstats(mr)
    P(f"| {m} | {len(sc)} | {rate('called'):.0%} | {rate('valid_args'):.0%} | {rate('right_tool'):.0%} | {rate('exact_path'):.0%} | "
      f"{edit_ok}/{len(edit_n)} | {rate('all'):.0%} | {worst[0]} {sum(worst[1])}/{len(worst[1])} | {ts['ev_mean']:.0f} | {ts['wall_mean']:.1f} | {ts['wall_max']:.1f} |")
json.dump(detail, open(os.path.join(H, "scored", "tools.json"), "w"), indent=1)

# ---- review
rs = load("review")
P("\n## Planted-defect code review (4 planted bugs; n runs)\n")
P("| model | n | parsed | TP mean (worst) /4 | recall | FP mean (worst) | precision | bugs found per run | eval tok mean (max) | think share | wall s mean (max) | truncated |")
P("|---|---|---|---|---|---|---|---|---|---|---|---|")
detail = defaultdict(list)
for m in models_in(rs):
    mr = [r for r in rs if r["model"] == m]
    scs = [review_fx.score(olib.extract_json(r["content"])) for r in mr]
    ok = [s for s in scs if s]
    for r, s in zip(mr, scs):
        detail[m].append({"run": r["run"], "score": s, "content": r["content"][:3000]})
    ts = tokstats(mr)
    if ok:
        tp = [s["tp"] for s in ok]; fp = [s["fp"] for s in ok]
        prec = sum(tp) / max(1, sum(tp) + sum(fp))
        P(f"| {m} | {len(mr)} | {len(ok)}/{len(mr)} | {st.mean(tp):.2f} ({min(tp)}) | {st.mean(tp)/4:.0%} | {st.mean(fp):.2f} ({max(fp)}) | {prec:.0%} | "
          f"{'; '.join(','.join(s['hit']) or '-' for s in ok)} | {ts['ev_mean']:.0f} ({ts['ev_max']}) | {ts['think_share']:.0%} | {ts['wall_mean']:.0f} ({ts['wall_max']:.0f}) | {ts['truncated']} |")
    else:
        P(f"| {m} | {len(mr)} | 0/{len(mr)} | - | - | - | - | - | {ts['ev_mean']:.0f} | {ts['think_share']:.0%} | {ts['wall_mean']:.0f} | {ts['truncated']} |")
json.dump(detail, open(os.path.join(H, "scored", "review.json"), "w"), indent=1)

# ---- plan
rs = load("plan")
P("\n## Plan review (3 planted plan defects; n runs)\n")
P("| model | n | parsed | found mean (worst) /3 | per-defect hits D1/D2/D3 | false alarms mean (worst) | eval tok mean (max) | think share | wall s mean (max) |")
P("|---|---|---|---|---|---|---|---|---|")
detail = defaultdict(list)
for m in models_in(rs):
    mr = [r for r in rs if r["model"] == m]
    scs = [plan_fx.score(olib.extract_json(r["content"])) for r in mr]
    ok = [s for s in scs if s]
    for r, s in zip(mr, scs):
        detail[m].append({"run": r["run"], "score": s, "content": r["content"][:3000]})
    ts = tokstats(mr)
    if ok:
        tp = [s["tp"] for s in ok]; fp = [s["fp"] for s in ok]
        per = Counter(h for s in ok for h in s["hit"])
        P(f"| {m} | {len(mr)} | {len(ok)}/{len(mr)} | {st.mean(tp):.2f} ({min(tp)}) | {per['D1']}/{per['D2']}/{per['D3']} of {len(ok)} | {st.mean(fp):.2f} ({max(fp)}) | "
          f"{ts['ev_mean']:.0f} ({ts['ev_max']}) | {ts['think_share']:.0%} | {ts['wall_mean']:.0f} ({ts['wall_max']:.0f}) |")
    else:
        P(f"| {m} | {len(mr)} | 0/{len(mr)} | - | - | - | {ts['ev_mean']:.0f} | {ts['think_share']:.0%} | {ts['wall_mean']:.0f} |")
json.dump(detail, open(os.path.join(H, "scored", "plan.json"), "w"), indent=1)

# ---- qa
rs = load("qa")
P("\n## QA AC verification (8 items: 4 pass, 4 subtle fail; n runs each)\n")
P("| model | n | accuracy | accuracy greedy (t0) | worst item acc | unsure rate | items unanimous across runs | unanimous-and-wrong items | wrong verdict on a TRUE-FAIL item (missed violation) | eval tok mean | wall s mean (max) |")
P("|---|---|---|---|---|---|---|---|---|---|---|")
detail = defaultdict(list)
for m in models_in(rs):
    mr = [r for r in rs if r["model"] == m]
    per = defaultdict(list)
    t0c = []
    miss_fail = 0; n_fail = 0
    for r in mr:
        it = next(i for i in qa_fx.ITEMS if i["id"] == r["item"])
        j = olib.extract_json(r["content"])
        v = str(j.get("verdict", "")).lower() if isinstance(j, dict) else "unparsed"
        per[r["item"]].append(v)
        if r["run"] == "t0": t0c.append(v == it["truth"])
        if it["truth"] == "fail":
            n_fail += 1; miss_fail += v == "pass"
        detail[m].append({"item": r["item"], "run": r["run"], "truth": it["truth"], "verdict": v, "evidence": (j or {}).get("evidence") if isinstance(j, dict) else r["content"][:300]})
    truth = {i["id"]: i["truth"] for i in qa_fx.ITEMS}
    allv = [(k, v) for k, vs in per.items() for v in vs]
    acc = sum(v == truth[k] for k, v in allv) / len(allv)
    unsure = sum(v == "unsure" for _, v in allv) / len(allv)
    unanimous = [k for k, vs in per.items() if len(set(vs)) == 1]
    unan_wrong = [k for k in unanimous if per[k][0] != truth[k]]
    worst = min(sum(v == truth[k] for v in vs) / len(vs) for k, vs in per.items())
    ts = tokstats(mr)
    P(f"| {m} | {len(allv)} | {acc:.0%} | {sum(t0c)}/{len(t0c)} | {worst:.0%} | {unsure:.0%} | {len(unanimous)}/8 | {', '.join(unan_wrong) or '-'} | {miss_fail}/{n_fail} | {ts['ev_mean']:.0f} | {ts['wall_mean']:.1f} ({ts['wall_max']:.1f}) |")
    detail[m + "::per_item"] = {k: {"truth": truth[k], "verdicts": vs} for k, vs in per.items()}
json.dump(detail, open(os.path.join(H, "scored", "qa.json"), "w"), indent=1)

# ---- vision
rs = load("vision")
P("\n## Vision / screenshot QA (7 pages: 5 planted defects, 2 clean; n runs each)\n")
P("| model | n | parsed | defect pages flagged fail | ...and named the right defect | clean pages false alarm | per-page right-defect (v2 overlap/v3 trunc/v4 text/v5 contrast/v7 table) | eval tok mean | prompt tok (image) | wall s mean (max) |")
P("|---|---|---|---|---|---|---|---|---|---|")
detail = defaultdict(list)
for m in models_in(rs):
    mr = [r for r in rs if r["model"] == m]
    sc = []
    for r in mr:
        pg = next(p for p in vision_fx.PAGES if p["id"] == r["item"])
        s = vision_fx.score(pg, olib.extract_json(r["content"]))
        sc.append((pg, s)); detail[m].append({"item": r["item"], "run": r["run"], **s, "content": r["content"][:600]})
    dp = [s for p, s in sc if p["defect"]]; cp = [s for p, s in sc if not p["defect"]]
    perpage = []
    for pid in ("v2_overlap", "v3_truncated", "v4_wrong_text", "v5_low_contrast", "v7_misaligned_table"):
        xs = [s for p, s in sc if p["id"] == pid]
        perpage.append(f"{sum(bool(s['right_defect']) for s in xs)}/{len(xs)}")
    ts = tokstats(mr)
    pt = st.mean([r["prompt_eval_count"] or 0 for r in mr])
    P(f"| {m} | {len(sc)} | {sum(s['parsed'] for _, s in sc)}/{len(sc)} | {sum(s['correct_verdict'] for s in dp)}/{len(dp)} | {sum(bool(s['right_defect']) for s in dp)}/{len(dp)} | "
      f"{sum(not s['correct_verdict'] for s in cp)}/{len(cp)} | {' '.join(perpage)} | {ts['ev_mean']:.0f} | {pt:.0f} | {ts['wall_mean']:.1f} ({ts['wall_max']:.1f}) |")
json.dump(detail, open(os.path.join(H, "scored", "vision.json"), "w"), indent=1)

# ---- contention summary
P("\n## Requests timed while another model was resident\n")
allr = [r for p in ("speed", "tools", "review", "plan", "qa", "vision") for r in load(p)]
c = Counter((r["model"], tuple(sorted(set(r["other_models_resident_before"])))) for r in allr if r["contended"])
for (m, o), n in sorted(c.items()):
    P(f"- {m}: {n} requests with {', '.join(o) or '(another model appeared during the request)'} also resident")
print("\n".join(out))
