# frozen_string_literal: true

module Lain
  module CLI
    class Backend
      # WHICH window this run's occupancy is measured against.
      #
      # Its own object because resolving a denominator is a second, independent
      # question from resolving a provider and a model, with three moving parts
      # of its own -- an operator flag, a live server, and the shipped table. It
      # depends on MESSAGES -- `#provider`, `#model`, `#num_ctx` -- not on
      # {Backend}'s internals.
      #
      # == Why this exists at all
      #
      # {ContextWindow::DEFAULTS} carries only what somebody has PUBLISHED, so
      # a model id nobody published falls to
      # {ContextWindow::CONSERVATIVE_FALLBACK}'s 8,192. Measured: 86.4%
      # occupancy published while the context was 2.7% full, with a numerator
      # that reproduced the provider's own `input_tokens` to the token. Only
      # the denominator was ever wrong, and only the server knows it.
      #
      # {ContextWindow::CLOUD_WINDOWS} covers shipped Ollama Cloud tags
      # authoritatively with no server asked. LOCAL ollama ids and arbitrary
      # pulled ollama ids still fall to the guess, which is what keeps this class
      # necessary: `ollama.com` has no resident runner to probe, a local one
      # does, and only {Served} can state what it is actually serving.
      class WindowBook
        Lookup = Data.define(:book, :seconds)

        # A book, and how long the probe behind it took.
        class Lookup
          # A probe slower than this charges {Live::REASK_LIMIT}. Well above a
          # local `/api/ps`, measured at about a millisecond answering or
          # refusing, and well below what a turn can absorb once per agent-loop
          # iteration. A probe that runs out
          # {Provider::Ollama::Transport::PROBE_TIMEOUT_SECONDS} is always over it.
          COSTLY_SECONDS = 0.05

          def costly? = seconds > COSTLY_SECONDS
        end

        # A book that answers for ONE model and delegates every other name.
        #
        # It is NOT a {ContextWindow} built by merging the served window into
        # {ContextWindow::DEFAULTS}, and the difference is a live 4-8x
        # over-estimate rather than a nicety. `ContextWindow#matched` falls back
        # to `name.include?(token)` across every key, so a merged key becomes a
        # SUBSTRING rule for every later model name: with `--model qwen3`
        # resident at 32,768, a mid-session `/model qwen3-coder:30b`, `/model
        # qwen3:4b` and `/model qwen3-tiny:0.5b` ALL measured 32,768 -- the
        # forbidden direction, on models whose real windows are 4-8x smaller,
        # and untagged names that are prefixes of tagged ones are the ordinary
        # case here. The server answered about ONE runner, so naming that runner
        # is the only rule a served window can honestly carry.
        #
        # Which names those are is not this object's to decide: it spends by
        # exactly the set {Provider::Ollama#serves?} grants by (see
        # {#initialize}). Three messages, which is the whole duck its three
        # readers send ({StatusFeed}, {Compaction::Source}, {Agent#occupancy}).
        class Served
          # @param model [String] the model the window was reported FOR
          # @param window_tokens [Integer] that model's served window
          # @param provenance [Symbol] who vouches for that number. {PROBED} by
          #   default, because a server answering is what this book was written
          #   for. {ContextWindow::GUESSED} is the `--num-ctx`-alone case: the
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
            # The SAME set {Provider::Ollama#serves?} grants a window by, which
            # matches a runner entry against `[model, "#{model}:latest"]`
            # because ollama appends `:latest` to an untagged request before
            # printing it back -- so a book can exist BECAUSE the server
            # answered for `qwen3:latest` when the operator typed `qwen3`.
            # Spending it by the narrower rule refuses the very name that
            # granted it, and the two readers then disagree by exactly one tag:
            # {Agent#occupancy} divides using `context.model` (the operator's
            # string) while {StatusFeed#occupancy_of} divides using
            # `event.model` (what the provider ECHOED). Measured before the two
            # sets were joined: prompt 22%, the state feed 0.8641, on one turn.
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
          # naming the runner resident right now, which is what
          # {ContextWindow::PROBED} means -- unless the run's `provenance:` says
          # a flag, not a server, is where the number came from.
          #
          # A name this book did NOT probe delegates, provenance and all.
          # Tagging the delegated case probed would be the defect this book
          # exists to fix, pointed the other way: a rewrite authorised by a
          # runner nobody asked about that model. The authority has to travel
          # with the number, or the two halves of one answer disagree.
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
        # The identity is what the three readers share and must go on sharing:
        # {StatusFeed}, {Compaction::Source} and {Agent#occupancy} are each
        # handed this at wiring time and never ask {Backend} again, and three
        # readers dividing by three numbers is the failure the whole arrangement
        # exists to prevent. What changes is the ANSWER inside it.
        #
        # An answer has to be able to change because a `--num-ctx` launched
        # while nothing is resident resolves to a GUESS (see {WindowBook#book}),
        # and a memoized guess is permanent: the runner loads on turn one and
        # the session measures against an unconfirmed number for as long as it
        # runs.
        #
        # The trigger is EXTERNAL, and it is not "on every read": re-resolving
        # per read would give {StatusFeed}, the compaction decision and the
        # prompt line each their own round trip, able to disagree within one
        # turn. {Middleware::ResolveWindow} fires {#reresolve} ONCE at the top
        # of each turn, so every reader inside a turn divides by the same
        # number.
        #
        # It stops two ways. Only a GUESS is worth re-asking, so once the run's
        # own model resolves to something authoritative the asking stops --
        # which is what keeps a hosted run from opening a round trip per turn,
        # and is asserted mechanically by `spec/lain/seams/recorded_run_spec.rb`,
        # whose cassette records exactly ONE `/api/ps` for a two-turn run.
        # {REASK_LIMIT} is the second way, bounding what probes that COST something
        # may add: a slow or silent host is asked at most `1 + REASK_LIMIT` times.
        class Live
          # How many COSTLY re-asks ({Lookup#costly?}) a run tolerates before
          # keeping the answer it has, not counting the resolution at launch.
          #
          # Against a host that DROPS packets each probe costs the full
          # {Provider::Ollama::Transport::PROBE_TIMEOUT_SECONDS}: measured 2.003s
          # per re-resolution, and {Middleware::ResolveWindow} fires once per
          # ITERATION of the agent loop, so a ten-tool-call turn paid +20
          # seconds, every turn, for a number that was never going to arrive. A
          # slow host that does answer costs the same way, answer or not.
          #
          # A cheap probe spends none of it, whatever it found. The runner may
          # load on any later turn -- evicted by a summarizer on another model,
          # re-keyed by a sibling command, or an ollama started after lain -- and
          # charging every guess left a session launched during a reload dividing
          # by 8,192 for good: four `/api/ps` asks, then never again, while
          # ollama served 32,768.
          #
          # Giving up is not settling: the book keeps whatever it has, still
          # tagged GUESSED, so an exhausted budget authorises no rewrite.
          REASK_LIMIT = 3

          # @param source [#lookup, #model] looks a fresh book up, and names the
          #   model whose answer decides whether asking again could help
          def initialize(source:)
            @source = source
            @book = source.lookup.book
            @charged = 0
            @vouched = {}
          end

          # @return [Integer]
          def window_tokens(model) = book_for(model).window_tokens(model)

          # @return [ContextWindow::WindowResolution]
          def resolve(model) = book_for(model).resolve(model)

          # @return [ContextWindow::Occupancy, ContextWindow::Occupancy::None]
          def occupancy(used_tokens, model:) = book_for(model).occupancy(used_tokens, model:)

          # Ask again, if asking could still help.
          #
          # @return [self]
          def reresolve
            return self unless asking_can_help?

            lookup = @source.lookup
            @charged += 1 if lookup.costly?
            @book = lookup.book
            self
          end

          # Adopt the window a provider named while refusing a prompt for not
          # fitting it. The server counted that prompt against the context it
          # had actually loaded, so the number is measured, not requested -- the
          # same fact `/api/ps` states, and it vouches the same way. A runner
          # left smaller by a sibling session is the case this also covers:
          # the request that reloads it is refused against the context it
          # reloaded at, which is later news than any probe.
          #
          # The vouch answers for the model the refused request named, and for
          # that model only: a {Served} book carries one name for the reason its
          # own doc gives, so a refusal after a `/model` switch leaves the run's
          # own model with the answer it had.
          #
          # @param window_tokens [Integer] the refusal's context size
          # @param model [String, nil] the refused request's model; the run's
          #   own when the caller cannot see the request
          # @return [self]
          def vouch(window_tokens, model: @source.model)
            return self if model.nil?

            served = Served.new(model:, window_tokens:)
            @vouched[model.to_s] = served
            @vouched["#{model}:latest"] = served
            self
          end

          private

          def book_for(model) = @vouched.fetch(model.to_s, @book)

          # Two independent reasons not to ask, and they answer different
          # questions: {#settled?} is "a better answer is not possible",
          # {REASK_LIMIT} is "a better answer is not worth waiting for".
          def asking_can_help? = @charged < REASK_LIMIT && !settled?

          # A blank or unresolvable model settles rather than raising: the book
          # is already loud about that wiring bug at READ time, and a turn that
          # was not about the window must not die here.
          def settled?
            model = @source.model
            model.nil? || resolve(model).authoritative?
          rescue ContextWindow::UnknownModel
            true
          end
        end

        # @param backend [#provider, #model, #num_ctx] the run's flag
        #   resolution. All three are sent from inside {#book}'s rescue: an
        #   option hash naming no `--provider` at all (a bench arm, a spec)
        #   makes `#provider` AND `#model` raise {UnknownProvider}, and a
        #   denominator lookup is not where that refusal belongs
        # @param clock [#call] monotonic seconds, read either side of a probe to
        #   price it
        def initialize(backend:, clock: RunClock::MONOTONIC)
          @backend = backend
          @clock = clock
        end

        # The run's book, or the bench's own when nothing better resolved --
        # which is the ORDINARY case, not an error path: nothing resident yet,
        # no server running, or a provider with no endpoint that reports one.
        #
        # Every refusal below is DEFERRED to {Backend#provider}'s real callers,
        # not swallowed: raising one here would move a flag refusal ahead of the
        # chronicle open, which is the ordering {CLI::ChatLaunch} keeps so a
        # refusal never orphans a fresh journal. `URI::Error` is a backstop
        # only -- `--api-base` is refused by {Backend::Endpoint} at
        # construction, before a WindowBook can exist.
        #
        # @return [Served, ContextWindow]
        def book = lookup.book

        # {#book}, with what the probe behind it cost -- which is what {Live}
        # spends its re-asking budget on.
        #
        # @return [Lookup]
        def lookup
          model = @backend.model
          provider = @backend.provider
          started = @clock.call
          probe = provider.window_probe(model)
          Lookup.new(book: book_from(model, probe.window_tokens), seconds: @clock.call - started)
        rescue UnknownProvider, Backend::MissingAPIKey, URI::Error
          Lookup.new(book: ContextWindow.default, seconds: 0.0)
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

        def book_from(model, reported)
          window = narrowest(reported)
          return ContextWindow.default if window.nil?

          Served.new(model:, window_tokens: window, provenance: vouched_by(reported))
        end

        # WHO VOUCHES for the number, a different question from what the number
        # is. A `--num-ctx` the provider did not confirm is a REQUEST: plausible
        # enough to divide by -- discarding it over-reports 4x on the ordinary
        # `--num-ctx 32768` case -- and unmeasured, so it may not authorise the
        # irreversible rewrite {Compaction::Source#need_for} withholds from a
        # guess. Measured: `--num-ctx 999999` on a model trained to 262,144
        # journaled `window=999999 provenance="probed"` while ollama served
        # 262,144.
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
        # reloads it at 8,192. Answering the larger over-estimates by 4x, and an
        # over-estimated window means {Compaction::Need::ApproachingWindow}
        # never fires at all, which `context_window.rb` ranks as worse than the
        # crash the conservative fallback replaces.
        #
        # The provider {#book} asks is a THROWAWAY, deliberately, and the
        # exception to the rule {Wiring#journal_degradation} states:
        # a served window is a fact about a live SERVER and there is no asking
        # one without a client.
        def narrowest(reported) = [@backend.num_ctx, reported].compact.min
      end
    end
  end
end
