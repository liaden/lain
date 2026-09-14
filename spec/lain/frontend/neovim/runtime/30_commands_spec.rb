# frozen_string_literal: true

require "tmpdir"

# `runtime/30_commands.lua` -- what a user command does when it REFUSES.
#
# The operational half of `spec/refusal_delivery_discipline_spec.rb`. `define`
# does not rescue -- its only `pcall` guards the idempotent delete -- so an
# `error()` inside a callback escapes into nvim, which appends its own
# `stack traceback:` and, with a UI attached, raises the hit-enter prompt behind
# which every non-fast RPC request queues.
RSpec.describe Lain::Frontend::Neovim, :nvim do
  include NeovimRuntime

  around { |example| headless_editor("lain-nvim-commands-spec") { example.run } }

  describe "a user command that refuses" do
    def attach_ui(columns: 60, lines: 20)
      inspector.session.request(:nvim_ui_attach, columns, lines, { "rgb" => true, "ext_linegrid" => true })
    end

    def typed(keys) = inspector.session.request(:nvim_input, keys)

    def message_history
      inspector.exec_lua("return vim.api.nvim_exec2('messages', { output = true }).output", [])
    end

    # The width block's sampler, for its reason: `nvim_get_mode` is one of the
    # two calls nvim answers WHILE it is blocked, so it can be answered before
    # the keys queued ahead of it have run, and an early "not blocking" would be
    # a pass taken before the subject acted.
    def settled_mode(window: 0.5)
      deadline = Time.now + window
      modes = [inspector.session.request(:nvim_get_mode)]
      while Time.now < deadline
        sleep 0.02
        modes << inspector.session.request(:nvim_get_mode)
      end
      modes.find { |mode| mode["blocking"] } || modes.last
    end

    # `mode` is read beside `blocking` because nvim spells the hit-enter family
    # with a leading "r" -- "r" for the prompt, "rm" for `-- More --`, "r?" for
    # a confirm query -- and only one of the three is what this raises today.
    it "refuses :LainNote outside a review buffer without a traceback or a hit-enter prompt" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        attach_ui
        typed(":LainNote note hello\r")
        mode = settled_mode

        expect(mode).to include("blocking" => false)
        expect(mode["mode"]).not_to start_with("r")
        expect(message_history).not_to include("stack traceback")
      ensure
        typed("\r")
      end
    end

    # The prefix lives in ONE place -- `review_refused` prepends it
    # (`runtime/65_review.lua`) -- so a converted sentence that still spells its
    # own reached a human as `lain: lain: ...` for a whole card before it was
    # caught. Anchored at the start of a LINE rather than merely contained,
    # which is what makes "exactly once" sayable at all.
    it "prefixes the refusal exactly once, on one line of the message history" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        attach_ui
        typed(":LainNote note hello\r")
        settled_mode

        history = message_history
        expect(history).to include("lain: :LainNote needs a buffer lain has open for review")
        expect(history).not_to include("lain: lain:")
        expect(history.lines.map(&:chomp).grep(/\Alain: /).size).to eq(1)
      ensure
        typed("\r")
      end
    end

    # The notified half. `:LainPin` reads the CURRENT window's cursor, so fired
    # from anywhere but lain://timeline it would pin a turn the human never
    # looked at -- it refuses instead, and used to do that through `vim.notify`,
    # which writes the same message area with none of the rail's fitting. The
    # editor is on lain://journal here, which is where attach leaves it.
    it "refuses :LainPin off the timeline on the rail, prefixed once" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        attach_ui
        typed(":LainPin\r")
        mode = settled_mode

        expect(mode).to include("blocking" => false)
        expect(message_history).to include("lain: :LainPin pins the turn under the cursor")
        expect(message_history).not_to include("lain: lain:")
      ensure
        typed("\r")
      end
    end

    # The add-to-survey gesture (`:LainSurveyAdd`, `46_sidebar.lua:326`)
    # used to ack a `survey_add` rpcrequest that `Gestures#routes`
    # (`human_replies.rb:843-852`) has no route for -- a silent no-op, and the
    # human was told nothing was wrong. It now refuses instead, on the same
    # rail as everything else in this block, and sends no request at all: the
    # frontend's own `command_inbox` -- which every ACKED command lands in
    # regardless of routing (`rpc_thread.rb:1220`) -- proves that by staying
    # empty.
    it "refuses :LainSurveyAdd from a real file buffer instead of acking silently" do
      frontend = described_class.new(channel:, socket_path: @socket)

      Dir.mktmpdir do |dir|
        path = File.join(dir, "survey_target.rb")
        File.write(path, "# a real file\n")

        frontend.run do
          attach_ui
          inspector.session.request(:nvim_command, "edit #{path}")
          typed(":LainSurveyAdd\r")
          mode = settled_mode

          expect(mode).to include("blocking" => false)
          expect(message_history).to include("lain: :LainSurveyAdd sends nothing -- accretion is not wired yet")
          expect { frontend.command_inbox.pop(true) }.to raise_error(ThreadError)
        ensure
          typed("\r")
        end
      end
    end

    # Scenario 3's distinctness, from the buffer side: the wrong-buffer
    # refusal and the not-wired refusal are two different
    # sentences, so a human who reads one is never told the other's reason.
    # The editor is on lain://journal here, which is where attach leaves it
    # (`:LainPin`'s own example above relies on the same fact) -- buftype is
    # non-empty there, so the wrong-buffer guard fires before the not-wired
    # refusal ever would.
    it "keeps the wrong-buffer refusal distinct from the not-wired one" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        attach_ui
        wait_until_editor { buffer_lines("lain://journal").any? }
        inspector.command("buffer lain://journal")
        typed(":LainSurveyAdd\r")
        mode = settled_mode

        expect(mode).to include("blocking" => false)
        history = message_history
        expect(history).to include("lain: :LainSurveyAdd needs a real file buffer, not lain://journal")
        expect(history).not_to include("accretion is not wired")
      ensure
        typed("\r")
      end
    end
  end
end
