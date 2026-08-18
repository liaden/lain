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
          # @param shipped [ContextWindow] answers every other name; the bench's
          #   own book by default, so an unrelated model degrades exactly as it
          #   did before this object existed
          def initialize(model:, window_tokens:, shipped: ContextWindow.default)
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
          # {ContextWindow::PROBED} means, and it is why this book exists.
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
          def resolve(model)
            return @shipped.resolve(model) unless mine?(model)

            ContextWindow::WindowResolution.new(window_tokens: @window_tokens,
                                                provenance: ContextWindow::PROBED)
          end

          # @return [ContextWindow::Occupancy, ContextWindow::Occupancy::None]
          def occupancy(used_tokens, model:)
            ContextWindow::Occupancy.of(used_tokens:, window_tokens: window_tokens(model))
          end

          private

          def mine?(model) = @named && @names.include?(model.to_s)
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
          window = served(model)
          window ? Served.new(model:, window_tokens: window) : ContextWindow.default
        rescue UnknownProvider, Backend::MissingAPIKey, URI::Error
          ContextWindow.default
        end

        private

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
        # A THROWAWAY provider, deliberately, and the exception to the rule
        # {Wiring::AgentBuild#journal_degradation} states: interrogating a
        # class-level declaration needs no instance, but a served window is a
        # fact about a live SERVER and there is no asking one without a client.
        def served(model) = [@backend.num_ctx, @backend.provider.context_window_tokens(model)].compact.min
      end
    end
  end
end
