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
  #
  # A member of an agent's TURN stack answers one message more, `#settle(timeline)`,
  # sent as each turn commits and before any tool that turn called runs.
  # {Base} answers it with nothing to do, and {.settles!} refuses a turn stack
  # holding a member that cannot, where the stack is handed to the agent.
  module Middleware
    # A turn-stack member that does not answer `#settle`.
    class CannotSettle < Error; end

    # @param stack [#call] a turn stack, or a lone member
    # @return [#call] `stack`, every member of it answering `#settle`
    # @raise [CannotSettle] naming each member that does not
    def self.settles!(stack)
      unsettled = unsettled(stack)
      return stack if unsettled.empty?

      raise CannotSettle, "turn middleware must answer #settle(timeline), which every turn sends before its " \
                          "tools run; #{unsettled.map(&:inspect).join(", ")} answer#{"s" if unsettled.one?} " \
                          "only #call. Subclass Lain::Middleware::Base, whose #settle does nothing."
    end

    def self.unsettled(member)
      return member.to_a.flat_map { |inner| unsettled(inner) } if member.is_a?(Stack)

      member.respond_to?(:settle) ? [] : [member]
    end
    private_class_method :unsettled
    # The leaf base: a pass-through. Subclasses override {#call} and invoke the
    # downstream via {#downstream}.
    class Base
      def call(env, &app)
        downstream(env, &app)
      end

      # The turn phase's one message besides {#call}: the agent has just
      # committed a turn and hands over the timeline holding it, before any tool
      # that turn called can run. A member with a record to keep writes it here;
      # everything else has nothing to do.
      def settle(_timeline) = self

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

      # {Base#settle}, handed to every member in order.
      def settle(timeline)
        @middlewares.each { |middleware| middleware.settle(timeline) }
        self
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
