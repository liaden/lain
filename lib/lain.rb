# frozen_string_literal: true

# THE load-order manifest. Internal requires live here and in each unit's own
# index file (foo.rb requires foo/**), never in leaf files -- so the dependency
# order below is the one place a cycle would have to show itself. Entries are
# in topological order of the real require graph: a unit may reference, at load
# time, only constants from lines above it. New files join their unit's index;
# new units join this list where their dependencies place them.
require_relative "lain/version"
require_relative "lain/error"
require_relative "lain/paths"
require_relative "lain/canonical"
require_relative "lain/content_addressed"
require_relative "lain/prompt"
require_relative "lain/freezable"
require_relative "lain/guard"
require_relative "lain/telemetry"
require_relative "lain/channel"
require_relative "lain/request"
require_relative "lain/workspace"
require_relative "lain/context"
require_relative "lain/session"
require_relative "lain/tool"
require_relative "lain/effect"
require_relative "lain/journal"
require_relative "lain/toolset"
require_relative "lain/role"
require_relative "lain/middleware"
require_relative "lain/usage"
require_relative "lain/response"
require_relative "lain/store"
require_relative "lain/event"
require_relative "lain/timeline"
require_relative "lain/session_record"
require_relative "lain/agent"
require_relative "lain/promise"
require_relative "lain/approval"
require_relative "lain/capability"
require_relative "lain/price_book"
require_relative "lain/ledger"
require_relative "lain/memory"
require_relative "lain/sink"
require_relative "lain/provider"
require_relative "lain/cli"
require_relative "lain/embedder"
require_relative "lain/compare"
require_relative "lain/bench"
require_relative "lain/frontend"
require_relative "lain/grader"
require_relative "lain/tools"

# The compiled Rust extension. Defines Lain.hello and Lain::Ext.init_tracing.
require "lain/lain"

# An agent harness built as a study bench: context strategies, tool designs, and
# orchestration tactics are swappable, observable, and comparable.
module Lain
end
