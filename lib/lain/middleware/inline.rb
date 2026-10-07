# frozen_string_literal: true

module Lain
  module Middleware
    # A block as a middleware: the block receives `env` and the downstream as its
    # own block, so a user file can write a member without naming a class.
    class Inline < Base
      # @param block [Proc] a `|env, &downstream|` proc
      def initialize(block)
        super()
        @block = block
      end

      def call(env, &app)
        @block.call(env) { |inner| downstream(inner, &app) }
      end
    end
  end
end
