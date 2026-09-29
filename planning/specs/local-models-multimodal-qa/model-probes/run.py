#!/usr/bin/env python3
"""Run every probe for ONE model, serially. Usage: run.py MODEL probes=speed,tools,... [runs=4] [np=6144] [think=default|false]"""
import sys, os, json, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures"))
import olib
from olib import chat, RUNS, ps
import tools_fx, review_fx, plan_fx, qa_fx, vision_fx

model = sys.argv[1]
kv = dict(a.split("=", 1) for a in sys.argv[2:])
probes = kv.get("probes", "speed,tools,review,plan,qa").split(",")
runs = RUNS[: int(kv.get("runs", 4))]
if int(kv.get("runs", 4)) < 4 and ("t0", 0.0, 0) not in runs:
    runs = runs[:-1] + [("t0", 0.0, 0)]   # always keep the greedy run
NP = int(kv.get("np", 6144))
THINK = {"default": None, "false": False, "true": True}[kv.get("think", "default")]
TAG = kv.get("tag", "")
thinking_capable = kv.get("thinks", "1") == "1"


def log(*a):
    print(time.strftime("%H:%M:%S"), model, *a, flush=True)


def go(msgs, probe, item, run, temp, seed, **kw):
    r = chat(model, msgs, probe=probe + TAG, item=item, run=run, temperature=temp, seed=seed,
             num_predict=kw.pop("num_predict", NP), think=kw.pop("think", THINK), **kw)
    pr, dr = olib.rates(r)
    log(probe, item, run, f"wall={r['wall_s']}s ev={r['eval_count']} think_chars={r['thinking_chars']}",
        f"pf={pr and round(pr)} dec={dr and round(dr,1)} done={r['done_reason']} contended={r['contended']}",
        ("ERR " + r["error"]) if r["error"] else "")
    return r


if "speed" in probes:
    long_ctx = (review_fx.numbered_text() + "\n\n" + plan_fx.PLAN + "\n\n") * 3
    for i in range(3):
        msgs = [{"role": "user", "content": f"Request nonce {time.time_ns()}-{i}.\n" + long_ctx + "\nIn one sentence, what domain is this code for?"}]
        go(msgs if i else [{"role": "user", "content": "Say hi."}], "speed", ["load", "prefill_warm", "prefill_warm2"][i],
           f"r{i}", 0.0, 0, num_predict=256, think=(False if thinking_capable else None))
    # decode-rate item: a fixed long generation without thinking
    go([{"role": "user", "content": "Write a 300-word explanation of how a Merkle DAG supports O(1) forks."}],
       "speed", "decode", "r0", 0.0, 0, num_predict=512, think=(False if thinking_capable else None))
    log("ps:", json.dumps(ps()))

if "tools" in probes:
    for t in tools_fx.TASKS:
        for run, temp, seed in runs:
            go([{"role": "system", "content": tools_fx.SYSTEM}, {"role": "user", "content": t["prompt"]}],
               "tools", t["id"], run, temp, seed, tools=tools_fx.TOOLS)

if "review" in probes:
    for run, temp, seed in runs:
        go([{"role": "user", "content": review_fx.prompt()}], "review", "diff1", run, temp, seed)

if "plan" in probes:
    for run, temp, seed in runs:
        go([{"role": "user", "content": plan_fx.PROMPT}], "plan", "plan1", run, temp, seed)

if "qa" in probes:
    for it in qa_fx.ITEMS:
        for run, temp, seed in runs:
            go([{"role": "user", "content": qa_fx.prompt(it)}], "qa", it["id"], run, temp, seed)

if "vision" in probes:
    for p in vision_fx.PAGES:
        img = olib.b64(vision_fx.path(p["id"]))
        for run, temp, seed in runs:
            go([{"role": "user", "content": vision_fx.PROMPT.format(spec=p["spec"]), "images": [img]}],
               "vision", p["id"], run, temp, seed)
    img = olib.b64(os.path.join(vision_fx.D, "contact_tile.png"))
    go([{"role": "user", "content": vision_fx.CONTACT_PROMPT, "images": [img]}], "vision_contact", "contact", "t0", 0.0, 0)

if "ctx32k" in probes:
    go([{"role": "user", "content": "Say hi."}], "speed", "ctx32k_residency", "r0", 0.0, 0, num_ctx=32768,
       num_predict=16, think=(False if thinking_capable else None))
    log("ps@32k:", json.dumps(ps()))

log("DONE")
