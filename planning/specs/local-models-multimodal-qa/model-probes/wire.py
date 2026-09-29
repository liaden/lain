#!/usr/bin/env python3
"""Wire checks: format+tools, format+think, tool-role message carrying images. Usage: wire.py MODEL a,b | c"""
import sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures"))
import olib, tools_fx, vision_fx

model, which = sys.argv[1], sys.argv[2].split(",")
SCHEMA = {"type": "object", "properties": {"answer": {"type": "string"}, "confidence": {"type": "number"}},
          "required": ["answer", "confidence"]}


def show(r):
    print(json.dumps({k: r[k] for k in ("model", "item", "run", "error", "done_reason", "eval_count", "thinking_chars", "tool_calls")}))
    print("CONTENT:", (r["content"] or "")[:400].replace("\n", "\\n"))
    print("THINKING:", (r["thinking"] or "")[:200].replace("\n", "\\n"))
    print("---")


if "a" in which:
    # a question that needs a tool, and one that doesn't
    for item, q in [("needs_tool", "What is on the first line of lib/widgets/frobnicator_v2.rb?"),
                    ("no_tool", "What is 17 * 3? Reply in the requested format.")]:
        for run, t, s in [("s11", 0.6, 11), ("t0", 0.0, 0)]:
            show(olib.chat(model, [{"role": "system", "content": tools_fx.SYSTEM}, {"role": "user", "content": q}],
                           probe="wire", item=f"a_format+tools_{item}", run=run, temperature=t, seed=s,
                           tools=tools_fx.TOOLS, fmt=SCHEMA, raw_keep=True, num_predict=2048))
if "b" in which:
    for think in (True, False):
        for run, t, s in [("s11", 0.6, 11), ("t0", 0.0, 0)]:
            show(olib.chat(model, [{"role": "user", "content": "Is 221 prime? Answer in the requested format."}],
                           probe="wire", item=f"b_format+think={think}", run=run, temperature=t, seed=s,
                           fmt=SCHEMA, think=think, raw_keep=True, num_predict=4096))
if "c" in which:
    img = olib.b64(os.path.join(vision_fx.D, "v4_wrong_text.png"))
    shot_tool = [{"type": "function", "function": {"name": "screenshot", "description": "Take a screenshot of the page under test.",
                  "parameters": {"type": "object", "properties": {"url": {"type": "string"}}, "required": ["url"]}}}]
    base = [{"role": "user", "content": "Take a screenshot of http://localhost:8080/report and tell me the exact heading text and the Churned value."},
            {"role": "assistant", "content": "", "tool_calls": [{"function": {"name": "screenshot", "arguments": {"url": "http://localhost:8080/report"}}}]}]
    variants = {
        "c_tool_msg_with_images": base + [{"role": "tool", "tool_name": "screenshot", "content": "screenshot attached", "images": [img]}],
        "c_tool_msg_no_image_control": base + [{"role": "tool", "tool_name": "screenshot", "content": "screenshot attached"}],
        "c_user_msg_with_image_control": base + [{"role": "tool", "tool_name": "screenshot", "content": "screenshot follows in next message"},
                                                   {"role": "user", "content": "(screenshot)", "images": [img]}],
    }
    for item, msgs in variants.items():
        for run, t, s in [("s11", 0.6, 11), ("t0", 0.0, 0)]:
            show(olib.chat(model, msgs, probe="wire", item=item, run=run, temperature=t, seed=s,
                           tools=shot_tool, raw_keep=True, num_predict=2048))
