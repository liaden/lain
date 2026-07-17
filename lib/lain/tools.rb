# frozen_string_literal: true

module Lain
  # Concrete tool implementations. {Lain::Tool} is the abstract shape; each
  # class here is a capability an Agent's {Lain::Toolset} can be handed. See
  # the plan's "Tool tiers, and where the security boundary is" for why each
  # one sits at the tier it does.
  module Tools
  end
end

require_relative "tools/read_file"
require_relative "tools/list_files"
require_relative "tools/glob"
require_relative "tools/grep"
require_relative "tools/memory_read"
require_relative "tools/memory_write"
require_relative "tools/edit_file"
require_relative "tools/write_file"
require_relative "tools/todo_write"
require_relative "tools/bash"
require_relative "tools/subagent"
require_relative "tools/ask_human"
require_relative "tools/web_fetch"
require_relative "tools/web_search"
