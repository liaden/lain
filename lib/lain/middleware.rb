# frozen_string_literal: true

module Lain
  # The public API for wrapping work, in the Rack / Sidekiq / Faraday idiom: a
  # middleware is anything answering `#call(env) { |env| ... }`, transforming the
  # environment on the way in, invoking the downstream via the block, and
  # transforming the result on the way out.
  #
  # The shape recurs across the project because middleware forms a MONOID under
  # composition: `>>` is associative and {Identity} is a pass-through unit. The
  # law is not decoration -- a non-associative composition operator would make
  # the meaning of a stack depend on how it happened to be grouped, which is
  # precisely the Rack ordering footgun. {Stack} makes the order inspectable and
  # mutable so the footgun is visible, and the law (property-tested) guarantees
  # grouping never changes behavior.
  module Middleware
    # The composition operator, mixed into everything that behaves as a
    # middleware. `a >> b` yields a new middleware that runs `a` outermost and
    # `b` just inside it.
    module Composable
      def >>(other)
        Composed.new(self, other)
      end
    end

    # Two middlewares nested into one. Associativity falls out of this being
    # plain function nesting: however you group the `>>`s, the resulting nesting
    # order is the same, so there is only one behavior to observe.
    class Composed
      include Composable

      def initialize(outer, inner)
        @outer = outer
        @inner = inner
        freeze
      end

      def call(env, &app)
        @outer.call(env) { |inner_env| @inner.call(inner_env, &app) }
      end
    end

    # The leaf base: a pass-through. Subclasses override {#call} and invoke the
    # downstream via {#downstream}. On its own it is the monoid identity's
    # behavior, which is why {Identity} is just an instance of it.
    class Base
      include Composable
      include Algebra::Monoid

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

      # {Identity} is an instance built after this class body closes (below),
      # so the unit can only be named lazily -- {Context::Combinator}'s same
      # move. Declared on {Base} only, per the {Context::Combinator} precedent:
      # `registry.about(Composed)` answers `[]` because `>>` and the monoid it
      # forms both belong to the base capability every middleware shares, not
      # to the one subclass that happens to implement composition.
      monoid on: :>>, identity: Algebra.later { Middleware::Identity }
    end

    # The monoid unit: composing it changes nothing. Having a real value for
    # "no-op middleware" is what lets a fold over an empty middleware list, or an
    # optional middleware slot, stay total instead of special-casing nil.
    Identity = Base.new

    # An ordered, INSPECTABLE, MUTABLE list of middlewares that is itself a
    # middleware. Ordering is Rack's classic footgun, so unlike the frozen value
    # objects elsewhere in Lain this one is deliberately Sidekiq-style: you can
    # read the order (`#to_a`) and adjust it (`#use`, `#insert_before`,
    # `#insert_after`) rather than having to reconstruct the whole chain to move
    # one entry.
    class Stack
      include Composable

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
require_relative "middleware/guard_test_layout"
require_relative "middleware/journal_requests"
require_relative "middleware/journal_turns"
require_relative "middleware/redact_secret_reads"
require_relative "middleware/refuse_secret_writes"
require_relative "middleware/resolve_window"
require_relative "middleware/skill_dispatch"
require_relative "middleware/withhold_secret_paths"
