# frozen_string_literal: true

module Lain
  # The public API for wrapping work, in the Rack / Sidekiq / Faraday idiom: a
  # middleware is anything answering `#call(env) { |env| ... }`, transforming the
  # environment on the way in, invoking the downstream via the block, and
  # transforming the result on the way out.
  #
  # The reason this shape recurs across the project (Faraday, model, tool, turn,
  # repl) is a single algebraic fact: middleware forms a MONOID under composition.
  # `>>` nests two middlewares; nesting is associative -- `(a >> b) >> c` and
  # `a >> (b >> c)` wrap the downstream in exactly the same order -- and
  # {Identity} is a pass-through unit, `id >> a == a >> id == a`. The law is not
  # decoration: a composition operator that were not associative would make the
  # meaning of a stack depend on how it happened to be grouped, which is precisely
  # the Rack ordering footgun. {Stack} makes the order inspectable and mutable so
  # the footgun is visible, and the monoid law (property-tested) guarantees
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

    # Two middlewares nested into one. `outer` wraps `inner` wraps the eventual
    # downstream app. Associativity falls out of this being plain function
    # nesting: however you group the `>>`s, the resulting nesting order is the
    # same, so there is only one behavior to observe.
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

      def call(env, &app)
        downstream(env, &app)
      end

      protected

      # Invoke the downstream, or act as the identity when there is none.
      #
      # Subclasses must call this rather than `yield`. A bare `yield` in a
      # middleware raises LocalJumpError the moment anyone calls it outside a
      # stack -- and no RuboCop cop can catch that statically, because it cannot
      # prove whether a caller passes a block. Routing every subclass through one
      # total helper makes the pass-through structural: impossible to forget
      # rather than merely remembered.
      def downstream(env, &app)
        app ? app.call(env) : env
      end
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
      # -- the Sidekiq convention, so "put approval before timeout" reads as
      # `insert_before(Timeout, approval)`.
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

    # Records that an env passed through, before and after the downstream ran.
    #
    # It writes to an INJECTED sink -- never to stdout/stderr. That is the whole
    # point: output discipline forbids terminal writes outside the frontend, and a
    # log line interleaved into the NDJSON journal would corrupt the experiment
    # record. Pass a {Lain::Sink} (anything answering `#puts`); to log onto a
    # {Lain::Channel}, wrap it in a {Lain::Sink::IOAdapter} so each line becomes
    # an attributed event rather than loose bytes.
    class Logging < Base
      # A compact, side-effect-free view of an env. Defaults to its sorted keys,
      # so logging a huge tool payload does not dump the payload.
      # Duck on `to_h`, not `is_a?(Hash)`: since the Stack boundary wraps the env
      # into an {Env}, a middleware in a real stack is handed the whole value, not
      # a bare Hash -- but a hand-rolled non-hash env (a bare Symbol in a probe)
      # still degrades to its class name rather than raising.
      DEFAULT_FORMATTER = lambda do |env|
        env.respond_to?(:to_h) ? env.to_h.keys.map(&:to_s).sort.join(",") : env.class.name
      end

      # @param sink [#puts] where log lines go (a {Lain::Sink}, not the terminal)
      # @param label [String] prefix identifying which stack is logging
      # @param formatter [#call] env -> String, kept cheap and pure
      def initialize(sink:, label: "middleware", formatter: DEFAULT_FORMATTER)
        @sink = sink
        @label = label.to_s
        @formatter = formatter
        super()
        freeze
      end

      def call(env, &app)
        @sink.puts("#{@label} > #{@formatter.call(env)}")
        result = downstream(env, &app)
        @sink.puts("#{@label} < #{@formatter.call(result)}")
        result
      end
    end

    # Bounds how long the downstream is allowed to take.
    #
    # It does NOT preempt. Preemption needs a concurrency model -- a watchdog
    # thread or fiber to interrupt a blocked call -- and that model is deliberately
    # deferred (see the plan's "Concurrency model"); writing one here would bake in
    # a decision the bench is meant to make later, and violate the no-threads
    # constraint. So Timeout does two honest things instead: it publishes a
    # monotonic `env[:deadline]` that a cooperative downstream (e.g. a tool
    # polling for cancellation) can honor, and it measures elapsed time at the
    # boundary, raising {Exceeded} if the work overran. A truly interrupting
    # Timeout lands with the concurrency model; until then this bounds what it can
    # bound without pretending to bound what it cannot.
    class Timeout < Base
      class Exceeded < Error; end

      # The env key under which the absolute monotonic deadline is published.
      DEADLINE_KEY = :deadline

      # @param seconds [Numeric] the budget (> 0)
      # @param clock [#call] monotonic time source, injectable for tests
      def initialize(seconds:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        raise ArgumentError, "seconds must be a positive Numeric, got #{seconds.inspect}" unless positive?(seconds)

        @seconds = seconds
        @clock = clock
        super()
        freeze
      end

      def call(env, &app)
        started = @clock.call
        deadline = started + @seconds
        # Duck on `merge` rather than `is_a?(Hash)`: the Stack boundary hands us an
        # {Env}, which merges just like a Hash; a non-hash env passes through.
        downstream_env = env.respond_to?(:merge) ? env.merge(DEADLINE_KEY => deadline) : env

        result = downstream(downstream_env, &app)

        elapsed = @clock.call - started
        raise Exceeded, "downstream exceeded #{@seconds}s budget (took #{elapsed.round(3)}s)" if elapsed > @seconds

        result
      end

      private

      def positive?(seconds)
        seconds.is_a?(Numeric) && seconds.positive?
      end
    end
  end
end

require_relative "middleware/env"
require_relative "middleware/journal_requests"
require_relative "middleware/refuse_secret_writes"
