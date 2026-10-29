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
      expect(described_class::DEFAULT_TOKENS).to be_deeply_frozen
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

    it "renders a heading bold and a command name in its own colour" do
      expect(theme.paint(:heading, "commands:")).to eq(colored.bold("commands:"))
      expect(theme.paint(:command_name, "/help")).to eq(colored.cyan("/help"))
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

    context "with NO_COLOR set on a terminal" do
      let(:terminal) { Class.new(StringIO) { def tty? = true }.new }

      before { stub_const("ENV", ENV.to_h.merge("NO_COLOR" => "1")) }

      it "has depth 0 and paints the text unchanged" do
        subject = described_class.for(terminal)

        expect([subject.depth, subject.paint(:error, "boom"), subject.enabled?]).to eq([0, "boom", false])
      end
    end

    it "still paints on a terminal when NO_COLOR is unset" do
      terminal = Class.new(StringIO) { def tty? = true }.new
      stub_const("ENV", ENV.to_h.except("NO_COLOR"))

      expect(described_class.for(terminal)).to be_enabled
    end
  end

  describe "STYLES" do
    it "names every attribute Pastel can apply, which is all a config may ask a token to wear" do
      expect(described_class::STYLES).to include(:green, :bold, :bright_red, :on_blue).and(be_deeply_frozen)
      expect(described_class::STYLES).not_to include(:chartreuse)
    end
  end

  describe "STYLES excludes the resets" do
    it "leaves out clear and reset, which end a style rather than being one" do
      expect(described_class::STYLES).not_to include(:clear, :reset)
    end
  end

  describe "the user's configured theme" do
    let(:terminal) { Class.new(StringIO) { def tty? = true }.new }
    let(:paths) { Lain::Paths.new(env: { "HOME" => home, "XDG_CONFIG_HOME" => home }) }
    let(:home) { Dir.mktmpdir }

    before do
      stub_const("ENV", ENV.to_h.except("NO_COLOR"))
      FileUtils.mkdir_p(File.join(home, "lain"))
      File.write(paths.user_config, "theme response: %w[green]\n")
      Lain::Project::Trust.for_user(paths:).grant!
    end

    after { FileUtils.rm_rf(home) }

    it "recolours the declared token and keeps the rest" do
      subject = described_class.configured(terminal, paths:)

      expect([subject.paint(:response, "hi"), subject.paint(:rule, "x")])
        .to eq([Pastel.new(enabled: true).green("hi"), Pastel.new(enabled: true).dim("x")])
    end

    it "is what on_stdout builds, over $stdout" do
      allow(described_class).to receive(:configured).and_call_original

      described_class.on_stdout(paths:)

      expect(described_class).to have_received(:configured).with($stdout, paths:)
    end

    it "hands a terminal its theme and the pastel that theme paints with" do
      subject = described_class.configured(terminal, paths:)

      expect(subject.terminal).to eq(theme: subject, pastel: subject.pastel)
    end

    it "honours NO_COLOR in the theme and in the pastel the terminal is handed alike" do
      stub_const("ENV", ENV.to_h.merge("NO_COLOR" => "1"))
      handed = described_class.configured(terminal, paths:).terminal

      expect([handed[:theme].paint(:response, "hi"), handed[:pastel].green("hi")]).to eq(%w[hi hi])
    end
  end

  describe "#tokens" do
    it "answers the registered vocabulary" do
      expect(theme.tokens).to include(:response, :error, :question, :tool_error, :prompt)
    end
  end
end
