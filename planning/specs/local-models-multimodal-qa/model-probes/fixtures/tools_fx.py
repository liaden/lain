TOOLS = [
    {"type": "function", "function": {"name": "read_file", "description": "Read a file from the repository.",
     "parameters": {"type": "object", "properties": {"path": {"type": "string", "description": "Repo-relative path"}}, "required": ["path"]}}},
    {"type": "function", "function": {"name": "edit_file", "description": "Replace exactly one occurrence of old_string with new_string in a file. old_string must match the file byte-for-byte, including indentation.",
     "parameters": {"type": "object", "properties": {"path": {"type": "string"}, "old_string": {"type": "string"}, "new_string": {"type": "string"}}, "required": ["path", "old_string", "new_string"]}}},
    {"type": "function", "function": {"name": "run_command", "description": "Run a shell command from the repository root.",
     "parameters": {"type": "object", "properties": {"cmd": {"type": "string"}}, "required": ["cmd"]}}},
    {"type": "function", "function": {"name": "grep", "description": "Search file contents with a regular expression.",
     "parameters": {"type": "object", "properties": {"pattern": {"type": "string"}, "path": {"type": "string", "description": "Directory or file to search"}}, "required": ["pattern", "path"]}}},
]

SYSTEM = """You are a coding agent working in a small Ruby repository. Use the provided tools to act; do not describe what you would do. Make exactly one tool call per reply.

Repository tree:
  README.md
  Gemfile
  config/app.settings.yml
  lib/core/Config_Loader.rb
  lib/util/str_helpers.rb
  lib/widgets/frobnicator.rb
  lib/widgets/frobnicator_v2.rb
  lib/widgets/frobnicatorV3_draft.rb
  scripts/deploy-prod_2.sh
  spec/widgets/frobnicator_v2_spec.rb
  spec/util/str_helpers_spec.rb
"""

FROB_V2 = '''# frozen_string_literal: true

module Widgets
  class FrobnicatorV2
    DEFAULTS = {
      retries:   3,
      backoff_s: 0.25,
      jitter:    true,
    }.freeze

    def initialize(opts = {})
      @opts = DEFAULTS.merge(opts)
    end

    def frob!(target)
      attempts = 0
      begin
        attempts += 1
        target.poke
      rescue Timeout::Error
        retry if attempts < @opts[:retries]
        raise
      end
    end
  end
end
'''

STR_HELPERS = '''module Util
  module StrHelpers
    module_function

    # Collapse runs of whitespace; callers recieve a new frozen String.
    def normalize_whitespace(s)
\treturn "" if s.nil?
\ts.gsub(/\\s+/, " ").strip.freeze
    end
  end
end
'''

# each: id, user prompt, expected tool, checker args
TASKS = [
    {"id": "read_v2", "prompt": "Show me the contents of the v2 frobnicator widget.",
     "tool": "read_file", "path": "lib/widgets/frobnicator_v2.rb"},
    {"id": "read_loader", "prompt": "Open the config loader under lib/core.",
     "tool": "read_file", "path": "lib/core/Config_Loader.rb"},
    {"id": "read_v3draft", "prompt": "Read the V3 draft of the frobnicator.",
     "tool": "read_file", "path": "lib/widgets/frobnicatorV3_draft.rb"},
    {"id": "run_spec", "prompt": "Run the RSpec file for the v2 frobnicator.",
     "tool": "run_command", "cmd_contains": "spec/widgets/frobnicator_v2_spec.rb"},
    {"id": "run_deploy", "prompt": "Run the prod deploy script with --dry-run.",
     "tool": "run_command", "cmd_contains": "scripts/deploy-prod_2.sh", "cmd_contains2": "--dry-run"},
    {"id": "grep_norm", "prompt": "Find where normalize_whitespace is defined, searching only lib/util.",
     "tool": "grep", "pattern_contains": "normalize_whitespace", "path_prefix": "lib/util"},
    {"id": "edit_retries", "prompt": "Here is lib/widgets/frobnicator_v2.rb:\n```ruby\n" + FROB_V2 + "```\nChange the default retry count from 3 to 5. Edit the file now.",
     "tool": "edit_file", "path": "lib/widgets/frobnicator_v2.rb", "file": FROB_V2, "new_contains": "5", "old_must_contain": "3"},
    {"id": "edit_typo_tabs", "prompt": "Here is lib/util/str_helpers.rb (note: the method body is indented with TAB characters):\n```ruby\n" + STR_HELPERS + "```\nFix the spelling mistake 'recieve' in the comment. Edit the file now.",
     "tool": "edit_file", "path": "lib/util/str_helpers.rb", "file": STR_HELPERS, "new_contains": "receive", "old_must_contain": "recieve"},
]


def score(task, rec):
    """Return dict of booleans for a single response."""
    tc = rec.get("tool_calls") or []
    out = {"called": bool(tc), "valid_args": False, "right_tool": False, "exact_path": False, "edit_ok": None,
           "prose_only": not tc}
    if not tc:
        return out
    fn = tc[0].get("function", {})
    args = fn.get("arguments")
    if isinstance(args, str):
        try:
            import json; args = json.loads(args)
        except Exception:
            args = None
    tool = next((t for t in TOOLS if t["function"]["name"] == fn.get("name")), None)
    if isinstance(args, dict) and tool:
        req = tool["function"]["parameters"]["required"]
        props = tool["function"]["parameters"]["properties"]
        out["valid_args"] = all(k in args and isinstance(args[k], str) for k in req) and all(k in props for k in args)
    out["right_tool"] = fn.get("name") == task["tool"]
    if not (out["right_tool"] and isinstance(args, dict)):
        return out
    t = task["tool"]
    if t == "read_file":
        out["exact_path"] = args.get("path") == task["path"]
    elif t == "run_command":
        c = args.get("cmd", "")
        out["exact_path"] = task["cmd_contains"] in c and task.get("cmd_contains2", "") in c
    elif t == "grep":
        out["exact_path"] = task["pattern_contains"] in args.get("pattern", "") and str(args.get("path", "")).lstrip("./").startswith(task["path_prefix"])
    elif t == "edit_file":
        out["exact_path"] = args.get("path") == task["path"]
        old, new = args.get("old_string", ""), args.get("new_string", "")
        out["edit_ok"] = (bool(old) and old in task["file"] and task["file"].count(old) == 1
                          and task["old_must_contain"] in old and task["new_contains"] in new)
    return out
