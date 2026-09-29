"""Thin Ollama /api/chat client that records every request/response summary to JSONL."""
import json, time, urllib.request, os, re, base64

HOST = "http://localhost:11434"
HERE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(HERE, "raw")
os.makedirs(RAW, exist_ok=True)
NUM_CTX = 16384
NUM_BATCH = 2048
# 3 seeded samples at 0.6 plus one greedy run
RUNS = [("s11", 0.6, 11), ("s22", 0.6, 22), ("s33", 0.6, 33), ("t0", 0.0, 0)]


def _post(path, body, timeout=900):
    req = urllib.request.Request(HOST + path, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def ps():
    with urllib.request.urlopen(HOST + "/api/ps", timeout=30) as r:
        j = json.loads(r.read())
    return [{"name": m["name"], "size": m.get("size"), "size_vram": m.get("size_vram"),
             "context_length": m.get("context_length"),
             "fully_vram": m.get("size") == m.get("size_vram")} for m in j.get("models", [])]


def chat(model, messages, *, probe, item, run="adhoc", temperature=0.6, seed=0, tools=None,
         fmt=None, think=None, num_ctx=NUM_CTX, num_predict=6144, extra=None, raw_keep=False):
    body = {"model": model, "messages": messages, "stream": False,
            "options": {"num_batch": NUM_BATCH, "num_ctx": num_ctx, "temperature": temperature,
                        "seed": seed, "num_predict": num_predict}}
    if tools is not None: body["tools"] = tools
    if fmt is not None: body["format"] = fmt
    if think is not None: body["think"] = think
    if extra: body.update(extra)
    before = ps()
    others = [m["name"] for m in before if not m["name"].startswith(model.split(":")[0])]
    t0 = time.time()
    err = None
    try:
        resp = _post("/api/chat", body)
    except urllib.error.HTTPError as e:
        resp = {}; err = f"HTTP {e.code}: {e.read().decode()[:500]}"
    except Exception as e:  # noqa
        resp = {}; err = repr(e)
    wall = time.time() - t0
    after = ps()
    msg = resp.get("message", {}) or {}
    rec = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S"), "model": model, "probe": probe, "item": item,
        "run": run, "temperature": temperature, "seed": seed, "num_ctx": num_ctx, "think": think,
        "wall_s": round(wall, 2), "error": err,
        "ps_before": before, "ps_after": after, "other_models_resident_before": others,
        "contended": bool(others) or any(not m["name"].startswith(model.split(":")[0]) for m in after),
        "load_duration": resp.get("load_duration"), "prompt_eval_count": resp.get("prompt_eval_count"),
        "prompt_eval_duration": resp.get("prompt_eval_duration"), "eval_count": resp.get("eval_count"),
        "eval_duration": resp.get("eval_duration"), "total_duration": resp.get("total_duration"),
        "done_reason": resp.get("done_reason"),
        "content": msg.get("content", ""), "thinking": msg.get("thinking", "") or "",
        "tool_calls": msg.get("tool_calls"),
    }
    rec["thinking_chars"] = len(rec["thinking"])
    if raw_keep:
        b2 = json.loads(json.dumps(body))
        for m in b2["messages"]:
            if "images" in m: m["images"] = [f"<base64 {len(i)} chars>" for i in m["images"]]
        rec["request"] = b2
        rec["raw_response"] = resp
    with open(os.path.join(RAW, f"{probe}.jsonl"), "a") as f:
        f.write(json.dumps(rec) + "\n")
    return rec


def rates(rec):
    pe = rec.get("prompt_eval_duration") or 0
    ed = rec.get("eval_duration") or 0
    return ((rec["prompt_eval_count"] or 0) / (pe / 1e9) if pe else None,
            (rec["eval_count"] or 0) / (ed / 1e9) if ed else None)


def extract_json(text):
    """Pull the first JSON array/object out of a model reply (fences, prose tolerated)."""
    if not text: return None
    m = re.search(r"```(?:json)?\s*(.*?)```", text, re.S)
    cands = [m.group(1)] if m else []
    cands.append(text)
    for c in cands:
        c = c.strip()
        try: return json.loads(c)
        except Exception: pass
        for open_, close in (("[", "]"), ("{", "}")):
            i, j = c.find(open_), c.rfind(close)
            if i != -1 and j > i:
                try: return json.loads(c[i:j + 1])
                except Exception: pass
    return None


def b64(path):
    with open(path, "rb") as f: return base64.b64encode(f.read()).decode()
