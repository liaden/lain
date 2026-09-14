# frozen_string_literal: true

require "stringio"

# The lua half: `runtime/46_sidebar.lua` -- `_G.__lain.set_review`, which is the
# FIRST caller of `review_place`, and `:LainReviewOpen`, which sends the
# cursor line with the stamp the buffer carries.
#
# `layout_spec.rb`'s harness, driving the injected chunk DIRECTLY: what is under
# test is what the editor does with a buffer and a window, and a frontend in
# front of that would mean every assertion had first to prove the frontend was
# not the thing that moved.
#
# ONE EDITOR PER EXAMPLE, and it was measured rather than assumed. Sharing one
# across the rendering group (`before(:context)`) was tried and dropped: it took
# the file from 1.11s to 0.83s, which is 0.28s against a suite whose longest
# FILE is 17.2s, and cost a `RSpec/BeforeAfterAll` suppression plus the order
# dependence that cop is about -- these examples close windows and swap the
# current buffer. A `--headless --clean` spawn measures 5-6ms, so a fresh editor
# is not the expensive fixture that pattern exists for; the 29ms first recorded
# here was the whole around hook -- spawn, socket wait, attach and runtime
# injection -- not the spawn.
RSpec.describe "runtime/46_sidebar.lua", :nvim do
  # The module driven DIRECTLY, through the chunk the loader injects: no
  # {Frontend::Neovim} lifecycle, no RPC thread, no render queue, so an assertion
  # about a window or a buffer is about what the editor did rather than about the
  # frontend's bookkeeping.
  describe "set_review and :LainReviewOpen" do
    # One editor per example, torn down whatever the example did to it -- these
    # examples close windows and swap the current buffer, which is the state a
    # shared editor would carry into the next one.
    around { |example| headless_editor("lain-nvim-sidebar-spec", runtime: true) { example.run } }

    def review_buffer = Lain::Frontend::Neovim::ReviewView::NAME

    def lua(source, args = []) = @editor.exec_lua(source, args)

    # THE SIDES ARE THE THIRD ARGUMENT, and defaulted here to both: every example
    # in this file is about the sidebar's own rows, and a changeset review is the
    # round they were written against. Passing them is not optional -- an omitted
    # third argument delivers `nil` to a parameter the layout reads.
    def set_review(lines, gen, sides = Lain::Review::SIDES) = lua("_G.__lain.set_review(...)", [lines, gen, sides])

    def review_lines
      lua("return vim.api.nvim_buf_get_lines(vim.fn.bufnr(...), 0, -1, false)", [review_buffer])
    end

    def review_buf = lua("return vim.fn.bufnr(...)", [review_buffer])

    def buffer_var(key)
      lua("local name, var = ...; return vim.b[vim.fn.bufnr(name)][var]", [review_buffer, key])
    end

    def sidebar_window
      lua(<<~LUA)
        for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
          if vim.t[tab].lain_review then
            for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
              if vim.w[win].lain_review_slot == "sidebar" then return win end
            end
          end
        end
        return nil
      LUA
    end

    describe "rendering into the review tabpage" do
      it "writes the lines it is given into lain://review" do
        set_review(%w[one two three], 1)

        expect(review_lines).to eq(%w[one two three])
      end

      it "replaces the whole rendering rather than appending to it" do
        set_review(%w[one two three], 1)
        set_review(%w[only], 2)

        expect(review_lines).to eq(["only"])
      end

      it "stamps the buffer with the rendering's generation" do
        set_review(%w[one], 41)

        expect(buffer_var("lain_view_generation")).to eq(41)
      end

      it "lands the sidebar in the review tabpage's sidebar slot, not in a split of the session tab" do
        set_review(%w[one], 1)

        expect(lua("return vim.api.nvim_win_get_buf(...)", [sidebar_window])).to eq(review_buf)
      end

      it "leaves the buffer nomodifiable at rest so a stray keystroke cannot desync it" do
        set_review(%w[one], 1)

        expect(lua("return vim.bo[vim.fn.bufnr(...)].modifiable", [review_buffer])).to be(false)
      end

      it "claims the buffer for the lain view contract" do
        set_review(%w[one], 1)

        expect(buffer_var("lain_view")).to eq(review_buffer)
      end

      # 00_constants' READONLY_FILETYPES is a shared table this module does not
      # edit, so the lookup misses and the option would land unset -- exactly the
      # orphan-buffer defect fixed for lain://workspace ("filetype '', no
      # syntax, outside the lain contract").
      it "joins the one shared lain filetype rather than landing as an orphan buffer" do
        set_review(%w[one], 1)

        expect(lua("return vim.bo[vim.fn.bufnr(...)].filetype", [review_buffer])).to eq("lain")
      end

      it "re-renders into the SAME buffer rather than stacking a new one per render" do
        set_review(%w[one], 1)
        first = review_buf
        set_review(%w[two], 2)

        expect(review_buf).to eq(first)
      end

      it "rebuilds the layout when the human closed the sidebar window" do
        set_review(%w[one], 1)
        lua("vim.api.nvim_win_close(..., true)", [sidebar_window])
        set_review(%w[two], 2)

        expect(lua("return vim.api.nvim_win_get_buf(...)", [sidebar_window])).to eq(review_buf)
      end

      it "sends the cursor line and the buffer's stamp as ONE array of arguments" do
        set_review(%w[one two], 7)
        sent = lua(<<~LUA, [review_buffer])
          local restore = vim.api.nvim_get_current_buf()
          local seen = nil
          vim.api.nvim_set_current_buf(vim.fn.bufnr(...))
          vim.api.nvim_win_set_cursor(0, { 2, 0 })
          local original = vim.rpcrequest
          vim.rpcrequest = function(_, method, verb, args) seen = { method, verb, args } end
          pcall(vim.cmd, "LainReviewOpen")
          vim.rpcrequest = original
          vim.api.nvim_set_current_buf(restore)
          return seen
        LUA

        expect(sent).to eq(["lain_command", "review_open", [2, 7]])
      end

      it "refuses :LainReviewOpen outside lain://review rather than opening a row nobody looked at" do
        set_review(%w[one two], 7)
        sent = lua(<<~LUA)
          local restore = vim.api.nvim_get_current_buf()
          local seen = false
          vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, true))
          local original = vim.rpcrequest
          vim.rpcrequest = function() seen = true end
          pcall(vim.cmd, "LainReviewOpen")
          vim.rpcrequest = original
          vim.api.nvim_set_current_buf(restore)
          return seen
        LUA

        expect(sent).to be(false)
      end
    end

    # The MARK gesture, which had already been wired all the way to
    # {Review::Handover#mark} with no key able to send it.
    describe "the mark keys" do
      # Read off the LIVE editor rather than off the runtime's source, because
      # what a human presses is what nvim has bound, not what a file says. Each
      # binding's rhs carries the state as a literal, so this pins three things at
      # once: every state has a key, no key sends a state Ruby cannot take, and
      # the sidebar's set is exactly `Review::MARK_STATES`.
      #
      # The set EQUALITY is the assertion, not `include`. A third state added to
      # `review/vocabulary.rb` and not here would pass an `include`, ship a
      # sidebar that cannot express it, and be refused -- silently -- at the far
      # end of the wire; a key sending a fourth spelling would pass it too, and be
      # refused at `Review::Marks.normalize`. This is `48_annotate`'s MARKERS
      # defence, one module over.
      let(:mark_maps) do
        <<~LUA
          local restore = vim.api.nvim_get_current_buf()
          vim.api.nvim_set_current_buf(vim.fn.bufnr(...))
          local states = {}
          for _, map in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
            local state = tostring(map.rhs):match("LainReviewMark%s+(%a+)")
            if state then states[#states + 1] = { key = map.lhs, state = state } end
          end
          vim.api.nvim_set_current_buf(restore)
          return states
        LUA
      end

      def bound_states
        set_review(%w[one two], 1)
        lua(mark_maps, [review_buffer])
      end

      it "binds one key per member of Review::MARK_STATES, and no others" do
        expect(bound_states.map { |bound| bound["state"] }).to match_array(Lain::Review::MARK_STATES)
      end

      # ONE KEY PER STATE is the card, so the count is the assertion that says so:
      # a single toggle key would satisfy every payload example below on its first
      # press and still be the defect `human_replies.rb` names.
      it "gives each state its own key rather than one key that toggles" do
        keys = bound_states.map { |bound| bound["key"] }

        expect(keys.uniq.size).to eq(Lain::Review::MARK_STATES.size)
      end

      # ON THE RAIL RATHER THAN RAISED, and what is asserted about the WIRE
      # is untouched: nothing is sent, which is the rule this example exists for.
      # What changed is `ok`. This used to `error()` out of the callback, and nvim
      # appends its own `stack traceback:` to anything escaping a `define`d one --
      # then raises a hit-enter prompt behind which every non-fast RPC request
      # queues, so the editor answers nothing at all while the refusal is up. It
      # answers through `__lain.review_refused` now, so the command COMPLETES and
      # the vocabulary is read off nvim's message history instead of off the
      # error. `spec/refusal_delivery_discipline_spec.rb` is the mechanical half;
      # this is what a human actually sees.
      #
      # `width` comes back beside the text because this sentence splices a closed
      # vocabulary in with `table.concat`: the discipline spec can measure only
      # its literal FRAME, and `refusal_width_discipline_spec.rb` is pure Ripper
      # and cannot read a lua string at all. So the 80-column budget is enforced
      # for this sentence HERE and nowhere else -- it shipped at 91 until it was
      # measured. `strdisplaywidth`, because columns are what page.
      it "refuses a state Ruby has no spelling for rather than putting it on the wire" do
        set_review(%w[one two], 7)
        outcome = lua(<<~LUA, [review_buffer])
          local restore = vim.api.nvim_get_current_buf()
          local seen = false
          vim.api.nvim_set_current_buf(vim.fn.bufnr(...))
          local original = vim.rpcrequest
          vim.rpcrequest = function() seen = true end
          local ok = pcall(vim.cmd, "LainReviewMark revewed")
          vim.rpcrequest = original
          vim.api.nvim_set_current_buf(restore)
          local shown = vim.api.nvim_exec2("messages", { output = true }).output
          local rail = vim.split(shown, "\\n")
          local line = ""
          for _, one in ipairs(rail) do
            if vim.startswith(one, "lain: ") then line = one end
          end
          return { sent = seen, ok = ok, shown = shown, line = line, width = vim.fn.strdisplaywidth(line) }
        LUA

        expect(outcome).to include("sent" => false, "ok" => true)
        expect(outcome["line"]).to start_with("lain: :LainReviewMark's state is one of")
        expect(outcome["line"]).to include(*Lain::Review::MARK_STATES)
        # 80 is `RefusalWidthDiscipline::BAR` (spec/refusal_width_discipline_spec.rb),
        # spelled out because that constant is not loaded here. If the budget ever
        # moves, `grep -rn 'be <= 80' spec/` is what finds this and its two siblings.
        expect(outcome["width"]).to be <= 80
        expect(outcome["shown"]).not_to include("stack traceback")
        expect(outcome["shown"]).not_to include("lain: lain:")
      end

      it "refuses :LainReviewMark outside lain://review rather than marking a row nobody looked at" do
        set_review(%w[one two], 7)
        sent = lua(<<~LUA)
          local restore = vim.api.nvim_get_current_buf()
          local seen = false
          vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, true))
          local original = vim.rpcrequest
          vim.rpcrequest = function() seen = true end
          pcall(vim.cmd, "LainReviewMark reviewed")
          vim.rpcrequest = original
          vim.api.nvim_set_current_buf(restore)
          return seen
        LUA

        expect(sent).to be(false)
      end
    end

    describe "the first render of a session" do
      it "opens the review in its own tabpage and leaves the human where they were" do
        before_tab = lua("return vim.api.nvim_get_current_tabpage()")
        before_windows = lua("return vim.api.nvim_tabpage_list_wins(...)", [before_tab])

        set_review(%w[one], 1)

        expect(lua("return vim.api.nvim_get_current_tabpage()")).to eq(before_tab)
        expect(lua("return vim.api.nvim_tabpage_list_wins(...)", [before_tab])).to eq(before_windows)
      end

      it "sizes the sidebar as a navigator rather than a third of the screen" do
        set_review(%w[one], 1)

        expect(lua("return vim.api.nvim_win_get_width(...)", [sidebar_window])).to eq(40)
      end
    end
  end

  # The changeset review's two gestures, crossing the WIRE into a real Ruby process. The block
  # above stubs `vim.rpcrequest` and can therefore only say what lua ATTEMPTED;
  # that is the shape of assertion this chunk has repeatedly shipped green over a
  # subject nobody was talking to. Here a real {Frontend::Neovim} serves the
  # socket, so every layer between the keystroke and the payload is the shipped
  # one -- the runtime as {RuntimeLoader} concatenates it, the {RpcThread}'s
  # select loop, its {Router}'s acked/answered split, and {ReviewWrite}'s judgement
  # of the arguments' SHAPE.
  #
  # The one thing that is not real is the object at the far end of the verdict
  # rail: {Review::Handover} needs a {Review::Session} over a {Review::Changeset},
  # which is a fixture this card has no business building. A recorder is bound
  # there instead, and the assertions are about what reached it, which is exactly
  # the wire this card supplies a caller for.
  #
  # Keys go through `nvim_feedkeys`, never `:normal!` and never `vim.cmd`: the
  # card is a KEYMAP, and both alternatives bypass mapping resolution entirely --
  # an example that ran the command directly would pass against a runtime that
  # binds no keys at all.
  describe Lain::Frontend::Neovim, "the changeset review's two gestures", :seam do
    # The same harness the thirteen per-module specs use, and for the same reason:
    # this group drives the runtime THROUGH a frontend, so it wants `channel`,
    # `wait_until_editor`, `press` and `next_command` rather than its own copies.
    # The group above does not, because it drives the injected chunk directly.
    include NeovimRuntime

    # {#inspector}, the second connection, is how this file observes an editor the
    # frontend owns: `_G.__lain` is process-wide lua state, so a render posted from
    # there lands in the same runtime the frontend injected, and the `chan` upvalue
    # the gestures send on still names the FRONTEND's channel.
    around { |example| headless_editor("lain-nvim-gestures-spec") { example.run } }

    # A recorder, not a double: `wrote_verdict` must ANSWER (nil is "taken", a
    # String is the refusal the human's command fails with), and what these
    # examples need to know is what it was handed.
    let(:review) do
      Class.new do
        def initialize = @verdicts = []

        attr_reader :verdicts

        def wrote_annotation(_note) = nil

        def wrote_verdict(verdict)
          @verdicts << verdict
          nil
        end
      end.new
    end

    def sidebar = Lain::Frontend::Neovim::ReviewView::NAME

    # Spelled out rather than through `...` so the rail's whole shape is visible
    # here, sides included: see the helper above for why the third argument may
    # not be dropped.
    def set_review(lines, generation, sides = Lain::Review::SIDES)
      inspector.exec_lua("local lines, gen, sides = ...; _G.__lain.set_review(lines, gen, sides)",
                         [lines, generation, sides])
    end

    # `pcall`, because the whole point of the ANSWERED rail is that a refusal
    # arrives as the command's ERROR -- and `Neovim::Client#command` would turn
    # that into a raise in the spec process rather than a value to assert on.
    def run(command)
      inspector.exec_lua(<<~LUA, [command])
        local ok, err = pcall(vim.cmd, ...)
        return { ok = ok, err = tostring(err) }
      LUA
    end

    # nvim's own `:messages`, read over the SECOND connection -- what a human
    # sitting at the editor would scroll back to, rather than anything the
    # frontend recorded about itself. `neovim_spec.rb`'s helper, verbatim.
    def messages
      inspector.exec_lua("return vim.api.nvim_exec2('messages', { output = true }).output", [])
    end

    # A refusal `__lain.review_refused` echoed, waited for: the command returns
    # before nvim has necessarily flushed the echo, so a bare read races it.
    def refusal_shown = wait_until_editor { messages[/lain: .+/] }

    # The real review model behind the verdict rail, for the one example that
    # asserts what the human SEES. Hand-written diff bytes over a verifying
    # double ({DiffSource}) rather than a repository -- `handover_spec.rb`'s own
    # fixture choice -- so the only thing standing in for production here is the
    # source of the bytes, and everything from `Session#submit` outward is real.
    #
    # `Policy::Permissive`, because the point is the acknowledgement and not the
    # admissibility: the default policy refuses an approve over hunks nobody
    # read, which is a different example's subject.
    def handover_over(surface)
      Lain::Review::Handover.new(session: Lain::Review::Session.open(
        changeset: Lain::Review::Changeset.new(source: verdict_source), journal: Lain::Journal.new(io: StringIO.new),
        source: "local_branch", surface:, policy: Lain::Review::Verdict::Policy::Permissive.new
      ))
    end

    def verdict_diff
      <<~DIFF
        diff --git a/a.rb b/a.rb
        index 1111111..2222222 100644
        --- a/a.rb
        +++ b/a.rb
        @@ -1,3 +1,3 @@ def alpha
         one
        -two
        +TWO
      DIFF
    end

    # Attributed, because a changeset whose diff names a file no commit's numstat
    # does is one `Partition::ByCommit` refuses.
    def verdict_commit
      Lain::Review::Source::Commit.new(
        sha: -("c" * 40), subject: -"touch a", body: "",
        numstat: [Lain::Review::Source::FileStat.new(path: -"a.rb", added: 1, deleted: 1)].freeze
      )
    end

    def verdict_source
      DiffSource.over(instance_double(Lain::Review::Source::LocalBranch,
                                      diff: verdict_diff.b, commits: [verdict_commit].freeze,
                                      base_ref: -("b" * 40), head_ref: -("h" * 40)))
    end

    describe "review_mark" do
      # The payload, end to end: `["review_mark", [line, state, generation]]` is
      # what `HumanReplies::Gestures#mark_hunk` destructures and what
      # `human_replies_spec` pushes by hand -- so this is the one example that
      # says the editor produces the shape every spec on the other side assumes.
      it "sends the row, the state the key names, and the rendering's stamp" do
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          set_review(%w[one two], 7)
          press(sidebar, "x", cursor: [2, 0])

          expect(next_command(frontend)).to eq(["review_mark", [2, "reviewed", 7]])
        end
      end

      it "sends the OTHER state from the other key, on the same row" do
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          set_review(%w[one two], 7)
          press(sidebar, "u", cursor: [2, 0])

          expect(next_command(frontend)).to eq(["review_mark", [2, "unreviewed", 7]])
        end
      end

      # THE COUNTER-EXAMPLE THE CARD IS ABOUT. A lua-side toggle passes both
      # examples above on a first press and diverges only on the second, which is
      # precisely the failure `human_replies.rb:554-558` describes: a state derived
      # from a rendering rather than from the human's finger, silently flipping the
      # wrong way because both values are legal. Twice on one row, twice the same
      # word.
      it "sends the same state twice for two presses of one key rather than toggling" do
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          set_review(%w[one two], 7)
          press(sidebar, "x", cursor: [2, 0])
          press(sidebar, "x", cursor: [2, 0])

          expect([next_command(frontend), next_command(frontend)])
            .to eq([["review_mark", [2, "reviewed", 7]], ["review_mark", [2, "reviewed", 7]]])
        end
      end

      # The stamp, on the mark rail: two renderings of EQUAL HEIGHT, which is
      # the case a line count cannot tell apart and the reason protocol 8 replaced
      # one with the other. A payload carrying the count, the first generation, or
      # nothing at all all read alike against a single render.
      it "carries the stamp of the rendering on screen, not the one before it" do
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          set_review(%w[one two], 6)
          set_review(%w[alpha beta], 7)
          press(sidebar, "x", cursor: [1, 0])

          expect(next_command(frontend)).to eq(["review_mark", [1, "reviewed", 7]])
        end
      end

      # BUFFER-LOCAL, and `60_question.lua`'s comment says what a global one costs:
      # `x` is how a human deletes a character, in every file they have open. A map
      # that escaped the sidebar would break that everywhere AND send a gesture
      # about a row nobody is looking at, and nothing in the payload examples above
      # can see either.
      it "keeps the keys buffer-local, so x in the human's own file still deletes a character" do
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          set_review(%w[one two], 7)
          typed = inspector.exec_lua(<<~LUA, [])
            local buf = vim.api.nvim_create_buf(true, false)
            vim.api.nvim_set_current_buf(buf)
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "abc" })
            vim.api.nvim_win_set_cursor(0, { 1, 0 })
            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("x", true, false, true), "x", false)
            return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
          LUA

          expect(typed).to eq(["bc"])
          expect { frontend.command_inbox.pop(true) }.to raise_error(ThreadError)
        end
      end
    end

    describe "review_verdict" do
      # ONE ARRAY HOLDING THE PAYLOAD. `ReviewWrite.verdict` refuses anything else
      # BY NAME (`65_review.lua:75-79` records what flat positionals cost), so a
      # verdict that reaches the recorder at all is a verdict that arrived in the
      # shape every verb on this rail uses -- and a flat-positional lua half fails
      # here with that refusal rather than passing quietly.
      it "hands the verdict to the bound review" do
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          frontend.bind_changeset_review(review)

          expect(run("LainReviewVerdict approve")).to include("ok" => true)
          expect(review.verdicts).to eq(["approve"])
        end
      end

      # The vocabulary is `Review::VERDICTS` and lua does not restate it, so this
      # is the example that says so from both sides: nothing reaches the review,
      # and the sentence the human gets is the one the ONE declaration produced.
      #
      # READ OFF THE MESSAGE RAIL now, not off `pcall`'s `ok`. The command
      # used to re-raise the refusal that crossed the wire, so the human met a
      # `stack traceback:` under lain's own sentence; it
      # now answers through `__lain.review_refused` and returns, so the command
      # COMPLETES and the sentence is echoed. What is asserted about the sentence
      # and about the review is unchanged -- only where the sentence is read from.
      it "refuses a word the vocabulary does not hold, and tells the human which words it does" do
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          frontend.bind_changeset_review(review)

          expect(run("LainReviewVerdict looks-fine")).to include("ok" => true)
          expect(refusal_shown).to include(*Lain::Review::VERDICTS).and include("looks-fine")
          expect(review.verdicts).to be_empty
        end
      end

      # A bare invocation takes the SAME path as a typo, deliberately: lua holds
      # no vocabulary to check against, so the empty verdict is refused by the
      # object that owns the words and the human is told what they are.
      it "refuses an empty verdict by naming the vocabulary rather than sending nothing" do
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          frontend.bind_changeset_review(review)

          expect(run("LainReviewVerdict")).to include("ok" => true)
          expect(refusal_shown).to include(*Lain::Review::VERDICTS)
          expect(review.verdicts).to be_empty
        end
      end

      # THE ACKNOWLEDGEMENT, end to end and with nothing doubled between the
      # keystroke and the message area. Every example above binds a recorder,
      # which can say what reached Ruby and can never say what the human SEES --
      # and "the human sees nothing" was the whole defect: `:LainReviewVerdict
      # approve` journaled correctly and printed nowhere.
      #
      # So this one binds a REAL {Review::Handover} over a REAL
      # {Review::Session}, whose surface is the frontend's OWN
      # {Review::Surface::Neovim} (`#review_surface` -- never a second one built
      # here, for the reason that method's doc gives), and reads nvim's own
      # `:messages` back through the inspector connection. Nothing but the diff
      # bytes is a fixture.
      it "echoes the verdict into the editor's own message history" do
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          frontend.bind_changeset_review(handover_over(frontend.review_surface))

          expect(run("LainReviewVerdict approve")).to include("ok" => true)
          expect(wait_until_editor { messages[/approve/] }).to include("approve")
        end
      end

      # ANSWERED, and the editor with no review open is the ordinary state of
      # every session: the command refuses with {NoReviewWrites}'s own sentence
      # rather than acking a verdict nothing recorded.
      it "refuses with the unopened-review sentence when no review is bound" do
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          expect(run("LainReviewVerdict approve")).to include("ok" => true)
          expect(refusal_shown).to include("no review is open here")
        end
      end

      # THE OTHER HALF OF EVERY REFUSAL ABOVE, asserted once rather than three
      # times: none of them may cost the human a traceback. It is a separate
      # example because the three above are about WHAT lain said and this is about
      # how it arrived, which no assertion on the sentence can state.
      #
      # ANCHORED ON `refusal_shown` FIRST, and that is not ceremony. A bare
      # negative passes vacuously if either command silently no-ops, and worse, it
      # RACES the echo it is looking past -- `refusal_shown` exists in this file
      # precisely because the command returns before nvim has necessarily flushed.
      # Waiting for the refusal to land is what makes the absence of a traceback
      # beside it mean anything.
      it "shows no Lua stack traceback for any of those refusals" do
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          frontend.bind_changeset_review(review)

          expect(run("LainReviewVerdict looks-fine")).to include("ok" => true)
          expect(refusal_shown).to include(*Lain::Review::VERDICTS)
          expect(run("LainReviewVerdict")).to include("ok" => true)

          expect(messages).not_to include("stack traceback")
        end
      end
    end
  end
end
