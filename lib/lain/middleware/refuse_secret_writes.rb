# frozen_string_literal: true

module Lain
  module Middleware
    # Refuses a `memory_write` whose input looks like a secret, before the
    # write ever reaches the recorder.
    #
    # This has to sit in the TOOL phase, at the `ToolRunner#dispatch` seam
    # (env is `{effect:, context:}`, the outcome rides `env[:result]`), because
    # that is the only point with the authority to withhold the call entirely.
    # Once a credential is inside a Memory::Item it is indexed and readable by
    # every future `memory_read` -- there is no un-indexing it, so the check
    # has to run BEFORE the recorder, not clean up after it.
    #
    # Matching is deterministic and textual: API-key shapes, PEM blocks,
    # obvious credential assignments. PHI heuristics are explicitly out of
    # scope here -- "this reads like a medical record" is a judgment call, not
    # a regex, which is exactly what `oracle:` is for: a Null Object today, a
    # future ollama classifier (OR-1) tomorrow, without this class changing
    # shape.
    #
    # Only `memory_write` is guarded. A `bash` or `read_file` effect whose
    # input independently looks secret-ish passes through untouched -- this is
    # a write-refusal control, not a general secret scanner, and scanning
    # tools that were never going to persist anything is scope creep the card
    # does not ask for. Guarding is exact string equality on "memory_write":
    # a tool that writes memory under any other name is unguarded by design,
    # accepted until a second memory writer actually exists.
    class RefuseSecretWrites < Base
      GUARDED_TOOL = "memory_write"

      # name => pattern. The NAME is what gets journaled and put in the
      # model-facing error; the bytes that matched never are -- see
      # {Event::WriteRefused}.
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
      # confused with a real opinion. Swap in an ollama-backed classifier
      # (OR-1) later without this middleware changing shape.
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
        return downstream(env, &app) unless effect.name == GUARDED_TOOL

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
      # produced without the tool ever running.
      def refuse(env, effect, pattern)
        @journal << Event::WriteRefused.new(tool_use_id: effect.tool_use_id, pattern:)
        env.merge(result: Tool::Result.error(
          "memory_write refused: input matches a #{pattern} pattern; nothing was written."
        ))
      end
    end
  end
end
