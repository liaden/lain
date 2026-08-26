# frozen_string_literal: true

module Lain
  module Tools
    # Tier 1 (structured): reports what THIS session has spent, in tokens.
    #
    # It exists because the defect it removes was REACHABILITY, not honesty:
    # asked for its own usage, the agent invented a metrics table -- a model
    # name it was not running, plus fabricated memory, CPU, round-trip and
    # network figures -- while `turn_usage` records carrying the true answer sat
    # in the journal it had just written. No tool could answer the question, so
    # the model answered it from nowhere.
    #
    # == Tokens, never dollars
    #
    # {Lain::Ledger} raises rather than pricing a model it has no entry for, and
    # the ollama-cloud arm has no {Lain::PriceBook} entry at all -- so a dollar
    # figure would have to be GUESSED for exactly the runs a human is most
    # likely to ask about. The description says so, because the description is
    # the lever that keeps the model from reaching for one anyway.
    #
    # == And never a turn count
    #
    # {Lain::Agent::Accounting} holds a cumulative {Lain::Usage} and the last
    # turn's context occupancy, and nothing else. `Agent#iterations` counts LOOP
    # iterations, a different quantity, so reporting it as "turns" would be a
    # wrong number in good formatting -- the failure this tool removes.
    #
    # == A RUN, not a session lifetime -- and the description says so
    #
    # Accounting starts at `Usage.zero` and nothing passes an `accounting:`, so
    # `--resume` gives a FRESH ledger over a RESUMED Timeline and everything
    # spent before the resume is invisible here. A confidently formatted
    # under-report is the same defect as a confidently formatted invention, so
    # the description says "this run" and names the exclusion out loud.
    #
    # True session-lifetime accounting across a resume needs a ledger seeded
    # from the resumed record, not a wording fix here.
    class SessionUsage < Tool
      # A named refusal rather than a Null Object, and that is the whole
      # design: the only thing a Null could answer is `Usage.zero`, which is
      # indistinguishable from the honest zero of a run that has asked nothing.
      # A silent zero is the invented-figure defect wearing this tool's clothes.
      #
      # It RAISES rather than returning an error {Tool::Result}, because an
      # unwired collaborator is a wiring defect and not a tool failing at its
      # job; {Lain::Effect::Handler} turns it into an error result for the model.
      class Unwired < Lain::Error; end

      # The four wire fields in Usage's own declaration order, then the two
      # totals it derives -- reported rather than left to the model, because an
      # arithmetic step the model takes is one it can get wrong.
      COUNTS = {
        "input" => :input_tokens,
        "output" => :output_tokens,
        "cache creation" => :cache_creation_input_tokens,
        "cache read" => :cache_read_input_tokens,
        "total input" => :total_input_tokens,
        "total" => :total_tokens
      }.freeze
      private_constant :COUNTS

      HEADER = "Usage so far this run, in tokens:"
      private_constant :HEADER

      # Addressed to the MODEL: it must say what went wrong and, above all,
      # that no number is being offered.
      UNWIRED_MESSAGE = "session_usage is not wired to a running agent, so this run's token " \
                        "usage cannot be read. No figure is available -- do not estimate one."
      private_constant :UNWIRED_MESSAGE

      # @param usage [#call] a THUNK, not a value, resolving to the live
      #   {Lain::Usage} of the run's own Agent: the Agent is built after the
      #   Toolset it is handed, so the only reference that can exist at
      #   construction is one read at CALL time.
      #
      #   Not defaulted, and nothing below coalesces a nil to
      #   {Lain::Usage.zero}: see {Unwired} for why answering zero is the one
      #   thing this must not do.
      def initialize(usage:)
        super()
        @usage = usage
      end

      def name = "session_usage"

      # A constant, not a method body: a frozen literal a method was
      # rebuilding a reference to on every schema render. The three things it
      # must never stop saying are the run scope, the resume exclusion, and
      # tokens-not-dollars.
      DESCRIPTION = "Reports THIS RUN's cumulative model token usage, read from the " \
                    "running agent's own accounting: input, output, cache-creation and " \
                    "cache-read tokens, the total billed on the way in, the grand total, " \
                    "and the prompt cache hit ratio. Scope is the current run, NOT the " \
                    "lifetime of a resumed session: a session continued with --resume " \
                    "starts a fresh ledger, so tokens spent before the resume are not " \
                    "counted here and must not be reported as if they were. Figures are " \
                    "TOKENS, never dollars -- this harness refuses to price a model it " \
                    "has no price book entry for, so no cost estimate is available and " \
                    "none should be invented. It reports no turn count, no latency and " \
                    "no memory figures; the run keeps none. Takes no arguments."
      private_constant :DESCRIPTION

      def description = DESCRIPTION

      # Audited: reads one {Lain::Usage} value off the run's {Agent::Accounting}
      # and formats it. No Session write-set mutation, no process-global state.
      def parallel_safe? = true

      protected

      def perform(_input, _invocation)
        usage = resolved
        Tool::Result.ok([HEADER, *counts(usage), ratio(usage)].join("\n"))
      end

      private

      # Two arms are refused by name: a tool built with no thunk at all, and a
      # thunk that RESOLVES to nil. The second only reaches here because the
      # wiring's thunk is written `-> { @agent&.usage }` -- without the `&.` the
      # NoMethodError is raised INSIDE the lambda and the model reads
      # `undefined method 'usage' for nil`: loud, but with no reason attached
      # and nothing telling it not to guess.
      #
      # `|| raise` and not `|| Usage.zero`: {Lain::Usage.zero} is TRUTHY, so a
      # run that has genuinely spent nothing takes the ok path and reports zero.
      # Only an absent accounting reaches the raise.
      def resolved
        raise Unwired, UNWIRED_MESSAGE if @usage.nil?

        @usage.call || raise(Unwired, UNWIRED_MESSAGE)
      end

      def counts(usage) = COUNTS.map { |label, reader| row(label, usage.public_send(reader)) }

      # The bench's first-class cache metric: a silent prompt-cache invalidator
      # shows up here as a ratio that quietly falls to zero while nothing errors.
      def ratio(usage) = row("cache hit ratio", format("%.1f%%", usage.cache_hit_ratio * 100))

      def row(label, value) = "  #{label}: #{value}"
    end
  end
end
