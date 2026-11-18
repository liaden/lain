# frozen_string_literal: true

module RuboCop
  module Cop
    module Lain
      # A spec file that names an anthropic SDK constant must `require "anthropic"`.
      #
      # The gem is a test-only dependency loaded lazily, because spec/support loads in
      # every parallel worker and the gem is 33.6MB. A file naming an SDK constant before
      # any oracle provider built one fails in 2 ways: `Anthropic::Errors::X.new` raises
      # NameError, but only in a worker that happened to run it first; and
      # `instance_double("Anthropic::BedrockMantleClient")` is SILENT, because RSpec
      # verifies a doubled constant only if it is defined, so an undefined one degrades to
      # a double that accepts any message. The cop reads strings as well as constants for
      # that reason. Lain's own `Provider::Anthropic` is not the SDK and is not matched.
      #
      # @example
      #   # bad
      #   instance_double("Anthropic::BedrockMantleClient")
      #
      #   # good
      #   require "anthropic"
      #   instance_double("Anthropic::BedrockMantleClient")
      class SdkRequire < Base
        MSG = "`%<name>s` is the anthropic SDK, which loads lazily, so this file sees it only if an " \
              "earlier example built an oracle provider (and a string-named double verifies nothing " \
              "without it). Add `require \"anthropic\"` to this file."

        SDK_NAMES = %w[Errors Client BedrockMantleClient Resources Models Internal].freeze
        SDK_STRING = /(?<![:\w])(?:::)?Anthropic::(?:#{SDK_NAMES.join("|")})\b/

        # The first reference is only known after the whole file is read.
        def on_new_investigation
          ast = processed_source.ast
          return if ast.nil? || requires_gem?(ast)

          reference = sdk_references(ast).min_by { |node| node.source_range.begin_pos }
          add_offense(reference, message: format(MSG, name: reference.source.delete("\"'"))) if reference
        end

        private

        def requires_gem?(ast) = ast.each_node(:send).any? { |send| require_anthropic?(send) }

        def require_anthropic?(send)
          send.receiver.nil? && send.method?(:require) && send.first_argument&.str_type? &&
            send.first_argument.value == "anthropic"
        end

        def sdk_references(ast) = ast.each_node(:const, :str).select { |node| sdk?(node) }

        def sdk?(node)
          node.const_type? ? sdk_constant?(node) : sdk_string?(node.value)
        end

        # Bytes, because a literal holding invalid UTF-8 makes a character regexp raise.
        def sdk_string?(value) = value.b.match?(SDK_STRING)

        def sdk_constant?(node)
          SDK_NAMES.include?(node.short_name.to_s) && top_level_anthropic?(node.namespace)
        end

        def top_level_anthropic?(namespace)
          namespace&.const_type? && namespace.short_name == :Anthropic &&
            [nil, :cbase].include?(namespace.namespace&.type)
        end
      end
    end
  end
end
