# frozen_string_literal: true

require "reline"

module Lain
  module Frontend
    # lain's whole Reline layer: which line-editor method gets called, how the
    # editor is configured, and the seam other code registers key actions
    # through. Three parts, one file, because they are one question -- how does
    # lain configure the line editor -- and answering it in three places is how
    # the answers drift.
    #
    # Named LineEditor and not Reline, even though the file is reline.rb: a
    # constant `Lain::Frontend::Reline` would shadow the stdlib `::Reline` for
    # every file lexically inside `module Lain::Frontend`, so {TTY}'s
    # `Reline::HISTORY` would silently resolve here instead. The file keeps the
    # gem's name because that is what the unit is about; the constant may not.
    #
    # Configuration goes through `Reline.core.config` and NEVER through the
    # human's ~/.inputrc. lain is a guest in someone's terminal: it may ask
    # this process's line editor for vi mode, and it may not edit a file the
    # user owns and every other Readline program in their shell also reads.
    #
    # KNOWN LIMITATION, verified against reline 0.6.3: in vi COMMAND mode
    # Reline's `ed_newline` calls `finish` directly without consulting
    # readmultiline's block (its own source comment there reads "should check
    # confirm_multiline_termination to finish?"). So:
    #
    #   The continuation rule applies in emacs mode and in vi INSERT mode --
    #   where a human types. In vi COMMAND mode, Enter submits the buffer
    #   whether or not the line ends in a backslash.
    #
    # Arguably correct rather than broken: Enter in vi command mode means
    # "execute". So it is documented here, taught contextually the first time
    # it actually bites (see VI_COMMAND_CAVEAT), and pinned by specs -- not
    # announced at startup. It is not worked around: the workaround is
    # rebinding Enter in the vi_command keymap, a second method on a stdlib
    # class and a far deeper coupling than this seam is allowed.
    #
    # Key actions are unaffected and fire in all three keymaps.
    class LineEditor
      # A line ending in a backslash continues; anything else submits. That
      # rule is the whole submit predicate, and `readmultiline`'s block IS the
      # predicate -- there is no second place where submission is decided.
      #
      # No escape-of-escape: a line ending in two backslashes still ends in a
      # backslash, so it still continues. The alternative -- IRB's approach of
      # asking whether the buffer parses as complete Ruby -- means nothing for
      # prose. A chat message is not a program, so a rule the human can state
      # in one sentence beats a heuristic they cannot.
      CONTINUATION = "\\"
      CONTINUED_LINE = "#{CONTINUATION}\n".freeze

      # The method Reline dispatches a lain-bound key to. Reline binds keys to
      # METHOD NAMES on Reline::LineEditor, never to Procs (see its
      # #wrap_method_call: `respond_to?(sym, true)`, then `method(sym)`), so
      # the seam has to be a method on a stdlib class. Exactly one, defined at
      # the bottom of this file, reaching handlers through {Registry}.
      ACTION = :lain_key_action

      # Reline's own indicators are "(cmd)"/"(ins)"; lain's bracketed form
      # matches {TTY::Countdown}'s "[c] cancel", so the two pieces of
      # bottom-of-screen furniture read as one interface rather than two.
      COMMAND_INDICATOR = "[cmd]"
      INSERT_INDICATOR = "[ins]"

      # Reports nowhere. A LineEditor built without a notifier still has to do
      # something with a handler's failure, and the Null Object is what keeps
      # {Registry#dispatch} from growing a nil check.
      SILENT = ->(_message) {}

      # The one thing vi mode still costs, taught at the moment it is useful
      # rather than announced at every session start.
      #
      # Not a startup banner: this is a design DIFFERENCE, not a fault, and
      # arguably the right one (Enter in vi command mode means "execute", so
      # submitting is defensible). Loud failure is for things that went wrong.
      # A line printed every session about behaviour the human cannot change is
      # how a codebase teaches its user to skim past the warnings that DO
      # matter -- and this frontend has several that do.
      VI_COMMAND_CAVEAT =
        "note: that line ended in a backslash but was submitted anyway -- vi command mode " \
        "submits on Enter without applying the continuation rule (a Reline limitation). " \
        "The rule works in vi insert mode."

      # Raised rather than shadowing. A key silently stolen from the line
      # editor -- or from another lain action -- is a defect the human finds
      # only when a key they have muscle memory for stops doing what it did.
      class KeyTaken < StandardError; end

      class << self
        def registry = @registry ||= Registry.new

        # Register `handler` on `name`, a control key written the way a human
        # writes it ("C-g"). The handler is called with the whole buffer typed
        # so far and returns either replacement text or nil; see {Registry}.
        def bind(name, &handler) = registry.bind(name, &handler)

        def bound?(name) = registry.bound?(name)

        def unbind_all = registry.clear
      end

      # @param vi_mode [Boolean] ask this process's line editor for vi mode. Off
      #   unless asked: with vi_mode false this class touches neither the editing
      #   mode nor the mode indicator, so an unconfigured lain leaves Reline
      #   exactly as it found it.
      # @param notify [#call] renders a warning line ({TTY#render_warning}) --
      #   presentation stays out of this class, the same seam
      #   {TTY::History} takes its `notify:` through. It configures the
      #   process-wide {Registry}, because there is one line editor per
      #   process and pretending otherwise would be a fiction.
      def initialize(vi_mode: false, notify: SILENT)
        @vi_mode = vi_mode
        @notify = Reporter.new(notify)
        @warned_about_vi = false
      end

      # @return [String, nil] the message with continuation markers removed, or
      #   nil at EOF (Ctrl-D / closed input)
      def read(prompt)
        configure
        # The notifier is installed for the duration of THIS read and taken
        # down after, because a read is the only window a key action can fire
        # in. Constructing a LineEditor therefore mutates nothing global -- it
        # used to install the notifier globally, so a second construction
        # silently disarmed the first one's.
        self.class.registry.reporting_to(@notify) do
          buffer = ::Reline.readmultiline(prompt, true) { |pending| submit?(pending) }
          buffer && accept(buffer)
        end
      end

      # `readmultiline` hands its block the whole buffer WITH a trailing
      # newline, which is why the trim is here and not at the call site.
      #
      # `delete_suffix("\n")` and not `chomp`: chomp would also strip a lone
      # "\r", making this half of the rule CRLF-tolerant while
      # {#join_continuations} stayed LF-only, so a continuation marker could be
      # honoured by one and left in the message by the other. Reline normalises
      # CRLF away itself (`insert_multiline_text` gsubs /\r\n?/), so LF-exact on
      # both sides is both correct and symmetric.
      def submit?(buffer) = !buffer.delete_suffix("\n").end_with?(CONTINUATION)

      # The marker is syntax, not content: the backslash the human typed to
      # continue is dropped, and the newline it continued over is kept.
      def join_continuations(buffer) = buffer.gsub(CONTINUED_LINE, "\n")

      private

      # A buffer that arrives still ending in a continuation marker means the
      # predicate was never consulted, and vi command mode's `ed_newline` --
      # which calls `finish` directly -- is the only way that happens. So this
      # is an exact signal that cannot false-positive: in every other mode the
      # predicate would have continued the line instead of submitting it. The
      # marker stays in the message rather than being eaten; the note explains
      # it, and silently deleting a character the human typed would be worse.
      def accept(buffer)
        warn_about_vi_command_mode unless submit?(buffer)
        join_continuations(buffer)
      end

      def configure
        config = ::Reline.core.config
        # Reline reads inputrc lazily, INSIDE readmultiline, on the first
        # prompt only. Forcing that read here -- before lain's own settings
        # land -- is what makes `vi_mode: true` mean it: otherwise an inputrc naming
        # an editing mode would overwrite the mode lain was asked for, and for
        # the session's first prompt alone, which is worse than either answer
        # applied consistently. Read, never written.
        config.read unless config.loaded?
        apply_vi_mode(config) if @vi_mode
      end

      def apply_vi_mode(config)
        config.editing_mode = :vi_insert
        config.show_mode_in_prompt = true
        config.vi_cmd_mode_string = COMMAND_INDICATOR
        config.vi_ins_mode_string = INSERT_INDICATOR
      end

      # Once per session, not once per occurrence: the point is to explain the
      # surprise the first time it happens, not to keep scoring it.
      def warn_about_vi_command_mode
        return if @warned_about_vi

        @warned_about_vi = true
        @notify.call(VI_COMMAND_CAVEAT)
      end
    end

    class LineEditor
      # Wraps the frontend's warning seam so a notifier that itself fails can
      # never escape into Reline's input loop. There is nowhere left to report
      # a failure to report, and the prompt has to outlive both of them.
      class Reporter
        def initialize(notify)
          @notify = notify
        end

        def call(message)
          @notify.call(message)
        rescue StandardError
          nil
        end
      end
    end

    # Reopened rather than nested in the class body above -- the tty.rb idiom:
    # each collaborator is its own responsibility, and the split keeps each
    # body inside Metrics/ClassLength instead of loosening it.
    class LineEditor
      # The process-global key-action registry.
      #
      # Global because everything beneath it already is: Reline is a singleton
      # (`Reline.core`), its config owns the keymaps, and the method a key
      # dispatches to is a method on the Reline::LineEditor CLASS. A
      # per-instance registry would be a fiction over shared state, and the
      # first two callers to register would silently fight over it.
      class Registry
        # Reline's binding for a byte, per keymap. lain binds into ALL THREE and
        # refuses any key any one of them genuinely claims.
        #
        # vi_insert was excluded once, on the grounds that it binds C-g and C-x
        # to `ed_insert` and claiming a key from self-insert felt rude. That was
        # wrong, and wrong in the worst way: `set editing-mode vi` in a human's
        # inputrc makes vi_insert the ACTIVE keymap at lain's DEFAULT setting,
        # with `vi_mode:` never touched -- so a key bound only into emacs and
        # vi_command routed to `ed_insert` and echoed a literal control
        # character into the message instead of running. Measured on a real
        # machine, not reasoned about.
        #
        # Including it is also the consistent reading of NOT_A_CLAIM below: if
        # self-insert does not count as the user's binding when asking whether a
        # key is free, it cannot count as a reason to refuse to bind there.
        # Nothing is actually taken from the human -- vi_insert keeps
        # `ed_quoted_insert` on C-v, which is how a literal control character
        # has always been typed.
        KEYMAPS = {
          emacs: ::Reline::KeyActor::EMACS_MAPPING,
          vi_insert: ::Reline::KeyActor::VI_INSERT_MAPPING,
          vi_command: ::Reline::KeyActor::VI_COMMAND_MAPPING
        }.freeze

        # What a live keymap entry may say without meaning "this key is taken".
        #
        # ACTION: {#clear} leaves Reline routing to it, so counting it would
        # make a rebind after unbind_all refuse itself.
        #
        # :ed_insert: self-insert is the ABSENCE of a binding expressed as one.
        # That single reading does both jobs this class needs, and they are the
        # same job seen from two sides:
        #
        #   - binding INTO vi_insert takes nothing from the human, because a key
        #     that only self-inserts was never doing anything for them (hence
        #     vi_insert's presence in KEYMAPS above);
        #   - a self-inserting entry in the live table is not a prior claim, so
        #     lain may bind over it. Without this, a human whose inputrc selects
        #     vi mode meets vi_insert's catch-all -- every one of C-a..C-z reads
        #     as :ed_insert -- and lain refuses to bind any key at all.
        #
        # Note the asymmetry, and it is deliberate: an inputrc that says
        # `"\C-g": self-insert` reports :self_insert, which is NOT in this list
        # and so DOES raise KeyTaken. Explicit intent is not the catch-all --
        # someone who names a key in their inputrc has spoken about that key.
        NOT_A_CLAIM = [nil, ACTION, :ed_insert].freeze

        # "C-g" and "c-G" name the same key; nothing else names a key at all.
        # Deliberately narrow -- a control byte is the whole free space worth
        # having, and a name lain cannot translate must fail loudly rather than
        # register a binding that can never fire.
        KEY_NAME = /\AC-([a-z])\z/i

        def initialize
          @handlers = {}
          @notify = Reporter.new(SILENT)
        end

        def bind(name, &handler)
          raise ArgumentError, "#{name}: a key action needs a handler" unless handler

          byte = byte_for(name)
          claim = claimed_by(byte)
          raise KeyTaken, "#{name} is already bound by #{claim}" if claim

          # Keymaps FIRST. A handler stored before the routing exists leaves
          # `bound?` answering true for a key that goes nowhere -- a
          # registration that reports success and can never fire.
          KEYMAPS.each_key { |keymap| ::Reline.core.config.add_default_key_binding_by_keymap(keymap, [byte], ACTION) }
          @handlers[byte] = handler
          verify_routing(name, byte)
          name
        end

        def bound?(name) = @handlers.key?(byte_for(name))

        # Drops lain's handlers. It does NOT return the keys to Reline: the
        # keymap entry still routes to ACTION, where dispatch finds no handler
        # and does nothing. Harmless, and {#claimed_by} knows not to count
        # lain's own leftover routing as a claim.
        def clear = @handlers.clear

        # The notifier belongs to a read, not to a process -- see
        # {LineEditor#read}.
        def reporting_to(notify)
          previous = @notify
          @notify = notify
          yield
        ensure
          @notify = previous
        end

        # Runs ON Reline's input loop. A handler must therefore never block.
        #
        # Precisely: a blocking handler is uninterruptible by SIGINT. For the
        # duration of a read Reline re-traps INT to its own flag-setter
        # (line_editor.rb:207), and lain's {CLI::Signals} Proc -- the one that
        # wakes {CLI::PromptBreaker}'s watcher thread -- is stashed as @old_trap
        # and reached only from `handle_interrupted`, which runs on this very
        # loop. Block the loop and Ctrl-C does nothing until the handler
        # returns. TERM and QUIT are NOT re-trapped, so those still break out
        # via the watcher's Thread#raise; SIGINT is the one that wedges, and it
        # is the one a human will reach for.
        #
        # @return [String, nil] replacement text, or nil to leave the buffer be
        def dispatch(key, buffer)
          handler = @handlers[byte_of(key)]
          handler && replacement_from(handler.call(buffer))
        rescue StandardError => e
          # A handler is other code running inside the line editor: its failure
          # costs the human a keystroke and must never cost them the prompt.
          # Anything that is NOT a StandardError -- an Interrupt from
          # {CLI::PromptBreaker}, a SignalException -- goes straight through,
          # because those are how a prompt is meant to end.
          @notify.call("warning: key action failed (#{e.class}: #{e.message})")
          nil
        end

        private

        # THE conversion this seam lives or dies by. Reline indexes its keymaps
        # by Integer byte, but hands a bound method `key.char`, which
        # key_stroke.rb:55 builds as `matched_bytes.pack('c*')
        # .force_encoding(@encoding)` -- a STRING, "\a" for C-g. Keying the
        # registry on the raw argument produces a seam that registers happily,
        # routes correctly, fires, and then silently matches no handler.
        # Integer is accepted too, because a caller reaching in directly (or a
        # future Reline) may reasonably pass one. See the round-trip spec.
        def byte_of(key) = key.is_a?(Integer) ? key : key.to_s.each_byte.first

        def replacement_from(result)
          return nil unless result
          return result if result.is_a?(String)

          raise TypeError, "a key action returns replacement text or nil, got #{result.class}"
        end

        def byte_for(name)
          letter = KEY_NAME.match(name.to_s)&.captures&.first
          raise ArgumentError, %(#{name} is not a control-key name such as "C-g") unless letter

          letter.downcase.ord - "a".ord + 1
        end

        # Who already owns this key, or nil. Three sources, and the third is
        # the one that is easy to miss: `Config#key_bindings` is
        # `Composite([oneshot, additional[mode], default[mode]])`, and inputrc
        # populates `additional`, which OUTRANKS the default table lain writes
        # to. A key that looks free in the MAPPING constants can still be taken
        # by the human -- verified: with `"\C-g": abort` in an inputrc,
        # key_bindings.get([7]) is :abort while EMACS_MAPPING[7] is still nil.
        # Binding it would hand back a registration that can never fire.
        def claimed_by(byte)
          return "lain" if @handlers.key?(byte)

          keymap, mapping = KEYMAPS.find { |_, table| !NOT_A_CLAIM.include?(table[byte]) }
          return "the line editor in the #{keymap} keymap (as #{mapping[byte]})" if keymap

          inputrc = inputrc_binding(byte)
          inputrc && "the user's inputrc (as #{inputrc})"
        end

        # THE guard against a bind that succeeds and hands back a key which
        # does nothing -- the shape of both defects this file has shipped.
        # Writing into every keymap is necessary and not sufficient: what
        # decides whether a key works is the keymap actually in force, so ask.
        def verify_routing(name, byte)
          routed = active_binding(byte)
          return if routed == ACTION

          @handlers.delete(byte)
          raise KeyTaken, "#{name} did not take: the active keymap routes it to #{routed.inspect}"
        end

        # The live table for the CURRENT editing mode -- the one that will
        # actually be in force, which is not necessarily the one lain asked
        # for: an inputrc `set editing-mode vi` selects it before lain looks.
        def active_binding(byte)
          config = ::Reline.core.config
          config.read unless config.loaded?
          config.key_bindings.get([byte])
        end

        # See NOT_A_CLAIM for the bindings that read as taken and are not.
        def inputrc_binding(byte)
          bound = active_binding(byte)
          bound unless NOT_A_CLAIM.include?(bound)
        end
      end
    end
  end
end

# The one method lain adds to a stdlib class, and the only place anything here
# reaches into Reline's editor at all. There is no Proc-shaped alternative --
# Reline dispatches a key to a method name (see {Lain::Frontend::LineEditor::ACTION}).
#
# Private, matching Reline's own actions (`private def ed_newline`): the
# dispatcher looks it up with `respond_to?(sym, true)`, so a private method is
# reachable without adding to a stdlib class's public surface.
Reline::LineEditor.class_eval do
  private

  def lain_key_action(key)
    replacement = Lain::Frontend::LineEditor.registry.dispatch(key, whole_buffer)
    return if replacement.nil?

    # Reline has no single verb for "replace the whole buffer": set_current_line
    # reaches only the cursor's own line, and delete_text with no arguments
    # drops exactly one line per call. Calling it once per line clears the
    # buffer from ANY cursor position and leaves Reline to keep @line_index and
    # @byte_pointer consistent -- which is why this seam owns none of Reline's
    # ivars, only three of its public methods.
    (whole_buffer.count("\n") + 1).times { delete_text }
    insert_multiline_text(replacement)
  end
end
