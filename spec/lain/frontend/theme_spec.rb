# frozen_string_literal: true

require "stringio"

RSpec.describe Lain::Frontend::Theme do
  let(:colored) { Pastel.new(enabled: true) }

  def theme(pastel: colored, **)
    described_class.new(pastel:, **)
  end

  describe "#paint" do
    it "styles text by naming a token" do
      expect(theme.paint(:error, "boom")).to eq(colored.red.bold("boom"))
    end

    it "raises rather than returning unstyled text for an unregistered token" do
      expect { theme.paint(:chartreuse, "boom") }
        .to raise_error(described_class::UnknownToken, /chartreuse/)
    end

    it "names every registered token in the raised message, so a typo is diagnosable" do
      expect { theme.paint(:erorr, "boom") }.to raise_error(described_class::UnknownToken, /error/)
    end

    it "leaves a token with no style unstyled, without raising" do
      expect(theme.paint(:tool_output, "plain\n")).to eq("plain\n")
    end

    it "names intent, never a file descriptor" do
      expect { theme.paint(:stdout, "x") }.to raise_error(described_class::UnknownToken)
      expect { theme.paint(:stderr, "x") }.to raise_error(described_class::UnknownToken)
    end
  end

  describe "DEFAULT_TOKENS" do
    it "is deeply frozen, so no caller can change what every theme in the process paints" do
      expect { described_class::DEFAULT_TOKENS[:error] << :underline }.to raise_error(FrozenError)
    end

    it "is Ractor.shareable?, the mechanical statement that it holds no mutable state" do
      expect(Ractor.shareable?(described_class::DEFAULT_TOKENS)).to be(true)
    end

    it "never freezes a caller's own array, at any depth" do
      mine = %i[magenta]
      [256, 16, 8, 0].each { |mode| theme(tokens: { mine: }, detect: -> { mode }) }

      expect(mine).not_to be_frozen
    end

    it "deep-freezes a caller's merged table too" do
      subject = theme(tokens: described_class::DEFAULT_TOKENS.merge(loud: %i[magenta]))

      expect { subject.paint(:loud, "x") }.not_to raise_error
      expect(subject.paint(:loud, "x")).to eq(colored.magenta("x"))
    end
  end

  describe "today's default appearance" do
    it "renders a response the colour it carries today" do
      expect(theme.paint(:response, "hi")).to eq(colored.cyan("hi"))
    end

    it "renders an error the colour it carries today" do
      expect(theme.paint(:error, "nope")).to eq(colored.red.bold("nope"))
    end

    it "renders a question the colour it carries today" do
      expect(theme.paint(:question_label, "the agent asks:")).to eq(colored.yellow.bold("the agent asks:"))
      expect(theme.paint(:question, "why?")).to eq(colored.yellow("why?"))
    end

    it "renders tool output the colours it carries today" do
      expect(theme.paint(:label, "[tu_1 stderr]")).to eq(colored.dim("[tu_1 stderr]"))
      expect(theme.paint(:tool_error, "boom\n")).to eq(colored.red("boom\n"))
    end

    it "keeps the harness's own error line and a subprocess's error bytes as two ideas" do
      expect(theme.paint(:error, "boom")).not_to eq(theme.paint(:tool_error, "boom"))
    end

    it "renders the prompt, the rule, and a warning the way they read today" do
      expect(theme.paint(:prompt, "> ")).to eq(colored.bold("> "))
      expect(theme.paint(:rule, "---")).to eq(colored.dim("---"))
      expect(theme.paint(:warning, "careful")).to eq(colored.yellow("careful"))
    end
  end

  describe "#depth" do
    it "reports the terminal's colour depth" do
      expect(theme(detect: -> { 16 }).depth).to eq(16)
    end

    it "reports no colour at all when styling is disabled" do
      expect(theme(pastel: Pastel.new(enabled: false), detect: -> { 16 }).depth).to eq(0)
    end

    it "asks the detector once, at construction, so no render forks a subprocess" do
      calls = 0
      subject = theme(detect: lambda {
        calls += 1
        16
      })

      expect(calls).to eq(1)

      subject.paint(:response, "x")
      expect(calls).to eq(1)
    end

    it "asks the detector once even when concurrent threads share one theme" do
      calls = Queue.new
      subject = theme(detect: lambda {
        calls << :asked
        16
      })
      Array.new(8) { Thread.new { subject.depth } }.each(&:join)

      expect(calls.size).to eq(1)
    end

    # depth is advisory: TERM=dumb on a real tty reports 0 colours, and Pastel
    # still emits escapes there. `enabled?`, never `depth.zero?`, is the test a
    # caller uses to predict plain bytes.
    it "still emits escapes on a terminal claiming no colour, because enabled? decides" do
      subject = theme(detect: -> { 0 })

      expect(subject.depth).to eq(0)
      expect(subject).to be_enabled
      expect(subject.paint(:response, "x")).to eq(colored.cyan("x"))
    end

    it "emits plain bytes exactly when it reports itself disabled" do
      subject = described_class.new(pastel: Pastel.new(enabled: false), detect: -> { 256 })

      expect(subject).not_to be_enabled
      expect(subject.paint(:response, "x")).to eq("x")
    end
  end

  describe "a token beyond the terminal's depth" do
    let(:tokens) { described_class::DEFAULT_TOKENS.merge(loud: %i[bright_red bold]) }

    it "names the bright colour when the terminal has 16" do
      expect(theme(tokens:, detect: -> { 16 }).paint(:loud, "x")).to eq(colored.bright_red.bold("x"))
    end

    it "falls back to the base colour when the terminal has only 8" do
      expect(theme(tokens:, detect: -> { 8 }).paint(:loud, "x")).to eq(colored.red.bold("x"))
    end
  end

  describe ".for" do
    it "emits no escape sequences for any token on a non-tty stream" do
      subject = described_class.for(StringIO.new)

      painted = subject.tokens.map { |token| subject.paint(token, "text") }

      expect(painted).to all(eq("text"))
    end

    it "still fails loudly on an unknown token when styling is off" do
      expect { described_class.for(StringIO.new).paint(:chartreuse, "x") }
        .to raise_error(described_class::UnknownToken)
    end

    it "reports itself disabled on a non-tty stream" do
      expect(described_class.for(StringIO.new)).not_to be_enabled
    end
  end

  describe "#tokens" do
    it "answers the registered vocabulary" do
      expect(theme.tokens).to include(:response, :error, :question, :tool_error, :prompt)
    end

    it "answers whether a name is registered" do
      expect(theme.token?(:response)).to be(true)
      expect(theme.token?(:chartreuse)).to be(false)
    end
  end
end
