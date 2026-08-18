# frozen_string_literal: true

module Lain
  module CLI
    class Backend
      # WHICH window this run's occupancy is measured against.
      #
      # Its own object for {Backend::Summarizer}'s reason: resolving a
      # denominator is a second, independent question from resolving a provider
      # and a model, and it has three moving parts of its own -- an operator
      # flag, a live server, and the shipped table. Folding them into
      # {Backend} is what the Metrics cop called out, and the cop was right
      # (CLAUDE.md: extract, never loosen).
      #
      # It depends on MESSAGES -- `#provider`, `#model`, `#num_ctx` -- not on
      # {Backend}'s internals.
      #
      # == Why this exists at all
      #
      # {ContextWindow::DEFAULTS} is an Anthropic-shaped table, so every ollama
      # and most bedrock model ids fall to
      # {ContextWindow::CONSERVATIVE_FALLBACK}'s 8,192. The POC measured that
      # cost exactly: 86.4% occupancy published while the context was 2.7% full,
      # with a numerator that reproduced the provider's own `input_tokens` to
      # the token. Only the denominator was ever wrong, and only the server
      # knows it.
      class WindowBook
        # A book that answers for ONE model and delegates every other name.
        #
        # It is NOT a {ContextWindow} built by merging the served window into
        # {ContextWindow::DEFAULTS}, and the difference is a live 4-8x
        # over-estimate rather than a nicety. `ContextWindow#matched` falls back
        # to `name.include?(token)` across every key, so a merged key becomes a
        # SUBSTRING rule for every later model name: with `--model qwen3`
        # resident at 32,768 (ollama prints the runner as `qwen3:latest`, and
        # `Ollama#serves?` matches the untagged name an operator typed), a
        # mid-session `/model qwen3-coder:30b`, `/model qwen3:4b` and `/model
        # qwen3-tiny:0.5b` ALL measured 32,768 -- the forbidden direction, on
        # models whose real windows are 4-8x smaller, and untagged names that
        # are prefixes of tagged ones are the ordinary case here rather than a
        # contrived one. The server answered about ONE runner, so naming that
        # runner is the only rule a served window can honestly carry.
        #
        # Which names those are is not this object's to decide, though: it
        # spends by exactly the set {Provider::Ollama#serves?} grants by (see
        # {#initialize}). A window granted through one rule and refused by a
        # narrower one is the same two-surface split in miniature.
        #
        # Three messages, which is the whole duck its three readers send
        # ({StatusFeed}, {Compaction::Source}, {Agent#occupancy}).
        class Served
          # @param model [String] the model the window was reported FOR
          # @param window_tokens [Integer] that model's served window
          # @param provenance [Symbol] who vouches for that number. {PROBED} by
          #   default, because a server answering is what this book was written
          #   for and every construction predating the keyword means exactly
          #   that. {ContextWindow::GUESSED} is the `--num-ctx`-alone case: the
          #   operator named a plausible window and no runner has confirmed it
          #   (see {WindowBook#book}). Validated HERE, at construction, rather
          #   than on the first turn that reads it -- a book is built at launch
          #   and read all session, so a bad value found on the render path is
          #   a chat that dies mid-turn.
          # @param shipped [ContextWindow] answers every other name; the bench's
          #   own book by default, so an unrelated model degrades exactly as it
          #   did before this object existed
          def initialize(model:, window_tokens:, provenance: ContextWindow::PROBED,
                         shipped: ContextWindow.default)
            @model = -model.to_s
            # The SAME set {Provider::Ollama#serves?} grants a window by. That
            # method matches a runner entry against `[model, "#{model}:latest"]`
            # because ollama appends `:latest` to an untagged request before
            # printing it back -- so a book can exist BECAUSE the server
            # answered for `qwen3:latest` when the operator typed `qwen3`.
            # Spending it by the narrower rule then refuses the very name that
            # granted it, and the two readers disagree by exactly one tag:
            # {Agent#occupancy} divides using `context.model` (the operator's
            # string) while {StatusFeed#occupancy_of} divides using
            # `event.model` (what the provider ECHOED). Measured before the two
            # sets were joined: prompt 22%, `.lain/state.json` 0.8641, on one
            # turn -- the half-fixed number this card exists to prevent,
            # reappearing in the untagged case this object was written for.
            @names = [@model, -"#{@model}:latest"].freeze
            @window_tokens = ContextWindow::Occupancy.window!(window_tokens)
            @resolution = ContextWindow::WindowResolution.new(window_tokens: @window_tokens, provenance:)
            @shipped = shipped
            # A blank model is a WIRING bug and {ContextWindow} is loud about
            # one. Answering for it would swallow that -- reachable, because
            # `--num-ctx` alone resolves a window with no server involved, so a
            # blank `--model` would otherwise arrive here with a real number.
            @named = !@model.strip.empty?
            freeze
          end

          # @return [Integer]
          # @raise [ContextWindow::UnknownModel] for a blank name, or an
          #   unmatched one in a `shipped` book with no fallback
          def window_tokens(model) = resolve(model).window_tokens

          # The ONE window in this system anybody measured: ollama's `/api/ps`
          # naming the runner resident right now. That is what
          # {ContextWindow::PROBED} means, and it is why this book exists --
          # unless the run's `provenance:` says a flag, not a server, is where
          # the number came from.
          #
          # A name this book did NOT probe delegates, provenance and all -- so a
          # delegated answer comes back {ContextWindow::PUBLISHED} or
          # {ContextWindow::GUESSED} by whatever the shipped book knows, never
          # probed. Tagging the delegated case probed would be the same defect
          # T9 fixes, pointed the other way: a rewrite authorised by a runner
          # nobody asked about that model. The `#window_tokens` half of this
          # already delegates for exactly the reason spelled out above -- the
          # server answered about ONE runner -- and the authority has to travel
          # with the number or the two halves of one answer disagree.
          #
          # @return [ContextWindow::WindowResolution]
          # @raise [ContextWindow::UnknownModel] for a blank name, or an
          #   unmatched one in a `shipped` book with no fallback
          def resolve(model) = mine?(model) ? @resolution : @shipped.resolve(model)

          # @return [ContextWindow::Occupancy, ContextWindow::Occupancy::None]
          def occupancy(used_tokens, model:)
            ContextWindow::Occupancy.of(used_tokens:, window_tokens: window_tokens(model))
          end

          private

          def mine?(model) = @named && @names.include?(model.to_s)
        end

        # The run's ONE book object, holding an answer that may still improve.
        #
        # The identity is what the three readers share and must go on sharing --
        # {StatusFeed}, {Compaction::Source} and {Agent#occupancy} are each
        # handed this at wiring time and never ask {Backend} again, and three
        # readers dividing by three numbers is the failure that whole
        # arrangement exists to prevent. What changes is the ANSWER inside it.
        #
        # == Why an answer has to be able to change
        #
        # A `--num-ctx` launched while nothing is resident resolves to a GUESS
        # (see {WindowBook#book}), and a memoized guess is permanent: the runner
        # loads on turn one and the session goes on measuring against a number
        # nobody confirmed for as long as it runs. Re-resolving is how the first
        # real `/api/ps` answer upgrades it.
        #
        # == The trigger is external, and it is not "on every read"
        #
        # This object has no clock and no turn counter, so it cannot decide WHEN
        # by itself -- and re-resolving per READ would be worse than never doing
        # it: {StatusFeed}, the compaction decision and the prompt line would
        # each get their own round trip and could disagree within one turn,
        # which is exactly what {Backend#context_window}'s memo prevents.
        # {Middleware::ResolveWindow} fires {#reresolve} ONCE at the top of each
        # turn, wired by {Wiring::AgentBuild}, so every reader inside a turn
        # divides by the same number.
        #
        # == And it stops, two ways
        #
        # Only a GUESS is worth re-asking. Once the run's own model resolves to
        # something authoritative -- a probed runner, or a published table entry
        # -- no later probe can improve it, so the asking stops. That is what
        # keeps a hosted run from opening a round trip per turn for a provider
        # that publishes no served window at all, and it is asserted
        # mechanically by `spec/lain/seams/recorded_run_spec.rb`, whose cassette
        # records exactly ONE `/api/ps` for a two-turn run.
        #
        # {REASK_LIMIT} is the second way, and it is the one that bounds the
        # WORST case rather than the ordinary one -- see there.
        class Live
          # How many times a run re-asks before keeping the answer it has, NOT
          # counting the resolution at launch.
          #
          # A limit is needed because "stops when authoritative" does not stop
          # at all for the runs least able to diagnose it. An ollama model the
          # shipped table does not carry resolves GUESSED through
          # {ContextWindow::CONSERVATIVE_FALLBACK}, so only a runner answering
          # can ever settle it -- and {Middleware::ResolveWindow} fires once per
          # ITERATION of the agent loop, not once per user ask. Against a host
          # that DROPS packets each probe costs the full
          # {Provider::Ollama::Transport::PROBE_TIMEOUT_SECONDS}: measured 2.003s
          # per re-resolution, so a ten-tool-call turn paid +20 seconds, every
          # turn, for a number that was never going to arrive.
          #
          # THREE, because that is what the correction actually needs. Ollama
          # fixes a runner's context at LOAD time and the first request is what
          # loads it, so an answer that is coming arrives by the second
          # iteration's refresh; the third is slack for a first request that
          # failed. Past that, re-asking is not patience, it is a tax.
          #
          # Giving up is not settling. The book keeps whatever it has, which for
          # the case above is the operator's `--num-ctx` still tagged GUESSED --
          # so an exhausted budget still authorises no rewrite.
          REASK_LIMIT = 3

          # @param source [#book, #model] resolves a fresh book, and names the
          #   model whose answer decides whether asking again could help
          def initialize(source:)
            @source = source
            @book = source.book
            @reasks = 0
          end

          # @return [Integer]
          def window_tokens(model) = @book.window_tokens(model)

          # @return [ContextWindow::WindowResolution]
          def resolve(model) = @book.resolve(model)

          # @return [ContextWindow::Occupancy, ContextWindow::Occupancy::None]
          def occupancy(used_tokens, model:) = @book.occupancy(used_tokens, model:)

          # Ask again, if asking could still help.
          #
          # @return [self]
          def reresolve
            return self unless asking_can_help?

            @reasks += 1
            @book = @source.book
            self
          end

          private

          # Two independent reasons not to ask, and they answer different
          # questions: {#settled?} is "a better answer is not possible",
          # {REASK_LIMIT} is "a better answer is not worth waiting for".
          def asking_can_help? = @reasks < REASK_LIMIT && !settled?

          # A blank or unresolvable model settles rather than raising: it is a
          # wiring bug the book itself is already loud about at READ time, and
          # asking again cannot make it less blank -- so a turn that was not
          # about the window must not die here.
          def settled?
            model = @source.model
            model.nil? || @book.resolve(model).authoritative?
          rescue ContextWindow::UnknownModel
            true
          end
        end

        # @param backend [#provider, #model, #num_ctx] the run's flag
        #   resolution. All three are sent from inside {#book}'s rescue: an
        #   option hash naming no `--provider` at all (a bench arm, a spec)
        #   makes `#provider` AND `#model` raise {UnknownProvider}, and a
        #   denominator lookup is not where that refusal belongs.
        def initialize(backend:)
          @backend = backend
        end

        # The run's book, or the bench's own when nothing better resolved --
        # which is the ORDINARY case, not an error path: nothing resident yet,
        # no server running, or a provider with no endpoint that reports one.
        #
        # Every refusal below belongs to {Backend#provider}'s real callers,
        # never to a denominator lookup: raising one here would move a flag
        # refusal ahead of the chronicle open, which is the ordering
        # {CLI::ChatLaunch} keeps so a refusal never orphans a fresh journal. A
        # run with a bad `--provider` or no key still refuses, loudly, at the
        # wiring -- both are DEFERRED here, not swallowed, and each has an
        # example saying so.
        #
        # `--api-base` used to be a THIRD deferral, and is not one anymore: T5
        # moved it to {Backend::Endpoint}, refused at CONSTRUCTION -- before a
        # WindowBook can even exist, since {Backend#context_window} only runs
        # on an already-constructed backend. `URI::Error` stays in the rescue
        # set below purely as a backstop; nothing on this path is expected to
        # raise it anymore.
        #
        # @return [Served, ContextWindow]
        def book
          model = @backend.model
          reported = @backend.provider.context_window_tokens(model)
          window = narrowest(reported)
          return ContextWindow.default if window.nil?

          Served.new(model:, window_tokens: window, provenance: vouched_by(reported))
        rescue UnknownProvider, Backend::MissingAPIKey, URI::Error
          ContextWindow.default
        end

        # The run's own model, or nil when no `--provider` resolved one. Asked
        # by {Live}, which has to know WHICH name to judge its answer by; the
        # same rescue as {#book}, because a denominator lookup is not where a
        # missing `--provider` gets refused.
        #
        # @return [String, nil]
        def model
          @backend.model
        rescue UnknownProvider
          nil
        end

        private

        # WHO VOUCHES for the number, which is a different question from what
        # the number is. A `--num-ctx` the provider did not confirm is a
        # REQUEST: plausible enough to divide by -- discarding it over-reports
        # 4x on the ordinary `--num-ctx 32768` case -- and unmeasured, so it may
        # not authorise the irreversible rewrite {Compaction::Source#need_for}
        # withholds from a guess. Measured: `--num-ctx 999999` on a model
        # trained to 262,144 journaled `window=999999 provenance="probed"` while
        # ollama served 262,144.
        #
        # A reported window keeps {ContextWindow::PROBED} even when `--num-ctx`
        # is the smaller of the two: the min is still a ceiling on a runner that
        # ANSWERED, and it is the window the next request is actually served.
        def vouched_by(reported) = reported.nil? ? ContextWindow::GUESSED : ContextWindow::PROBED

        # `--num-ctx` and the provider's answer are not alternatives, they are
        # two ceilings, and the smaller one is what the next request is served.
        # {Provider::Ollama#context_window_tokens} reports the runner resident
        # NOW, and ollama reloads a runner whose `NumCtx` differs from the
        # request's -- so a runner left at 32,768 by `ollama run` or by a
        # sibling session answers 32,768 while a `--num-ctx 8192` request
        # reloads it at 8,192. Answering the larger would over-estimate by 4x,
        # and an over-estimated window means {Compaction::Need::ApproachingWindow}
        # never fires at all, which `context_window.rb` ranks as worse than the
        # crash the conservative fallback replaces. `min` is that method's
        # documented requirement on any caller that sends `num_ctx`, and this
        # is that caller.
        #
        # The provider {#book} asks is a THROWAWAY, deliberately, and the
        # exception to the rule {Wiring::AgentBuild#journal_degradation} states:
        # interrogating a class-level declaration needs no instance, but a
        # served window is a fact about a live SERVER and there is no asking one
        # without a client.
        def narrowest(reported) = [@backend.num_ctx, reported].compact.min
      end
    end
  end
end
