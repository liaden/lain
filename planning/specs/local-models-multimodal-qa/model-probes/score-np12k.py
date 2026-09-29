#!/usr/bin/env python3
"""Score the np=12288 budget retest (raw/*_np12k.jsonl) with the same fixtures as analyze.py."""
import os, sys, json, statistics as st
from collections import defaultdict, Counter
H = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, H); sys.path.insert(0, os.path.join(H, "fixtures"))
import olib, review_fx, plan_fx

def rows(p): return [json.loads(l) for l in open(os.path.join(H, "raw", p))]

def toks(mr):
    ev = [r["eval_count"] or 0 for r in mr]
    wall = [r["wall_s"] for r in mr]
    trunc = sum(1 for r in mr if r["done_reason"] == "length")
    think = sum(r["thinking_chars"] for r in mr)
    return st.mean(ev), max(ev), st.mean(wall), max(wall), trunc, think

print("## Budget retest at num_predict=12288 (the three models that answered nothing at 6144)\n")
for probe, fx, n_def, label in (("review_np12k", review_fx, 4, "code review"),
                                ("plan_np12k", plan_fx, 3, "plan review")):
    rs = rows(probe + ".jsonl")
    print(f"### {label} (was 0/4 answered at 6144)\n")
    print("| model | n | parsed | found mean (worst) | recall | false alarms mean (worst) | eval tok mean (max) | wall s mean (max) | hit the 12288 cap |")
    print("|---|---|---|---|---|---|---|---|---|")
    for m in dict.fromkeys(r["model"] for r in rs):
        mr = [r for r in rs if r["model"] == m]
        scs = [fx.score(olib.extract_json(r["content"])) for r in mr]
        ok = [s for s in scs if s]
        ev_m, ev_x, w_m, w_x, trunc, _ = toks(mr)
        if ok:
            tp = [s["tp"] for s in ok]; fp = [s["fp"] for s in ok]
            print(f"| {m} | {len(mr)} | {len(ok)}/{len(mr)} | {st.mean(tp):.2f} ({min(tp)}) of {n_def} | {st.mean(tp)/n_def:.0%} | "
                  f"{st.mean(fp):.2f} ({max(fp)}) | {ev_m:.0f} ({ev_x}) | {w_m:.0f} ({w_x:.0f}) | {trunc}/{len(mr)} |")
        else:
            print(f"| {m} | {len(mr)} | 0/{len(mr)} | - | - | - | {ev_m:.0f} ({ev_x}) | {w_m:.0f} ({w_x:.0f}) | {trunc}/{len(mr)} |")
    print()
