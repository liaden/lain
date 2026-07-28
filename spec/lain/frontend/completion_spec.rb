# frozen_string_literal: true

require "pastel"
require "stringio"
require "tmpdir"
require "tty-cursor"

RSpec.describe Lain::Frontend::Completion do
  # Every drawn byte lands here instead of a terminal, so an assertion reads
  # the menu exactly as the screen would receive it.
  let(:screen) { [] }
  let(:theme) { Lain::Frontend::Theme.new(pastel: Pastel.new(enabled: false)) }

  def command(name) = double(name:)

  def completion(sources, theme: self.theme, limit: 8)
    described_class.new(sources:, theme:, screen: screen.method(:<<), limit:)
  end

  def commands(*names)
    Lain::Frontend::Completion::Sources.new(commands: names.map { |name| command(name) })
  end

  def drawn = screen.join

  describe "#call" do
    it "offers a registered command for a slash prefix" do
      completion(commands("help", "status")).call("/st")

      expect(drawn).to include("/status")
    end

    it "completes the token to the command it offered" do
      expect(completion(commands("help", "status")).call("/st")).to eq("/status")
    end

    it "offers a project path for an at prefix" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib", "lain", "frontend"))
        File.write(File.join(dir, "lib", "lain", "frontend", "tty.rb"), "")
        sources = Lain::Frontend::Completion::Sources.new(root: dir)

        expect(completion(sources).call("@ttyrb")).to eq("@lib/lain/frontend/tty.rb")
      end
    end

    it "offers the fuzzy matcher's best candidate first" do
      Dir.mktmpdir do |dir|
        %w[app.rb tty.rb utility.rb].each { |name| File.write(File.join(dir, name), "") }
        sources = Lain::Frontend::Completion::Sources.new(root: dir)

        completion(sources).call("@tty")

        expect(drawn.index("@tty.rb")).to be < drawn.index("@utility.rb")
      end
    end

    it "paints the matched characters with the theme's match token" do
      colored = Lain::Frontend::Theme.new(pastel: Pastel.new(enabled: true), detect: -> { 256 })

      completion(commands("help", "status"), theme: colored).call("/st")

      expect(drawn).to include(colored.paint(:match, "st"))
    end

    it "replaces only the token being completed, leaving the rest of the line intact" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib", "lain", "frontend"))
        File.write(File.join(dir, "lib", "lain", "frontend", "tty.rb"), "")
        sources = Lain::Frontend::Completion::Sources.new(root: dir)

        expect(completion(sources).call("tell me about @ttyrb"))
          .to eq("tell me about @lib/lain/frontend/tty.rb")
      end
    end

    it "carries earlier lines of a multiline buffer through untouched" do
      expect(completion(commands("status")).call("first line\n/st")).to eq("first line\n/status")
    end

    it "leaves the line alone and says so when nothing matches" do
      expect(completion(commands("help", "status")).call("/zzz")).to be_nil
      expect(drawn).to include("/zzz")
    end

    it "leaves the line alone when the buffer ends in no token at all" do
      expect(completion(commands("status")).call("plain prose ")).to be_nil
      expect(drawn).to eq("")
    end

    it "leaves the line alone when the trailing token carries no sigil" do
      expect(completion(commands("status")).call("and/or")).to be_nil
    end

    it "offers everything a source has when the sigil stands alone" do
      completion(commands("help", "status")).call("/")

      expect(drawn).to include("/help").and include("/status")
    end

    it "offers no more candidates than the limit it was given" do
      completion(commands("sa", "sb", "sc"), limit: 2).call("/s")

      expect(drawn.scan("/s").size).to eq(2)
    end

    # PTY-confirmed before this spec existed: a file named "ev\e[2Jil_tty.rb"
    # put a live erase-display sequence on the screen AND into the accepted
    # buffer. Scrubbed at the source, so the candidate the menu draws and the
    # candidate the buffer receives are the same scrubbed string -- which is
    # also what keeps the matcher's positions indexing the string on screen.
    it "puts no raw escape on the screen when a filename carries one" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "ev\e[2Jil_tty.rb"), "")
        sources = Lain::Frontend::Completion::Sources.new(root: dir)

        completion(sources).call("@evil")

        expect(drawn).not_to include("\e[2J")
      end
    end

    it "puts no raw escape into the buffer it hands back either" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "ev\e[2Jil_tty.rb"), "")
        sources = Lain::Frontend::Completion::Sources.new(root: dir)

        expect(completion(sources).call("@evil")).not_to include("\e")
      end
    end

    it "scrubs at the menu as well, so no later source can reach the screen unscrubbed" do
      hostile = double(sigil?: true, for: Lain::Ext::Fuzzy.new(["ev\e[2Jil.rb"]))

      completion(hostile).call("@evil")

      expect(drawn).not_to include("\e[2J")
    end

    it "draws below the prompt and puts the cursor back where the line editor left it" do
      completion(commands("status")).call("/st")

      expect(drawn).to start_with(TTY::Cursor.save).and end_with(TTY::Cursor.restore)
    end
  end

  describe "#clear" do
    it "erases a drawn menu so it never outlives the prompt" do
      subject = completion(commands("status"))
      subject.call("/st")
      screen.clear

      subject.clear

      expect(drawn).to eq(TTY::Cursor.clear_screen_down)
    end

    it "writes nothing when no menu was ever drawn" do
      completion(commands("status")).clear

      expect(drawn).to eq("")
    end

    it "erases once, not once per prompt that follows" do
      subject = completion(commands("status"))
      subject.call("/st")
      subject.clear
      screen.clear

      subject.clear

      expect(drawn).to eq("")
    end
  end

  # The key action is process-global because Reline is (see
  # Frontend::LineEditor::Registry), so the installed completion is too.
  describe ".install" do
    after { Lain::Frontend::LineEditor.unbind_all }

    def installable = completion(commands("status"))

    it "binds the completion key and answers it with the newest completion" do
      Lain::Frontend::LineEditor.unbind_all

      described_class.install(installable)

      expect(Lain::Frontend::LineEditor.bound?(described_class::KEY)).to be(true)
    end

    it "does not raise KeyTaken when a second completion is installed" do
      described_class.install(installable)

      expect { described_class.install(installable) }.not_to raise_error
    end

    # T14's third KeyTaken case: `bind` consults the LIVE config, so a human
    # whose inputrc claims C-x gets a refusal. Completion is a convenience and
    # the prompt is not -- a refused key may cost the feature and never the TTY.
    it "stays off and says so when the key is already claimed, rather than raising" do
      Lain::Frontend::LineEditor.unbind_all
      allow(Lain::Frontend::LineEditor).to receive(:bind)
        .and_raise(Lain::Frontend::LineEditor::KeyTaken, "C-x is already bound by the user's inputrc (as :abort)")
      warnings = []

      expect { described_class.install(installable, notify: warnings.method(:<<)) }.not_to raise_error
      expect(warnings.first).to include("completion is off").and include("inputrc")
    end

    # T14's self-verification: a bind that writes the keymaps but does not
    # actually route now raises rather than reporting a success that can never
    # fire. NOTHING claimed the key in this case, so it is a genuinely separate
    # cause that happens to share KeyTaken's class -- which is exactly why the
    # warning forwards Reline's words instead of blaming a prior binding.
    it "stays off and says so when the key is bound but does not route" do
      Lain::Frontend::LineEditor.unbind_all
      allow(Lain::Frontend::LineEditor).to receive(:bind)
        .and_raise(Lain::Frontend::LineEditor::KeyTaken,
                   "C-x did not take: the active keymap routes it to :ed_ignore")
      warnings = []

      expect { described_class.install(installable, notify: warnings.method(:<<)) }.not_to raise_error
      expect(warnings.first).to include("completion is off").and include("did not take")
    end

    it "points the current completion at the one installed last" do
      described_class.install(installable)
      newest = described_class.install(installable)

      expect(described_class.current).to be(newest)
    end
  end
