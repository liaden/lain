# frozen_string_literal: true

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
  def press(editor, byte = ctrl_g)
    char = [byte].pack("c*").force_encoding(Encoding::UTF_8)
    editor.input_key(Reline::Key.new(char, config.key_bindings.get([byte]) || :ed_insert, false))
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

    # F8, specified rather than accidental: the rule is "a line ENDING in a
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

    # F7: the two halves of the rule agree on line endings. Reline normalises
    # CRLF out of the buffer itself, so this pins that they stay symmetric
    # rather than one silently tolerating what the other does not.
    it "treats the continuation marker identically in both halves of the rule" do
      editor = described_class.new

      expect(editor.submit?("first \\\n")).to be(false)
      expect(editor.join_continuations("first \\\nsecond")).to eq("first \nsecond")
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

      described_class.new(vi_mode: true).read("> ")

      expect(config.editing_mode_is?(:vi_insert)).to be(true)
    end

    it "shows which mode is active, with a string for each" do
      allow(Reline).to receive(:readmultiline).and_return("hi")

      described_class.new(vi_mode: true).read("> ")

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

        described_class.new(vi_mode: true).read("> ")

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

        described_class.new(vi_mode: true).read("> ")

        expect(config.editing_mode_is?(:vi_insert)).to be(true)
      end
    end

    # S2: vi_mode is a KNOWN-DEGRADED mode, and the damage is worse than a
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

      described_class.new(vi_mode: true, notify: reported.method(:push)).read("> ")

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

    # F4: the handler used to land in @handlers before the keymap loop, so a
    # keymap failure left `bound?` answering true for a key that routed nowhere
    # -- a registration that reports success and can never fire.
    it "registers nothing at all when installing the keymap binding fails" do
      allow(config).to receive(:add_default_key_binding_by_keymap).and_raise("keymap exploded")

      expect { described_class.bind("C-g") { |_buffer| nil } }.to raise_error(/keymap exploded/)
      expect(described_class.bound?("C-g")).to be(false)
    end

    # F5: Config#key_bindings is Composite([oneshot, additional[mode],
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
    # live binding non-nil" check refuses every key there is, and T15/T16 get
    # no seam at all. Self-insert is the absence of a binding, not a claim.
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

    # The general guard against the failure mode that produced both this
    # blocker and S1: a bind that succeeds and yields a key which does nothing.
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

    # F2: the report itself runs inside dispatch's rescue. A notifier that
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

  # F3: constructing a LineEditor used to install its notifier on the
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
  describe "the Reline surface lain is pinned to" do
    it "still leaves C-g free in every keymap lain binds into" do
      expect(Reline::KeyActor::EMACS_MAPPING[ctrl_g]).to be_nil
      expect(Reline::KeyActor::VI_COMMAND_MAPPING[ctrl_g]).to be_nil
      # Self-insert, i.e. free -- see Registry::NOT_A_CLAIM.
      expect(Reline::KeyActor::VI_INSERT_MAPPING[ctrl_g]).to eq(:ed_insert)
    end

    # The contract published to T15 and T16 names exactly two keys. This is the
    # spec that fails if a reline bump changes that, rather than two cards
    # discovering it in a terminal.
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
end
