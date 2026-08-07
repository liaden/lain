# frozen_string_literal: true

module Lain
  module Middleware
    # Refuses a `memory_write` or `improvement_write` whose input looks like a
    # secret, before the write ever reaches its recorder/sink.
    #
    # This has to sit in the TOOL phase, at the `ToolRunner#dispatch` seam
    # (env is `{effect:, context:}`, the outcome rides `env[:result]`), because
    # that is the only point with the authority to withhold the call entirely.
    # Once a credential is inside a Memory::Item (or an Improvement) it is
    # indexed/durable and readable by every future read -- there is no
    # un-indexing it, so the check has to run BEFORE the write, not clean up
    # after it.
    #
    # Matching is deterministic and textual: API-key shapes, PEM blocks,
    # obvious credential assignments. PHI heuristics are explicitly out of
    # scope here -- "this reads like a medical record" is a judgment call, not
    # a regex, which is exactly what `oracle:` is for: a Null Object today, a
    # future ollama classifier (OR-1) tomorrow, without this class changing
    # shape.
    #
    # Only the tools named in {GUARDED_TOOLS} are guarded. A `bash` or
    # `read_file` effect whose input independently looks secret-ish passes
    # through untouched -- this is a write-refusal control, not a general
    # secret scanner, and scanning tools that were never going to persist
    # anything is scope creep the card does not ask for. Guarding is exact
    # membership in that Set: a tool that persists content under any other
    # name is unguarded by design, until it earns a place in the Set.
    #
    # {GUARDED_TOOLS} started as a single hardcoded name (`memory_write`);
    # M2 generalized it to a Set when `improvement_write` became a second
    # writer with the same secret-leak exposure. The refusal MESSAGE names
    # whichever tool was actually refused (`effect.name`, not a hardcoded
    # string), but the journaled {Telemetry::WriteRefused} shape -- what a
    # replay reader keys on -- is untouched: still just `tool_use_id` and
    # `pattern`, with no tool name added to the record.
    class RefuseSecretWrites < Base
      GUARDED_TOOLS = Set["memory_write", "improvement_write"].freeze

      # name => pattern. The NAME is what gets journaled and put in the
      # model-facing error; the bytes that matched never are -- see
      # {Telemetry::WriteRefused}.
      #
      # The table itself lives in {CredentialPatterns}, which the read side
      # shares. This is the WRITE selection: the shapes safe to refuse a user's
      # own prose over, deliberately narrower than what runs over file bytes.
      PATTERNS = CredentialPatterns.for(:write)

      # A refusal that came from the oracle rather than from a named PATTERNS
      # entry is NOT a pattern hit, and journaling it under the same grammar
      # recorded a judgment call ("not worth remembering") as a security
      # finding ("this looks like a credential"). {Telemetry::WriteRefused}
      # requires `pattern` non-nil, so a decline cannot simply omit it; it
      # carries a reason from a reserved namespace instead. The PREFIX is the
      # mechanical test -- {.decline?}, not an allow-list of pattern names a
      # reader would have to keep in sync with {PATTERNS}. It is a prefix
      # rather than one flat value so a later arm can name WHICH judgment
      # declined without a replay reader learning a new word.
      #
      # Both live on {CredentialPatterns} now: the table's own load-time guard
      # rejects a pattern name inside the namespace, which it can only do if it
      # owns the prefix. One definition, so the guard and this test cannot
      # disagree about what the namespace is.
      DECLINE_PREFIX = CredentialPatterns::DECLINE_PREFIX
      ORACLE_DECLINE = "#{DECLINE_PREFIX}oracle".freeze

      # @param reason [String] a journaled {Telemetry::WriteRefused#pattern}
      # @return [Boolean] true if a judgment declined the write, false if a
      #   credential pattern matched it
      def self.decline?(reason) = CredentialPatterns.decline?(reason)

      # What the MODEL is told about a decline. It deliberately names no
      # pattern and makes no credential claim: the model that reads "matches
      # a ... pattern" for a write the oracle merely found unworthy learns
      # the wrong lesson and redacts prose that was never sensitive. The
      # second clause is why the model has a move other than an identical
      # retry -- a refusal that only says "no" gets resent verbatim.
      DECLINED = "the oracle judged this input not worth writing -- " \
                 "write substantive content rather than retrying this one"

      # Null Object for the injectable predicate seam: never flags anything,
      # so bare construction needs no guard and today's default cannot be
      # confused with a real opinion. {Oracle::MemorySave::Gate} (T4/OR-3) is
      # the real arm this seam exists for -- a heuristic-tier oracle judging
      # "worth remembering?", collapsed to this seam's one bit -- and a
      # future ollama-backed classifier (OR-1) drops in the same way, all
      # without this middleware changing shape.
      class NullOracle
        def secret?(_input) = false

        INSTANCE = new.freeze

        def self.instance = INSTANCE
      end

      # @param journal [#<<] where WriteRefused records land; the Null channel
      #   by default, so no caller guards `if journal`
      # @param oracle [#secret?] a second, swappable arm over the same input.
      #   The duck's name predates its real users: what a true answer means is
      #   "withhold this write", and {Oracle::MemorySave::Gate} means it as a
      #   judgment ("not worth remembering"), not a credential finding --
      #   which is why it journals {ORACLE_DECLINE} and never a PATTERNS name.
      def initialize(journal: Channel::Null.instance, oracle: NullOracle.instance)
        @journal = journal
        @oracle = oracle
        super()
        freeze
      end

      def call(env, &app)
        effect = env.fetch(:effect)
        return downstream(env, &app) unless GUARDED_TOOLS.include?(effect.name)

        pattern = matched_pattern(effect.input)
        return refuse(env, effect, pattern, "input matches a #{pattern} pattern") if pattern
        return refuse(env, effect, ORACLE_DECLINE, DECLINED) if withhold?(effect.input)

        downstream(env, &app)
      end

      private

      # The seam's duck is `#secret?`, but a true answer means only "withhold
      # this write": {Oracle::MemorySave::Gate} answers it as a judgment, not
      # a credential finding. Naming that here keeps the call site from
      # reading "if it is secret, record it as not-a-secret". Renaming the
      # duck itself crosses into the oracle's own file and is ticketed.
      def withhold?(input) = @oracle.secret?(input)

      def matched_pattern(input)
        haystack = text(input)
        PATTERNS.find { |_name, pattern| haystack.match?(pattern) }&.first
      end

      # Flattens a tool input -- a Hash of Strings for `memory_write`, but kept
      # general over nested Hashes/Arrays -- into one String to scan. Keys are
      # included alongside values on purpose: "api_key: ..." landing in a key
      # rather than a value is still a credential assignment.
      def text(input)
        case input
        when Hash then input.flatten.map { |part| text(part) }.join("\n")
        when Array then input.map { |part| text(part) }.join("\n")
        else input.to_s
        end
      end

      # Withholds the call entirely: `app` (the downstream handler that would
      # actually perform the write) is never invoked, so `env[:result]` is
      # produced without the tool ever running. The message names the tool
      # actually refused (`effect.name`) so a model juggling both writers
      # learns which call to retry differently -- "memory_write refused"
      # read after an improvement_write call would be a lie.
      #
      # `reason` is journaled; `why` is what the model reads. They differ
      # because the record is keyed on by replay readers and the message is
      # prose, but both must agree on WHICH kind of refusal happened.
      def refuse(env, effect, reason, why)
        @journal << Telemetry::WriteRefused.new(tool_use_id: effect.tool_use_id, pattern: reason)
        env.merge(result: Tool::Result.error("#{effect.name} refused: #{why}; nothing was written."))
      end
    end
  end
end
