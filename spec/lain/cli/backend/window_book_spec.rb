# frozen_string_literal: true

# WHICH flags resolve into a book, and how the probe is made, is exercised in
# `spec/lain/cli/backend_spec.rb`'s `#context_window` group -- every example
# there has to build a whole Backend anyway, and the memoization those readers
# depend on is Backend's.
#
# What is here is the one thing that is NOT about Backend's flags: the
# PROVENANCE of the number a book answers with. T9 made that a value a caller
# can ask about, because `:approaching_window` spends a window on an
# irreversible lossy rewrite and a guess must not be allowed to authorise one.
RSpec.describe Lain::CLI::Backend::WindowBook do
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

    # The same set `Provider::Ollama#serves?` grants a window by: ollama appends
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
    # model -- F3 in the opposite direction.
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

    # The number is unchanged: T9 suppresses a trigger, it never moves a
    # denominator, and the three readers that divide by this book must go on
    # getting exactly what they got.
    # T6 gave this book a provenance because `--num-ctx` alone builds one with
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
        .to raise_error(ArgumentError, /unknown provenance :measured/)
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
  # exact wiring F3 broke under.
  describe "#book" do
    def backend(served_window:, num_ctx: nil)
      provider = instance_double(Lain::Provider::Ollama, context_window_tokens: served_window)
      instance_double(Lain::CLI::Backend, model: "qwen3:4b", num_ctx:, provider:)
    end

    it "answers the bench's own book when the provider reports no served window" do
      expect(described_class.new(backend: backend(served_window: nil)).book)
        .to equal(Lain::ContextWindow.default)
    end

    # The F3 path in one line: no runner resident, an ollama id no
    # Anthropic-shaped table carries, so the number is a floor somebody picked.
    it "resolves an unknown model through that book as a guess" do
      resolution = described_class.new(backend: backend(served_window: nil)).book.resolve("qwen3:4b")

      expect(resolution.window_tokens).to eq(Lain::ContextWindow::CONSERVATIVE_FALLBACK)
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

    # T6, and the measured defect it fixes. `--num-ctx 999999` on a model
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
    def source(*books, model: "qwen3:4b")
      answers = books.dup
      Class.new do
        attr_reader :asked

        define_method(:initialize) { @asked = 0 }
        define_method(:model) { model }
        define_method(:book) do
          @asked += 1
          answers.length > 1 ? answers.shift : answers.first
        end
      end.new
    end

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

    # T6 FIX ROUND, and a behaviour change made deliberately. "Re-resolves until
    # authoritative" silently means "never stops" for the users least able to
    # diagnose it: an ollama model the shipped table does not carry resolves
    # GUESSED through {ContextWindow::CONSERVATIVE_FALLBACK}, so no answer short
    # of a runner can ever settle it. Measured against a black-holed host at
    # 2.003s per re-resolution -- and {Middleware::ResolveWindow} fires once per
    # ITERATION of the agent loop, so a ten-tool-call turn paid +20s for a number
    # that was never going to arrive.
    describe "the budget on re-asking" do
      it "gives up after a fixed few re-asks and keeps the answer it has" do
        never_settles = source(guessed(16_384))
        live = described_class.new(source: never_settles)

        10.times { live.reresolve }

        expect(never_settles.asked).to eq(4)
        expect(live.window_tokens("qwen3:4b")).to eq(16_384)
      end

      # The budget must not cost the run the correction it exists for. Ollama
      # fixes a runner's context at LOAD time and the first request is what
      # loads it, so the answer -- if it is coming -- arrives within the first
      # couple of iterations, which is what the limit is sized for.
      it "still upgrades a guess that arrives inside the budget" do
        arriving = source(guessed(16_384), guessed(16_384), probed(32_768))
        live = described_class.new(source: arriving)

        3.times { live.reresolve }

        expect(live.resolve("qwen3:4b").provenance).to eq(Lain::ContextWindow::PROBED)
        expect(arriving.asked).to eq(3)
      end

      # Spending the budget is not the same as settling, and the difference is
      # what a later reader needs: the run kept a GUESS, and a guess still may
      # not authorise a rewrite.
      it "keeps the exhausted answer a guess, so it still authorises nothing" do
        live = described_class.new(source: source(guessed(16_384)))

        10.times { live.reresolve }

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
