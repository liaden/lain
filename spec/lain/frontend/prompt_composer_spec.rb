# frozen_string_literal: true

require "fileutils"
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

  # T13 -- the renderer that fills the seam above, composing the prompt from
  # the run's own state through the Rust formatter ({Lain::Ext::Prompt}).
  #
  # Nothing below sets an environment variable, and nothing below drives a
  # non-tty TTY: colour arrives as `theme.enabled?`, resolved by Ruby, which
  # is the whole reason the formatter takes `color:` as an argument.
  describe Lain::Frontend::PromptComposer::Formatted do
    # The SHIPPED file, read off disk exactly as a run reads it. A spec that
    # compiled its own equivalent string would prove nothing about the TOML
    # the gemspec actually ships.
    let(:shipped) do
      Lain::Ext::Prompt.from_toml(File.read(Lain::Frontend::PromptComposer::DEFAULT_CONFIG))
    end
    let(:state) { { "model" => "claude-opus-4-1", "occupancy" => "38%", "fleet" => "3", "idle" => "12m" } }
    # A Hash answers #to_h with itself, so the production {RunState} and a
    # spec's literal satisfy the same duck with no stand-in class.
    let(:wide) { -> { 200 } }
    # `path:` is required: every degraded-path warning names the file the human
    # has to go and edit, and a default would let a caller forget silently.
    let(:config_path) { "/projects/lain/.lain/prompt.toml" }

    def renderer(format: shipped, state: self.state, screen: wide, path: config_path, **)
      described_class.new(format:, state:, path:, screen:, **)
    end

    # AC1: the shipped default renders the run's state.
    describe "the shipped default config" do
      it "names the model, the occupancy and the idle time" do
        expect(renderer.call(text: "> ", theme: plain)).to include("claude-opus-4-1", "38%", "12m")
      end

      it "leaves today's prompt as the LAST line, so the line editor gets it byte for byte" do
        expect(renderer.call(text: "\e[1m> \e[0m", theme: plain).lines.last).to eq("\e[1m> \e[0m")
      end

      it "puts everything it composed above that line" do
        expect(renderer.call(text: "> ", theme: plain).lines.first).to end_with("\n")
      end

      it "hands back today's prompt untouched when the run has nothing to report yet" do
        expect(renderer(state: {}).call(text: "> ", theme: plain)).to eq("> ")
      end

      it "elides the fleet segment on a run that spawned nobody" do
        composed = renderer(state: state.merge("fleet" => nil)).call(text: "> ", theme: plain)

        expect(composed).not_to include("fleet")
        expect(composed).to include("claude-opus-4-1")
      end
    end

    # AC2: a user config replaces the shipped one.
    describe "a user config naming only the model" do
      let(:shipped) { Lain::Ext::Prompt.from_toml(%(format = "$model "\n)) }

      it "shows the model and nothing else the run knows" do
        composed = renderer.call(text: "> ", theme: plain)

        expect(composed.lines.first).to eq("claude-opus-4-1 \n")
        expect(composed).not_to include("38%", "12m", "fleet")
      end
    end

    # AC4: colour is resolved by Ruby and handed in.
    describe "colour" do
      it "emits no escape sequences when the theme is not painting" do
        expect(renderer.call(text: "> ", theme: plain)).not_to include("\e")
      end

      it "paints through the formatter when the theme is" do
        expect(renderer.call(text: "> ", theme: coloured)).to include("\e[")
      end
    end

    # AC5, and the escalation trigger: a misjudged width wraps the status line
    # and smears the row above the cursor.
    describe ".columns" do
      it "counts a wide glyph as two columns" do
        expect(described_class.columns("日本")).to eq(4)
      end

      it "counts graphemes, not characters" do
        family = "👨‍👩‍👧"

        expect(described_class.columns(family)).to be < family.chars.sum { |c| Lain::Ext::Prompt.width(c) }
      end

      # .width counts a literal "\n" as zero, so a multi-line string reports
      # the SUM of its lines -- a number that is not a terminal column.
      it "reports the widest line, never the sum a literal newline hides" do
        expect(described_class.columns("日本\nab")).to eq(4)
      end

      it "ignores the escapes the formatter itself emits" do
        expect(described_class.columns(Lain::Ext::Prompt.compile("[lain](bold green)").render({}, color: true)))
          .to eq(4)
      end

      it "answers zero for nothing at all" do
        expect(described_class.columns("")).to eq(0)
      end
    end

    describe "a status line wider than the room it has" do
      let(:cjk) { Lain::Ext::Prompt.from_toml(%(format = "日本語"\n)) }

      it "keeps the line when it fits the screen" do
        expect(renderer(format: cjk, screen: -> { 6 }).call(text: "> ", theme: plain)).to eq("日本語\n> ")
      end

      # Three characters, six columns: a String#size test would have kept this.
      it "drops it rather than wrapping, deciding on columns and not on character count" do
        expect(renderer(format: cjk, screen: -> { 4 }).call(text: "> ", theme: plain)).to eq("> ")
      end

      it "honours a max_width the config set, over the terminal's own width" do
        capped = Lain::Ext::Prompt.from_toml(%(format = "$model"\n[settings]\nmax_width = 4\n))

        expect(renderer(format: capped).call(text: "> ", theme: plain)).to eq("> ")
      end
    end

    # `TTY::Screen.width` looks cheap and is not: with no ioctl answer -- a pty
    # whose winsize was never set, the default in plenty of CI contexts -- its
    # chain falls through to `size_from_tput`, which shells out `tput lines`
    # AND `tput cols`. The panel measured 200 spawns per 100 reads, 3.0 ms per
    # prompt. Avoiding a fork/exec per prompt is the whole reason this renders
    # in process rather than shelling out to starship.
    describe "reading the screen width" do
      def counting_screen(columns = 200)
        calls = [0]
        [calls, -> { calls[0] += 1 and columns }]
      end

      it "reads it once per chat, however many prompts follow" do
        calls, screen = counting_screen
        composer = renderer(screen:)
        5.times { composer.call(text: "> ", theme: plain) }

        expect(calls.first).to eq(1)
      end

      it "does not read it at all when the config sets its own max_width" do
        calls, screen = counting_screen
        capped = Lain::Ext::Prompt.from_toml(%(format = "$model"\n[settings]\nmax_width = 60\n))
        renderer(format: capped, screen:).call(text: "> ", theme: plain)

        expect(calls.first).to be_zero
      end

      # An injected thunk is a caller's code. A prompt must not die over a
      # screen measurement, so anything that is not a usable column count
      # falls back rather than escaping.
      it "falls back to a usable width when the screen answers nothing usable" do
        [-> {}, -> { 0 }, -> { -1 }, -> { "eighty" }, -> { raise "no tty" }].each do |screen|
          expect(renderer(screen:).call(text: "> ", theme: plain).lines.last).to eq("> ")
          expect { renderer(screen:).call(text: "> ", theme: plain) }.not_to raise_error
        end
      end

      it "composes against the fallback width rather than dropping every line" do
        composed = renderer(format: Lain::Ext::Prompt.from_toml(%(format = "$model"\n)), screen: -> {})
                   .call(text: "> ", theme: plain)

        expect(composed).to eq("claude-opus-4-1\n> ")
      end
    end

    # StyleError is a RENDER-time refusal, not a compile-time one: a $style
    # variable can supply an unknown word on any given prompt. Rescued here
    # rather than left to the composer's net, because this object is the one
    # that knows a config supplied the word.
    describe "a config whose style comes from a variable" do
      let(:by_variable) { Lain::Ext::Prompt.from_toml(%(format = "[$model]($accent)"\n)) }

      def accented(accent, notify: Lain::Frontend::PromptComposer::SILENT)
        renderer(format: by_variable, state: state.merge("accent" => accent), notify:)
      end

      def with_accent(accent, **) = accented(accent, **).call(text: "> ", theme: coloured)

      it "renders the style the variable supplied" do
        expect(with_accent("bold red")).to include("claude-opus-4-1")
      end

      it "degrades to today's prompt on an unknown style word instead of raising" do
        expect(with_accent("chartreuse")).to eq("> ")
      end

      it "names the offending word rather than degrading in silence" do
        warnings = []
        with_accent("chartreuse", notify: warnings.method(:push))

        expect(warnings.first).to include("chartreuse")
      end

      # Three config layers can supply the format -- project, XDG, shipped --
      # so a warning that names only the bad word leaves the human guessing
      # which file to open.
      it "names the config file the word came from" do
        warnings = []
        with_accent("chartreuse", notify: warnings.method(:push))

        expect(warnings.first).to include(config_path)
      end

      # ONE renderer, three prompts: a fresh one per prompt would reset the
      # latch and prove nothing about the warning it is meant to suppress.
      it "warns once however many prompts one unbroken failure run lasts" do
        warnings = []
        composer = accented("chartreuse", notify: warnings.method(:push))
        3.times { composer.call(text: "> ", theme: coloured) }

        expect(warnings.size).to eq(1)
      end

      # The latch policy {PromptComposer#warn_degraded} landed with, held here
      # too: a $style word arrives in the VARIABLES, so it flaps exactly as the
      # occupancy reading does, and a second outage must not be invisible.
      # `accent` is flipped between composes, so one renderer walks a whole
      # outage-recovery-outage sequence.
      def warnings_across(accents)
        warnings = []
        vars = {}
        composer = renderer(format: by_variable, state: vars, notify: warnings.method(:push))
        accents.each do |accent|
          vars.replace(state.merge("accent" => accent))
          composer.call(text: "> ", theme: coloured)
        end
        warnings
      end

      it "warns again when the style recovers and then breaks a second time" do
        expect(warnings_across(["chartreuse", "bold red", "chartreuse"]).size).to eq(2)
      end

      it "stays silent through a long recovery, however many prompts it spans" do
        expect(warnings_across(["chartreuse", "bold red", "bold red", "bold red"]).size).to eq(1)
      end

      it "does not re-warn for a different bad word inside the same failure run" do
        expect(warnings_across(%w[chartreuse fuchsia periwinkle]).size).to eq(1)
      end
    end

    it "is pure: two prompts over the same state compose the same bytes" do
      composer = renderer

      expect(composer.call(text: "> ", theme: plain)).to eq(composer.call(text: "> ", theme: plain))
    end
  end

  # What the run knows, in the vocabulary a format writes against. Separate
  # from {Formatted} because "what is happening" and "how a format says it"
  # are two questions -- and only this half touches the Agent.
  describe Lain::Frontend::PromptComposer::RunState do
    let(:agent) { instance_double(Lain::Agent, occupancy: 0.384, context: instance_double(Lain::Context, model: "opus")) }
    let(:status_feed) { instance_double(Lain::StatusFeed, state: { "fleet" => %w[a b c] }) }
    let(:now) { 1000.0 }
    let(:clock) { Lain::RunClock.new(clock: -> { now }) }

    def state(**) = described_class.new(agent:, clock:, status_feed:, **).to_h

    it "reports the LIVE model slot, so a /model switch shows at the next prompt" do
      expect(state["model"]).to eq("opus")
    end

    it "reports occupancy as a whole percent" do
      expect(state["occupancy"]).to eq("38%")
    end

    it "reports nothing before the first turn, rather than a zero" do
      allow(agent).to receive(:occupancy).and_return(nil)

      expect(state["occupancy"]).to be_nil
    end

    # CONSERVATIVE_FALLBACK divides by 8192 for every model no book carries --
    # every Ollama id, most Bedrock ones -- so a reading past 1.0 is ordinary,
    # not a bug, and "134%" in a prompt is noise.
    it "clamps an occupancy past 1.0, which an unmatched model's fallback produces" do
      allow(agent).to receive(:occupancy).and_return(3.7)

      expect(state["occupancy"]).to eq("100%")
    end

    # The book is loud about a blank model slot and Agent#occupancy lets it
    # raise. A prompt is not the place to answer for a wiring bug: absence is
    # the only honest reading, and the missing segment is the signal.
    it "reports absence, not a raise, when the model slot is blank" do
      allow(agent).to receive(:occupancy).and_raise(Lain::ContextWindow::UnknownModel, "blank model")

      expect { state }.not_to raise_error
      expect(state["occupancy"]).to be_nil
    end

    it "reports the fleet size" do
      expect(state["fleet"]).to eq("3")
    end

    it "reports nothing for a fleet nobody spawned, so the segment elides" do
      allow(status_feed).to receive(:state).and_return({ "fleet" => [] })

      expect(state["fleet"]).to be_nil
    end

    describe "idle, as a run goes quiet" do
      let(:ticking) { [0.0] }
      let(:clock) { Lain::RunClock.new(clock: -> { ticking.first }) }

      def idle_after(seconds)
        reader = described_class.new(agent:, clock:, status_feed:)
        ticking[0] = seconds
        reader.to_h["idle"]
      end

      it "reports seconds under a minute" do
        expect(idle_after(42.0)).to eq("42s")
      end

      it "reports minutes under an hour" do
        expect(idle_after(300.0)).to eq("5m")
      end

      it "reports hours beyond that" do
        expect(idle_after(7200.0)).to eq("2h")
      end
    end

    it "answers a plain string-keyed Hash the formatter can render" do
      expect(state.keys).to contain_exactly("model", "occupancy", "fleet", "idle", "mode")
    end

    # T7: the posture the human is in must live in chrome they cannot lose,
    # but only when a mode is actually wired -- nobody threads one through
    # `cli/wiring.rb` until T5/T10 land, so `mode: nil` (the default) must
    # keep behaving exactly as it always has.
    describe "mode" do
      it "reports nothing when no mode is wired, so the default costs nothing" do
        expect(described_class.new(agent:, clock:, status_feed:).to_h["mode"]).to be_nil
      end

      it "reports the posture's own lighter for a non-default posture" do
        mode = Lain::Mode.new(posture: :plan, layers: [])

        expect(described_class.new(agent:, clock:, status_feed:, mode:).to_h["mode"]).to eq("PLAN")
      end

      it "reports nothing for the default posture with no layers active" do
        mode = Lain::Mode.new(posture: :accept_edits, layers: [])

        expect(described_class.new(agent:, clock:, status_feed:, mode:).to_h["mode"]).to be_nil
      end

      it "reports the posture lighter alongside every active layer's, in precedence order" do
        mode = Lain::Mode.new(posture: :manual, layers: %i[auto_approve])

        expect(described_class.new(agent:, clock:, status_feed:, mode:).to_h["mode"]).to eq("MAN AA")
      end

      it "reports only the active layers' lighters when the posture itself is silent" do
        mode = Lain::Mode.new(posture: :accept_edits, layers: %i[goal])

        expect(described_class.new(agent:, clock:, status_feed:, mode:).to_h["mode"]).to eq("GOAL")
      end
    end
  end

  # AC2 and AC3's other half: WHICH config a run renders through, and what
  # happens when the one it found does not parse.
  describe ".renderer" do
    require "tmpdir"

    let(:state) { { "model" => "opus", "occupancy" => "38%", "fleet" => nil, "idle" => "12m" } }

    def compose(path:, notify: Lain::Frontend::PromptComposer::SILENT)
      renderer = described_class.renderer(state:, path:, screen: -> { 200 }, notify:)
      described_class.new(theme: plain, renderer:).compose("> ")
    end

    it "renders the run's state through the shipped default" do
      expect(compose(path: described_class::DEFAULT_CONFIG).header.join).to include("opus", "38%", "12m")
    end

    it "renders a user config instead when one is found" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "prompt.toml")
        File.write(path, %(format = "$model "\n))

        expect(compose(path:)).to have_attributes(header: ["opus "], line: "> ")
      end
    end

    # AC3: loudly, and still usable.
    describe "a config that does not parse" do
      around do |example|
        Dir.mktmpdir do |dir|
          @path = File.join(dir, "prompt.toml")
          File.write(@path, %(format = "[unclosed"\n))
          example.run
        end
      end

      it "falls back to today's prompt" do
        expect(compose(path: @path)).to have_attributes(header: [], line: "> ")
      end

      it "reports a warning naming the file" do
        warnings = []
        compose(path: @path, notify: warnings.method(:push))

        expect(warnings.first).to include(@path)
      end
    end

    it "falls back the same way when the config cannot be read at all" do
      warnings = []
      rendering = compose(path: "/no/such/prompt.toml", notify: warnings.method(:push))

      expect(rendering.line).to eq("> ")
      expect(warnings.first).to include("/no/such/prompt.toml")
    end

    # `Ext::Prompt.from_toml` refuses non-UTF-8 bytes with Ruby's OWN
    # ::EncodingError, which is NOT under Lain::Error -- so the parse-failure
    # rescue does not see it, `Wiring#run` has no net around the renderer, and
    # `exe/lain` rescues only Lain::Error. A single Latin-1 byte in a config
    # therefore aborted the REPL with a backtrace BEFORE a prompt existed,
    # which is AC3 violated outright.
    describe "a config that is not valid UTF-8" do
      around do |example|
        Dir.mktmpdir do |dir|
          @path = File.join(dir, "prompt.toml")
          # "»" in Latin-1: byte 0xBB, which is not valid UTF-8 on its own.
          File.binwrite(@path, %(format = "\xBB "\n).b)
          example.run
        end
      end

      it "falls back to today's prompt instead of aborting the chat" do
        expect { compose(path: @path) }.not_to raise_error
        expect(compose(path: @path)).to have_attributes(header: [], line: "> ")
      end

      it "reports a warning naming the file" do
        warnings = []
        compose(path: @path, notify: warnings.method(:push))

        expect(warnings.first).to include(@path)
      end
    end
  end

  describe ".config_path" do
    require "tmpdir"

    let(:paths) { Lain::Paths.new(env: { "HOME" => "/home/nobody", "XDG_CONFIG_HOME" => "/no/such/config" }) }

    it "falls back to the shipped default when nobody wrote one" do
      Dir.mktmpdir do |project|
        expect(described_class.config_path(paths:, project:)).to eq(described_class::DEFAULT_CONFIG)
      end
    end

    it "prefers the project's own .lain/prompt.toml" do
      Dir.mktmpdir do |project|
        FileUtils.mkdir_p(File.join(project, ".lain"))
        own = File.join(project, ".lain", "prompt.toml")
        File.write(own, %(format = "$model"\n))

        expect(described_class.config_path(paths:, project:)).to eq(own)
      end
    end

    it "takes the XDG config when the project has none of its own" do
      Dir.mktmpdir do |base|
        # Paths suffixes every XDG base with /lain -- so does this spec, rather
        # than restating the join by hand.
        xdg = Lain::Paths.new(env: { "HOME" => "/home/nobody", "XDG_CONFIG_HOME" => base })
        FileUtils.mkdir_p(xdg.config_home)
        own = File.join(xdg.config_home, "prompt.toml")
        File.write(own, %(format = "$model"\n))

        expect(described_class.config_path(paths: xdg, project: "/no/such/project")).to eq(own)
      end
    end

    it "ships a default that parses, and names the variables the run supplies" do
      shipped = Lain::Ext::Prompt.from_toml(File.read(described_class::DEFAULT_CONFIG))

      expect(shipped.variables).to contain_exactly("model", "occupancy", "fleet", "idle", "mode")
    end
  end

  # T7 -- the posture surfaces in chrome the human cannot lose, but only when
  # a mode is actually wired: `accept_edits` with no layers is the default,
  # and the default must cost nothing.
  describe "the mode segment the default format renders" do
    let(:shipped) { Lain::Ext::Prompt.from_toml(File.read(Lain::Frontend::PromptComposer::DEFAULT_CONFIG)) }
    let(:state) { { "model" => "claude-opus-4-1", "occupancy" => "38%", "fleet" => "3", "idle" => "12m" } }

    # The format string exactly as it read immediately BEFORE this card,
    # reproduced verbatim -- so a divergence shows up as a real byte
    # difference rather than this test comparing the new format against
    # itself. This is the proof the card's escalation trigger demands: a
    # non-default posture must not change what a default-posture prompt
    # renders.
    let(:pre_t7_format) do
      Lain::Ext::Prompt.from_toml(
        %(format = "[$model](bold cyan)( [ctx $occupancy](dim))( [fleet $fleet](dim))( [idle $idle](dim))"\n)
      )
    end

    it "is byte-identical to the unlayered format when the posture is the default and no layers are active" do
      old_bytes = pre_t7_format.render(state, color: false)
      new_bytes = shipped.render(state.merge("mode" => nil), color: false)

      expect(new_bytes).to eq(old_bytes)
    end

    it "carries a non-default posture's lighter into the rendered line" do
      rendered = shipped.render(state.merge("mode" => "PLAN"), color: false)

      expect(rendered).to include("PLAN")
    end

    it "carries the posture lighter and every active layer's lighter" do
      rendered = shipped.render(state.merge("mode" => "MAN AA"), color: false)

      expect(rendered).to include("MAN", "AA")
    end
  end

  # T7's fourth scenario: a mode collaborator that raises must not lose the
  # prompt. No new rescue is added for this -- {Formatted#call} raises
  # straight through `@state.to_h`, and {PromptComposer#compose}'s existing
  # RENDERER_FAULTS net already catches it, exactly as it does today for any
  # other reader that raises. This pins that the mode reading rides the same
  # net rather than needing one of its own.
  describe "a mode collaborator that raises" do
    let(:agent) { instance_double(Lain::Agent, occupancy: nil, context: instance_double(Lain::Context, model: "opus")) }
    let(:status_feed) { instance_double(Lain::StatusFeed, state: { "fleet" => [] }) }
    let(:clock) { Lain::RunClock.new(clock: -> { 0.0 }) }
    # Answers neither #posture nor #layers -- the shape a badly-wired
    # collaborator would take, not a well-formed Mode.
    let(:broken_mode) { Object.new }

    it "degrades to the plain prompt and warns once, through the composer's existing fault net" do
      state = Lain::Frontend::PromptComposer::RunState.new(agent:, clock:, status_feed:, mode: broken_mode)
      renderer = described_class.renderer(state:, screen: -> { 200 })
      warnings = []
      composer = described_class.new(theme: plain, renderer:, notify: warnings.method(:push))

      expect(composer.compose("> ").line).to eq("> ")
      expect(warnings.size).to eq(1)
    end
  end
end
