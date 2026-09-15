# frozen_string_literal: true

# WHICH flags resolve into a book, and how the probe is made, is exercised in
# `spec/lain/cli/backend_spec.rb`'s `#context_window` group -- every example
# there has to build a whole Backend anyway, and the memoization those readers
# depend on is Backend's.
#
# What is here is the one thing that is NOT about Backend's flags: the
# PROVENANCE of the number a book answers with. It is a value a caller can ask
# about, because `:approaching_window` spends a window on an irreversible lossy
# rewrite and a guess must not be allowed to authorise one.
RSpec.describe Lain::CLI::Backend::WindowBook do
  def probed_by(*probes, num_ctx: nil)
    provider = instance_double(Lain::Provider::Ollama)
    allow(provider).to receive(:window_probe).and_return(*probes)
    instance_double(Lain::CLI::Backend, model: "qwen3:4b", num_ctx:, provider:)
  end

  # A clock that moves `seconds` between any two readings, so every probe
  # takes exactly that long without a spec ever waiting on one.
  def clock_costing(seconds)
    now = 0.0
    -> { now += seconds }
  end

  let(:probe) { Lain::Provider::WindowProbe }
  let(:costly) { Lain::CLI::Backend::WindowBook::Lookup::COSTLY_SECONDS }

  describe Lain::CLI::Backend::WindowBook::Served do
    # The narrower book underneath, carrying its own fallback, so an example can
    # tell "delegated and matched" from "delegated and guessed" without leaning
    # on the shipped Anthropic table.
    def shipped = Lain::ContextWindow.new(windows: { "sonnet" => 200_000 }, fallback: 8_192)

    def served(model: "qwen3", window_tokens: 32_768) = described_class.new(model:, window_tokens:, shipped:)

    # The server answered about ONE resident runner. That is the only window
    # anywhere in this system that was actually MEASURED.
    it "calls the window it was built for probed" do
      resolution = served.resolve("qwen3")

      expect(resolution.window_tokens).to eq(32_768)
      expect(resolution.provenance).to eq(Lain::ContextWindow::PROBED)
      expect(resolution).to be_authoritative
    end

    # The same set `Provider::Ollama#runs?` grants a window by: ollama appends
    # `:latest` to an untagged request before printing it back, so the book
    # exists BECAUSE the server answered for `qwen3:latest` when the operator
    # typed `qwen3`. Spending it by a narrower rule would refuse the very name
    # that granted it.
    it "calls the tagged form of its own name probed too" do
      expect(served.resolve("qwen3:latest").provenance).to eq(Lain::ContextWindow::PROBED)
    end

    # The escalation trigger this card was given, settled in the safe
    # direction: a Served book answering for a model it did NOT probe is
    # published (or guessed) by whatever `shipped` says. Calling it probed
    # would hand a rewrite the authority of a runner nobody asked about that
    # model -- the guessed-window defect in the opposite direction.
    it "is not probed for a model it merely delegated" do
      resolution = served.resolve("claude-sonnet-4-6")

      expect(resolution.window_tokens).to eq(200_000)
      expect(resolution.provenance).to eq(Lain::ContextWindow::PUBLISHED)
    end

    it "is guessed for a delegated model the shipped book only has a fallback for" do
      resolution = served.resolve("qwen3-coder:30b")

      expect(resolution.window_tokens).to eq(8_192)
      expect(resolution.provenance).to eq(Lain::ContextWindow::GUESSED)
      expect(resolution).not_to be_authoritative
    end

    # A blank model is a WIRING bug and {ContextWindow} is loud about one;
    # answering for it here would swallow that.
    it "still refuses a blank model through the book it delegates to" do
      expect { served.resolve("   ") }
        .to raise_error(Lain::ContextWindow::UnknownModel, /wiring bug/)
    end

    # The number is unchanged: provenance suppresses a trigger, it never moves a
    # denominator, and the three readers that divide by this book must go on
    # getting exactly what they got.
    # This book gained a provenance because `--num-ctx` alone builds one with
    # no server behind it. The DEFAULT stays probed: every construction that
    # predates the keyword is a window a runner reported, and
    # `spec/lain/compaction/source_spec.rb` builds one directly to mean exactly
    # that.
    it "is probed by default, so a construction that names no provenance still means measured" do
      expect(described_class.new(model: "qwen3", window_tokens: 32_768).resolve("qwen3").provenance)
        .to eq(Lain::ContextWindow::PROBED)
    end

    it "carries a guessed provenance for its own model when told to" do
      resolution = described_class.new(model: "qwen3", window_tokens: 16_384,
                                       provenance: Lain::ContextWindow::GUESSED, shipped:).resolve("qwen3")

      expect(resolution.window_tokens).to eq(16_384)
      expect(resolution).not_to be_authoritative
    end

    # Loud at CONSTRUCTION, not on the first turn that reads it: a book is
    # built at launch and read for the whole session, so a typo'd provenance
    # discovered on the render path is a chat that dies mid-turn.
    it "refuses an unknown provenance where the mistake was made" do
      expect { described_class.new(model: "qwen3", window_tokens: 32_768, provenance: :measured) }
        .to raise_error(ArgumentError, /provenance must be one of .*, got :measured/)
    end

    it "answers the same numbers #window_tokens always did" do
      book = served

      expect(book.window_tokens("qwen3")).to eq(book.resolve("qwen3").window_tokens)
      expect(book.window_tokens("claude-sonnet-4-6")).to eq(200_000)
      expect(book.window_tokens("qwen3-coder:30b")).to eq(8_192)
    end
  end

  # The ordinary case, not an error path: nothing resident yet, no server
  # running, or a provider with no endpoint that reports one. It is also the
  # exact wiring the guessed-window defect broke under.
  describe "#book" do
    def backend(served_window:, num_ctx: nil)
      probe = served_window ? Lain::Provider::WindowProbe.resident(served_window) : Lain::Provider::WindowProbe::NONE_RESIDENT
      probed_by(probe, num_ctx:)
    end

    # The re-asking budget is charged by what a probe COST, which only the
    # lookup that timed it can say. What the probe answered decides the book;
    # how long it took decides whether asking again is affordable.
    describe "#lookup" do
      it "charges a probe that took longer than the threshold, whatever it answered" do
        lookup = described_class.new(backend: probed_by(probe::NONE_RESIDENT), clock: clock_costing(0.25)).lookup

        expect(lookup).to be_costly
      end

      it "charges nothing for a fast refused connection, so an ollama started later is still learned" do
        lookup = described_class.new(backend: probed_by(probe::UNREACHABLE), clock: clock_costing(0.001)).lookup

        expect(lookup).not_to be_costly
        expect(lookup.book).to equal(Lain::ContextWindow.default)
      end

      it "always charges a probe that ran out the probe timeout" do
        timeout = Lain::Provider::Ollama::Transport::PROBE_TIMEOUT_SECONDS

        expect(timeout).to be > costly
        expect(described_class.new(backend: probed_by(probe::UNREACHABLE), clock: clock_costing(timeout)).lookup)
          .to be_costly
      end

      it "keeps an unconfirmed --num-ctx as the guess, whoever failed to confirm it" do
        lookup = described_class.new(backend: probed_by(probe::UNREACHABLE, num_ctx: 16_384)).lookup

        expect(lookup.book.resolve("qwen3:4b").window_tokens).to eq(16_384)
        expect(lookup.book.resolve("qwen3:4b")).not_to be_authoritative
      end
    end

    it "answers the bench's own book when the provider reports no served window" do
      expect(described_class.new(backend: backend(served_window: nil)).book)
        .to equal(Lain::ContextWindow.default)
    end

    # The guessed-window path in one line: no runner resident, an ollama id no
    # Anthropic-shaped table carries, so the number is a floor somebody picked.
    it "resolves an unknown model through that book as a guess" do
      resolution = described_class.new(backend: backend(served_window: nil)).book.resolve("qwen3:4b")

      expect(resolution.window_tokens).to eq(Lain::ContextWindow::CONSERVATIVE_FALLBACK)
      expect(resolution).not_to be_authoritative
    end

    # End to end: the cloud arm's window needs NO provider
    # change. `ollama.com` has no resident runner to probe, so the provider
    # reports nil and `#book` hands back the shipped book -- which now carries
    # the cloud catalogue, so the answer is authoritative rather than the 8,192
    # floor the same path gives `qwen3:4b` two examples above. Asserted as
    # `authoritative?`, not merely non-nil: authority is what
    # {Lain::Compaction::Source} spends on an irreversible rewrite.
    def cloud_backend(num_ctx:)
      provider = instance_double(Lain::Provider::Ollama, window_probe: Lain::Provider::WindowProbe::NONE_RESIDENT)
      instance_double(Lain::CLI::Backend, model: "gpt-oss:120b-cloud", num_ctx:, provider:)
    end

    it "resolves a shipped cloud model authoritatively, given no --num-ctx" do
      resolution = described_class.new(backend: cloud_backend(num_ctx: nil)).book.resolve("gpt-oss:120b-cloud")

      expect(resolution).to be_authoritative
      expect(resolution.provenance).to eq(Lain::ContextWindow::PUBLISHED)
      expect(resolution.window_tokens).to eq(128_000)
    end

    # The other half of the same path, recorded rather than fixed: `narrowest`
    # only returns nil when BOTH ceilings are absent, so a `--num-ctx` skips the
    # early return and `vouched_by(nil)` tags the answer GUESSED -- the shipped
    # table is never consulted and {Lain::Compaction::Source} declines
    # `:approaching_window` on it. That is pre-existing and identical on the
    # local arm; the cloud catalogue publishes windows, it does not change who
    # vouches for one. Pinned so the day it changes, it changes here first.
    it "falls back to an unauthoritative --num-ctx for the same cloud model" do
      resolution = described_class.new(backend: cloud_backend(num_ctx: 16_384)).book.resolve("gpt-oss:120b-cloud")

      expect(resolution.window_tokens).to eq(16_384)
      expect(resolution.provenance).to eq(Lain::ContextWindow::GUESSED)
      expect(resolution).not_to be_authoritative
    end

    it "resolves the served model as probed once a runner answers" do
      resolution = described_class.new(backend: backend(served_window: 32_768)).book.resolve("qwen3:4b")

      expect(resolution.window_tokens).to eq(32_768)
      expect(resolution.provenance).to eq(Lain::ContextWindow::PROBED)
    end

    # `--num-ctx` and the provider's answer are two ceilings and the smaller is
    # what the next request is served -- but the smaller is still a MEASURED
    # ceiling on a runner that answered, so it keeps its authority.
    it "keeps a num-ctx-limited window probed" do
      resolution = described_class.new(backend: backend(served_window: 32_768, num_ctx: 8_192))
                                  .book.resolve("qwen3:4b")

      expect(resolution.window_tokens).to eq(8_192)
      expect(resolution.provenance).to eq(Lain::ContextWindow::PROBED)
    end

    # The measured defect this fixes. `--num-ctx 999999` on a model
    # trained to 262,144 journaled `window=999999 provenance="probed"` while
    # ollama served 262,144: with nothing resident the provider answers nil,
    # `.compact` drops it, and the operator's number became the whole book
    # tagged with the tier whose docstring says "the server said so".
    #
    # Kept as the DENOMINATOR, because discarding a plausible number would
    # over-report 4x on the ordinary `--num-ctx 32768` case. Refused as an
    # AUTHORITY, because nobody measured it, and an unmeasured window may not
    # authorise an irreversible lossy rewrite.
    describe "a --num-ctx no server has confirmed" do
      let(:resolution) do
        described_class.new(backend: backend(served_window: nil, num_ctx: 16_384)).book.resolve("qwen3:4b")
      end

      it "is still the denominator" do
        expect(resolution.window_tokens).to eq(16_384)
      end

      it "is guessed, not probed" do
        expect(resolution.provenance).to eq(Lain::ContextWindow::GUESSED)
      end

      it "may not authorise a rewrite" do
        expect(resolution).not_to be_authoritative
      end
    end
  end

  # The run's ONE book object, and the answer inside it that may still improve.
  # Splitting those two is what this class is for: the three readers
  # ({StatusFeed}, {Compaction::Source}, {Agent#occupancy}) are handed the same
  # instance at wiring time and never asked again, so refreshing the ANSWER is
  # the only way a session started before its runner was loaded can ever stop
  # dividing by a guess.
  describe Lain::CLI::Backend::WindowBook::Live do
    # A source that answers a different book each time it is asked, which is
    # exactly the situation the trigger exists for: the first `/api/ps` says
    # nothing is resident, a later one names the runner.
    # It counts the askings, because "it stopped asking" is the property, and a
    # book that merely happens to answer the same number twice would satisfy an
    # assertion about the number alone.
    #
    # An answer is a book a cheap probe found, or a {#slow} one, which charges
    # the re-asking budget.
    def source(*answers, model: "qwen3:4b")
      lookups = answers.map { |answer| answer.is_a?(lookup_class) ? answer : cheap(answer) }
      Class.new do
        attr_reader :asked

        define_method(:initialize) { @asked = 0 }
        define_method(:model) { model }
        define_method(:lookup) do
          @asked += 1
          lookups.length > 1 ? lookups.shift : lookups.first
        end
      end.new
    end

    def lookup_class = Lain::CLI::Backend::WindowBook::Lookup

    def cheap(book) = lookup_class.new(book:, seconds: 0.0)
    def slow(book) = lookup_class.new(book:, seconds: Lain::CLI::Backend::WindowBook::Lookup::COSTLY_SECONDS * 5)

    def guessed(window_tokens) = book_for(window_tokens, Lain::ContextWindow::GUESSED)
    def probed(window_tokens) = book_for(window_tokens, Lain::ContextWindow::PROBED)

    def book_for(window_tokens, provenance)
      Lain::CLI::Backend::WindowBook::Served.new(model: "qwen3:4b", window_tokens:, provenance:)
    end

    it "answers its source's book before anything triggers a re-resolution" do
      live = described_class.new(source: source(guessed(16_384)))

      expect(live.resolve("qwen3:4b").provenance).to eq(Lain::ContextWindow::GUESSED)
      expect(live.window_tokens("qwen3:4b")).to eq(16_384)
    end

    # The self-correction, in one object: the guess is what the run divides by
    # until a server confirms one, and then the confirmed number replaces it.
    it "upgrades a guess to the probed answer when re-resolved" do
      live = described_class.new(source: source(guessed(16_384), probed(32_768)))

      live.reresolve

      expect(live.resolve("qwen3:4b").provenance).to eq(Lain::ContextWindow::PROBED)
      expect(live.window_tokens("qwen3:4b")).to eq(32_768)
    end

    # The half that keeps the cost bounded and the answer stable: a measured
    # window is the best answer this book can ever hold, so re-resolving it
    # would spend a round trip per turn to learn nothing. `spec/lain/seams/
    # recorded_run_spec.rb` depends on this mechanically -- its cassette
    # records exactly ONE `/api/ps` for a two-turn run.
    it "stops asking once the answer is authoritative" do
      probing = source(probed(32_768), guessed(8_192))
      live = described_class.new(source: probing)

      3.times { live.reresolve }

      expect(probing.asked).to eq(1)
      expect(live.window_tokens("qwen3:4b")).to eq(32_768)
    end

    # A published window off the shipped table is a real number somebody wrote
    # down, not a floor nobody chose -- so a hosted run settles on its first
    # answer and never probes again, which is what keeps this trigger free for
    # every provider that publishes no served window at all.
    it "treats a published table hit as settled too" do
      shipped = source(Lain::ContextWindow.default, probed(1), model: "claude-opus-4-5")

      described_class.new(source: shipped).reresolve

      expect(shipped.asked).to eq(1)
    end

    # A blank `--model` is a wiring bug, and the book it delegates to is loud
    # about one. Asking again cannot make it less blank, so the trigger settles
    # rather than raising out of a turn that was not about the window.
    it "settles rather than raising when the run resolved no model to ask about" do
      blank = source(Lain::ContextWindow.default, probed(1), model: "  ")
      live = described_class.new(source: blank)

      expect { live.reresolve }.not_to raise_error
      expect(blank.asked).to eq(1)
    end

    # "Re-resolves until authoritative" means "never stops" for an ollama model
    # the shipped table does not carry: it resolves GUESSED through
    # {ContextWindow::CONSERVATIVE_FALLBACK}, so no answer short of a runner can
    # settle it. That is affordable while a probe is cheap and ruinous while it
    # is not -- measured against a black-holed host at 2.003s per re-resolution,
    # and {Middleware::ResolveWindow} fires once per ITERATION of the agent loop,
    # so a ten-tool-call turn paid +20s. So the budget counts costly probes only.
    describe "the budget on re-asking" do
      # The same budget over the real lookup, charged by a clock rather than
      # by a scripted verdict: the three hosts it was argued over.
      describe "over a timed lookup" do
        def live_over(*probes, seconds:)
          backend = probed_by(*probes)
          book = Lain::CLI::Backend::WindowBook.new(backend:, clock: clock_costing(seconds))
          [described_class.new(source: book), backend.provider]
        end

        it "stops asking a 250 ms nothing-resident server after 1 + REASK_LIMIT probes" do
          live, provider = live_over(probe::NONE_RESIDENT, seconds: 0.25)

          10.times { live.reresolve }

          expect(provider).to have_received(:window_probe).exactly(1 + described_class::REASK_LIMIT).times
        end

        it "learns a model that loads after three turns of refused connections" do
          live, = live_over(*Array.new(4, probe::UNREACHABLE), probe.resident(32_768), seconds: 0.001)

          4.times { live.reresolve }

          expect(live.resolve("qwen3:4b")).to be_authoritative
          expect(live.window_tokens("qwen3:4b")).to eq(32_768)
        end

        it "still bounds a black-holed host" do
          live, provider = live_over(probe::UNREACHABLE,
                                     seconds: Lain::Provider::Ollama::Transport::PROBE_TIMEOUT_SECONDS)

          10.times { live.reresolve }

          expect(provider).to have_received(:window_probe).exactly(1 + described_class::REASK_LIMIT).times
        end
      end

      it "gives up after a fixed few slow re-asks and keeps the answer it has" do
        never_settles = source(slow(guessed(16_384)))
        live = described_class.new(source: never_settles)

        10.times { live.reresolve }

        expect(never_settles.asked).to eq(4)
        expect(live.window_tokens("qwen3:4b")).to eq(16_384)
      end

      # The budget must not cost the run the correction it exists for: an answer
      # that arrives while some of it is left is taken.
      it "still upgrades a guess that arrives inside the budget" do
        arriving = source(slow(guessed(16_384)), slow(guessed(16_384)), probed(32_768))
        live = described_class.new(source: arriving)

        3.times { live.reresolve }

        expect(live.resolve("qwen3:4b").provenance).to eq(Lain::ContextWindow::PROBED)
        expect(arriving.asked).to eq(3)
      end

      # The budget is for probes that cost something to repeat. A local server
      # answering "nothing resident" does so in about a millisecond, and the
      # runner it has not loaded yet -- evicted by a summarizer on another
      # model, re-keyed by a sibling command -- may load on any later turn.
      it "re-asks a cheap nothing-resident server for as long as it takes" do
        answers = Array.new(10) { guessed(16_384) } << probed(32_768)
        loading = source(*answers)
        live = described_class.new(source: loading)

        10.times { live.reresolve }

        expect(live.resolve("qwen3:4b")).to be_authoritative
        expect(live.window_tokens("qwen3:4b")).to eq(32_768)
      end

      it "spends nothing on a cheap re-ask" do
        mixed = source(slow(guessed(16_384)), guessed(16_384), guessed(16_384), guessed(16_384),
                       slow(guessed(16_384)), slow(guessed(16_384)))
        live = described_class.new(source: mixed)

        10.times { live.reresolve }

        expect(mixed.asked).to eq(7)
      end

      # Spending the budget is not the same as settling, and the difference is
      # what a later reader needs: the run kept a GUESS, and a guess still may
      # not authorise a rewrite.
      it "keeps the exhausted answer a guess, so it still authorises nothing" do
        live = described_class.new(source: source(slow(guessed(16_384))))

        10.times { live.reresolve }

        expect(live.resolve("qwen3:4b")).not_to be_authoritative
      end
    end

    # An over-window refusal is the server counting the prompt against the
    # context it actually loaded, and it names that context. That is the same
    # fact `/api/ps` states, arriving by another road, so it vouches the same.
    describe "a window an over-window refusal names" do
      it "becomes the authoritative answer for the run's model" do
        live = described_class.new(source: source(guessed(16_384)))

        live.vouch(32_768)

        expect(live.resolve("qwen3:4b")).to be_authoritative
        expect(live.window_tokens("qwen3:4b")).to eq(32_768)
      end

      it "lifts the refusal /critique gives a guessed window" do
        live = described_class.new(source: source(guessed(16_384)))
        budget = -> { Lain::Review::Critique::Budget.for(window: live, model: "qwen3:4b", max_tokens: 512, prelude: "") }

        expect { budget.call }.to raise_error(Lain::Review::Critique::Refused, /guessed/)
        live.vouch(32_768)
        expect(budget.call.window_tokens).to eq(32_768)
      end

      # A runner left small by a sibling session answers `/api/ps` with its own
      # context, and the request that reloads it is refused against the new
      # one. The refusal is the later fact.
      it "replaces a stale probed window too" do
        live = described_class.new(source: source(probed(8_192)))

        live.vouch(16_384)

        expect(live.window_tokens("qwen3:4b")).to eq(16_384)
      end

      it "settles the book, so nothing is asked again" do
        asking = source(guessed(16_384))
        live = described_class.new(source: asking)

        live.vouch(32_768)
        3.times { live.reresolve }

        expect(asking.asked).to eq(1)
      end

      # The refusal answered one request, for one model. After a `/model`
      # switch that is not the run's own, and the run's own keeps its answer.
      it "vouches a switched model's window and leaves the launch model's book untouched" do
        live = described_class.new(source: source(probed(32_768)))

        live.vouch(65_536, model: "qwen3-coder:30b")

        expect(live.resolve("qwen3-coder:30b")).to be_authoritative
        expect(live.window_tokens("qwen3-coder:30b")).to eq(65_536)
        expect(live.window_tokens("qwen3:4b")).to eq(32_768)
      end

      it "vouches for nothing when the run resolved no model" do
        live = described_class.new(source: source(Lain::ContextWindow.default, model: nil))

        live.vouch(32_768)

        expect(live.resolve("qwen3:4b")).not_to be_authoritative
      end
    end

    it "measures occupancy through whichever answer it currently holds" do
      live = described_class.new(source: source(guessed(16_384), probed(32_768)))

      expect(live.occupancy(8_192, model: "qwen3:4b").ratio).to eq(0.5)
      live.reresolve
      expect(live.occupancy(8_192, model: "qwen3:4b").ratio).to eq(0.25)
    end
  end
end
