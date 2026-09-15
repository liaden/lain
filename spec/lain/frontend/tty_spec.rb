# frozen_string_literal: true

require "fileutils"
require "open3"
require "pastel"
require "rbconfig"
require "shellwords"
require "stringio"
require "tmpdir"

RSpec.describe Lain::Frontend::TTY do
  # What a TERMINAL reads as a line break, which is the property the arrival
  # note and the inbox listing actually claim -- `"\n"` alone is the pin that
  # a lone `\r` walks straight through.
  def line_break = /[\r\n\v\f\u{0085}\u{2028}\u{2029}]/

  let(:channel) { Lain::Channel.new }
  let(:output) { StringIO.new }
  let(:input) { StringIO.new }
  let(:tty) { described_class.new(channel:, output:, input:) }

  def tool_output(tool_use_id: "tu_1", stream: :stdout, bytes: "hello\n")
    Lain::Telemetry::ToolOutput.new(tool_use_id:, stream:, bytes:)
  end

  # Reline::HISTORY is process-global (Reline::History < Array), so every example
  # that touches it must restore the pre-existing content -- otherwise a line
  # pushed by one example leaks into the next.
  #
  # Reline.core.config is process-global too, and the interactive prompt now
  # reads the human's inputrc to resolve the editing mode. Without the
  # INPUTRC override these examples run against whatever dotfile the developer
  # happens to own -- an inputrc saying `set editing-mode vi` puts Reline in a
  # different keymap for every example that follows, and reset_variables also
  # drops any key binding a sibling spec file registered. Nothing here fails
  # without it today; it is here so that "passes on my machine" and "passes"
  # stay the same sentence.
  around do |example|
    original = Reline::HISTORY.to_a
    original_inputrc = ENV.fetch("INPUTRC", nil)
    ENV["INPUTRC"] = File.join(Dir.tmpdir, "lain-spec-no-such-inputrc")
    Reline.core.config.reset_variables
    Reline::HISTORY.clear
    example.run
    Reline::HISTORY.clear
    Reline::HISTORY.concat(original)
    ENV["INPUTRC"] = original_inputrc
    Reline.core.config.reset_variables
  end

  # What production actually announces and lists -- a whole Question::Set
  # wearing the one clamped line the inbox rows show
  # (Tools::AskHuman::Announcement). A bare String is still legal on both
  # seams, and the examples that pass one cover that arm.
  def announced(*ids, body: nil)
    questions = ids.map { |id| Lain::Question.new(id:, body: body || "which #{id}?") }
    Lain::Tools::AskHuman::Announcement.new(Lain::Question::Set.new(questions:))
  end

  # The OTHER value this seam carries: a human's own reply, measured and
  # handed back. Built exactly as `AskHuman#reopened` builds it, because what
  # is being pinned is how the surfaces render the production value.
  def handed_back(bytes)
    Lain::Tools::AskHuman::Ceiling.handback(Lain::Tools::AskHuman::Ceiling.overrun("L" * bytes))
  end

  def ceiling = Lain::Tools::AskHuman::Ceiling::BOUND.limit

  describe "#drain_and_render" do
    it "renders every currently-queued event and returns how many it rendered" do
      channel.push(tool_output(bytes: "first\n"))
      channel.push(tool_output(bytes: "second\n"))

      expect(tty.drain_and_render).to eq(2)
      expect(output.string).to include("first").and include("second")
    end

    it "attributes rendered output by tool_use_id and stream" do
      channel.push(tool_output(tool_use_id: "tu_abc", stream: :stderr, bytes: "boom\n"))

      tty.drain_and_render

      expect(output.string).to include("tu_abc").and include("stderr").and include("boom")
    end

    it "does not block and renders nothing when the channel is empty" do
      expect(tty.drain_and_render).to eq(0)
      expect(output.string).to eq("")
    end
  end

  describe "#run" do
    it "enters the alternate screen before yielding and restores it after" do
      tty.run { channel.close }

      expect(output.string).to start_with(described_class::ALTERNATE_SCREEN_ON)
      expect(output.string).to end_with(described_class::ALTERNATE_SCREEN_OFF)
    end

    it "restores the main screen even when the yielded block raises" do
      expect { tty.run { raise "boom" } }.to raise_error("boom")

      expect(output.string).to end_with(described_class::ALTERNATE_SCREEN_OFF)
    end

    it "drains and renders events pushed before the block closes the channel" do
      channel.push(tool_output(bytes: "streamed live\n"))

      tty.run { channel.close }

      expect(output.string).to include("streamed live")
    end

    it "renders its ToolOutput events, ignores unrelated events, and exits on close" do
      channel.push(tool_output(bytes: "mine\n"))
      channel.push(Lain::Telemetry::Dropped.new(count: 3))

      tty.run { channel.close }

      expect(output.string).to include("mine")
    end

    it "yields self, so a caller can drive #prompt / #render_response inside the block" do
      yielded = nil
      tty.run do |handle|
        yielded = handle
        channel.close
      end

      expect(yielded).to be(tty)
    end

    it "closes the channel on the way out even if the block does not" do
      tty.run { :noop }

      expect(channel).to be_closed
    end
  end

  # The prompt reads {Lain::StatusFeed}'s published `.lain/state.json` and
  # shows a warmth glyph -- a snapshot taken once, as the prompt is composed for
  # the line editor (interface-integration.md's fixed-prompt limitation), never
  # mid-wait.
  describe "prompt warmth" do
    around do |example|
      Dir.mktmpdir { |dir| @state_dir = dir and example.run }
    end

    def state_path
      File.join(@state_dir, ".lain", "state.json")
    end

    def write_state(cache_deadline:)
      FileUtils.mkdir_p(File.dirname(state_path))
      File.write(state_path, JSON.generate({ "cache_deadline" => cache_deadline, "fleet" => [], "inbox_count" => 0 }))
    end

    def write_raw(bytes)
      FileUtils.mkdir_p(File.dirname(state_path))
      File.write(state_path, bytes)
    end

    # A fixed wall clock ("now" = epoch 1_000) so warm/cold is a plain
    # before/after comparison against a deadline written into the fixture
    # file -- no real time passes and no example races a real deadline.
    def tty_with_state(state_path: self.state_path, output_tty: true)
      allow(output).to receive(:tty?).and_return(output_tty)
      described_class.new(channel:, output:, state_path:, wall_clock: -> { Time.at(1_000) },
                          pastel: Pastel.new(enabled: false))
    end

    it "renders a warm glyph when the deadline is still ahead of now" do
      write_state(cache_deadline: Time.at(1_500).utc.iso8601)

      composed = tty_with_state.compose("> ")

      expect(composed).to include(Lain::StatusFeed::Reading::WARM)
      expect(composed).not_to include(Lain::StatusFeed::Reading::COLD)
    end

    # The same file {Lain::StatusFeed} and `lain up` default to, ASKED of
    # the one locator rather than composed a third time. The locator is stubbed
    # to answer a path it would never derive, and only that path holds a warm
    # deadline, so a default composed here reads nothing and renders the bare
    # prompt. The chdir keeps a regressed default inside the tmpdir rather than
    # letting it find the real repo's own `.lain/`.
    it "asks the ONE project locator for its state path rather than composing one" do
      elsewhere = File.join(@state_dir, "the-locator-said-here", "state.json")
      FileUtils.mkdir_p(File.dirname(elsewhere))
      File.write(elsewhere, JSON.generate({ "cache_deadline" => Time.at(1_500).utc.iso8601 }))
      allow(Lain::ProjectDir).to receive(:new).and_return(instance_double(Lain::ProjectDir, state_path: elsewhere))
      allow(output).to receive(:tty?).and_return(true)

      composed = Dir.chdir(@state_dir) do
        described_class.new(channel:, output:, wall_clock: -> { Time.at(1_000) },
                            pastel: Pastel.new(enabled: false)).compose("> ")
      end

      expect(composed).to include(Lain::StatusFeed::Reading::WARM)
    end

    it "renders a cold glyph when the deadline has already passed" do
      write_state(cache_deadline: Time.at(500).utc.iso8601)

      expect(tty_with_state.compose("> ")).to include(Lain::StatusFeed::Reading::COLD)
    end

    it "renders today's bare prompt when no state file has ever been published" do
      expect(tty_with_state(state_path: File.join(@state_dir, "never-written", "state.json")).compose("> "))
        .to eq("> ")
    end

    it "renders today's bare prompt when the feed exists but has no cache_deadline yet" do
      write_state(cache_deadline: nil)

      expect(tty_with_state.compose("> ")).to eq("> ")
    end

    # Review fix round: the reviewer reproduced a crash where a syntactically
    # valid state.json with a semantically bad cache_deadline reached
    # Time.iso8601 uncaught, taking down the whole prompt loop -- not just the
    # glyph. The contract is "never raise at the prompt, for any file
    # content", so every malformed shape below must degrade to the bare
    # prompt exactly like a missing file does.
    it "renders today's bare prompt when the state file is not valid JSON" do
      write_raw("not json at all {{{")

      expect(tty_with_state.compose("> ")).to eq("> ")
    end

    it "renders today's bare prompt when cache_deadline is not a parseable timestamp" do
      write_state(cache_deadline: "not-a-real-timestamp")

      expect(tty_with_state.compose("> ")).to eq("> ")
    end

    it "renders today's bare prompt when the published JSON's top level is not a Hash" do
      write_raw(JSON.generate([1, 2, 3]))

      expect(tty_with_state.compose("> ")).to eq("> ")
    end

    it "leaves non-tty output byte-identical to today: no glyph, no escapes" do
      write_state(cache_deadline: Time.at(1_500).utc.iso8601)

      expect(tty_with_state(output_tty: false).compose("> ")).to eq("> ")
      expect(output.string).to eq("")
    end
  end

  # The prompt string is composed through a {Lain::Frontend::PromptComposer} seam. The
  # default renderer is the null one, and the five `"> "` assertions above are
  # its contract: with nobody composing anything, the bytes the line editor
  # receives are exactly the ones it received before the seam existed. What
  # {#compose} answers is what the pump hands the line editor.
  describe "prompt composition" do
    around do |example|
      Dir.mktmpdir { |dir| @prompt_dir = dir and example.run }
    end

    def tty_with_renderer(renderer)
      described_class.new(channel:, output:, prompt_renderer: renderer,
                          history_path: File.join(@prompt_dir, "history"))
    end

    it "answers the composed line for the line editor" do
      expect(tty_with_renderer(->(text:, **) { "opus 42% #{text}" }).compose("> ")).to eq("opus 42% > ")
    end

    it "writes every line but the final one to the screen BEFORE the editor takes over" do
      tty_with_renderer(->(text:, **) { "model: opus\ncontext: 42%\n#{text}" }).compose("> ")

      expect(output.string).to eq("model: opus\ncontext: 42%\n")
    end

    # Reline escapes a newline in its prompt to a literal backslash-n
    # (line_editor.rb), so a multi-line rendering has to be split here or it
    # arrives mangled.
    it "never lets a newline reach the line editor" do
      expect(tty_with_renderer(->(text:, **) { "model: opus\ncontext: 42%\n#{text}" }).compose("> ")).to eq("> ")
    end

    it "shows today's prompt, and no header, when the renderer raises" do
      expect(tty_with_renderer(->(**) { raise Lain::ContextWindow::UnknownModel, "no model configured" }).compose("> "))
        .to eq("> ")
    end

    # A degraded renderer is reported through the same warning line an
    # unwritable history file uses -- once, above the prompt, never instead
    # of it.
    it "renders a warning line for a broken renderer rather than failing silently" do
      tty_with_renderer(->(**) { raise Lain::ContextWindow::UnknownModel, "no model configured" }).compose("> ")

      expect(output.string).to eq("warning: prompt renderer unavailable (no model configured)\n")
    end

    it "still prepends the warmth glyph the null renderer was handed" do
      allow(output).to receive(:tty?).and_return(true)
      state = File.join(@prompt_dir, "state.json")
      File.write(state, JSON.generate({ "cache_deadline" => Time.at(1_500).utc.iso8601 }))

      composed = described_class.new(channel:, output:, state_path: state, pastel: Pastel.new(enabled: false),
                                     wall_clock: -> { Time.at(1_000) }, history_path: File.join(@prompt_dir, "history"))
                                .compose("> ")

      expect(composed).to eq("#{Lain::StatusFeed::Reading::WARM} > ")
    end
  end

  describe "history (XDG state)" do
    around do |example|
      Dir.mktmpdir { |dir| @history_dir = dir and example.run }
    end

    def history_path
      File.join(@history_dir, "history")
    end

    def tty_with_history(history_path: self.history_path)
      described_class.new(channel:, output:, history_path:)
    end

    # Up-arrow walks THIS session's lines. The file is one undifferentiated pool
    # across every project and every concurrent `lain up` pane, so loading it
    # made recall a merge of other people's panes ordered by whoever flushed
    # first -- see {Lain::Frontend::TTY::History}'s comment.
    it "does not load the history file into Reline::HISTORY, so recall is this session's" do
      File.write(history_path, "first command\nsecond command\n")

      tty_with_history.run { channel.close }

      expect(Reline::HISTORY.to_a).to be_empty
    end

    # The other half of the same rule: the file is still WRITTEN, and appended to
    # rather than started fresh, so a project-scoped recall has something to read
    # later. A prior session's line is the fixture precisely because it is what
    # this class no longer hands to the prompt.
    it "appends past an earlier session's lines rather than replacing them" do
      File.write(history_path, "from an earlier session\n")

      tty_with_history.remember("this session's line")

      expect(File.read(history_path)).to eq("from an earlier session\nthis session's line\n")
    end

    it "writes an accepted line to disk before the next prompt" do
      tty_with_history.remember("remember me")

      expect(File.read(history_path)).to eq("remember me\n")
    end

    it "creates the history file owner-only (0600) at open(), with no chmod window" do
      expect(File).not_to receive(:chmod)

      tty_with_history.remember("secret-adjacent line")

      expect(File.stat(history_path).mode & 0o777).to eq(0o600)
    end

    it "appends rather than truncating across multiple accepted lines" do
      history_tty = tty_with_history
      %w[one two].each { |line| history_tty.remember(line) }

      expect(File.read(history_path)).to eq("one\ntwo\n")
    end

    it "degrades loudly-but-usable when the history location is unwritable" do
      blocking_file = File.join(@history_dir, "blocked")
      File.write(blocking_file, "not a directory")
      unwritable_path = File.join(blocking_file, "history")

      expect { tty_with_history(history_path: unwritable_path).remember("still works") }.not_to raise_error

      expect(output.string.downcase).to include("warning")
    end

    it "renders exactly one warning even after repeated failed writes" do
      blocking_file = File.join(@history_dir, "blocked")
      File.write(blocking_file, "not a directory")
      unwritable_path = File.join(blocking_file, "history")

      history_tty = tty_with_history(history_path: unwritable_path)
      %w[a b].each { |line| history_tty.remember(line) }

      expect(output.string.downcase.scan("warning").size).to eq(1)
    end
  end

  describe "#render_response" do
    it "prints the response's text" do
      response = Lain::Response.new(
        content: [{ "type" => "text", "text" => "the answer is 4" }],
        stop_reason: :end_turn
      )

      tty.render_response(response)

      expect(output.string).to include("the answer is 4")
    end
  end

  # A command's structured answer. Each segment is painted under the token
  # IT named, so the frontend never has to know what a command's parts mean.
  describe "#render_renderable" do
    let(:colored) { Pastel.new(enabled: true) }
    let(:styling_tty) do
      described_class.new(channel:, output:, input:, pastel: colored,
                          theme: Lain::Frontend::Theme.new(pastel: colored, detect: -> { 256 }))
    end

    it "prints the renderable's words" do
      tty.render_renderable(Lain::Renderable.new.plain("cache ").with(:warm, "warm"))

      expect(output.string).to include("cache warm")
    end

    it "paints each segment under its own token, never one style over them all" do
      styling_tty.render_renderable(Lain::Renderable.new.plain("cache ").with(:warm, "warm"))

      expect(output.string).to include("cache #{colored.green("warm")}")
    end

    it "closes a command's answer exactly as it closes a model's turn" do
      response = Lain::Response.new(content: [{ "type" => "text", "text" => "same words" }],
                                    stop_reason: :end_turn)
      turn = StringIO.new
      described_class.new(channel:, output: turn, input:).render_response(response)

      tty.render_renderable(Lain::Renderable.new.with(:response, "same words"))

      expect(output.string).to eq(turn.string)
    end
  end

  describe "#render_error" do
    it "prints the message" do
      tty.render_error("something broke")

      expect(output.string).to include("something broke")
    end
  end

  # A pending ask_human question is surfaced synchronously so the human
  # sees what they are answering before #prompt reads the reply -- like
  # #render_response, it bypasses the Channel (a finished exchange, not a
  # concurrently-arriving stream).
  describe "#render_question" do
    it "prints the question the agent put to the human" do
      tty.render_question("which config file should I edit?")

      expect(output.string).to include("which config file should I edit?")
    end
  end

  # A question ARRIVES as a one-line note -- never the modal inline block
  # render_question prints -- so the human keeps their prompt and drains at
  # their own pace (/inbox, or the nvim buffer).
  describe "#render_arrival" do
    it "renders exactly one line naming the question and pointing at /inbox" do
      tty.render_arrival("which database should staging use?")

      expect(output.string).to include("which database should staging use?")
      expect(output.string).to include("/inbox")
      expect(output.string.chomp).not_to include("\n")
    end

    # Production announces a whole Question::Set wearing a one-line
    # summary (Tools::AskHuman::Announcement), and the note now names who is
    # stuck as well as both surfaces that can answer it.
    it "names the asker and points at the editor's inbox as well as /inbox" do
      tty.render_arrival(announced("db"), from: "researcher")

      expect(output.string).to include("researcher").and include("which db?")
      expect(output.string).to include("-- answer in lain://inbox, or /inbox")
      expect(output.string.chomp).not_to match(line_break)
    end

    it "stays one line for a five-question set of multi-line bodies" do
      tty.render_arrival(announced("db", "region", "budget", "deploy", "owner",
                                   body: "which database?\n\n| a | b |\n| - | - |"),
                         from: "orchestrator")

      expect(output.string).to include("which database?").and include("(+4 more)")
      expect(output.string.chomp).not_to match(line_break)
    end

    # One line on the TERMINAL, which is what the property is actually about:
    # a lone \r holds no "\n" and still redraws the note from column 0, so
    # everything before it -- the asker included -- is overwritten by whatever
    # the question's author put after it.
    it "is one line for a terminal, not merely free of newlines" do
      tty.render_arrival(announced("db", body: "harmless question\rATTACKER OWNS THIS LINE"),
                         from: "researcher")

      expect(output.string.chomp).not_to match(line_break)
      expect(output.string).to include("researcher").and include("lain://inbox, or /inbox")
    end

    # A handback's BYTES are the measurement followed by every byte of the
    # reply -- the payload has to reach the notifier and the document below --
    # so the note reads its `#summary` like an Announcement's. Read as a bare
    # String it printed the whole reply as one unwrapped terminal line: 64 KiB
    # for the smallest overrun there is, and megabytes for a pasted log.
    it "states a handback's measurement in a note far smaller than the reply it measured" do
      handback = handed_back(ceiling + 1)

      tty.render_arrival(handback, from: "chat")

      expect(output.string).to include("over the ceiling of #{ceiling}").and include("type `send`")
      expect(output.string.bytesize).to be < (handback.bytesize / 100)
      expect(output.string.chomp).not_to match(line_break)
    end

    # The width is bounded by the digits in a byte count rather than by the
    # payload, so five megabytes costs the same line as sixty-four kilobytes.
    it "stays the same bounded line for a five-megabyte reply" do
      tty.render_arrival(handed_back(5 * 1024 * 1024), from: "chat")

      expect(output.string.bytesize).to be < 400
      expect(output.string.chomp).not_to match(line_break)
    end

    it "clamps a long asker name to the width the sender column already uses" do
      tty.render_arrival(announced("db"), from: "an-agent-with-a-very-long-name-indeed")

      expect(output.string).to include("an-agent-with-a-ver ")
      expect(output.string).not_to include("long-name-indeed")
    end
  end

  # The TTY-only drain surface. Lists what is pending (sender and age) and
  # reads ONE answer; the resolution itself stays with the caller's block --
  # AskHuman#reply is the Repl's seam, never the TTY's.
  # A prompt a human leaves drawn while a fleet keeps arriving must not hold an
  # unbounded backlog: the newest notes are kept, and one line says how many
  # older ones went.
  describe "notes held behind a drawn prompt" do
    it "keeps the newest and says how many earlier ones were dropped" do
      limit = 200
      plain = described_class.new(channel:, output:, pastel: Pastel.new(enabled: false))

      Sync do |task|
        released = Async::Notification.new
        drawn = task.async { plain.drawing(-> { true }) { released.wait } }
        task.async { (limit + 50).times { |index| plain.render_warning("note #{index}") } }.wait
        released.signal
        drawn.wait
      end

      printed = output.string.lines
      expect(printed.first).to include("50 earlier notes were dropped")
      expect(printed.drop(1).map { |row| row[/note (\d+)/, 1].to_i }).to eq((50...(limit + 50)).to_a)
    end
  end

  describe "#drain_inbox" do
    let(:drain_tty) do
      described_class.new(channel:, output:, input:, pastel: Pastel.new(enabled: false),
                          wall_clock: -> { Time.at(1_000) })
    end

    # What the human types at the drain's prompt, a line per read.
    def typed = ->(_prompt) { input.gets&.chomp }

    def item(question:, from: "orchestrator", asked_at: Time.at(880))
      Struct.new(:question, :from, :asked_at).new(question, from, asked_at)
    end

    # The arrival's twin, and it had the same defect: an Announcement's bytes
    # are a LONE question's body verbatim, so a question carrying a table was
    # a five-line "row" that buried the item beneath it -- and then repeated
    # itself, verbatim, in the document below.
    it "lists one line per item however long the question's body is" do
      input.string = "postgres\n"
      wordy = announced("db", body: "Which database?\n\n| option | cost |\n| --- | --- |\n| pg | low |")

      drain_tty.drain_inbox([item(question: wordy), item(question: announced("region"))],
                            reader: typed) { |_answer| nil }

      listed = output.string.lines.take(2)
      expect(listed.first).to include("Which database?").and(satisfy { |line| !line.include?("| pg |") })
      expect(listed.last).to include("which region?")
    end

    it "lists every pending item with sender and age before prompting" do
      input.string = "postgres\n"
      items = [item(question: "which db?", from: "orchestrator", asked_at: Time.at(880)),
               item(question: "deploy now?", from: "researcher", asked_at: Time.at(997))]

      drain_tty.drain_inbox(items, reader: typed) { |_answer| nil }

      expect(output.string).to include("orchestrator").and include("which db?").and include("2m")
      expect(output.string).to include("researcher").and include("deploy now?").and include("3s")
    end

    # THE SHARED ROW, on this surface. Pinned as a whole LINE rather than three
    # `include`s, because what one row buys is the layout as much as the age --
    # and the editor's lain://inbox draws this same string.
    it "lists a pending question as the row the editor's inbox also draws" do
      input.string = "\n"

      drain_tty.drain_inbox([item(question: "which db?")], reader: typed) { |_answer| nil }

      expect(output.string.lines.first.chomp).to eq("orchestrator  2m  which db?")
    end

    it "yields a non-empty answer to the block -- the resolution seam" do
      input.string = "postgres\n"
      resolved = []

      drain_tty.drain_inbox([item(question: "which db?")], reader: typed) { |answer| resolved << answer }

      expect(resolved).to eq(["postgres"])
    end

    it "renders the empty note and never prompts or yields when nothing is pending" do
      drain_tty.drain_inbox([], reader: typed) { |_answer| raise "must not yield" }

      expect(output.string).to include("(no questions pending)")
      expect(output.string).not_to include("human>")
    end

    it "does not yield for an empty line or EOF" do
      input.string = "\n"

      expect { |probe| drain_tty.drain_inbox([item(question: "which db?")], reader: typed, &probe) }
        .not_to yield_control
    end

    # A set made this worse than a lost keystroke: a whitespace-only line was
    # yielded, its prose was dropped as blank by the AnswerSet, and what came
    # back was a document asserting the human answered nothing -- a claim they
    # never made, delivered to the model as their reply. `Blankness` rather
    # than `strip` so the drain's idea of "nothing at all" is the same one the
    # value object uses to drop it (U+00A0 and the zero-width set included).
    it "does not yield for a whitespace-only line, and never fabricates a record from one" do
      input.string = "    \n"

      expect { |probe| drain_tty.drain_inbox([item(question: announced("db"))], reader: typed, &probe) }
        .not_to yield_control
    end

    it "reads the answer through an injected reader (the conductor's read_reply seam)" do
      prompts = []
      reader = lambda do |prompt|
        prompts << prompt
        "from-conductor"
      end
      resolved = []

      drain_tty.drain_inbox([item(question: "which db?")], reader:) { |answer| resolved << answer }

      expect(resolved).to eq(["from-conductor"])
      expect(prompts).to eq(["human> "])
    end

    # Where "shown their own text again" is served, and the split that makes
    # it safe: the ROW stays one bounded line, and the block below it carries
    # every byte, because a human typed `/inbox` to see exactly what they are
    # about to confirm. Type-tested for an Announcement, the block was empty
    # and the drain offered a confirmation with nothing to confirm.
    it "lists a handback in one line and prints the whole reply in the document below" do
      input.string = "send\n"
      handback = handed_back(ceiling + 1)

      drain_tty.drain_inbox([item(question: handback)], reader: typed) { |_answer| nil }

      expect(output.string.lines.first.bytesize).to be < 400
      expect(output.string.lines.first).to include("over the ceiling of #{ceiling}")
      expect(output.string.bytesize).to be > ceiling
    end

    # A set carries more than a line, so the drain prints the same
    # markdown document the editor opens -- for the item a typed answer will
    # actually answer, which is the oldest one listed.
    it "prints the markdown of the set a typed answer will answer" do
      input.string = "postgres\n"

      drain_tty.drain_inbox([item(question: announced("db", "region"))], reader: typed) { |_answer| nil }

      expect(output.string).to include("## `db` (write your answer below)").and include("which db?")
      expect(output.string).to include("## `region` (write your answer below)")
    end

    it "prints the document only for the oldest item -- the one an answer reaches" do
      input.string = "postgres\n"
      items = [item(question: announced("db")), item(question: announced("region"))]

      drain_tty.drain_inbox(items, reader: typed) { |_answer| nil }

      expect(output.string).to include("## `db`")
      expect(output.string).not_to include("## `region`")
    end

    it "yields a typed reply as the whole set answered in prose" do
      input.string = "use postgres everywhere\n"
      resolved = []

      drain_tty.drain_inbox([item(question: announced("db", "region"))], reader: typed) do |answer|
        resolved << answer
      end

      expect(resolved.first).to include("answered the whole set in prose rather than by selection")
      expect(resolved.first).to include("> use postgres everywhere")
    end

    # A validating constructor now stands between the human's keystrokes and
    # the resolve, and a refusal there is NOT a dead question: the set is
    # still pending, so the reason is rendered where they typed it and the
    # prompt comes round again. Raising instead unwound into the caller's
    # `ensure`, which retired the only line the question could be answered
    # through -- an agent parked forever on a paste.
    it "refuses an answer the record cannot carry and reads again rather than raising" do
      reads = 0
      reader = lambda do |_prompt|
        reads += 1
        reads == 1 ? "x" * (70 * 1024) : "postgres"
      end
      resolved = []

      drain_tty.drain_inbox([item(question: announced("db"))], reader:) { |answer| resolved << answer }

      expect(output.string).to include("beyond the 65536-byte maximum")
      expect(resolved.first).to include("> postgres")
      expect(reads).to eq(2)
    end

    # The encoding arm, which raised from the event write long before this
    # card and reached the human as the same dead line. Refused at the read,
    # where a human can retype it, and on the bare-String arm too -- that one
    # builds no AnswerSet, so nothing else would have looked.
    it "refuses a reply that is not valid UTF-8, on a bare String as on a set" do
      reads = 0
      reader = lambda do |_prompt|
        reads += 1
        reads == 1 ? (+"caf\xE9 please").force_encoding(Encoding::UTF_8) : "postgres"
      end
      resolved = []

      drain_tty.drain_inbox([item(question: "which db?")], reader:) { |answer| resolved << answer }

      expect(output.string).to include("not valid UTF-8")
      expect(resolved).to eq(["postgres"])
    end

    it "renders that answer as unstructured -- never as a selection" do
      input.string = "use postgres\n"
      set = announced("db")
      resolved = []

      drain_tty.drain_inbox([item(question: set)], reader: typed) { |answer| resolved << answer }

      expect(resolved.first).to eq(Lain::Question::AnswerSet.new(questions: set.set, text: "use postgres").render)
      expect(resolved.first).not_to include("Chose:")
      expect(resolved.first).not_to include("The human answered 1 of 1 question")
    end
  end

  # The countdown status line, ticked externally (a real caller is a
  # timer thread; these specs drive it directly with an injected clock so no
  # example needs a real sleep).
  describe "#render_countdown" do
    let(:coordinator) { instance_double(Lain::CLI::Shutdown, signal: nil) }

    # A plain incrementing lambda stands in for the monotonic clock -- one
    # call per tick, exactly what #render_countdown makes, so N calls to
    # render_countdown advance "now" by N steps with no real time passing.
    def counting_clock(start:, step: 1)
      now = start
      lambda do
        value = now
        now += step
        value
      end
    end

    # Both output and input must present as a real terminal for the
    # interactive (escape-drawing, key-reading) path -- StringIO's #tty? is
    # always false, so these examples stub it on rather than swap the double
    # type, matching the existing `allow(input).to receive(:tty?)` idiom
    # above.
    def interactive_tty(clock: counting_clock(start: 100))
      allow(output).to receive(:tty?).and_return(true)
      allow(input).to receive(:tty?).and_return(true)
      described_class.new(channel:, output:, input:, pastel: Pastel.new(enabled: false), clock:)
    end

    def seconds_rendered
      output.string.scan(/closing in (\d+)s/).flatten.map(&:to_i)
    end

    it "renders three successive ticks with decreasing seconds and the offered keys" do
      tty = interactive_tty

      3.times { tty.render_countdown(deadline: 103, options: { coordinator: }) }

      expect(seconds_rendered).to eq([3, 2, 1])
      expect(output.string).to include("[c] cancel")
      expect(output.string).to include("[w] wait longer")
      expect(output.string).to include("[r] respond then exit")
    end

    it "forwards a pressed offered key to the coordinator as a signal" do
      input.string = "w"
      tty = interactive_tty

      tty.render_countdown(deadline: 103, options: { coordinator: })

      expect(coordinator).to have_received(:signal).with(:extend)
    end

    it "ignores a key that is not one of the offered bindings" do
      input.string = "z"
      tty = interactive_tty

      tty.render_countdown(deadline: 103, options: { coordinator: })

      expect(coordinator).not_to have_received(:signal)
    end

    it "renders a grown deadline on the tick after the coordinator re-arms the window" do
      tty = interactive_tty

      tty.render_countdown(deadline: 103, options: { coordinator: })
      tty.render_countdown(deadline: 163, options: { coordinator: })

      expect(seconds_rendered.last).to be > seconds_rendered.first
    end

    it "clears and redraws the countdown line around a channel event so the two never interleave" do
      tty = interactive_tty
      tty.render_countdown(deadline: 103, options: { coordinator: })
      before_event = output.string.length

      channel.push(tool_output(bytes: "live output\n"))
      tty.drain_and_render

      full = output.string
      event_index = full.index("live output")
      clear_index = full.index(TTY::Cursor.clear_line, before_event)

      expect(event_index).not_to be_nil
      expect(clear_index).to be < event_index
      expect(full.index("closing in", event_index)).not_to be_nil, "expected the countdown to redraw after the event"
    end

    # The line-ending fix touches ONLY the inactive branch, so these two hold the active
    # branch still for BOTH decorators: the status line steps aside, the event
    # prints, and the status line redraws on a row of its own -- true of a
    # mid-line tool chunk too, because the fresh row is the STATUS LINE's need,
    # not the content's. (The byte-identity half of the claim is demonstrated
    # outside RSpec, in a manual before/after capture.)
    it "prints a provider-retry event above the status line and redraws the line beneath it" do
      tty = interactive_tty
      tty.render_countdown(deadline: 103, options: { coordinator: })
      before_event = output.string.length

      channel.push(Lain::Telemetry::ProviderRetry.new(attempt: 1, will_retry_in: 0.11))
      tty.drain_and_render

      tail = output.string[before_event..]
      expect(tail).to start_with(TTY::Cursor.clear_line)
      expect(tail).to match(/\[retry\] attempt 1[^\n]*\n/)
      expect(tail.index("closing in")).to be > tail.index("\n")
    end

    it "still gives the redrawn status line a fresh row after a tool-output chunk with no newline" do
      tty = interactive_tty
      tty.render_countdown(deadline: 103, options: { coordinator: })
      before_event = output.string.length

      channel.push(tool_output(bytes: "no trailing newline"))
      tty.drain_and_render

      tail = output.string[before_event..]
      expect(tail).to include("no trailing newline\n")
      expect(tail.index("closing in")).to be > tail.index("no trailing newline")
    end

    it "degrades to a plain line with no key reading and no escapes when output is not a tty" do
      allow(input).to receive(:tty?).and_return(true)
      input.string = "w"
      plain_tty = described_class.new(channel:, output:, input:, clock: counting_clock(start: 100))

      plain_tty.render_countdown(deadline: 103, options: { coordinator: })

      expect(output.string).not_to match(/\e\[/)
      expect(output.string).to include("closing in 3s")
      expect(coordinator).not_to have_received(:signal)
    end

    it "degrades the same way when input is not a tty, even on a tty output" do
      allow(output).to receive(:tty?).and_return(true)
      input.string = "w"
      plain_tty = described_class.new(channel:, output:, input:, clock: counting_clock(start: 100))

      plain_tty.render_countdown(deadline: 103, options: { coordinator: })

      expect(output.string).not_to match(/\e\[/)
      expect(output.string).to include("closing in 3s")
      expect(coordinator).not_to have_received(:signal)
    end
  end

  # The window-scoped lifecycle: a countdown that has ended must leave no
  # trace -- later channel events take the plain no-countdown path,
  # and the terminal mode entered at window start is restored exactly once.
  describe "#stop_countdown" do
    let(:coordinator) { instance_double(Lain::CLI::Shutdown, signal: nil) }

    def counting_clock(start:, step: 1)
      now = start
      lambda do
        value = now
        now += step
        value
      end
    end

    def interactive_tty(input: self.input, clock: counting_clock(start: 100))
      allow(output).to receive(:tty?).and_return(true)
      allow(input).to receive(:tty?).and_return(true) if input.equal?(self.input)
      described_class.new(channel:, output:, input:, pastel: Pastel.new(enabled: false), clock:)
    end

    # The Evans-blocker seam: a console-capable input the spec can spy on.
    # StringIO cannot see termios, so the raw-once/restore-once contract is
    # pinned against the io/console duck (`raw!`/`console_mode`); the PTY
    # probe in the handback is the evidence for the real-terminal half.
    def console_input(saved_mode: :cooked_mode)
      instance_double(IO, tty?: true, raw!: nil, console_mode: saved_mode, :console_mode= => nil).tap do |console|
        allow(console).to receive(:read_nonblock).and_raise(IO::EAGAINWaitReadable)
      end
    end

    it "returns later channel events to the plain path, with no stale status line redrawn" do
      tty = interactive_tty
      2.times { tty.render_countdown(deadline: 103, options: { coordinator: }) }

      tty.stop_countdown
      after_stop = output.string.length
      channel.push(tool_output(bytes: "long after the window\n"))
      tty.drain_and_render

      tail = output.string[after_stop..]
      expect(tail).not_to include("closing in")
      expect(tail).not_to match(/\e\[/)
      expect(tail).to include("long after the window\n")
    end

    it "erases the bottom status line rather than leaving it on screen" do
      tty = interactive_tty
      tty.render_countdown(deadline: 103, options: { coordinator: })
      before_stop = output.string.length

      tty.stop_countdown

      expect(output.string[before_stop..]).to include(TTY::Cursor.clear_line)
    end

    it "is idempotent: a second stop writes nothing and restores nothing again" do
      console = console_input
      tty = interactive_tty(input: console)
      tty.render_countdown(deadline: 103, options: { coordinator: })
      tty.stop_countdown
      after_first = output.string.length

      tty.stop_countdown

      expect(output.string.length).to eq(after_first)
      expect(console).to have_received(:console_mode=).once
    end

    it "enters raw mode once for the whole window, not once per tick" do
      console = console_input
      tty = interactive_tty(input: console)

      3.times { tty.render_countdown(deadline: 103, options: { coordinator: }) }

      expect(console).to have_received(:raw!).once
    end

    it "restores the console mode it saved at window start" do
      console = console_input(saved_mode: :the_mode_before)
      tty = interactive_tty(input: console)
      tty.render_countdown(deadline: 103, options: { coordinator: })

      tty.stop_countdown

      expect(console).to have_received(:console_mode=).with(:the_mode_before).once
    end

    it "never leaves the terminal raw when the run block raises mid-window" do
      console = console_input
      tty = interactive_tty(input: console)

      expect do
        tty.run do
          tty.render_countdown(deadline: 103, options: { coordinator: })
          raise "boom"
        end
      end.to raise_error("boom")

      expect(console).to have_received(:console_mode=).once
    end

    it "does not enter raw mode at all for a plain (non-interactive) countdown" do
      console = console_input
      allow(console).to receive(:tty?).and_return(false)
      tty = interactive_tty(input: console)

      tty.render_countdown(deadline: 103, options: { coordinator: })
      tty.stop_countdown

      expect(console).not_to have_received(:raw!)
      expect(console).not_to have_received(:console_mode=)
    end
  end

  # With no countdown running there is no status line to protect, and the
  # plain path printed every decorator's bytes bare. A line-shaped decorator's
  # output then ran together -- four retry lines plus the error that followed
  # them arrived as one screen row. Here the line ending is the DECORATOR's
  # question, not the status line's, which is why only this branch changes.
  describe "line endings with no countdown active" do
    def provider_retry(attempt:)
      Lain::Telemetry::ProviderRetry.new(attempt:, will_retry_in: 0.11, status: 503,
                                         reason: "Faraday::ConnectionFailed")
    end

    it "gives four retry lines and the error that follows them five line endings, not one" do
      4.times { |index| channel.push(provider_retry(attempt: index + 1)) }

      tty.drain_and_render
      tty.render_error("provider gave up")

      lines = output.string.lines
      expect(lines.size).to eq(5)
      expect(lines).to all(end_with("\n"))
      expect(lines.grep(/\[retry\]/).size).to eq(4)
    end

    it "leaves a streaming tool-output chunk unterminated, since a chunk is not a line" do
      channel.push(tool_output(bytes: "half a li"))

      tty.drain_and_render

      expect(output.string).to end_with("half a li")
    end
  end

  # The `vi` and `notify` mode layers, read off the chat's live layer set at
  # the moment each one matters: `vi` at every read, `notify` at every arrival.
  describe "the vi and notify mode layers" do
    let(:raised) { [] }
    let(:displayed) { [] }
    let(:layered) do
      described_class.new(channel:, output:, input:, layers: -> { Lain::Mode::LayerSet.new(raised) },
                          tmux: ->(note) { displayed << note })
    end

    describe "vi" do
      it "answers vi while the layer is raised, and not once it is lowered" do
        raised << :vi
        in_vi = layered.vi?
        raised.clear

        expect([in_vi, layered.vi?]).to eq([true, false])
      end
    end

    describe "notify, on a question's arrival" do
      it "rings the terminal and asks tmux to display a message naming the asker" do
        raised << :notify

        layered.render_arrival(announced("db"), from: "explorer")

        expect(output.string).to include("\a")
        expect(displayed).to contain_exactly(a_string_including("explorer"))
      end

      it "rings after the note is on the screen, not before it" do
        raised << :notify

        layered.render_arrival(announced("db"), from: "explorer")

        expect(output.string.index("\a")).to be > output.string.index("explorer")
      end

      it "writes no bell and runs no tmux command while the layer is down" do
        layered.render_arrival(announced("db"), from: "explorer")

        expect(output.string).not_to include("\a")
        expect(displayed).to be_empty
      end

      it "reads the layer at the arrival, so lowering it silences the next one" do
        raised << :notify
        layered.render_arrival(announced("db"), from: "explorer")
        raised.clear

        layered.render_arrival(announced("region"), from: "explorer")

        expect(output.string.count("\a")).to eq(1)
        expect(displayed.size).to eq(1)
      end
    end

    # A parked approval's note and a review's "a file is waiting" line are the
    # other two things a human is summoned by.
    describe "#render_summons" do
      it "renders the line as a note and rings with it while the layer is up" do
        raised << :notify

        layered.render_summons("epic.md is open for review")

        expect(output.string).to include("epic.md is open for review").and include("\a")
        expect(displayed).to eq(["epic.md is open for review"])
      end

      it "renders the line and nothing else while the layer is down" do
        layered.render_summons("epic.md is open for review")

        expect(output.string).to include("epic.md is open for review")
        expect(output.string).not_to include("\a")
        expect(displayed).to be_empty
      end
    end

    # `request_review` marks a hand-over done only once its line to the human
    # returns, so a raise from here -- after the note is printed and the bell
    # has rung -- would report a review the human was shown as one never handed
    # over. A file name is bytes, and nothing upstream promises they are UTF-8.
    it "rings once and raises nothing for a summons whose line is not valid UTF-8" do
      shelled = []
      tmux = Lain::Frontend::TTY::TmuxMessage.new(env: { "TMUX" => "/tmp/tmux-1000/default,1,0" },
                                                  shell_out: lambda { |*argv, **|
                                                    shelled << argv
                                                    instance_double(Mixlib::ShellOut, run_command: nil)
                                                  },
                                                  background: ->(&work) { work.call })
      summoning = described_class.new(channel:, output:, input:, layers: -> { Lain::Mode::LayerSet.new([:notify]) },
                                      tmux:)

      expect(summoning.render_summons("review \xFF\xFE.md is waiting")).to be_nil
      expect(output.string.b.count("\a")).to eq(1)
      expect(shelled.size).to eq(1)
    end

    it "rings for nothing when built with no layers at all" do
      tty.render_arrival(announced("db"), from: "explorer")
      tty.render_summons("epic.md is open for review")

      expect(output.string).not_to include("\a")
    end
  end

  # The one thing the notify layer runs outside this process. It runs off the
  # arrival's own stack, bounded by a timeout, against the chat's own tmux.
  describe "TTY::TmuxMessage" do
    let(:shelled) { [] }
    let(:shell_out) do
      lambda do |*argv, **options|
        shelled << [argv, options]
        instance_double(Mixlib::ShellOut, run_command: nil)
      end
    end
    let(:inline) { ->(&work) { work.call } }
    let(:chat_env) { { "TMUX" => "/tmp/tmux-1000/default,4242,0", "TMUX_PANE" => "%3", "HOME" => "/home/x" } }

    def message(env: chat_env, background: inline, shell: shell_out)
      Lain::Frontend::TTY::TmuxMessage.new(env:, shell_out: shell, background:)
    end

    # The one shell-out a call made, failing when it made none or several.
    def shelled_once
      expect(shelled.size).to eq(1)
      shelled.first
    end

    it "asks the chat's own tmux server to display the note" do
      message.call("? explorer which db?")

      argv, options = shelled_once
      expect(argv).to eq(["tmux", "display-message", "? explorer which db?"])
      expect(options[:environment]).to eq("TMUX" => chat_env["TMUX"], "TMUX_PANE" => "%3")
    end

    it "bounds the tmux call with a timeout" do
      message.call("a note")

      expect(shelled_once.last[:timeout]).to be_a(Numeric).and be_positive
    end

    it "runs nothing outside tmux" do
      message(env: { "HOME" => "/home/x" }).call("a note")
      message(env: { "TMUX" => "" }).call("a note")

      expect(shelled).to be_empty
    end

    it "returns before the tmux call runs, so the arrival render never waits on it" do
      deferred = []

      message(background: ->(&work) { deferred << work }).call("a note")

      expect(shelled).to be_empty
      expect(deferred.size).to eq(1)
    end

    # tmux expands `#(...)` in a display-message by running it as a shell
    # command, and `%` as strftime -- so a note carrying model-written text is
    # escaped into a literal before tmux sees it.
    it "escapes tmux's format and time expansions, so model text cannot run a command" do
      message.call("run #(touch /tmp/owned) at 100% -- \e[31m")

      expect(shelled_once.first.last).to eq("run ##(touch /tmp/owned) at 100%% -- \\e[31m")
    end

    it "hands tmux a scrubbed note when the note is not valid UTF-8, and raises nothing" do
      expect(message.call("? \xFF #(x)")).to be_nil

      expect(shelled_once.first.last).to eq("? \uFFFD ##(x)").and be_valid_encoding
    end

    it "does the escaping off the caller's stack, where a failure is swallowed" do
      deferred = []

      expect(message(background: ->(&work) { deferred << work }).call("\xFF #(x)")).to be_nil
      expect(shelled).to be_empty

      deferred.each(&:call)
      expect(shelled_once.first.last).to eq("\uFFFD ##(x)")
    end

    it "clamps a long note to one status-line's worth" do
      message.call("x" * 5_000)

      expect(shelled_once.first.last.length).to be <= Lain::Frontend::TTY::TmuxMessage::LIMIT
    end

    it "swallows a tmux that is missing, failing or too slow" do
      failing = ->(*, **) { raise Mixlib::ShellOut::CommandTimeout, "tmux took too long" }

      expect(message(shell: failing).call("a note")).to be_nil
    end
  end

  # A note that arrives while a prompt is drawn is HELD, and printed, in arrival
  # order, the moment that prompt closes and before the next one draws. It never
  # interrupts the line editor's read, so what the human has typed -- its text,
  # its cursor, its editing mode -- is never touched, and the prompt is never
  # torn. That is the restatement of "a note does not tear a drawn prompt": the
  # typed text is intact, the prompt untorn, and the note appears as the prompt
  # closes. The live surface for an arrival is the input pane.
  #
  # Driven in a child on a private tmux server, because what is asserted is what
  # a terminal SHOWS -- rows, a wrapped line, vi's cursor -- and only a terminal
  # emulator can say that. The child runs the real TTY, InputRail and StdinPump.
  describe "a note rendered while a prompt is drawn", :seam do
    before { skip("tmux not found on PATH") unless system("tmux", "-V", out: File::NULL, err: File::NULL) }

    child = <<~'RUBY'
      require "lain"

      dir = ARGV.fetch(0)
      layers = ENV.fetch("LAYERS", "").split(",").map(&:to_sym)
      # The shipped default.toml, over a run state that has something to say, so
      # the prompt is the two rows a production chat draws.
      shipped = Struct.new(:readings) { def to_h = readings }.new({ model: "opus", occupancy: "12%" })
      renderer = ENV["HUD"] ? { prompt_renderer: Lain::Frontend::PromptComposer.renderer(state: shipped) } : {}
      tty = Lain::Frontend::TTY.new(channel: Lain::Channel.new, history_path: File.join(dir, "history"),
                                    state_path: File.join(dir, "state.json"), pastel: Pastel.new(enabled: false),
                                    layers: -> { Lain::Mode::LayerSet.new(layers) }, **renderer)
      rail = Lain::Frontend::InputRail.new(screen: tty)
      Sync do |task|
        pumping = Lain::Frontend::StdinPump.new(rail:, screen: tty).start(task)
        task.async do
          task.sleep(0.02) until File.exist?(File.join(dir, "notes"))
          count, gap = File.read(File.join(dir, "notes")).split.map { |word| Float(word) }
          Integer(count).times do |index|
            tty.render_arrival("note #{index} of the fleet", from: "researcher")
            task.sleep(gap)
          end
          File.write(File.join(dir, "noted"), "")
        end
        if ENV["WITHDRAW"]
          question = task.async { rail.read(:human, "human> ") }
          task.sleep(0.02) until File.exist?(File.join(dir, "arm"))
          tty.render_warning("HELD-NOTE")
          task.sleep(0.2)
          question.stop
        end
        2.times { File.write(File.join(dir, "lines"), "#{rail.read(:you, "you> ").inspect}\n", mode: "a") }
        pumping.stop
      end
    RUBY

    around do |example|
      Dir.mktmpdir do |dir|
        @dir = dir
        @socket = "lain-spec-note-#{Process.pid}-#{rand(1 << 30)}"
        File.write(File.join(dir, "child.rb"), child)
        example.run
      ensure
        tmux("kill-server")
      end
    end

    def tmux(*args) = Open3.capture2("tmux", "-L", @socket, *args).first

    def start(columns: 100, env: {}, ready: /you>/)
      command = [*env.map { |name, value| "#{name}=#{value}" }, "TERM=xterm-256color", "INPUTRC=/nonexistent",
                 RbConfig.ruby, "-W0", "-I", File.expand_path("../../../lib", __dir__),
                 File.join(@dir, "child.rb"), @dir].shelljoin
      tmux("-f", File::NULL, "new-session", "-d", "-x", columns.to_s, "-y", "40", "-s", "note", "env #{command}")
      tmux("set", "-g", "remain-on-exit", "on")
      shows(ready)
    end

    def type(text) = tmux("send-keys", "-t", "note", "-l", text)

    def press(*keys) = tmux("send-keys", "-t", "note", *keys)

    def screen = tmux("capture-pane", "-t", "note", "-p")

    # capture-pane drops a row's trailing blanks, so a bare prompt reads "you>".
    def rows(pattern) = screen.lines.grep(pattern)

    def shows(pattern, timeout: 20)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      sleep(0.05) until screen.match?(pattern) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      raise "#{pattern.inspect} never showed; the screen was:\n#{screen}" unless screen.match?(pattern)
    end

    def notes(count, gap: 0.0)
      File.write(File.join(@dir, "notes"), "#{count} #{gap}")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
      noted = File.join(@dir, "noted")
      sleep(0.02) until File.exist?(noted) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep(0.3)
    end

    def submitted
      path = File.join(@dir, "lines")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
      sleep(0.02) until File.exist?(path) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      File.readlines(path, chomp: true).first
    end

    it "holds the note while the prompt is drawn, keeps the typed words, and prints the note as the prompt closes" do
      start
      type("half a sent")
      shows(/half a sent/)
      notes(1)

      expect(rows(/note 0/)).to be_empty
      expect(rows(/you> /)).to eq(["you> half a sent\n"])

      type("ence")
      press("Enter")

      expect(submitted).to eq('"half a sentence"')
      shows(/note 0 of the fleet/)
      after_submit = screen.split("you> half a sentence", 2).last
      expect(after_submit.index("note 0 of the fleet")).to be < after_submit.index("you>")
    end

    # Answered on another surface, a `human>` has no closing words to end its
    # row, so the notes held behind it start a row of their own.
    it "prints a note held behind a prompt withdrawn without closing words on a row of its own" do
      start(env: { "WITHDRAW" => "1" }, ready: /human>/)
      type("half")
      shows(/human> half/)
      FileUtils.touch(File.join(@dir, "arm"))
      shows(/HELD-NOTE/)

      expect(rows(/HELD-NOTE/)).to eq(["HELD-NOTE\n"])
      expect(rows(/human> half/)).to eq(["human> half\n"])
    end

    it "tears nothing of the shipped two-row prompt" do
      start(env: { "HUD" => "1" })
      type("half a sent")
      shows(/half a sent/)
      notes(1)

      expect(rows(/opus/).size).to eq(1)
      expect(rows(/you> /)).to eq(["you> half a sent\n"])
    end

    it "leaves a typed line wider than the terminal one line, and submits it whole" do
      wide = "#{"x" * 130}TAIL"
      start(columns: 60)
      type(wide)
      shows(/TAIL/)
      notes(1)

      expect(rows(/^you>/).size).to eq(1)
      press("Enter")
      expect(submitted).to eq(wide.inspect)
    end

    it "keeps vi's mode and cursor, so a command typed after the note does what it says" do
      start(env: { "LAYERS" => "vi" })
      type("hello world")
      shows(/hello world/)
      press("Escape")
      sleep(0.3)
      type("0")
      sleep(0.3)
      notes(1)
      type("iX")
      sleep(0.2)
      press("Enter")

      expect(submitted).to eq('"Xhello world"')
    end

    it "loses and repeats nothing typed while notes keep arriving, and prints them all as the prompt closes" do
      typed = "abcdefghijklmnopqrstuvwxyz0123456789"
      start
      typist = Thread.new do
        typed.each_char do |char|
          type(char)
          sleep(0.013)
        end
      end
      notes(15, gap: 0.02)
      typist.join
      sleep(0.5)

      expect(rows(/note \d+ of the fleet/)).to be_empty
      press("Enter")
      expect(submitted).to eq(typed.inspect)
      shows(/note 14 of the fleet/)
      expect(rows(/note \d+ of the fleet/).map { |row| row[/note (\d+)/, 1].to_i }).to eq((0..14).to_a)
      expect(rows(/of the fleet/)).to all(start_with("? researcher note"))
    end
  end
end
