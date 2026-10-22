# frozen_string_literal: true

require "pty"
require "reline"
require "tmpdir"

RSpec.describe Lain::Frontend::LineEditor do
  # C-g. Spelled as the byte on purpose: this is the number Reline's input loop
  # hands to a bound method (Reline::LineEditor#input_key calls
  # process_key(key.char, ...)), so a spec driving the seam directly has to
  # speak it. #bind's callers never see it.
  def ctrl_g = 7

  # Everything Reline holds is process-global -- `Reline.core` is a singleton,
  # its config owns the keymaps, and the method a key dispatches to is a method
  # on the Reline::LineEditor CLASS. So every example restores all of it.
  # reset_variables rebuilds @default_key_bindings from the KeyActor MAPPING
  # constants, which also discards whatever lain bound; the registry is cleared
  # to match, so the two can never drift apart.
  around do |example|
    original_inputrc = ENV.fetch("INPUTRC", nil)
    # A path that cannot exist. Reline reads the user's inputrc itself on the
    # first prompt, so without this the suite would measure lain's
    # configuration against whatever inputrc the developer running it happens
    # to own, and pass or fail by accident.
    ENV["INPUTRC"] = File.join(Dir.tmpdir, "lain-spec-no-such-inputrc")
    reset_reline
    example.run
  ensure
    ENV["INPUTRC"] = original_inputrc
    reset_reline
  end

  def reset_reline
    Reline.core.config.reset_variables
    described_class.unbind_all
  end

  def config = Reline.core.config

  # A real Reline::LineEditor with `text` typed into it. The key-action seam is
  # a method ON that class (Reline binds keys to method names, never to Procs),
  # so the only honest way to exercise it is to build one and hand it the byte
  # the way Reline's own input loop does.
  def editor_typing(text)
    editor = Reline::LineEditor.new(config)
    editor.reset("> ")
    editor.insert_multiline_text(text)
    editor
  end

  # A REAL keypress. Built the way Reline's own reader builds one
  # (key_stroke.rb:55 -- `matched_bytes.pack('c*').force_encoding(@encoding)`,
  # so `char` is a STRING, never the Integer the keymaps are indexed by),
  # routed through the LIVE keymap, and delivered through the same #input_key
  # the input loop calls.
  #
  # Every part of that matters, and fabricating any of it is how a fully green
  # suite once proved nothing at all: the registry was keyed by Integer 7 while
  # the real path delivers "\a", every example called `editor.send(ACTION, 7)`
  # directly, and the seam never fired once in a real terminal.
  #
  # The `|| :ed_insert` fallback is not a convenience -- it is what Reline's own
  # expand does for an unbound single byte, so an unregistered key behaves here
  # exactly as it would under a human's fingers.
  def press(editor, key = ctrl_g)
    bytes = Array(key)
    char = bytes.pack("c*").force_encoding(Encoding::UTF_8)
    editor.input_key(Reline::Key.new(char, config.key_bindings.get(bytes) || :ed_insert, false))
  end

  # The operator's real configuration: an inputrc that selects vi editing mode,
  # which makes :vi_insert active without lain's vi_mode: flag being touched.
  def with_vi_inputrc
    Dir.mktmpdir do |dir|
      path = File.join(dir, "inputrc")
      File.write(path, "set editing-mode vi\n")
      ENV["INPUTRC"] = path
      config.reset_variables
      yield
    end
  end

  # A multiline editor wired to the real submit predicate, for the examples
  # that ask which editing modes actually consult it.
  def multiline_editor
    editor = Reline::LineEditor.new(config)
    editor.reset("> ")
    editor.multiline_on
    editor.confirm_multiline_termination_proc = described_class.new.method(:submit?)
    editor
  end

  # A key action can only fire WHILE a read is in flight, which is exactly the
  # window the notifier is installed for. So an example that wants a handler's
  # failure reported has to press during a read, not beside one -- pressing
  # from inside the stubbed readmultiline is the honest simulation.
  def during_read(editor, notify:)
    allow(Reline).to receive(:readmultiline) do
      press(editor)
      "submitted"
    end
    described_class.new(notify:).read("> ")
  end

  describe "#read, and the submit predicate" do
    it "returns one message carrying both lines when a backslash continued the first" do
      allow(Reline).to receive(:readmultiline).and_return("first \\\nsecond")

      expect(described_class.new.read("> ")).to eq("first \nsecond")
    end

    it "submits a line that does not end in a backslash, unchanged" do
      allow(Reline).to receive(:readmultiline).and_return("hello")

      expect(described_class.new.read("> ")).to eq("hello")
    end

    it "returns nil at EOF so Ctrl-D still ends the session" do
      allow(Reline).to receive(:readmultiline).and_return(nil)

      expect(described_class.new.read("> ")).to be_nil
    end

    # The rule, not a concatenation: readmultiline's block IS the predicate, so
    # assert the block Reline was handed answers the rule on both branches.
    it "gives readmultiline a predicate that continues on a trailing backslash and submits otherwise" do
      predicate = nil
      allow(Reline).to receive(:readmultiline) do |*_args, &block|
        predicate = block
        "hello"
      end

      described_class.new.read("> ")

      expect(predicate.call("hello\n")).to be(true)
      expect(predicate.call("first \\\n")).to be(false)
      expect(predicate.call("first \\\nsecond\n")).to be(true)
    end

    it "reads through readmultiline with history on" do
      allow(Reline).to receive(:readmultiline).and_return("hi")

      described_class.new.read("> ")

      expect(Reline).to have_received(:readmultiline).with("> ", true)
    end

    it "removes the continuation marker but keeps the newline it continued over" do
      allow(Reline).to receive(:readmultiline).and_return("one\\\ntwo\\\nthree")

      expect(described_class.new.read("> ")).to eq("one\ntwo\nthree")
    end

    describe "the prompt on the rows of a pasted block" do
      def prompts_drawn_for(prompt, rows, answer:)
        drawn = nil
        allow(Reline).to receive(:readmultiline) do
          drawn = Reline.prompt_proc&.call(Array.new(rows, "x"))
          "pasted"
        end
        described_class.new.read(prompt, answer:)
        drawn
      end

      it "draws an approval prompt once and leaves the pasted rows bare" do
        expect(prompts_drawn_for("approve? [y/N] ", 2, answer: true)).to eq(["approve? [y/N] ", ""])
      end

      it "draws a human> prompt on row 1 only" do
        expect(prompts_drawn_for("human> ", 3, answer: true)).to eq(["human> ", "", ""])
      end

      it "keeps the prompt on every row when the read answers nothing" do
        expect(prompts_drawn_for("you> ", 2, answer: false)).to be_nil
      end

      it "puts Reline's own prompt proc back after the read" do
        original = ->(_lines) { [] }
        Reline.prompt_proc = original
        prompts_drawn_for("approve? [y/N] ", 2, answer: true)

        expect(Reline.prompt_proc).to be(original)
      ensure
        Reline.prompt_proc = nil
      end
    end

    describe "asking the terminal for Shift+Enter" do
      let(:request) { "\e[>4;1m" }
      let(:reset) { "\e[>4;0m" }

      def written_during
        master, slave = PTY.open
        allow(Reline.core).to receive(:output).and_return(slave)
        yield
        slave.close
        pty_drained(master)
      ensure
        master&.close
      end

      it "writes the request before the read and the reset after it, on a terminal" do
        allow(Reline).to receive(:readmultiline).and_return("hi")
        bytes = written_during { described_class.new.read("> ") }

        expect(bytes).to eq("#{request}#{reset}")
      end

      it "has written the request by the time readmultiline runs" do
        master, slave = PTY.open
        allow(Reline.core).to receive(:output).and_return(slave)
        during = nil
        allow(Reline).to receive(:readmultiline) do
          during = pty_read(master, request.bytesize)
          "hi"
        end

        described_class.new.read("> ")

        expect(during).to eq(request)
      ensure
        slave&.close
        master&.close
      end

      it "resets after an exception" do
        allow(Reline).to receive(:readmultiline).and_raise(Interrupt)
        bytes = written_during { expect { described_class.new.read("> ") }.to raise_error(Interrupt) }

        expect(bytes).to end_with(reset)
      end

      it "resets at EOF" do
        allow(Reline).to receive(:readmultiline).and_return(nil)
        bytes = written_during { described_class.new.read("> ") }

        expect(bytes).to end_with(reset)
      end

      it "lets the read's own exception through when the reset cannot be written" do
        dead = instance_double(IO, tty?: true)
        calls = 0
        allow(dead).to receive(:write) { (calls += 1) == 1 ? 1 : raise(Errno::EIO) }
        allow(Reline.core).to receive(:output).and_return(dead)
        allow(Reline).to receive(:readmultiline).and_raise(Interrupt)

        expect { described_class.new.read("> ") }.to raise_error(Interrupt)
      end

      it "writes nothing to an output that is not a terminal" do
        output = StringIO.new
        allow(Reline.core).to receive(:output).and_return(output)
        allow(Reline).to receive(:readmultiline).and_return("hi")

        described_class.new.read("> ")

        expect(output.string).to eq("")
      end
    end

    # Specified rather than accidental: the rule is "a line ENDING in a
    # backslash", so a backslash followed by a space is not one, and submits
    # with the backslash left in as ordinary text. Deliberate -- tolerating
    # trailing whitespace would weaken the rule from something a human can
    # state in one sentence to "the last non-space character", to rescue a
    # typo that is visible on screen as it is made.
    it "submits a line whose backslash is followed by a space, marker intact" do
      editor = described_class.new

      expect(editor.submit?("first \\ \n")).to be(true)
      expect(editor.join_continuations("first \\ ")).to eq("first \\ ")
    end

    # The two halves of the rule agree on line endings. Reline normalises
    # CRLF out of the buffer itself, so this pins that they stay symmetric
    # rather than one silently tolerating what the other does not.
    it "treats the continuation marker identically in both halves of the rule" do
      editor = described_class.new

      expect(editor.submit?("first \\\n")).to be(false)
      expect(editor.join_continuations("first \\\nsecond")).to eq("first \nsecond")
    end
  end

  # Bytes fed through Reline's own key matcher and the live keymap, as its input
  # loop does, so a sequence nobody bound is swallowed exactly as in a terminal.
  def typing(editor, bytes)
    stroke = Reline::KeyStroke.new(config, Encoding::UTF_8)
    pending = bytes.bytes
    until pending.empty?
      keys, pending = stroke.expand(pending)
      keys.each { |key| editor.input_key(key) }
    end
  end

  describe "a newline that does not submit" do
    before { described_class.load_inputrc }

    typing_modes = %i[emacs vi_insert]
    {
      "CSI-u Shift+Enter" => "\e[13;2u",
      "modifyOtherKeys Shift+Enter" => "\e[27;2;13~",
      "Alt+Enter" => "\e\r"
    }.each do |name, sequence|
      typing_modes.each do |mode|
        it "inserts a newline on #{name} in #{mode} mode" do
          config.editing_mode = mode
          editor = multiline_editor

          typing(editor, "ab#{sequence}cd")

          expect(editor.whole_buffer).to eq("ab\ncd")
        end
      end
    end

    it "inserts a newline on Alt+Enter in vi command mode and submits nothing" do
      config.editing_mode = :vi_insert
      editor = multiline_editor
      typing(editor, "ab")
      config.editing_mode = :vi_command

      typing(editor, "\e\r")
      config.editing_mode = :vi_insert
      typing(editor, "cd")

      expect(editor.whole_buffer).to eq("ab\ncd")
      expect(editor.finished?).to be(false)
    end

    ["\e[13;2u", "\e[27;2;13~", "\e\r"].product(%i[emacs vi_insert vi_command]).each do |sequence, mode|
      it "expands #{sequence.inspect} to key_newline in #{mode} mode" do
        config.editing_mode = mode
        stroke = Reline::KeyStroke.new(config, Encoding::UTF_8)

        keys, = stroke.expand(sequence.bytes)

        expect(keys.map(&:method_symbol)).to eq([:key_newline])
      end
    end

    it "joins the lines again when Backspace arrives on the empty one" do
      editor = multiline_editor
      typing(editor, "ab\e[13;2u")

      typing(editor, "\x7f")

      expect(editor.whole_buffer).to eq("ab")
    end
  end

  describe "vi mode" do
    it "leaves the editing mode alone when vi mode was not asked for" do
      allow(Reline).to receive(:readmultiline).and_return("hi")

      described_class.new.read("> ")

      expect(config.editing_mode_is?(:emacs)).to be(true)
      expect(config.show_mode_in_prompt).to be(false)
    end

    it "puts the editor in vi insert mode when vi mode is enabled" do
      allow(Reline).to receive(:readmultiline).and_return("hi")

      described_class.new(vi_mode: -> { true }).read("> ")

      expect(config.editing_mode_is?(:vi_insert)).to be(true)
    end

    it "shows which mode is active, with a string for each" do
      allow(Reline).to receive(:readmultiline).and_return("hi")

      described_class.new(vi_mode: -> { true }).read("> ")

      expect(config.show_mode_in_prompt).to be(true)
      expect(config.vi_ins_mode_string).not_to be_empty
      expect(config.vi_cmd_mode_string).not_to be_empty
    end

    it "never writes the user's inputrc" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "inputrc")
        File.write(path, "set editing-mode emacs\n")
        ENV["INPUTRC"] = path
        before = File.read(path)
        allow(Reline).to receive(:readmultiline).and_return("hi")

        described_class.new(vi_mode: -> { true }).read("> ")

        expect(File.read(path)).to eq(before)
      end
    end

    # Reline reads inputrc lazily, on the first prompt, INSIDE readmultiline --
    # so an inputrc naming an editing mode would otherwise overwrite the mode
    # lain was asked for, and only for the first prompt of the session, which
    # is worse than either answer applied consistently.
    it "wins over an inputrc that names a different editing mode" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "inputrc")
        File.write(path, "set editing-mode emacs\n")
        ENV["INPUTRC"] = path
        allow(Reline).to receive(:readmultiline).and_return("hi")

        described_class.new(vi_mode: -> { true }).read("> ")

        expect(config.editing_mode_is?(:vi_insert)).to be(true)
      end
    end

    # vi_mode is a KNOWN-DEGRADED mode, and the damage is worse than a
    # footnote. vi INSERT mode -- where the human actually types -- binds every
    # one of C-a..C-z to ed_insert, so a key action cannot fire AND the keypress
    # inserts a literal control character into the message. vi COMMAND mode
    # submits on Enter without consulting the continuation rule. Two of this
    # card's three features are off.
    #
    # The flag ships (two ACs require the mode to exist and to indicate itself)
    # but it may not ship SILENTLY: loud failure is the house rule, and a
    # warning at opt-in is what "loud" means for a mode the user chose.
    it "fires a key action in vi insert mode, where the human types" do
      described_class.bind("C-g") { |_buffer| "replaced" }
      config.editing_mode = :vi_insert
      editor = editor_typing("hello")

      press(editor)

      expect(config.key_bindings.get([ctrl_g])).to eq(described_class::ACTION)
      expect(editor.whole_buffer).to eq("replaced")
    end

    it "fires a key action in vi command mode too" do
      described_class.bind("C-g") { |_buffer| "replaced" }
      config.editing_mode = :vi_command
      editor = editor_typing("hello")

      press(editor)

      expect(editor.whole_buffer).to eq("replaced")
    end

    # The other half of "a vi user gets both features": ed_newline only
    # special-cases :vi_command, so the continuation rule is consulted normally
    # in vi INSERT mode.
    it "consults the backslash rule in vi insert mode" do
      config.editing_mode = :vi_insert
      editor = multiline_editor
      editor.insert_text("first \\")

      editor.send(:ed_newline, 13)

      expect(editor.finished?).to be(false)
    end

    # Nothing is said at startup, in any mode. The vi command mode caveat is a
    # design difference, not a fault, and a banner about it at every session
    # start is how a codebase teaches its user to skim past warnings that DO
    # matter. It is taught contextually instead -- see below.
    it "says nothing at startup, even in vi mode" do
      reported = []
      allow(Reline).to receive(:readmultiline).and_return("hi")

      described_class.new(vi_mode: -> { true }, notify: reported.method(:push)).read("> ")

      expect(reported).to be_empty
    end

    it "says nothing at startup for a user whose inputrc selects vi mode" do
      with_vi_inputrc do
        reported = []
        allow(Reline).to receive(:readmultiline).and_return("hi")

        described_class.new(notify: reported.method(:push)).read("> ")

        expect(reported).to be_empty
      end
    end
  end

  # The `vi` mode layer is raised and lowered mid-session, so the editor asks
  # at every read rather than once at construction -- and what a lowered layer
  # hands back is whatever was in force before lain first asked, never a mode
  # of lain's choosing.
  describe "vi mode asked for at every read, as the vi layer is raised and lowered" do
    let(:layer) { [false] }
    let(:editor) { described_class.new(vi_mode: -> { layer.first }) }

    before { allow(Reline).to receive(:readmultiline).and_return("hi") }

    def read_with_layer(raised)
      layer[0] = raised
      editor.read("> ")
    end

    def spy_on_mode_writes
      allow(config).to receive(:editing_mode=).and_call_original
      allow(config).to receive(:show_mode_in_prompt=).and_call_original
    end

    it "switches a session that started in emacs to vi at the read after the layer is raised" do
      read_with_layer(false)
      read_with_layer(true)

      expect(config.editing_mode_is?(:vi_insert)).to be(true)
    end

    it "is back in emacs, with no mode shown, at the read after the layer is lowered" do
      read_with_layer(true)
      read_with_layer(false)

      expect(config.editing_mode_is?(:emacs)).to be(true)
      expect(config.show_mode_in_prompt).to be(false)
      expect([config.vi_cmd_mode_string, config.vi_ins_mode_string]).to eq(["(cmd)", "(ins)"])
    end

    it "hands back the mode in force before the first raise, however many reads the layer stayed up" do
      read_with_layer(true)
      read_with_layer(true)
      read_with_layer(false)

      expect(config.editing_mode_is?(:emacs)).to be(true)
    end

    it "never sets the editing mode or its indicator in a session that never raises the layer" do
      spy_on_mode_writes

      3.times { read_with_layer(false) }

      expect(config).not_to have_received(:editing_mode=)
      expect(config).not_to have_received(:show_mode_in_prompt=)
    end

    it "writes nothing further once a lowered layer has been handed back" do
      read_with_layer(true)
      read_with_layer(false)
      spy_on_mode_writes

      read_with_layer(false)

      expect(config).not_to have_received(:editing_mode=)
      expect(config).not_to have_received(:show_mode_in_prompt=)
    end

    # The operator's inputrc is the mode the session started in, so lowering
    # the layer gives THAT back rather than emacs.
    it "gives an inputrc that selected vi its own settings back when the layer is lowered" do
      with_vi_inputrc do
        read_with_layer(true)
        read_with_layer(false)

        expect(config.editing_mode_is?(:vi_insert)).to be(true)
        expect(config.show_mode_in_prompt).to be(false)
      end
    end
  end

  # Taught at the moment it is useful: the first time a submitted buffer still
  # ends in a continuation marker. That can only happen when the predicate was
  # never consulted -- Reline's ed_newline calls finish directly in vi command
  # mode -- so the signal is exact and cannot false-positive. In emacs and vi
  # insert mode the predicate would have continued the line instead.
  describe "teaching the vi command mode caveat, contextually" do
    it "warns when a submitted buffer still ends in a continuation marker" do
      reported = []
      allow(Reline).to receive(:readmultiline).and_return("first \\")

      described_class.new(notify: reported.method(:push)).read("> ")

      expect(reported.join).to match(/vi command mode/i)
      expect(reported.join).to match(/continuation|backslash/i)
    end

    it "says nothing when the rule was applied normally" do
      reported = []
      allow(Reline).to receive(:readmultiline).and_return("first \\\nsecond")

      described_class.new(notify: reported.method(:push)).read("> ")

      expect(reported).to be_empty
    end

    it "warns once, not on every such submission" do
      reported = []
      allow(Reline).to receive(:readmultiline).and_return("first \\")

      editor = described_class.new(notify: reported.method(:push))
      3.times { editor.read("> ") }

      expect(reported.size).to eq(1)
    end

    it "still returns the message, marker and all, rather than eating a character" do
      allow(Reline).to receive(:readmultiline).and_return("first \\")

      expect(described_class.new.read("> ")).to eq("first \\")
    end

    it "says nothing at EOF" do
      reported = []
      allow(Reline).to receive(:readmultiline).and_return(nil)

      described_class.new(notify: reported.method(:push)).read("> ")

      expect(reported).to be_empty
    end
  end

  describe "key actions" do
    it "invokes the handler with everything typed so far" do
      seen = []
      described_class.bind("C-g") do |buffer|
        seen << buffer
        nil
      end

      press(editor_typing("hello"))

      expect(seen).to eq(["hello"])
    end

    it "hands the handler every line of a multiline buffer, joined" do
      seen = []
      described_class.bind("C-g") do |buffer|
        seen << buffer
        nil
      end

      press(editor_typing("first\nsecond"))

      expect(seen).to eq(["first\nsecond"])
    end

    it "replaces the buffer with what the handler returned, without submitting" do
      described_class.bind("C-g") { |_buffer| "replaced" }
      editor = editor_typing("hello")

      press(editor)

      expect(editor.whole_buffer).to eq("replaced")
      expect(editor.finished?).to be(false)
    end

    it "accepts a multiline replacement" do
      described_class.bind("C-g") { |_buffer| "alpha\nbeta" }
      editor = editor_typing("hello")

      press(editor)

      expect(editor.whole_buffer).to eq("alpha\nbeta")
    end

    it "leaves the buffer untouched when the handler returns nil" do
      described_class.bind("C-g") { |_buffer| nil }
      editor = editor_typing("hello")

      press(editor)

      expect(editor.whole_buffer).to eq("hello")
      expect(editor.finished?).to be(false)
    end

    # A real state, not a contrived one: {.unbind_all} clears lain's handlers
    # but leaves Reline's keymap pointing at ACTION, so the action still fires
    # with nothing behind it. Dispatch has to absorb that.
    it "is a no-op when the keymap still routes to lain but nothing is registered" do
      described_class.bind("C-g") { |_buffer| "replaced" }
      described_class.unbind_all
      editor = editor_typing("hello")

      expect { press(editor) }.not_to raise_error
      expect(editor.whole_buffer).to eq("hello")
    end

    it "names a key the way a human writes it, case-insensitively" do
      described_class.bind("c-G") { |_buffer| "replaced" }
      editor = editor_typing("hello")

      press(editor)

      expect(editor.whole_buffer).to eq("replaced")
    end

    it "refuses a key name it cannot translate to a keystroke" do
      expect { described_class.bind("meta-x") { |_buffer| nil } }
        .to raise_error(ArgumentError, /meta-x/)
    end

    it "refuses a bind with no handler" do
      expect { described_class.bind("C-g") }.to raise_error(ArgumentError)
    end
  end

  describe "Registry.name?" do
    it "is true for the names bind can translate and false for the rest" do
      names = ["C-g", "c-G", "S-Tab", "s-tab", "Hyper-Q", "C-", 7, nil]

      expect(names.map { |name| described_class::Registry.name?(name) })
        .to eq([true, true, true, true, false, false, false, false])
    end
  end

  describe "Shift+Tab, a key bound by its whole escape sequence" do
    def shift_tab = [27, 91, 90]

    it "fires its handler on ESC [ Z and leaves the draft as typed" do
      seen = []
      described_class.bind("S-Tab") do |buffer|
        seen << buffer
        nil
      end
      editor = editor_typing("draft")

      press(editor, shift_tab)

      expect([seen, editor.whole_buffer, editor.finished?]).to eq([["draft"], "draft", false])
    end

    it "binds over the gate's own Shift+Tab, a completion move lain never turns on" do
      described_class.load_inputrc

      expect { described_class.bind("S-Tab") { |_buffer| nil } }.not_to raise_error
      expect(config.key_bindings.get(shift_tab)).to eq(described_class::ACTION)
    end

    it "leaves the gate's other escape sequences where they were, the up arrow among them" do
      described_class.load_inputrc
      up = config.key_bindings.get([27, 91, 65])
      reset_reline

      described_class.bind("S-Tab") { |_buffer| nil }

      expect([up, config.key_bindings.get([27, 91, 65])]).to eq(%i[ed_prev_history ed_prev_history])
    end

    it "is bound by its name, whatever the case, and apart from the control keys" do
      described_class.bind("S-Tab") { |_buffer| nil }

      expect([described_class.bound?("s-tab"), described_class.bound?("C-g")]).to eq([true, false])
    end

    it "fires in vi insert and vi command mode too" do
      fired = []
      described_class.bind("S-Tab") { |_buffer| fired.push(config.editing_mode_is?(:vi_command)).then { nil } }

      %i[vi_insert vi_command].each do |mode|
        config.editing_mode = mode
        press(editor_typing("draft"), shift_tab)
      end

      expect(fired).to eq([false, true])
    end

    it "leaves a lone ESC taking vi insert mode to command mode" do
      described_class.bind("S-Tab") { |_buffer| nil }
      config.editing_mode = :vi_insert

      press(editor_typing("abc"), [27])

      expect(config.editing_mode_is?(:vi_command)).to be(true)
    end

    it "refuses Shift+Tab when the user's inputrc has bound it" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "inputrc")
        File.write(path, %("\\e[Z": abort\n))
        ENV["INPUTRC"] = path
        config.reset_variables

        expect { described_class.bind("S-Tab") { |_buffer| nil } }
          .to raise_error(described_class::KeyTaken, /inputrc/)
      end
    end
  end

  describe "registering on a taken key" do
    it "raises rather than silently shadowing a key the line editor already binds" do
      expect { described_class.bind("C-a") { |_buffer| nil } }
        .to raise_error(described_class::KeyTaken, /C-a/)
    end

    it "raises rather than letting a second registration shadow the first" do
      described_class.bind("C-g") { |_buffer| "first" }

      expect { described_class.bind("C-g") { |_buffer| "second" } }
        .to raise_error(described_class::KeyTaken, /C-g/)
    end

    it "leaves the first handler in place after a refused second registration" do
      described_class.bind("C-g") { |_buffer| "first" }
      expect { described_class.bind("C-g") { |_buffer| "second" } }
        .to raise_error(described_class::KeyTaken)
      editor = editor_typing("hello")

      press(editor)

      expect(editor.whole_buffer).to eq("first")
    end

    it "reports which keys are bound" do
      described_class.bind("C-g") { |_buffer| nil }

      expect(described_class.bound?("C-g")).to be(true)
      expect(described_class.bound?("C-x")).to be(false)
    end

    # The handler used to land in @handlers before the keymap loop, so a
    # keymap failure left `bound?` answering true for a key that routed nowhere
    # -- a registration that reports success and can never fire.
    it "registers nothing at all when installing the keymap binding fails" do
      allow(config).to receive(:add_default_key_binding_by_keymap).and_raise("keymap exploded")

      expect { described_class.bind("C-g") { |_buffer| nil } }.to raise_error(/keymap exploded/)
      expect(described_class.bound?("C-g")).to be(false)
    end

    # Config#key_bindings is Composite([oneshot, additional[mode],
    # default[mode]]) and inputrc populates `additional`, which OUTRANKS the
    # default table lain writes to. Checking only the frozen MAPPING constants
    # therefore accepts a key the user has already taken, and hands back a
    # binding that can never fire. VERIFIED: with `"\C-g": abort` in an inputrc,
    # key_bindings.get([7]) is :abort while EMACS_MAPPING[7] is still nil.
    it "refuses a key the user's inputrc has already claimed" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "inputrc")
        File.write(path, %("\\C-g": abort\n))
        ENV["INPUTRC"] = path
        config.reset_variables

        expect { described_class.bind("C-g") { |_buffer| nil } }
          .to raise_error(described_class::KeyTaken, /inputrc/)
      end
    end

    # Found by running the review panel's probe against a REAL machine whose
    # inputrc selects vi mode. The live table is then vi_insert's catch-all,
    # where every one of C-a..C-z reads as :ed_insert -- so a naive "is the
    # live binding non-nil" check refuses every key there is, and the features
    # that need one get no seam at all. Self-insert is the absence of a
    # binding, not a claim.
    it "still binds when the user's inputrc selects vi mode" do
      with_vi_inputrc do
        expect { described_class.bind("C-g") { |_buffer| nil } }.not_to raise_error
        expect(described_class.bound?("C-g")).to be(true)
      end
    end

    # THE BLOCKER. `set editing-mode vi` in the human's inputrc makes
    # :vi_insert the active keymap at the DEFAULT flag setting -- lain's
    # vi_mode: is never touched. Binding only emacs and vi_command left the key
    # routed to :ed_insert, so it echoed a literal control character into the
    # message and the action never ran. Measured on a real machine, not reasoned
    # about: buffer came back "hello" for C-x.
    it "fires a key action when the user's inputrc selects vi mode, at the default flag" do
      with_vi_inputrc do
        described_class.bind("C-g") { |_buffer| "replaced" }
        editor = editor_typing("hello")

        press(editor)

        expect(editor.whole_buffer).to eq("replaced")
      end
    end

    # Constraint from the review: a refusal has to say which keymap and why,
    # not just "taken". (emacs claims a superset of what vi_insert claims, so
    # emacs is always the keymap named today -- vi_insert's own claim check is
    # defense in depth against a reline that changes that.)
    it "names the keymap and the function that already hold a refused key" do
      expect { described_class.bind("C-a") { |_buffer| nil } }
        .to raise_error(described_class::KeyTaken, /emacs keymap.*ed_move_to_beg/)
    end

    it "refuses a key vi insert mode genuinely binds" do
      # C-v is ed_quoted_insert -- a real function, not self-insert.
      expect(described_class::Registry::KEYMAPS[:vi_insert][22]).to eq(:ed_quoted_insert)
      expect { described_class.bind("C-v") { |_buffer| nil } }
        .to raise_error(described_class::KeyTaken)
    end

    # The general guard against the failure mode that produced this blocker and
    # its sibling: a bind that succeeds and yields a key which does nothing.
    # After registering, the ACTIVE keymap must actually route to lain.
    it "refuses, rather than returning a binding the active keymap will not route" do
      allow(described_class.registry).to receive(:active_binding).and_return(nil, :ed_ignore)

      expect { described_class.bind("C-g") { |_buffer| nil } }
        .to raise_error(described_class::KeyTaken, /route/)
      expect(described_class.bound?("C-g")).to be(false)
    end

    # The asymmetry in NOT_A_CLAIM, made explicit: vi_insert's :ed_insert
    # catch-all is the absence of a binding, but an inputrc that NAMES a key as
    # self-insert has spoken about that key, and reline reports it as
    # :self_insert -- a different symbol, deliberately not in the list.
    it "refuses a key the user's inputrc explicitly names as self-insert" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "inputrc")
        File.write(path, %("\\C-g": self-insert\n))
        ENV["INPUTRC"] = path
        config.reset_variables
        config.read # reline reads inputrc lazily; bind forces it too

        expect(config.key_bindings.get([ctrl_g])).to eq(:self_insert)
        expect { described_class.bind("C-g") { |_buffer| nil } }
          .to raise_error(described_class::KeyTaken, /inputrc/)
      end
    end

    it "still accepts a key the user's inputrc leaves alone" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "inputrc")
        File.write(path, %("\\C-g": abort\n))
        ENV["INPUTRC"] = path
        config.reset_variables

        expect { described_class.bind("C-x") { |_buffer| nil } }.not_to raise_error
      end
    end
  end

  describe "a handler that raises" do
    it "keeps the prompt alive, leaves the buffer alone, and reports the failure" do
      reported = []
      described_class.bind("C-g") { |_buffer| raise "boom" }
      editor = editor_typing("hello")

      expect { during_read(editor, notify: reported.method(:push)) }.not_to raise_error
      expect(editor.whole_buffer).to eq("hello")
      expect(reported.join).to include("boom")
    end

    # The PromptBreaker path: CLI::PromptBreaker::Break is an Interrupt, raised
    # into the prompt thread from a watcher thread. Swallowing it would wedge a
    # way out of the prompt, so anything that is not a StandardError goes
    # straight through.
    it "lets an Interrupt through untouched" do
      described_class.bind("C-g") { |_buffer| raise Interrupt }

      expect { press(editor_typing("hello")) }.to raise_error(Interrupt)
    end

    it "reports nowhere, rather than crashing, when no notifier was configured" do
      described_class.bind("C-g") { |_buffer| raise "boom" }

      expect { press(editor_typing("hello")) }.not_to raise_error
    end

    it "refuses a replacement that is not text, and does not take the prompt down with it" do
      reported = []
      described_class.bind("C-g") { |_buffer| 42 }
      editor = editor_typing("hello")

      during_read(editor, notify: reported.method(:push))

      expect(editor.whole_buffer).to eq("hello")
      expect(reported.join).to include("Integer")
    end

    # The report itself runs inside dispatch's rescue. A notifier that
    # raises would otherwise escape straight into Reline's input loop -- which
    # is precisely the outcome the rescue exists to prevent.
    it "survives a notifier that itself raises" do
      described_class.bind("C-g") { |_buffer| raise "boom" }
      editor = editor_typing("hello")

      expect { during_read(editor, notify: ->(_m) { raise "the notifier exploded" }) }
        .not_to raise_error
      expect(editor.whole_buffer).to eq("hello")
    end
  end

  # Constructing a LineEditor used to install its notifier on the
  # process-global registry, so a second construction silently disarmed the
  # first one's. The notifier is now scoped to a read, which is the only window
  # in which a key action can fire at all.
  describe "the notifier's lifetime" do
    it "installs nothing at construction" do
      described_class.new(notify: ->(_m) { raise "must never be installed" })
      described_class.bind("C-g") { |_buffer| raise "boom" }

      expect { press(editor_typing("hello")) }.not_to raise_error
    end

    it "is not disarmed by a second LineEditor built alongside it" do
      reported = []
      described_class.bind("C-g") { |_buffer| raise "boom" }
      editor = editor_typing("hello")
      described_class.new

      during_read(editor, notify: reported.method(:push))

      expect(reported.join).to include("boom")
    end

    it "is taken down again once the read returns" do
      reported = []
      described_class.bind("C-g") { |_buffer| raise "boom" }
      editor = editor_typing("hello")

      during_read(editor, notify: reported.method(:push))
      press(editor)

      expect(reported.size).to eq(1)
    end
  end

  # The gemspec pins reline for these. A minor bump renaming any of them would
  # otherwise break the prompt at runtime and in silence -- the key-action seam
  # would simply stop firing, and the mode indicator would simply not appear.
  # These fail loudly instead.
  describe "a key action that repaints the rows above the prompt" do
    let(:moves) { [] }
    let(:painted) { [] }

    # A two-line draft with the cursor on its second line, as Reline itself
    # renders it: drawn into a StringIO so no terminal is touched, with the
    # prompt starting `base_y` rows down the screen.
    def drawn_draft(base_y)
      editor = multiline_editor
      editor.insert_multiline_text("one\ntwo")
      editor.instance_variable_get(:@rendered_screen).base_y = base_y
      output = Reline::IOGate.instance_variable_get(:@output)
      Reline::IOGate.instance_variable_set(:@output, StringIO.new)
      editor.send(:render)
      editor
    ensure
      Reline::IOGate.instance_variable_set(:@output, output)
    end

    def repaint_from(editor)
      allow(Reline::IOGate).to receive(:move_cursor_up) { |rows| moves << rows }
      allow(Reline::IOGate).to receive(:move_cursor_column)
      described_class.bind("C-g") { |_buffer| described_class::Repaint.new(rows: 1, paint: -> { painted << :row }) }
      press(editor)
    end

    it "climbs past every row of the draft to the header above the prompt, then paints it" do
      editor = drawn_draft(5)

      repaint_from(editor)

      expect([editor.instance_variable_get(:@rendered_screen).cursor_y, moves, painted, editor.whole_buffer])
        .to eq([0, [2], [:row], "one\ntwo"])
    end

    it "lets a fault in the paint itself through rather than hiding it after the cursor moved" do
      editor = drawn_draft(5)
      allow(Reline::IOGate).to receive(:move_cursor_up) { |rows| moves << rows }
      allow(Reline::IOGate).to receive(:move_cursor_column)
      described_class.bind("C-g") { |_buffer| described_class::Repaint.new(rows: 1, paint: -> { nil.row }) }

      expect { press(editor) }.to raise_error(NoMethodError, /row/)
      expect(moves).to eq([2])
    end

    it "paints nothing when the header has already scrolled off the top of the screen" do
      repaint_from(drawn_draft(0))

      expect([moves, painted]).to eq([[], []])
    end
  end

  describe "the Reline surface lain is pinned to" do
    it "still keeps the rendered-screen state a repaint moves" do
      editor = Reline::LineEditor.new(config)

      expect([Reline::LineEditor::RenderedScreen.members & %i[base_y cursor_y],
              editor.respond_to?(:clear_rendered_screen_cache, true)]).to eq([%i[base_y cursor_y], true])
    end

    it "repaints nothing, and keeps the read, when that state is not what lain expects" do
      painted = []
      described_class.bind("C-g") { |_buffer| described_class::Repaint.new(rows: 1, paint: -> { painted << :row }) }
      editor = editor_typing("draft")
      editor.instance_variable_set(:@rendered_screen, Object.new)

      press(editor)

      expect([painted, editor.whole_buffer]).to eq([[], "draft"])
    end

    it "still leaves C-g free in every keymap lain binds into" do
      expect(Reline::KeyActor::EMACS_MAPPING[ctrl_g]).to be_nil
      expect(Reline::KeyActor::VI_COMMAND_MAPPING[ctrl_g]).to be_nil
      # Self-insert, i.e. free -- see Registry::NOT_A_CLAIM.
      expect(Reline::KeyActor::VI_INSERT_MAPPING[ctrl_g]).to eq(:ed_insert)
    end

    # The contract published to the two consuming features names exactly two
    # keys. This is the spec that fails if a reline bump changes that, rather
    # than two cards discovering it in a terminal.
    it "still offers exactly C-g and C-x, free in all three keymaps" do
      free = (1..26).select do |byte|
        described_class::Registry::KEYMAPS.each_value.all? do |mapping|
          described_class::Registry::NOT_A_CLAIM.include?(mapping[byte])
        end
      end

      expect(free.map { |byte| "C-#{(96 + byte).chr}" }).to eq(%w[C-g C-x])
    end

    it "still answers the buffer verbs the key-action seam drives" do
      %i[whole_buffer delete_text insert_multiline_text finished?].each do |verb|
        expect(Reline::LineEditor.public_method_defined?(verb)).to be(true), "Reline::LineEditor##{verb} is gone"
      end
    end

    # The pin that replaced a tautology. The old one asserted
    # `Reline::LineEditor.private_method_defined?(ACTION)` -- which lain defines
    # itself, unconditionally, so it could never fail and pinned nothing. THIS
    # is the surface that actually broke: a bound method is handed `key.char`,
    # and `key.char` is a String.
    it "still hands a bound method a Reline::Key whose char is a String, not a byte" do
      expect(Reline::Key.members).to eq(%i[char method_symbol unused_boolean])

      keys, = Reline::KeyStroke.new(config, Encoding::UTF_8).expand([ctrl_g])

      expect(keys.first.char).to be_a(String)
      expect(keys.first.char.bytes).to eq([ctrl_g])
    end

    it "still routes a real keypress through the live keymap to lain's action" do
      described_class.bind("C-g") { |_buffer| nil }

      expect(config.key_bindings.get([ctrl_g])).to eq(described_class::ACTION)
    end

    it "still answers the config accessors lain configures through" do
      %i[editing_mode= show_mode_in_prompt= vi_ins_mode_string= vi_cmd_mode_string=
         add_default_key_binding_by_keymap loaded? read].each do |accessor|
        expect(config).to respond_to(accessor)
      end
    end
  end

  # VERIFIED, not assumed: Reline's own ed_newline calls finish() directly when
  # the editing mode is vi_command, under a source comment reading "should check
  # confirm_multiline_termination to finish?". So in vi COMMAND mode Enter
  # submits whatever is in the buffer and the backslash rule does not apply.
  # Reported, not worked around: the workaround is rebinding Enter in the
  # vi_command keymap, a second method on a stdlib class and a much deeper
  # coupling than this seam is allowed to take on.
  describe "the vi command mode limitation" do
    it "consults the backslash rule in emacs mode" do
      config.editing_mode = :emacs
      editor = multiline_editor
      editor.insert_text("first \\")

      editor.send(:ed_newline, 13)

      expect(editor.finished?).to be(false)
    end

    it "does not consult it in vi command mode: Enter submits regardless" do
      config.editing_mode = :vi_command
      editor = multiline_editor
      editor.insert_text("first \\")

      editor.send(:ed_newline, 13)

      expect(editor.finished?).to be(true)
    end
  end

  # What the human typed before a prompt drew, taken through Reline's own gate:
  # Reline keeps bytes it read while asking where the cursor is, and a line
  # typed ahead waits THERE for its next read, not in the kernel.
  describe ".typed_ahead" do
    it "takes every byte the next read would, in the order it would take them, then stops" do
      allow(Reline::IOGate).to receive(:with_raw_input).and_yield
      allow(Reline::IOGate).to receive(:getc).with(0).and_return(*"yes\ry".bytes, nil)

      expect(described_class.typed_ahead(StringIO.new)).to eq("yes\ry")
    end

    # A dumb gate's getc never returns on an empty terminal, and the gate keeps
    # nothing back, so the terminal beneath it is swept -- raw, then restored.
    it "sweeps the terminal beneath a dumb gate, never the gate itself" do
      terminal = Class.new do
        def initialize = @chunks = ["yes\r", "y"]
        def raw(intr:) = intr && yield
        def read_nonblock(_size, exception:) = exception ? raise(ArgumentError) : (@chunks.shift || :wait_readable)
      end.new
      allow(Reline::IOGate).to receive(:dumb?).and_return(true)
      allow(Reline::IOGate).to receive(:getc)

      expect(described_class.typed_ahead(terminal)).to eq("yes\ry")
      expect(Reline::IOGate).not_to have_received(:getc)
    end

    it "runs the hook it is given before the read draws, and puts the previous one back" do
      previous = -> {}
      seen = nil
      Reline.pre_input_hook = previous

      described_class.before_first_draw(-> { :swept }) { seen = Reline.pre_input_hook.call }

      expect([seen, Reline.pre_input_hook]).to eq([:swept, previous])
    ensure
      Reline.pre_input_hook = nil
    end
  end

  # Whether the human has typed anything at the read open now, which is what
  # lets an answer a run waits on take the terminal from an idle `you>`.
  describe ".untouched?" do
    it "reads the open read's buffer, empty or not" do
      editor = instance_double(Reline::LineEditor, whole_buffer: "")
      allow(Reline.core).to receive(:line_editor).and_return(editor)

      expect(described_class.untouched?).to be(true)
      allow(editor).to receive(:whole_buffer).and_return("half a sent")
      expect(described_class.untouched?).to be(false)
    end

    # A dumb gate reads the terminal cooked: a line being typed is in the
    # kernel's buffer, never in Reline's, so an empty buffer says nothing.
    it "is never true on a dumb gate" do
      allow(Reline.core).to receive(:line_editor).and_return(instance_double(Reline::LineEditor, whole_buffer: ""))
      allow(Reline::IOGate).to receive(:dumb?).and_return(true)

      expect(described_class.untouched?).to be(false)
    end
  end

  # Whether the read open now holds typed words, which a dumb gate cannot know.
  describe ".typed?" do
    it "reads the open read's buffer, empty or not" do
      editor = instance_double(Reline::LineEditor, whole_buffer: "", finished?: false)
      allow(Reline.core).to receive(:line_editor).and_return(editor)

      expect(described_class.typed?).to be(false)
      allow(editor).to receive(:whole_buffer).and_return("half a sent")
      expect(described_class.typed?).to be(true)
    end

    it "is never true on a dumb gate" do
      editor = instance_double(Reline::LineEditor, whole_buffer: "x", finished?: false)
      allow(Reline.core).to receive(:line_editor).and_return(editor)
      allow(Reline::IOGate).to receive(:dumb?).and_return(true)

      expect(described_class.typed?).to be(false)
    end

    it "is false once Enter accepted the line, which is sent and no longer a draft" do
      editor = instance_double(Reline::LineEditor, whole_buffer: "hello", finished?: true)
      allow(Reline.core).to receive(:line_editor).and_return(editor)

      expect(described_class.typed?).to be(false)
    end
  end

  # How far the open read's cursor sits below its first row on screen, which is
  # what a caller wiping the whole read has to climb.
  describe ".rows_above_cursor" do
    it "counts the wrapped rows above the cursor, less any scrolled off the top" do
      editor = instance_double(Reline::LineEditor, wrapped_cursor_position: [4, 3], screen_scroll_top: 0)
      allow(Reline.core).to receive(:line_editor).and_return(editor)

      expect(described_class.rows_above_cursor).to eq(3)
      allow(editor).to receive(:screen_scroll_top).and_return(1)
      expect(described_class.rows_above_cursor).to eq(2)
    end

    it "is 0 on a dumb gate, which draws no rows of its own" do
      editor = instance_double(Reline::LineEditor, wrapped_cursor_position: [4, 3], screen_scroll_top: 0)
      allow(Reline.core).to receive(:line_editor).and_return(editor)
      allow(Reline::IOGate).to receive(:dumb?).and_return(true)

      expect(described_class.rows_above_cursor).to eq(0)
    end
  end

  # A real terminal, because the defect lives in the order of two reads that no
  # double reproduces: the gate's default bindings (up arrow, bracketed paste)
  # are installed only by Reline's own lazy inputrc read.
  describe "#read on a real terminal" do
    let(:child) do
      <<~RUBY
        require "lain"
        Reline::HISTORY << "earlier"
        Lain::Frontend::LineEditor.bind("C-g") { |_buffer| nil } if ARGV[1] == "bind_first"
        if ARGV[1] == "timed_cx"
          Lain::Frontend::LineEditor.bind("C-x") do |buffer|
            File.write(ARGV[2], "\#{Process.clock_gettime(Process::CLOCK_MONOTONIC)}\n", mode: "a")
            buffer
          end
        end
        if ARGV[1] == "shift_tab"
          Lain::Frontend::LineEditor.bind("S-Tab") do |_buffer|
            File.write(ARGV[2], "hit\n", mode: "a")
            nil
          end
        end
        if ARGV[1] == "int_after_enter"
          interrupts = Queue.new
          trap("INT") { interrupts << true }
          Thread.new do
            interrupts.pop
            File.write(ARGV[3], Lain::Frontend::LineEditor.typed?.inspect)
          end
        end
        line = Lain::Frontend::LineEditor.new.read("> ")
        if ARGV[1] == "int_after_enter"
          Process.kill("INT", Process.pid)
          sleep 0.5
        end
        File.write(ARGV[0], line.inspect)
      RUBY
    end

    def read_through_pty(term, keys, bind_first: false, mode: bind_first ? "bind_first" : "plain", **timing)
      Dir.mktmpdir { |dir| drive_child(term, keys, dir, mode, **timing) }
    end

    # `settle` holds the final Enter back, so a key that waits on a timeout is
    # seen waiting; `on_write` stamps the moment the keys go in.
    def drive_child(term, keys, dir, mode, settle: 0, on_write: nil)
      out = File.join(dir, "line")
      reader, writer, pid = spawn_child(term, dir, out, mode)
      drawn = Queue.new
      answerer = answer_cursor_queries(reader, writer, drawn)
      drawn.pop(timeout: 10) or raise "prompt never drew"
      on_write&.call
      writer.write(keys.delete_suffix("\r"))
      sleep(settle)
      writer.write("\r")
      Process.wait(pid)
      File.exist?(out) ? File.read(out) : nil
    ensure
      [reader, writer].each { |io| io&.close unless io&.closed? }
      answerer&.join(2)
    end

    def spawn_child(term, dir, out, mode)
      env = { "TERM" => term, "INPUTRC" => File.join(dir, "no-inputrc") }
      PTY.spawn(env, RbConfig.ruby, "-W0", "-I", File.expand_path("../../../lib", __dir__),
                "-e", child, out, mode, File.join(dir, "hits"), File.join(dir, "typed_at_int"))
    end

    def answer_cursor_queries(reader, writer, drawn)
      Thread.new do
        seen = +""
        loop do
          chunk = reader.readpartial(4096)
          writer.write("\e[1;1R") if chunk.include?("\e[6n")
          seen << chunk
          drawn << true if seen.include?("> ") && drawn.empty?
        end
      rescue IOError, Errno::EIO
        nil
      end
    end

    it "recalls the previous line with the up arrow on the ANSI gate" do
      expect(read_through_pty("xterm", "\e[A\r")).to eq('"earlier"')
    end

    it "takes a bracketed paste whole on the ANSI gate" do
      expect(read_through_pty("xterm", "\e[200~one\ntwo\e[201~\r")).to eq('"one\ntwo"')
    end

    it "does both when a key was bound before the first read, as the frontend does at startup" do
      expect(read_through_pty("xterm", "\e[A\r", bind_first: true)).to eq('"earlier"')
      expect(read_through_pty("xterm", "\e[200~one\ntwo\e[201~\r", bind_first: true)).to eq('"one\ntwo"')
    end

    # The gate's emacs defaults include C-x C-x, which would turn lain's C-x
    # into a prefix that waits out Reline's 500ms key-sequence timeout.
    describe "lain's C-x against the gate's C-x C-x" do
      def fire_times(keys)
        Dir.mktmpdir do |dir|
          started = nil
          drive_child("xterm", "#{keys}\r", dir, "timed_cx", settle: 0.8, on_write: -> { started = clock })
          [started, File.readlines(File.join(dir, "hits"), chomp: true).map(&:to_f)]
        end
      end

      def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      it "fires C-x at once rather than after the key-sequence timeout" do
        started, hits = fire_times("\x18")

        expect(hits.first - started).to be < 0.3
      end

      it "fires twice for C-x C-x" do
        _, hits = fire_times("\x18\x18")

        expect(hits.size).to eq(2)
      end
    end

    it "fires Shift+Tab off the terminal's ESC [ Z and types none of it into the line" do
      Dir.mktmpdir do |dir|
        line = drive_child("xterm", "draft\e[Z\r", dir, "shift_tab")

        expect([line, File.readlines(File.join(dir, "hits")).size]).to eq(['"draft"', 1])
      end
    end

    # A Ctrl-C in the same write as the Enter cannot be driven: the terminal discards unread input when
    # it raises the interrupt. So the interrupt is raised once the read has returned its line.
    it "does not take an accepted line for a draft when the interrupt is handled after its Enter" do
      Dir.mktmpdir do |dir|
        line = Timeout.timeout(20) { drive_child("xterm", "hello\r", dir, "int_after_enter") }

        expect([line, File.read(File.join(dir, "typed_at_int"))]).to eq(['"hello"', "false"])
      end
    end

    it "still reads a line on the dumb gate" do
      expect(read_through_pty("dumb", "typed\r")).to eq('"typed"')
    end
  end

  describe ".claim_on" do
    it "names what holds a key the line editor owns" do
      expect(described_class.claim_on("C-t")).to include("ed_transpose_chars")
    end

    it "is nil for a key lain itself has bound, whose own handler is no claim" do
      described_class.bind("S-Tab") { |_buffer| nil }

      expect(described_class.claim_on("S-Tab")).to be_nil
    end

    it "names the user's inputrc when it binds the key" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "inputrc")
        File.write(path, "\"\\e[Z\": menu-complete-backward\n")
        ENV["INPUTRC"] = path
        config.reset_variables

        expect(described_class.claim_on("S-Tab")).to match(/inputrc.*menu_complete_backward/)
      end
    end
  end
end
