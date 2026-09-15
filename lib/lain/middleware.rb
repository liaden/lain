# frozen_string_literal: true

module Lain
  # The public API for wrapping work, in the Rack / Sidekiq / Faraday idiom: a
  # middleware is anything answering `#call(env) { |env| ... }`, transforming the
  # environment on the way in, invoking the downstream via the block, and
  # transforming the result on the way out.
  #
  # Middlewares compose by membership in a {Stack}, never by a binary operator
  # nesting two of them into an opaque pair. Ordering is precisely the Rack
  # footgun, so the one composition mechanism is the one whose order a reader
  # can inspect and adjust.
  module Middleware
    # The leaf base: a pass-through. Subclasses override {#call} and invoke the
    # downstream via {#downstream}.
    class Base
      def call(env, &app)
        downstream(env, &app)
      end

      protected

      # Invoke the downstream, or act as the identity when there is none.
      #
      # Subclasses must call this rather than `yield`. A bare `yield` in a
      # middleware raises LocalJumpError the moment anyone calls it outside a
      # stack, and no cop can catch that statically -- it cannot prove whether a
      # caller passes a block. One total helper makes the pass-through
      # structural rather than merely remembered.
      def downstream(env, &app)
        app ? yield(env) : env
      end
    end

    # An ordered, INSPECTABLE, MUTABLE list of middlewares that is itself a
    # middleware. Ordering is Rack's classic footgun, so unlike the frozen value
    # objects elsewhere in Lain this one is deliberately Sidekiq-style: you can
    # read the order (`#to_a`) and adjust it (`#use`, `#insert_before`,
    # `#insert_after`) rather than having to reconstruct the whole chain to move
    # one entry.
    class Stack
      def initialize(middlewares = [])
        @middlewares = middlewares.dup
      end

      # Append a middleware to the innermost position (runs last on the way in).
      def use(middleware)
        @middlewares.push(middleware)
        self
      end

      # Insert `middleware` just before `target`. `target` is matched by class
      # (the first member that `is_a?` it) or, if given an instance, by identity
      # -- the Sidekiq convention, so "put approval before refuse_secret_writes"
      # reads as `insert_before(RefuseSecretWrites, approval)`.
      def insert_before(target, middleware)
        @middlewares.insert(index_of!(target), middleware)
        self
      end

      # Insert `middleware` just after `target` (see {#insert_before} for how
      # `target` is matched).
      def insert_after(target, middleware)
        @middlewares.insert(index_of!(target) + 1, middleware)
        self
      end

      # The middlewares in order, as a copy: inspecting the stack must never let a
      # caller mutate it by side effect.
      def to_a
        @middlewares.dup
      end

      def size
        @middlewares.size
      end

      def empty?
        @middlewares.empty?
      end

      # Run `env` through every middleware, terminating in the given app (or a
      # pass-through if none). Built by folding from the inside out so the first
      # member is outermost -- the reading order matches the execution order.
      #
      # The input is wrapped into an {Env} ONCE, here at the boundary, so every
      # caller keeps passing a plain hash while every middleware downstream sees
      # the whole value. `wrap` is idempotent, so a Stack nested in a Stack does
      # not double-wrap.
      def call(env, &app)
        wrapped = Env.wrap(env)
        terminal = app || ->(inner_env) { inner_env }
        chain = @middlewares.reverse.reduce(terminal) do |downstream, middleware|
          ->(inner_env) { middleware.call(inner_env, &downstream) }
        end
        chain.call(wrapped)
      end

      private

      def index_of!(target)
        index = @middlewares.index { |member| match?(member, target) }
        raise ArgumentError, "no middleware matching #{target.inspect} in this stack" unless index

        index
      end

      def match?(member, target)
        target.is_a?(Module) ? member.is_a?(target) : member.equal?(target)
      end
    end
  end
end

require_relative "middleware/env"
require_relative "middleware/gate"
require_relative "middleware/guard_test_layout"
require_relative "middleware/journal_requests"
require_relative "middleware/journal_turns"
require_relative "middleware/redact_secret_reads"
require_relative "middleware/refuse_secret_writes"
require_relative "middleware/refuse_unpermitted"
require_relative "middleware/request_budget"
require_relative "middleware/resolve_window"
require_relative "middleware/sensitivity"
require_relative "middleware/skill_dispatch"
require_relative "middleware/withhold_automatic_output"
require_relative "middleware/withhold_secret_paths"
