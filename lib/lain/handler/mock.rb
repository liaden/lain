# frozen_string_literal: true

require_relative "../effect"
require_relative "../tool"

module Lain
  class Handler
    # Interprets tool-call effects with canned answers instead of running
    # anything. It exists so specs (and dry replay) can drive the loop without a
    # live tool, a subprocess, or the network -- the same effects, deterministically
    # resolved.
    #
    # A canned result is looked up by tool name first, then by `tool_use_id`, so a
    # spec can pin either "every call to `read_file` returns X" or "this one
    # specific call returns X". A block, if given, wins over the map and receives
    # the whole effect, for results that depend on the input. Plain Strings and
    # Arrays are coerced to a successful {Tool::Result}, so the common case stays
    # terse.
    class Mock < Handler
      # @param results [Hash{String=>Tool::Result,String,Array}] name/id => canned answer
      # @param default [Tool::Result, String, Array, nil] used when nothing matches
      # @param inner [Lain::Handler, nil] fallback for other effect kinds
      # @yield [effect, context] optional resolver taking precedence over `results`
      def initialize(results: {}, default: nil, inner: nil, &block)
        super(inner: inner)
        @results = stringify(results)
        @default = default
        @block = block
      end

      def handles?(effect)
        effect.is_a?(Effect::ToolCall) || effect.is_a?(Effect::Approval)
      end

      protected

      def perform(effect, context)
        return call(effect.effect, context) if effect.is_a?(Effect::Approval)

        coerce(canned_for(effect, context))
      end

      private

      def canned_for(effect, context)
        return @block.call(effect, context) if @block
        return @results.fetch(effect.name) if @results.key?(effect.name)
        return @results.fetch(effect.tool_use_id) if @results.key?(effect.tool_use_id)
        return @default unless @default.nil?

        Tool::Result.error("no canned result for tool #{effect.name.inspect}")
      end

      def coerce(value)
        return value if value.is_a?(Tool::Result)

        Tool::Result.ok(value)
      end

      def stringify(results)
        results.transform_keys(&:to_s)
      end
    end
  end
end
