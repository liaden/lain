# frozen_string_literal: true

module Lain
  module Friction
    # Folds the existing offline analysis graders -- {Grader::FrustrationRepair}
    # (rephrase loops), {Grader::ToolSteering} (over-selected tools),
    # {Bench::Rewrites} (prompt-cache churn) and {Friction::CacheWaste} (what
    # that churn was BILLED) -- over one session Journal and renders each
    # detected signal beside the KNOB that addresses it. A pure function of the
    # Journal: no provider is touched, so two renders of the same entries are
    # byte-identical.
    #
    # {Friction::CacheWaste} is the one analyzer that reports even when it finds
    # nothing: a cache that held is a fact worth stating, where an absent section
    # reads the same as an analyzer that never ran. Its line therefore sits BELOW
    # the numbered signals rather than among them when there is no waste.
    #
    # The fuzzy tier behind {Grader::FrustrationRepair}'s injected `oracle:`
    # stays Null here on purpose: this report is the MECHANICAL floor only, never
    # a model call.
    #
    #   Friction::Report.new(Journal.records(File.foreach(path))).render
    #   #=> "1 friction signal(s):\n..."
    class Report
      # Tools whose command string the MODEL controls -- {Tool#requires_approval?}
      # is true today for exactly {Tools::Bash}. The Journal carries no tier
      # metadata of its own (a session header's `"tools"` entries are
      # name/description/input_schema/strict only), so this is a NAME heuristic
      # over the shipped tier-3 tools, not a live lookup against the toolset
      # that actually ran. Having the header record the tier is a follow-up.
      TIER_3_TOOL_NAMES = %w[bash].freeze

      # More than this many prefix rewrites in one session is "high" -- a
      # stated, arbitrary threshold, the same shape {Grader::ToolSteering::DEFAULT_THRESHOLD}
      # documents.
      CACHE_REWRITE_THRESHOLD = 3

      # Declarative signal-kind => knob-guidance mapping. This table is the
      # whole point of the class: adding a new knob is an edit here, never a
      # new conditional buried in a render method.
      KNOBS = {
        rephrase_loop_tier3: "consider the approval queue timeout, or a structured tool with its own " \
                             "precondition (Tool.requires) instead of this tier-3 one",
        rephrase_loop: "consider tightening this tool's error messages or description so a retry " \
                       "does not repeat the same failing call",
        tool_steering: "rewrite this tool's description so it does not over-claim -- see the disclosure sweep",
        cache_rewrites: "high cache-rewrite count -- look at compaction scheduling knobs " \
                        "(Compaction::Scheduler, Context::Compact's byte threshold)",
        cache_waste: "look at what edits the prompt PREFIX mid-session -- a Workspace or reminder " \
                     "block that changes every turn, or compaction firing while the cache was still warm"
      }.freeze

      # What each of the two cache lines MEASURED, said in the line itself.
      # They read different bytes and answer different questions: `cache_rewrites`
      # counts divergences between consecutive `request_sent` prefix chains and
      # never looks at a usage record, while `cache_waste` multiplies those same
      # breaks by the cache-creation tokens the next call was BILLED. So "4
      # prefix rewrites detected" beside "no prefix break was re-billed" is two
      # answers to two questions, and a reader given only the two numbers reads
      # it as a contradiction.
      #
      # Saying what each measured is the whole reconciliation, deliberately: the
      # counts are NOT made to agree, because they legitimately differ. The
      # rewrite line counts across every model, {Friction::CacheWaste} segments
      # per model (see its class doc), so a `/model` switch is one rewrite there
      # and no waste here -- which is the {MODEL_SWITCH_NOTE} case, and would be
      # papered over by any reconciliation that forced one number.
      REWRITE_MEASURE = "prompt prefix chains that diverged, counted across every model, before billing"
      WASTE_MEASURE = "measured as the cache-creation tokens billed after a break, per model"

      # The fact that turns three true numbers -- zero waste, zero tokens served,
      # zero saved -- from a healthy-looking cache report into what they are.
      # Stated from the journal's `capability_degraded` record and never
      # inferred, so a journal that recorded nothing says nothing here.
      #
      # The subject is "the provider that record names", not "this provider":
      # the record carries a provider field, no call record carries one, and
      # this report deliberately does not echo the name (it is a journal string
      # reaching a render, the hazard {Friction::CacheWaste::SAFE_MODEL} exists
      # for). Attributing the sentence to the record keeps it true without
      # claiming an authority over the session's calls that nothing here can
      # back -- which is also why {Friction::CacheWaste#no_prompt_cache?}, not
      # `#prompt_cache_degraded?`, is what selects this line.
      NO_PROMPT_CACHE = "not measured -- the journal records prompt_caching degraded, and no cache read " \
                        "or re-billed write contradicts it, so the provider that record names does not " \
                        "cache and no saving is quoted"

      # Why a model switch contributes no waste, said out loud rather than left
      # as an unexplained zero. {Friction::CacheWaste} segments per model, so a
      # switch's forfeited prefix never reaches the meter -- and a reader who
      # knows the session switched models needs to be told that on purpose.
      MODEL_SWITCH_NOTE = "a model switch forfeits the whole prompt prefix by design, " \
                          "so it is segmented out rather than counted as a prompt edit"

      # The analyzers this report folds, named for the "clean session" state --
      # kept as data (not re-derived from KNOBS' keys) so the two can evolve
      # independently: one knob can cover several analyzers' findings and vice
      # versa.
      ANALYZERS = ["Grader::FrustrationRepair", "Grader::ToolSteering", "Bench::Rewrites",
                   "Friction::CacheWaste"].freeze

      # @param entries [Enumerable<Hash, String>] the {Journal.records} duck
      # @param oracle [#frustrated?] forwarded to {Grader::FrustrationRepair};
      #   Null by default and never anything else in production use of this
      #   class (see the class doc) -- injectable only so a spec can assert
      #   the default stays Null.
      # @param lineages [Enumerable<Bench::Session::Lineages::Lineage>] the
      #   subagent work the graders index beside the session's own turns. A
      #   caller holding the session's path reads them from it
      #   ({Bench::Session::Lineages.read}), which is the only way a resumed
      #   session's chain can be followed; by default they are read off the
      #   entries alone.
      def initialize(entries, oracle: Grader::FrustrationRepair::NullOracle.instance,
                     lineages: Bench::Session::Lineages.recorded_in(entries))
        @entries = entries.to_a.freeze
        @oracle = oracle
        @lineages = lineages
      end

      # @return [String] the rendered report; never printed here (output
      #   discipline -- the frontend prints)
      def render
        lines = signal_lines
        body = lines.empty? ? clean_render : (["#{lines.size} friction signal(s):"] + lines).join("\n")
        ([body] + cache_waste_notes).join("\n")
      end

      private

      def clean_render
        "no friction found -- analyzers run: #{ANALYZERS.join(", ")}"
      end

      def signal_lines
        rephrase_lines + steering_lines + rewrite_lines + cache_waste_lines
      end

      # ONE projection over the entries, injected into both graders that read
      # it: each would otherwise build its own over the same in-memory array,
      # and this class already needs a third for {#retried_tool_name}.
      def call_index
        @call_index ||= Grader::ToolCallIndex.new(@entries, lineages: @lineages)
      end

      def rephrase_lines
        Grader::FrustrationRepair.new(oracle: @oracle)
                                 .signals(@entries, tool_call_index: call_index)
                                 .map { |signal| rephrase_line(signal) }
      end

      def rephrase_line(signal)
        name = retried_tool_name(signal)
        knob = TIER_3_TOOL_NAMES.include?(name) ? KNOBS.fetch(:rephrase_loop_tier3) : KNOBS.fetch(:rephrase_loop)
        "rephrase_loop at #{signal.turn_digest} (#{name}, caused by #{signal.caused_by.join(", ")}): #{knob}"
      end

      # {Grader::FrustrationRepair::Signal} carries no tool name of its own --
      # only `turn_digest`/`caused_by` digests. The retried tool is the name
      # shared between an ERRORED call at the cause turn and a call at the
      # signal's own turn (the mechanical detector requires that exact name
      # match, frustration_repair.rb's `nearest_prior_use`); intersecting
      # recovers it without re-implementing that walk.
      def retried_tool_name(signal)
        retry_names = names_at(signal.turn_digest)
        shared = errored_names_at(signal.caused_by.first) & retry_names
        shared.first || retry_names.first || "unknown"
      end

      def names_at(digest)
        (call_index.calls[digest] || []).map(&:name)
      end

      def errored_names_at(digest)
        (call_index.calls[digest] || []).select(&:is_error).map(&:name)
      end

      def steering_lines
        Grader::ToolSteering.new(@entries, tool_call_index: call_index).flags.map { |flag| steering_line(flag) }
      rescue Grader::ToolSteering::NoDeclaredTools
        []
      end

      def steering_line(flag)
        "tool_steering: #{flag.name} selected #{format("%.2f", flag.ratio)}x its declared share: " \
          "#{KNOBS.fetch(:tool_steering)}"
      end

      def rewrite_lines
        count = Bench::Rewrites.from_journal(@entries).count
        return [] if count <= CACHE_REWRITE_THRESHOLD

        ["cache_rewrites: #{count} prefix rewrites detected (#{REWRITE_MEASURE}): " \
         "#{KNOBS.fetch(:cache_rewrites)}"]
      end

      def cache_waste_section
        @cache_waste_section ||= CacheWasteSection.new(CacheWaste.from_journal(@entries),
                                                       knob: KNOBS.fetch(:cache_waste),
                                                       switch_note: MODEL_SWITCH_NOTE)
      end

      def cache_waste_lines = cache_waste_section.signal_lines

      def cache_waste_notes = cache_waste_section.notes

      # How one {Friction::CacheWaste} reads as report prose. Its own object
      # because folding the analyzers and PHRASING a priced finding are
      # different jobs, and the phrasing carries real policy rather than
      # formatting: an upper bound has to say "at most", a dollar figure with
      # nothing priceable behind it must not print as a confident zero, a
      # session with nothing to charge has to say so rather than be omitted, and
      # a session that never had a cache must not read as one whose cache
      # happened to save nothing.
      class CacheWasteSection
        # @param waste [Friction::CacheWaste]
        # @param knob [String] the guidance this section proposes
        # @param switch_note [String] why a model switch is not charged
        def initialize(waste, knob:, switch_note:)
          @waste = waste
          @knob = knob
          @switch_note = switch_note
        end

        # A numbered friction signal, and only when something was re-billed.
        # @return [Array<String>]
        def signal_lines
          return [] unless @waste.rebilled_tokens.positive?

          ["cache_waste: #{([rebilled] + context).join("; ")}: #{@knob}"]
        end

        # Explicit, not implied: a session whose cache held says so, rather than
        # having the section quietly omitted -- an absent section and a clean
        # session are indistinguishable to a reader. A journal with no priced
        # call at all says nothing, because there was nothing to judge.
        # @return [Array<String>]
        def notes
          return [] if @waste.calls.empty? || @waste.rebilled_tokens.positive?

          ["cache_waste: #{([headline] + context).join("; ")}"]
        end

        private

        # A cacheless provider's "none" is not the same finding as a cache that
        # HELD, and the two rendered identically. The other half lives in the
        # `false` branch: the journal that recorded no capability keeps the
        # measured wording, because it is still what was measured.
        def headline
          return NO_PROMPT_CACHE if @waste.no_prompt_cache?

          "none -- no prefix break was re-billed (#{WASTE_MEASURE})"
        end

        # "at most", because the figure IS an upper bound: a call that both
        # broke its prefix and appended new messages has its whole cache write
        # counted (see {Friction::CacheWaste}). That reasoning lives in the
        # source, where nobody running `lain friction SESSION` sees it -- two
        # words put the error's DIRECTION in the number itself.
        def rebilled
          "at most #{@waste.rebilled_tokens} tokens re-billed across " \
            "#{@waste.count} prefix break(s), #{cost_phrase(@waste.rebilled_cost)}"
        end

        # Always reported, in both branches: a waste figure alone is an
        # anti-metric (ROADMAP.md:233), and a zero that a model switch or an
        # unpriceable model explains must say so rather than read as a clean
        # bill. "main-agent" because {Middleware::JournalRequests} is wired
        # into the main Agent alone, so a subagent's turns are outside every
        # figure here -- "priced call(s)" alone is a scoping word only a source
        # reader decodes.
        def context
          [bought] + switch_notes + unpriced_notes + refusal_notes
        end

        # Two withholdings, and they answer different questions.
        #
        # The first: for a session the journal says had no cache,
        # both the served count and the saving go, for the reason
        # {Friction::CacheWaste#saving_on} sets out -- the arithmetic really is
        # zero, and printing it says "your cache saved you nothing" about a
        # session that never had one. Gated on `no_prompt_cache?` so it cannot
        # fire over calls that did use a cache.
        #
        # The second needs no capability record at all, which is what closes
        # the gap for the journals that carry none -- a recorded bench
        # session, a strict-policy run. A dollar figure with nothing MEASURED
        # behind it is the same shape as one with nothing PRICEABLE behind it,
        # which {#figure_phrase} already withholds: zero tokens at any rate is
        # zero, so `saving $0.000000` reports the multiplication rather than the
        # session. The token count stays, because a zero the reader can see is
        # the evidence; only the vacuous dollar tail goes.
        def bought
          calls = "#{@waste.calls.size} priced main-agent call(s)"
          return "#{calls}, with no prompt cache to serve or save against" if @waste.no_prompt_cache?

          served = "#{@waste.cached_tokens} tokens served from cache over #{calls}"
          @waste.cached_tokens.zero? ? served : "#{served}, #{saved_phrase(@waste.cached_savings)}"
        end

        def switch_notes
          count = @waste.model_switches
          count.zero? ? [] : ["#{count} model switch(es) counted, not charged -- #{@switch_note}"]
        end

        def unpriced_notes
          models = @waste.unpriced_models
          models.empty? ? [] : ["dollar figures exclude #{models.join(", ")} -- no price recorded"]
        end

        # A refused usage means a call was DROPPED, so every figure above is a
        # floor on the session. Silence would let that read as a full
        # accounting.
        def refusal_notes
          count = @waste.refused_usages
          return [] if count.zero?

          ["#{count} usage record(s) not attributed -- a model that disagreed with its request " \
           "(a concurrently-journaled subagent turn) or a record carrying no usage"]
        end

        def cost_phrase(figure) = figure_phrase(figure, "costing", "cost unpriced")

        def saved_phrase(figure) = figure_phrase(figure, "saving", "savings unpriced")

        # Rendered so the figure's COMPLETENESS is visible. A "$0.000000"
        # beside a non-zero token count reads as "this was free", which is the
        # lie {PriceBook} refuses to tell by raising -- so a figure with
        # nothing priceable behind it is WITHHELD, and a partly-priced one
        # reads as a floor rather than as a total.
        def figure_phrase(figure, verb, withheld)
          return withheld if !figure.complete? && figure.amount.zero?
          return "#{verb} at least $#{money(figure.amount)}" unless figure.complete?

          "#{verb} $#{money(figure.amount)}"
        end

        # The same six-decimal fixed point {Compare::METRICS} renders cost
        # with; BigDecimal's own `to_s` would emit scientific notation.
        def money(value) = format("%.6f", value)
      end
    end
  end
end
