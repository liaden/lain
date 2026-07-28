# frozen_string_literal: true

require "pastel"
require "stringio"

RSpec.describe Lain::Frontend::PromptComposer do
  let(:plain) { Lain::Frontend::Theme.new(pastel: Pastel.new(enabled: false)) }
  let(:coloured) { Lain::Frontend::Theme.new(pastel: Pastel.new(enabled: true), detect: -> { 256 }) }

  describe "the null renderer (the default)" do
    subject(:prompt) { described_class.new(theme: plain) }

    it "hands back the text it was given, byte for byte" do
      expect(prompt.compose("> ").line).to eq("> ")
    end

    it "produces an empty header, so nothing is printed above the editor" do
      expect(prompt.compose("> ").header).to eq([])
    end

    it "passes an already-styled prompt through untouched" do
      styled = "\e[32m●\e[0m \e[1m> \e[0m"

      expect(prompt.compose(styled).line).to eq(styled)
    end
  end

  describe "a renderer that composes from run state" do
    it "receives the default text and the theme" do
      renderer = spy("renderer", call: "x")

      described_class.new(theme: plain, renderer:).compose("> ")

      expect(renderer).to have_received(:call).with(text: "> ", theme: plain)
    end

    it "supplies the line handed to the line editor" do
      renderer = ->(text:, theme:) { "#{theme.paint(:plain, "opus 42%")} #{text}" }

      rendering = described_class.new(theme: plain, renderer:).compose("> ")

      expect(rendering.line).to eq("opus 42% > ")
    end

    it "paints through the theme it was handed, escapes and all" do
      renderer = ->(text:, theme:) { "#{theme.paint(:warm, "warm")}#{text}" }

      rendering = described_class.new(theme: coloured, renderer:).compose("> ")

      expect(rendering.line).to eq("\e[32mwarm\e[0m> ")
    end

    it "runs the renderer on every compose, so a caller may tick it" do
      calls = 0
      renderer = ->(text:, **) { calls += 1 and text }

      prompt = described_class.new(theme: plain, renderer:)
      3.times { prompt.compose("> ") }

      expect(calls).to eq(3)
    end
  end

  describe "a multi-line rendering" do
    def rendering_for(rendered)
      described_class.new(theme: plain, renderer: ->(**) { rendered }).compose("> ")
    end

    it "keeps only the final line for the editor" do
      expect(rendering_for("model: opus\n> ").line).to eq("> ")
    end

    it "puts every line above the final one in the header" do
      expect(rendering_for("model: opus\ncontext: 42%\n> ").header).to eq(["model: opus", "context: 42%"])
    end

    it "treats a trailing newline as an empty editor line, not a dropped header" do
      expect(rendering_for("model: opus\n")).to have_attributes(header: ["model: opus"], line: "")
    end

    it "renders an empty string as an empty prompt with no header" do
      expect(rendering_for("")).to have_attributes(header: [], line: "")
    end
  end

  # The rescue is what stands between a wiring bug in a renderer and an
  # unusable REPL: #occupancy raises on a blank model, and a renderer that
  # reads it is one config typo from raising on every prompt.
  describe "a failing renderer" do
    def line_from(renderer)
      described_class.new(theme: plain, renderer:).compose("> ").line
    end

    it "falls back to today's prompt when the renderer raises StandardError" do
      expect(line_from(->(**) { raise "boom" })).to eq("> ")
    end

    it "falls back when the renderer raises the app's own error class" do
      renderer = ->(**) { raise Lain::ContextWindow::UnknownModel, "no model" }

      expect(line_from(renderer)).to eq("> ")
    end

    it "falls back when the renderer raises a ScriptError (a half-built renderer)" do
      expect(line_from(->(**) { raise NotImplementedError })).to eq("> ")
    end

    it "falls back when the renderer blows the stack" do
      recurse = ->(**) { raise SystemStackError, "stack level too deep" }

      expect(line_from(recurse)).to eq("> ")
    end

    it "falls back when the renderer returns something that is not a String" do
      expect(line_from(->(**) {})).to eq("> ")
    end

    # Theme::UnknownToken is a KeyError, so the rescue that keeps the REPL
    # alive is broad enough to hide a misspelled token. It degrades like any
    # other fault -- and the warning below is what stops it being silent.
    it "falls back rather than raising when a renderer names an unregistered token" do
      expect(line_from(->(text:, theme:) { theme.paint(:no_such_token, text) })).to eq("> ")
    end

    it "produces no header on the fallback path" do
      expect(described_class.new(theme: plain, renderer: ->(**) { raise "boom" })
               .compose("> ").header).to eq([])
    end

    # Ctrl-C at the prompt is the human's decision, not the renderer's bug.
    # Swallowing it would leave no way to interrupt a wedged renderer.
    it "lets an Interrupt through" do
      renderer = ->(**) { raise Interrupt }

      expect { described_class.new(theme: plain, renderer:).compose("> ") }.to raise_error(Interrupt)
    end

    it "lets a SystemExit through" do
      renderer = ->(**) { raise SystemExit }

      expect { described_class.new(theme: plain, renderer:).compose("> ") }.to raise_error(SystemExit)
    end
  end

  # Total, but never silent. "Once" means once per contiguous failure RUN, not
  # once ever: TTY::History's warn-once does NOT govern here, because a file
  # that becomes unwritable stays unwritable, whereas the run state a renderer
  # reads flaps -- a model slot goes blank mid-session and comes back.
  describe "reporting a degraded renderer" do
    def warnings_from(renderer, prompts: 1)
      [].tap do |warnings|
        prompt = described_class.new(theme: plain, renderer:, notify: warnings.method(:push))
        prompts.times { prompt.compose("> ") }
      end
    end

    # `failing` is flipped by the example between composes, so one renderer
    # object walks a whole outage-recovery-outage sequence.
    def warnings_across(sequence)
      warnings = []
      failing = nil
      renderer = ->(text:, **) { failing ? raise(failing) : text }
      composer = described_class.new(theme: plain, renderer:, notify: warnings.method(:push))
      sequence.each do |fault|
        failing = fault
        composer.compose("> ")
      end
      warnings
    end

    it "names the failure so a wiring bug is findable" do
      expect(warnings_from(->(**) { raise "no model configured" }))
        .to eq(["warning: prompt renderer unavailable (no model configured)"])
    end

    it "reports a misspelled style token instead of quietly rendering plain" do
      warnings = warnings_from(->(text:, theme:) { theme.paint(:erorr, text) })

      expect(warnings.first).to include("erorr")
    end

    it "warns once however many prompts one unbroken failure run lasts" do
      expect(warnings_from(->(**) { raise "boom" }, prompts: 5).size).to eq(1)
    end

    it "warns again when the renderer recovers and then fails a second time" do
      expect(warnings_across(["flap", nil, "flap"]).size).to eq(2)
    end

    it "names the SECOND fault, so a new failure mode after a recovery is not invisible" do
      expect(warnings_across(["first", nil, "second"]))
        .to eq(["warning: prompt renderer unavailable (first)",
                "warning: prompt renderer unavailable (second)"])
    end

    it "stays silent through a long recovery, however many prompts it spans" do
      expect(warnings_across(["boom", nil, nil, nil, nil]).size).to eq(1)
    end

    # A different fault DURING one outage is still one outage: the operator is
    # already looking, and a warning per prompt would bury what they came for.
    it "does not re-warn for a different fault inside the same failure run" do
      expect(warnings_across(%w[first second third]).size).to eq(1)
    end

    it "says nothing while the renderer is working" do
      expect(warnings_from(->(text:, **) { text }, prompts: 5)).to be_empty
    end

    it "stays quiet with no notifier wired, rather than asking whether one is" do
      expect { described_class.new(theme: plain, renderer: ->(**) { raise "boom" }).compose("> ") }
        .not_to raise_error
    end
  end

  describe Lain::Frontend::PromptComposer::Rendering do
    let(:screen) { StringIO.new }

    it "puts the header on the screen and hands back only the final line" do
      rendering = described_class.new(header: ["model: opus", "context: 42%"], line: "> ")

      expect(rendering.editor_line(screen)).to eq("> ")
      expect(screen.string).to eq("model: opus\ncontext: 42%\n")
    end

    it "writes nothing when there is no header" do
      expect(described_class.new(header: [], line: "> ").editor_line(screen)).to eq("> ")
      expect(screen.string).to eq("")
    end
  end

  describe Lain::Frontend::PromptComposer::Null do
    it "is the identity on the text" do
      expect(described_class.new.call(text: "> ", theme: nil)).to eq("> ")
    end

    it "ignores keywords a future renderer may be handed" do
      expect(described_class.new.call(text: "> ", theme: nil, tick: 3)).to eq("> ")
    end
  end
end
