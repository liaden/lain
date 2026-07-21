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
      # The sk- shape is anchored with a lookbehind because unanchored it
      # matched INSIDE hyphenated prose ("ask-someone-to-help-..."), refusing a
      # benign write under a pattern name it never honestly matched: a real key
      # stands alone, never run into by a preceding word char or hyphen.
      PATTERNS = {
        "openai-style api key" => /(?<![\w-])sk-[A-Za-z0-9_-]{16,}/,
        "aws access key id" => /AKIA[0-9A-Z]{16}/,
        "pem private key block" => /-----BEGIN(?: [A-Z]+)? PRIVATE KEY-----/,
        "credential assignment" => /\b(?:password|passwd|secret|api[_-]?key|token)\s*[:=]\s*\S+/i
      }.freeze

      # The name journaled when the oracle -- not a named PATTERNS entry --
      # is what flagged the input. There is no regex to name in that case.
      ORACLE_MATCH = "oracle-flagged"

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
      # @param oracle [#secret?] a second, swappable arm over the same input --
      #   the Null Object today, an ollama-backed classifier once OR-1 lands
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
        return downstream(env, &app) unless pattern || @oracle.secret?(effect.input)

        refuse(env, effect, pattern || ORACLE_MATCH)
      end

      private

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
      def refuse(env, effect, pattern)
        @journal << Telemetry::WriteRefused.new(tool_use_id: effect.tool_use_id, pattern:)
        env.merge(result: Tool::Result.error(
          "#{effect.name} refused: input matches a #{pattern} pattern; nothing was written."
        ))
      end
    end
  end
end
