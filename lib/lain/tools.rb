# frozen_string_literal: true

module Lain
  # Concrete tool implementations. {Lain::Tool} is the abstract shape; each
  # class here is a capability an Agent's {Lain::Toolset} can be handed. Tools
  # are capabilities, not permissions -- the tier each one sits at, and where
  # the security boundary really is, is CLAUDE.md's "secret boundary" rule.
  module Tools
  end
end

require_relative "tools/read_file"
require_relative "tools/list_files"
require_relative "tools/glob"
require_relative "tools/grep"
require_relative "tools/memory_read"
require_relative "tools/memory_write"
require_relative "tools/improvement_write"
require_relative "tools/edit_file"
require_relative "tools/write_file"
require_relative "tools/todo_write"
require_relative "tools/bash"
require_relative "tools/subagent"
require_relative "tools/ask_human"
require_relative "tools/tool_search"
require_relative "tools/web_fetch"
require_relative "tools/web_fetch/readable"
require_relative "tools/web_search"
require_relative "tools/run_skill"
require_relative "tools/ast_dump"
require_relative "tools/test_pattern"
require_relative "tools/ast_search"
require_relative "tools/file_symbols"
require_relative "tools/request_review"
require_relative "tools/session_usage"