end

# The TTY half of T16: when the key is claimed, where the completion gets its
# screen, and when the menu is torn down. Here rather than in tty_spec.rb so the
# whole of one card's behaviour reads in one place.
RSpec.describe Lain::Frontend::TTY do
  let(:channel) { Lain::Channel.new }
  let(:output) { StringIO.new }
  let(:input) { instance_double(IO, tty?: true) }

  around do |example|
    original = Reline::HISTORY.to_a
    Reline::HISTORY.clear
    example.run
    Reline::HISTORY.clear
    Reline::HISTORY.concat(original)
  end

  def tty_over(dir)
    described_class.new(
      channel:, output:, input:,
      history_path: File.join(dir, "history"),
      completion_sources: Lain::Frontend::Completion::Sources.new(root: dir)
    )
  end

  # A completed session: the TTY has taken the terminal, so it has claimed the
  # key too. Everything about a live menu has to be exercised through #run,
  # because #run is now the only thing that installs.
  def prompting(dir, &block)
    File.write(File.join(dir, "tty.rb"), "")
    tty = tty_over(dir)
    tty.run(&block)
  end

  describe "claiming the completion key" do
    it "binds nothing merely by being constructed" do
      Lain::Frontend::LineEditor.unbind_all

      Dir.mktmpdir { |dir| tty_over(dir) }

      expect(Lain::Frontend::LineEditor.bound?(Lain::Frontend::Completion::KEY)).to be(false)
    end

    it "claims the key when it takes the terminal" do
      Lain::Frontend::LineEditor.unbind_all

      Dir.mktmpdir { |dir| prompting(dir) { channel.close } }

      expect(Lain::Frontend::LineEditor.bound?(Lain::Frontend::Completion::KEY)).to be(true)
    end

    it "still runs, and warns, when the human's inputrc has already claimed the key" do
      Lain::Frontend::LineEditor.unbind_all
      allow(Lain::Frontend::LineEditor).to receive(:bind)
        .and_raise(Lain::Frontend::LineEditor::KeyTaken, "C-x is already bound by the user's inputrc (as :abort)")

      Dir.mktmpdir { |dir| expect { prompting(dir) { channel.close } }.not_to raise_error }

      expect(output.string).to include("completion is off")
    end
  end

  describe "tearing the menu down" do
    it "erases the menu once the prompt it was drawn under has been submitted" do
      allow(Reline).to receive(:readmultiline).and_return("hello")

      Dir.mktmpdir do |dir|
        prompting(dir) do |tty|
          Lain::Frontend::Completion.current.call("@tty")
          output.truncate(output.rewind)
          tty.prompt("> ")
          channel.close
        end
      end

      expect(output.string).to include(TTY::Cursor.clear_screen_down)
    end

    # The third way a prompt ends, and the one an `ensure` is needed for:
    # CLI::PromptBreaker raises Interrupt into the prompt thread, and T14's
    # dispatch deliberately lets Interrupt through.
    it "erases the menu when the prompt is interrupted rather than answered" do
      allow(Reline).to receive(:readmultiline).and_raise(Interrupt)

      Dir.mktmpdir do |dir|
        expect do
          prompting(dir) do |tty|
            Lain::Frontend::Completion.current.call("@tty")
            output.truncate(output.rewind)
            tty.prompt("> ")
          end
        end.to raise_error(Interrupt)
      end

      expect(output.string).to include(TTY::Cursor.clear_screen_down)
    end
  end

  it "draws the menu through the countdown's screen lock rather than a second writer" do
    countdown = nil
    allow(Lain::Frontend::TTY::Countdown).to receive(:new).and_wrap_original do |original, **kwargs|
      countdown = original.call(**kwargs)
      allow(countdown).to receive(:draw).and_call_original
      countdown
    end

    Dir.mktmpdir do |dir|
      prompting(dir) do
        Lain::Frontend::Completion.current.call("@tty")
        channel.close
      end
    end

    expect(countdown).to have_received(:draw)
  end
end
