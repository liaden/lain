# frozen_string_literal: true

module Lain
  # The initial heap sizes every lain process starts with (factor 0.75 of the booted heap, measured).
  # Plain Ruby with no requires: bin/install-shim loads this file alone under a bare ruby to write
  # the shim's exports, so the shim and the panes and daemon read one constant.
  module HeapEnv
    VALUES = {
      "RUBY_GC_HEAP_0_INIT_SLOTS" => "300000",
      "RUBY_GC_HEAP_1_INIT_SLOTS" => "150000",
      "RUBY_GC_HEAP_2_INIT_SLOTS" => "75000"
    }.freeze

    # @param env [#to_h] the launching environment
    # @return [Hash{String => String}] env with the defaults beneath it, a set value winning
    def self.over(env)
      VALUES.merge(env.to_h) { |_, default, given| given.to_s.strip.empty? ? default : given }
    end
  end
end
