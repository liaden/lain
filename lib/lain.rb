# frozen_string_literal: true

require_relative "lain/version"
require_relative "lain/error"
require_relative "lain/canonical"
require_relative "lain/turn"
require_relative "lain/store"
require_relative "lain/timeline"
require_relative "lain/event"
require_relative "lain/channel"
require_relative "lain/sink"
require_relative "lain/usage"
require_relative "lain/request"
require_relative "lain/response"

# The compiled Rust extension. Defines Lain.hello and Lain::Ext.init_tracing.
require "lain/lain"

# An agent harness built as a study bench: context strategies, tool designs, and
# orchestration tactics are swappable, observable, and comparable.
module Lain
end
