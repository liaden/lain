# frozen_string_literal: true

module Lain
  module Middleware
    # The model phase's translator for a prompt its provider refused WHOLE for
    # not fitting the context: one record, and one line a human can act on.
    #
    # It guesses nothing. An estimate made here was tried and measured wrong in
    # both directions -- qwen3 tokenizes hex and JSON at 1.4 bytes a token and
    # prose at 4.6, and the window book can name a stale runner smaller than
    # the one a request would reload -- so the judgement belongs to the
    # provider, which counts with its own tokenizer against the context it
    # actually loaded. Ollama gives that judgement once asked not to truncate
    # ({Provider::Ollama::Encoding#encode}); a provider raises it as a
    # {Lain::WindowExceeded}, whatever its own error family.
    #
    # OUTERMOST in the model phase and composed by {CLI::Wiring#backing} rather
    # than the chronicle, so it holds under --no-journal too. The provider's
    # exact count becomes the run's reading in {Agent} itself, which owns the
    # accounting, so a run with no budget in front of it is measured the same.
    class RequestBudget < Base
      # The refusal an ask ends with, in the harness's own error vocabulary
      # ({CLI::Repl::Ask} carries a {Lain::Error} out as a value), still
      # carrying the provider's figures and the provider's error as its cause.
      #
      # Its words are finished when they are READ, not when it is raised:
      # whether the prompt was withdrawn is the {Agent}'s decision, made after
      # this raised.
      class OverWindow < Lain::Error
        include Lain::WindowExceeded

        WITHDRAWN = ", and it was withdrawn"

        # @param refused [String] the line up to the point a withdrawal is said
        # @param moves [String] the rest of the line
        # @param figures [Hash] the {Lain::WindowExceeded} figures
        def initialize(refused = nil, moves: "", **figures)
          @moves = moves
          super(refused, **figures)
        end

        def to_s = "#{super}#{WITHDRAWN if withdrawn?}#{@moves}"
      end

      REFUSED = "not answered: %<source>s refused this prompt at %<prompt>d tokens against the %<window>d-token " \
                "context it loaded, so no model saw it"

      # The moves, by whether the refused render left compaction anything to
      # drop. Offered over an empty head, compaction is the one move that
      # cannot happen, and every later prompt would be refused the same way.
      MOVES = {
        true => ". Make room with compaction (that count is now the reading it measures), /rewind, /unpin a " \
                "pinned turn, or a narrower read",
        false => ". Nothing older can be compacted yet, so make room with /rewind past the turn that grew it, " \
                 "/unpin a pinned turn, or a narrower read"
      }.freeze

      LARGER_CONTEXT = "; the system prompt and tools alone come to about %<fixed>d tokens, so start with a " \
                       "larger --num-ctx"

      # @param journal [#<<] where window_pressure records land; the run's
      #   record journal in a chat, and the Null channel by default
      # @param compaction [#droppable?] the run's per-turn Context source, asked
      #   whether the refused render left anything to drop; the Null source,
      #   which never does, by default
      def initialize(journal: Channel::Null.instance, compaction: Agent::PipelineSource::Null)
        @journal = journal
        @compaction = compaction
        super()
        freeze
      end

      def call(env, &app)
        downstream(env, &app)
      rescue Lain::WindowExceeded => e
        request = env.fetch(:request)
        @journal << pressure(e, request, env.fetch(:stands_on))
        raise OverWindow.new(format(REFUSED, source: e.source, prompt: e.prompt_tokens, window: e.window_tokens),
                             moves: moves(e, request), prompt_tokens: e.prompt_tokens, window_tokens: e.window_tokens,
                             source: e.source, model: request.model)
      end

      private

      def pressure(refusal, request, stands_on)
        Telemetry::WindowPressure.new(kind: :over_window, source: refusal.source, model: request.model,
                                      request_digest: request.digest, prompt_tokens: refusal.prompt_tokens,
                                      window_tokens: refusal.window_tokens, stands_on:)
      end

      def moves(error, request)
        moves = MOVES.fetch(@compaction.droppable?)
        fixed = fixed_tokens(error, request)
        fixed < error.window_tokens ? "#{moves}." : "#{moves}#{format(LARGER_CONTEXT, fixed:)}."
      end

      # The share of the provider's exact count the system prompt and the tool
      # schemas account for, by their share of the request's canonical bytes.
      # Proportional and therefore approximate, which is why it only chooses
      # the WORDS: when that share alone outgrows the context, no compaction,
      # rewind or unpin can help, and a refusal offering only those would be
      # the whole message a human got.
      def fixed_tokens(error, request)
        fixed = Canonical.dump(request.cache_prefix).bytesize
        whole = Canonical.dump(request.cache_payload).bytesize
        error.prompt_tokens * fixed / whole
      end
    end
  end
end
