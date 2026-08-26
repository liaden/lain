# frozen_string_literal: true

module Lain
  # The vocabulary of what an agent loop *performs*, as frozen value objects.
  #
  # Effects separate "decide what to do" from "do it": the loop builds an Effect
  # (pure data, no IO) and a {Lain::Effect::Handler} is the only thing that
  # touches the world. That split makes deterministic replay a *recorded
  # handler* rather than a second code path, and lets an approval or a timeout
  # wrap an intention before it is ever carried out.
  module Effect
    # Kind predicates, total over the vocabulary and defaulting to false, so no
    # reading site needs a `respond_to?` guard or a `rescue`. Each concrete
    # effect overrides only its own; every other kind inherits the honest false.
    module Kind
      def tool_call? = false
      def approval? = false
    end

    # `input` is a parsed Hash, never a serialized JSON string: nothing above
    # the Provider may string-match against wire JSON, so `tool_use.input` is
    # already parsed by the time it reaches here. `tool_use_id` is retained so
    # the eventual `tool_result` can carry the matching id.
    ToolCall = Data.define(:tool_use_id, :name, :input) do
      include Kind

      def initialize(tool_use_id:, name:, input:)
        super(tool_use_id: -tool_use_id.to_s, name: -name.to_s, input:)
      end

      def tool_call? = true
    end

    # Holds a provider-neutral {Lain::Request}, so the same effect replays
    # against a different provider without the loop knowing which.
    ModelCall = Data.define(:request) do
      include Kind
    end

    # The SECOND route into {Lain::Effect::Handler::Gate}. Most gating is
    # tier-based and needs no wrapper -- a tool answers
    # {Lain::Tool#requires_approval?} for itself. This marks ONE call for
    # approval regardless of the tool's own tier, keeping that per-call decision
    # in the data, where Gate pattern-matches it rather than infers it.
    Approval = Data.define(:effect) do
      include Kind

      def approval? = true
    end
  end
end

# Handler subclasses reopen Effect::Handler, so the class body must load first.
require_relative "effect/handler"
