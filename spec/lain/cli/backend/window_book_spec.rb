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
  end
end
