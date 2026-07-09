# frozen_string_literal: true

require_relative "lain/version"
require_relative "lain/error"
require_relative "lain/canonical"

# The compiled Rust extension. Defines Lain.hello and Lain::Ext.init_tracing.
require "lain/lain"

# An agent harness built as a study bench: context strategies, tool designs, and
# orchestration tactics are swappable, observable, and comparable.
module Lain
end
