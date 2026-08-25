# frozen_string_literal: true

module Lain
  module Tools
    # Tier 1 (structured): reports what THIS session has spent, in tokens.
    #
    # It exists because of F77. Asked for its own usage, the agent invented a
    # metrics table -- a model name it was not running, plus fabricated memory,
    # CPU, round-trip and network figures -- while eight `turn_usage` records
    # carrying the true answer sat in the journal it had itself just written.
    # The defect was REACHABILITY, not honesty: no tool could answer the
    # question, so the model answered it from nowhere. This one makes the true
    # answer reachable, which is what makes the invented one unnecessary.
    #
    # == Tokens, never dollars
    #
    # A cost in dollars is deliberately absent. {Lain::Ledger} raises rather
    # than pricing a model it has no entry for, and the ollama-cloud arm has no
    # {Lain::PriceBook} entry at all -- so a dollar figure here would have to be
    # guessed for exactly the runs a human is most likely to ask about. That is
    # F77 with better manners. The description says so, because the description
    # is the lever that keeps the model from reaching for one anyway.
    #
    # == And never a turn count
    #
    # {Lain::Agent::Accounting} holds a cumulative {Lain::Usage} and the last
    # turn's context occupancy, and nothing else; there is no turn counter.
    # `Agent#iterations` counts LOOP iterations, which is a different quantity,
    # so reporting it as "turns" would be a wrong number in good formatting --
    # the same failure this tool removes.
    #
    # == A RUN, not a session lifetime -- and the description says so
    #
    # {Lain::Agent::Accounting} starts at `Usage.zero` (`accounting.rb:22`) and
    # neither {Lain::CLI::Wiring} nor {Lain::CLI::Wiring::AgentBuild} passes an
    # `accounting:`, so `--resume` gives a FRESH ledger over a RESUMED Timeline.
    # Everything spent before the resume is therefore invisible here.
    #
    # That gap is why the description below says "this run" rather than "this
    # session", and says out loud that a resumed session's earlier spend is
    # excluded. A confidently formatted under-report is the same defect as a
    # confidently formatted invention -- the model would present it as lifetime
    # spend for no reason other than that this tool told it to. The word follows
    # `accounting.rb:5,13`, which calls this quantity "the run's token ledger",
    # and the HUD's `session:` -> `run:` rename made for the same reason.
    #
    # True session-lifetime accounting across a resume is a separate change: it
    # needs a ledger seeded from the resumed record, not a wording fix here.
    class SessionUsage < Tool
      # What a call refuses with when this tool was built with no accounting to
      # read -- the direct-construction seams, where there is no Agent at all.
      #
      # A named refusal rather than a Null Object, and that is the whole design:
      # the only thing a Null could answer is `Usage.zero`, which is
      # indistinguishable from the honest zero of a run that has asked nothing.
      # A silent zero is the F77 defect wearing this tool's clothes, so the nil
      # is CHECKED and refused by name instead. It raises rather than returning
      # an error {Tool::Result} because an unwired collaborator is a wiring
      # defect, not a tool failing at its job -- {Lain::Effect::Handler} turns it
      # into an error result for the model, and a direct caller gets the raise.
      class Unwired < Lain::Error; end

      # The token counts, label → the {Lain::Usage} reader that answers it: the
      # four wire fields in Usage's own declaration order, then the two totals
      # it derives -- reported rather than left to the model, because an
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

      # Addressed to the MODEL, because that is who reads it: it must say what
      # went wrong and, above all, that no number is being offered. The one
      # thing a reader of this sentence must not do is guess a figure.
      UNWIRED_MESSAGE = "session_usage is not wired to a running agent, so this run's token " \
                        "usage cannot be read. No figure is available -- do not estimate one."
      private_constant :UNWIRED_MESSAGE

      # @param usage [#call] a thunk resolving to the live {Lain::Usage} of the
      #   run's own Agent. A THUNK, not a value: the Agent is built after the
      #   Toolset it is handed ({Lain::CLI::Wiring#wire_agent}), so the only
      #   reference that can exist at construction is one read at CALL time --
      #   the convention `parent:` already follows at that same seam.
      #
      #   Not defaulted, and nothing below coalesces a nil to {Lain::Usage.zero}.
      #   An instance built without a live accounting has nothing true to
      #   report, and the one thing it must not do is answer zero -- that is
      #   indistinguishable from the honest zero of a run that has asked
      #   nothing. It refuses by name instead; see {Unwired}.
      def initialize(usage:)
        super()
        @usage = usage
      end

      def name = "session_usage"

      # A constant, not a method body: it outgrew Metrics/MethodLength the
      # moment the resume caveat had to be said out loud, and the cop was right
      # -- this is a frozen literal that a method was rebuilding a reference to
      # on every schema render. The three things it must never stop saying are
      # the run scope, the resume exclusion, and tokens-not-dollars.
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

      # The one nil check in this file, and {Unwired} says why it is a check
      # rather than a Null Object. Two arms are refused by name: a tool built
      # with no thunk at all, and a thunk that RESOLVES to nil -- the second is
      # {Lain::CLI::Wiring}'s `@agent` read before #wire_agent has assigned it.
      #
      # The second arm only reaches here because that thunk is written
      # `-> { @agent&.usage }`. Without the `&.` the NoMethodError is raised
      # INSIDE the lambda and this method never runs, so the model reads
      # `undefined method 'usage' for nil` -- loud, but with no reason attached
      # and nothing telling it not to guess. That was the shipped behaviour
      # until review caught it; a comment here claimed otherwise while the
      # spec's `-> {}` stand-in was shaped differently from the real seam and
      # so could not notice. The spec's stand-in now models the shipped thunk.
      #
      # `|| raise` and not `|| Usage.zero`: {Lain::Usage.zero} is TRUTHY, so a
      # run that has genuinely spent nothing takes the ok path and reports zero.
      # Only an absent accounting reaches the raise.
      def resolved
        raise Unwired, UNWIRED_MESSAGE if @usage.nil?

        @usage.call || raise(Unwired, UNWIRED_MESSAGE)
      end

      def counts(usage) = COUNTS.map { |label, reader| row(label, usage.public_send(reader)) }

      # The one row that is not a count, and the bench's first-class cache
      # metric: a silent prompt-cache invalidator shows up here as a ratio that
      # quietly falls to zero while nothing errors.
      def ratio(usage) = row("cache hit ratio", format("%.1f%%", usage.cache_hit_ratio * 100))

      def row(label, value) = "  #{label}: #{value}"
    end
  end
end
