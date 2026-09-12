# frozen_string_literal: true

# Loads the vendored HTTP transport (forked from ruby_llm 1.16.0, commit
# 2cf34b9 -- see VENDOR.md) in dependency order. Upstream relies on zeitwerk
# autoloading, so its own files carry no `require`s for sibling classes; this
# file is the one place that order is spelled out. `require "lain/provider/http"`
# is the self-contained subject every spec under spec/lain/provider/http/
# requires, per CLAUDE.md's "each spec requires its own subject."
require_relative "http/error"
require_relative "http/error_middleware"
require_relative "http/configuration"
require_relative "http/logging/sink_logger"
require_relative "http/connection"
require_relative "http/utils"
require_relative "http/tokens"
require_relative "http/thinking"
require_relative "http/tool_call"
require_relative "http/content"
require_relative "http/message"
require_relative "http/chunk"
require_relative "http/stream_accumulator"
require_relative "http/streaming"
require_relative "http/provider"
require_relative "http/providers/anthropic"
