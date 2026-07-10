# frozen_string_literal: true

require_relative "error"

module Lain
  # The vocabulary of what an agent loop *performs*, as frozen value objects.
  #
  # Effects exist so that "decide what to do" and "do it" are separable. The loop
  # builds an Effect (pure data: no IO, no side effect) and hands it to a
  # {Lain::Handler}; the handler is the only thing that touches the world. That
  # split is what makes deterministic replay a *recorded handler* rather than a
  # second code path, and what lets an approval or timeout wrap an intention
  # before it is ever carried out.
  #
  # Effects are deliberately few. Every one is a `Data` value, so two effects
  # with equal fields are equal and nothing about one can mutate after it is
  # built -- safe to journal, compare, and share.
  module Effect
    # An intended tool invocation. `input` is a parsed object (a Hash), never a
    # serialized JSON string: correctness gate 5 forbids string-matching against
    # wire JSON, so the Provider has already parsed `tool_use.input` before it
    # reaches here. `tool_use_id` is retained so the eventual `tool_result` can
    # carry the matching id (correctness gate 4).
    ToolCall = Data.define(:tool_use_id, :name, :input) do
      def initialize(tool_use_id:, name:, input:)
        super(tool_use_id: -tool_use_id.to_s, name: -name.to_s, input: input)
      end
    end

    # An intended model round trip. Holds a provider-neutral {Lain::Request}, so
    # the same effect can be replayed against a different provider or re-rendered
    # under a different context without the loop knowing which.
    ModelCall = Data.define(:request)

    # A gate: "this inner effect must be approved before it is performed."
    #
    # There are two routes into {Lain::Handler::Approving}, and this wrapper is
    # only one of them. Most gating is tier-based and needs no wrapper: a tool
    # answers {Lain::Tool#requires_approval?} for itself (a free-form `bash` is
    # gated; a structured `read_file` is not), and Approving reads that answer
    # off the very tool it will dispatch. This wrapper is the second route -- it
    # marks ONE specific call for approval regardless of the tool's own tier,
    # for when something upstream decides a particular invocation needs a human
    # even though the tool would normally run unattended. Wrapping keeps that
    # per-call decision in the data, where Approving pattern-matches it rather
    # than infers it.
    Approval = Data.define(:effect)
  end
end
