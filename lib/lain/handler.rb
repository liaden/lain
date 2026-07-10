# frozen_string_literal: true

require_relative "error"
require_relative "effect"
require_relative "tool"

module Lain
  # Interprets an {Lain::Effect} -- the one object permitted to touch the world.
  #
  # The loop produces pure Effect data; a Handler is the algebra that gives those
  # effects meaning. Because meaning is separated from intention, swapping the
  # handler swaps the semantics without changing the loop: {Live} dispatches a
  # tool for real, {Mock} returns a canned result, and a recorded handler would
  # replay one -- same effects, three interpretations.
  #
  # Handlers COMPOSE by decoration. Each holds an optional `inner` handler and
  # delegates any effect it does not itself handle, so a specialized handler
  # (approval, timeout, recording) can wrap a general one and only intercept the
  # effects it cares about. This is the same chain-of-responsibility shape the
  # middleware stack uses, one layer down.
  class Handler
    class UnhandledEffect < Error; end

    # @param inner [Lain::Handler, nil] fallback for effects this handler declines
    def initialize(inner: nil)
      @inner = inner
    end

    # Interpret `effect`. If this handler declines it, delegate to `inner`; if
    # there is no inner, refuse loudly rather than silently dropping an effect --
    # a dropped effect is a turn that quietly does nothing.
    def call(effect, context = nil)
      if handles?(effect)
        perform(effect, context)
      elsif @inner
        @inner.call(effect, context)
      else
        raise UnhandledEffect, "#{self.class} cannot handle #{effect.class}"
      end
    end

    # Adapt this handler into an `env -> env` app that can TERMINATE a
    # {Lain::Middleware::Stack}. The stack wraps the intention; this is the
    # bottom of the stack that finally performs it, writing the outcome back to
    # `env[:result]` so the surrounding middleware can observe it.
    def to_app
      lambda do |env|
        env.merge(result: call(env.fetch(:effect), env[:context]))
      end
    end

    # Whether this handler interprets `effect` itself (vs. delegating to inner).
    # Subclasses override; the base handles nothing, existing only to compose.
    def handles?(_effect)
      false
    end

    protected

    # The subclass's interpretation of an effect it {#handles?}. Never called for
    # an effect the handler declined.
    def perform(_effect, _context)
      raise UnhandledEffect, "#{self.class} declared it handles an effect it cannot perform"
    end
  end
end

require_relative "handler/approving"
require_relative "handler/live"
require_relative "handler/mock"
