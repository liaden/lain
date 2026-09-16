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
    #
    # A spawned child gets one too ({Tools::Subagent::ChildBuilder}), and the
    # `voice:` collaborator is the one thing that differs: WHOSE prompt was
    # refused decides both the words the refusal ends in and who the record
    # names, and the two are one answer. A prompt in the chat a human is typing
    # into can be made smaller by gestures on that chain, and its count
    # measures that chain's window; a child's can be made smaller only by
    # whoever spawned it, and its count measures a window this run never
    # rendered against -- so offering the chat's moves for a child's refusal
    # would point the reader at the wrong conversation, and folding a child's
    # record into the run's reading would retag it with the wrong chain.
    class RequestBudget < Base
      # The refusal an ask ends with, in the harness's own error vocabulary
      # ({CLI::Repl::Ask} carries a {Lain::Error} out as a value), still
      # carrying the provider's figures and the provider's error as its cause.
      #
      # Its words are finished when they are READ, not when it is raised:
      # whether the prompt was withdrawn is the {Agent}'s decision, made after
      # this raised. The withdrawal CLAUSE rides the same keyword the rest of
      # the wording does, because a child's ask withdraws its prompt exactly as
      # a chat's does and yet has nobody to tell: the chain it was taken off
      # ended with the child.
      class OverWindow < Lain::Error
        include Lain::WindowExceeded

        # The clause is `@withdrawal`, never `@withdrawn`: {Lain::Withdrawal}
        # owns that ivar as its flag, and a String in it reads as "not
        # withdrawn" while `withdrawn!` overwrites the words.
        #
        # @param refused [String] the line up to the point a withdrawal is said
        # @param withdrawal [String] what a withdrawal is said with, if anything
        # @param moves [String] the rest of the line
        # @param figures [Hash] the {Lain::WindowExceeded} figures
        def initialize(refused = nil, withdrawal: "", moves: "", **figures)
          @withdrawal = withdrawal
          @moves = moves
          super(refused, **figures)
        end

        def to_s = "#{super}#{@withdrawal if withdrawn?}#{@moves}"
      end

      REFUSED = "not answered: %<source>s refused %<subject>s at %<prompt>d tokens against the %<window>d-token " \
                "context it loaded, so no model saw it"

      # `compaction:` is an ingredient of the DEFAULT voice and of nothing else:
      # it is what an {Ask} consults, so a caller naming its own voice has
      # already answered the question this keyword asks. Nothing in lib/ writes
      # both -- a chat writes `compaction:`, a spawn writes `voice:`.
      #
      # The moves, by whether the refused render left compaction anything to
      # drop. Offered over an empty head, compaction is the one move that
      # cannot happen, and every later prompt would be refused the same way.
      MOVES = {
        true => ". Make room with compaction (that count is now the reading it measures), /rewind, /unpin a " \
                "pinned turn, or a narrower read",
        false => ". Nothing older can be compacted yet, so make room with /rewind past the turn that grew it, " \
                 "/unpin a pinned turn, or a narrower read"
      }.freeze

      # Said instead of either, once a handoff has already replaced the history
      # with a state document: offering compaction there names a move that has
      # been made, and the turns a /rewind would reach are the ones still here.
      HANDED_OFF = ". The history before this ask was already replaced by a handoff state document, so make room " \
                   "with /rewind past the turn that grew it, /unpin a pinned turn, or a narrower read"

      LARGER_CONTEXT = "; the system prompt and tools alone come to about %<fixed>d tokens, so start with a " \
                       "larger --num-ctx"

      # @param journal [#<<] where window_pressure records land; the run's
      #   record journal in a chat, and the Null channel by default
      # @param compaction [#droppable?, #handed_off?] the run's per-turn Context
      #   source, asked whether the refused render left anything to drop and
      #   whether a handoff has already replaced the history; the Null source,
      #   which never does either, by default
      # @param voice [#subject, #withdrawal, #moves, #spawn] whose prompt this
      #   budget refuses, which decides both the words and who the record names
      def initialize(journal: Channel::Null.instance, compaction: Agent::PipelineSource::Null, voice: nil)
        @journal = journal
        @voice = voice || Ask.new(compaction:)
        super()
        freeze
      end

      def call(env, &app)
        downstream(env, &app)
      rescue Lain::WindowExceeded => e
        request = env.fetch(:request)
        @journal << pressure(e, request, env.fetch(:stands_on))
        raise OverWindow.new(format(REFUSED, subject: @voice.subject, source: e.source, prompt: e.prompt_tokens,
                                             window: e.window_tokens),
                             withdrawal: @voice.withdrawal, moves: @voice.moves(e, request),
                             prompt_tokens: e.prompt_tokens, window_tokens: e.window_tokens, source: e.source,
                             model: request.model)
      end

      private

      def pressure(refusal, request, stands_on)
        Telemetry::WindowPressure.new(kind: :over_window, source: refusal.source, model: request.model,
                                      request_digest: request.digest, prompt_tokens: refusal.prompt_tokens,
                                      window_tokens: refusal.window_tokens, stands_on:, spawn: @voice.spawn)
      end
    end

    class RequestBudget
      # The run's own ask: a prompt the human is at the other end of, on the
      # chain a rewind, an unpin or a compaction moves. The default voice.
      class Ask
        SUBJECT = "this prompt"

        WITHDRAWAL = ", and it was withdrawn"

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

        # @param compaction [#droppable?] the run's per-turn Context source
        def initialize(compaction: Agent::PipelineSource::Null)
          @compaction = compaction
          freeze
        end

        def subject = SUBJECT

        def withdrawal = WITHDRAWAL

        def spawn = nil

        def moves(error, request)
          moves = @compaction.handed_off? ? HANDED_OFF : MOVES.fetch(@compaction.droppable?)
          fixed = fixed_tokens(error, request)
          fixed < error.window_tokens ? "#{moves}." : "#{moves}#{format(LARGER_CONTEXT, fixed:)}."
        end

        private

        # The share of the provider's exact count the system prompt and the
        # tool schemas account for, by their share of the request's canonical
        # bytes. Proportional and therefore approximate, which is why it only
        # chooses the WORDS: when that share alone outgrows the context, no
        # compaction, rewind or unpin can help, and a refusal offering only
        # those would be the whole message a human got.
        def fixed_tokens(error, request)
          fixed = Canonical.dump(request.cache_prefix).bytesize
          whole = Canonical.dump(request.cache_payload).bytesize
          error.prompt_tokens * fixed / whole
        end
      end

      # A spawned child's prompt, refused by the provider the child was given.
      # Whoever reads this is the SPAWNER -- a parent model, or a merge of
      # findings a human reads afterwards -- and not one of them is at a prompt
      # in the child's conversation, so every gesture the chat's own refusal
      # offers would point at the wrong chain. What is left is the one thing
      # the spawner controls: how much it hands a child to read.
      class Child
        MOVES = ". A child answers only the task it was handed, and nothing in this chat makes that task " \
                "smaller: hand it less to read -- fewer files, a narrower question -- or run it against a " \
                "model with a larger window."

        SUBJECT = "the %<name>s child's task"

        # @param name [String] what this spawn is announced as
        def initialize(name:)
          @name = -name.to_s
          freeze
        end

        def subject = format(SUBJECT, name: @name)

        def spawn = @name

        # SAID OF NOTHING. The child's own ask withdraws its prompt exactly as
        # a chat's does, and the chain it came off ended with the child, so
        # telling the spawner it was withdrawn describes a conversation nobody
        # can go back to.
        def withdrawal = ""

        # The refusal's figures and the parent's compaction source are both
        # beside the point: what a spawner may do about a child's prompt does
        # not vary with either, and a pipeline the child never rendered from
        # would answer about the wrong chain.
        def moves(*) = MOVES
      end
    end
  end
end
