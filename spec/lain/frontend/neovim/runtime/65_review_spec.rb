# frozen_string_literal: true

require "async"
require "tmpdir"
require "stringio"

# `runtime/65_review.lua` -- the review round trip, and the width any sentence it
# refuses with has to fit into.
#
# THE WIDTH GROUP ATTACHES A UI AND NOTHING ELSE IN THESE SPECS DOES,
# deliberately. Measured on nvim 0.12: with no UI attached nvim never raises the
# hit-enter prompt at all, so a headless editor cannot witness the defect -- and
# `nvim_ui_attach` is also what makes `&columns` real.
RSpec.describe Lain::Frontend::Neovim, :nvim do
  include NeovimRuntime

  around { |example| headless_editor("lain-nvim-review-spec") { example.run } }

  describe "the review round trip" do
    let(:written) do
      Lain::Epic::Intake::Written.new(
        graph: Lain::Epic::Graph.new(issues: [Lain::Epic::Issue.new(id: "b2", title: "the thing")])
      )
    end

    # The wire contract, pinned against the editor that actually produces it:
    # `[verb, args]` with args ONE array, because HumanReplies#pop_command
    # destructures exactly that -- and annotations String-keyed, because they
    # crossed msgpack from lua. Sent as flat positionals, every :LainReviewDone
    # was refused as NotOpen and the payload's third element was never even
    # looked at; both specs that covered this were green on their own side of
    # the seam.
    it "sends done as one array of args, annotations String-keyed" do
      Dir.mktmpdir("lain-review") do |dir|
        path = File.join(dir, "epic.md")
        File.write(path, "## b2 the thing\n")
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          frontend.open_review(path, 7, epic_slug: "alpha")
          expect(opened_review(path)).to include("generation" => 7, "slug" => "alpha", "focused" => true)

          inspector.exec_lua("vim.ui.input = function(_, callback) callback('tighten this AC') end; return true", [])
          inspector.command("LainAnnotate")
          inspector.command("LainReviewDone")

          expect(next_command(frontend)).to eq(
            ["review_done",
             [7, "alpha", [{ "line" => 1, "text" => "tighten this AC", "anchor_text" => "## b2 the thing" }]]]
          )
        end
      end
    end

    # The seam itself, crossed once: a REAL editor's done gesture routed through
    # the REAL consumer into a REAL Epic::Review, so the delta the tool would
    # await is produced by the bytes a human actually saved. Nothing here is
    # doubled -- that is the point. Two green specs on either side of this seam
    # are what let the wire shape drift in the first place.
    it "settles the bound review with what the human saved, and journals the note they left" do
      Dir.mktmpdir("lain-review") do |dir|
        path = File.join(dir, "epic.md")
        File.write(path, written.bytes)
        io = StringIO.new
        review = Lain::Epic::Review.new(journal: Lain::Journal.new(io:), epic_slug: "alpha")
        token = review.open(path:, written:)
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          frontend.open_review(path, token.generation, epic_slug: "alpha")
          opened_review(path)
          inspector.command("%s/the thing/a sharper thing/")
          inspector.command("write")
          # Annotating leaves the buffer unmodified (virtual text, not bytes),
          # so `done` still has a saved file to settle from.
          inspector.exec_lua("vim.ui.input = function(_, callback) callback('tighten this AC') end; return true", [])
          inspector.command("LainAnnotate")
          inspector.command("LainReviewDone")

          delta = settled_delta(frontend, review, token)
          expect(delta.account.changes).to eq({ retitled: ["b2"] })
          expect(Lain::Journal.records(io.string.lines, type: "annotation").to_a).to contain_exactly(
            hash_including("epic_slug" => "alpha", "generation" => token.generation, "line" => 1,
                           "text" => "tighten this AC", "issue_id" => "b2", "drifted" => false)
          )
        end
      end
    end

    # A buffer this command was never opened on refuses cleanly -- the
    # guard's own sentence, naming the command a changeset review or a survey
    # actually reaches, never an escaped Lua error.
    #
    # MEASURED, not assumed: any error that escapes a `define`d command's
    # callback (`30_commands.lua`'s `nvim_create_user_command`) gets nvim's own
    # "stack traceback:" appended underneath it, regardless of how it was
    # raised -- `error(msg, 0)` included, and re-raising a caught error from
    # inside a `pcall` does too, because the traceback is nvim's OWN outer
    # wrapper's doing and not the callback's. So "clean" here can only mean the
    # guard never raises at all; it echoes and returns, `review_refused`'s own
    # pattern one function above it in `65_review.lua`.
    it "refuses :LainReviewDone on a buffer no review ever opened, without a Lua stack traceback" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        # The freshly attached editor's own buffer 1 -- headless, `--clean`,
        # never handed to `open_review` -- so it carries neither
        # `b:lain_review_generation` nor `b:lain_review_epic_slug`.
        inspector.command("LainReviewDone")

        text = inspector.exec_lua("return vim.api.nvim_exec2('messages', { output = true }).output", [])
        expect(text).to include("lain:").and include(":LainReviewVerdict")
        expect(text).not_to include("stack traceback")
      end
    end

    # THE SECOND GUARD, and its own example: `:LainReviewDone`'s "no open
    # review" guard above and its "unsaved buffer" guard changed mechanism
    # together (`error()` -> `review_refused` + `return`), and a `return`
    # where an `error()` used to be is exactly the shape that silently turns a
    # real refusal into a no-op that still lets the write through -- the risk
    # is not hypothetical, it is what the mechanism change could have done
    # wrong. So this is checked on its own: the buffer is genuinely modified
    # (not saved), the human's own gesture, and the assertion is not just the
    # message but that NOTHING reached the command inbox for `Reviews#settle`
    # to act on -- a leaked payload here would be a review settled from bytes
    # the buffer never actually held.
    #
    # The neighbouring, POSITIVE case -- a clean epic buffer still sends
    # `["review_done", [generation, epic_slug, annotations]]` -- is already
    # covered above ("sends done as one array of args..." and "settles the
    # bound review..."), both of which exercise this exact guard's PASS path.
    it "refuses :LainReviewDone on a modified buffer without a traceback, and leaks nothing to the command inbox" do
      Dir.mktmpdir("lain-review") do |dir|
        path = File.join(dir, "epic.md")
        File.write(path, "## b2 the thing\n")
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          frontend.open_review(path, 7, epic_slug: "alpha")
          opened_review(path)
          # Modified, never written: `Reviews#settle` reads FROM DISK, so an
          # edit that never reached it must never be treated as reviewed.
          inspector.exec_lua("vim.bo[vim.api.nvim_get_current_buf()].modified = true", [])

          inspector.command("LainReviewDone")

          text = inspector.exec_lua("return vim.api.nvim_exec2('messages', { output = true }).output", [])
          expect(text).to include("lain: save the review before marking it done")
          expect(text).not_to include("stack traceback")
          expect { frontend.command_inbox.pop(true) }.to raise_error(ThreadError)
        end
      end
    end

    # THE SAME RULE, ON THE COMMAND THAT DID NOT GET IT. The two examples
    # above cover refusals this runtime raises LOCALLY; this one covers a
    # refusal that crossed the WIRE -- `review_verdict` is an ANSWERED verb, so
    # lain's sentence comes back as the rpcrequest's error and `46_sidebar.lua`
    # caught it in a `pcall` and then re-raised it with `error(tostring(refusal),
    # 0)`. Re-raising is what buys the traceback: the callback is bound by
    # `nvim_create_user_command` and nvim appends `stack traceback:` to anything
    # that escapes one HOWEVER it was raised. `pcall` never avoided that and was
    # never going to -- the way out is not to raise, which is what
    # `:LainReviewDone` above already does. (Not raising did NOT, on its own,
    # buy freedom from the hit-enter prompt -- `nvim_echo` of a message longer
    # than the message area pages however it is called. Making the rail itself
    # width-aware is what bought that, and "the refusal rail's width" below is
    # where it is pinned.)
    #
    # NO REVIEW IS OPEN, which is the cheapest true refusal on this rail and the
    # ordinary state of every session that has not started one:
    # {Neovim::NoReviewWrites::UNOPENED} is what comes back, so the sentence is
    # lain's own and nothing here fabricates it. `review_view_spec.rb` covers
    # the richer refusals (an unknown verdict, an empty one) against a bound
    # review; the rule is the same at all three and is stated once, here, beside
    # the command that already keeps it.
    it "refuses :LainReviewVerdict without a traceback when the refusal crossed the wire" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        outcome = inspector.exec_lua(<<~LUA, [])
          local ok, err = pcall(vim.cmd, "LainReviewVerdict approve")
          return { ok = ok, err = tostring(err) }
        LUA

        # The command COMPLETED -- a refusal is a refusal, not a crash.
        expect(outcome).to include("ok" => true)

        text = inspector.exec_lua("return vim.api.nvim_exec2('messages', { output = true }).output", [])
        expect(text).to include("lain:").and include("no review is open here")
        expect(text).not_to include("stack traceback")
      end
    end
  end

  # The reason this is worth its own block: a refusal wider than the
  # message area raises nvim's hit-enter prompt, and that prompt blocks the
  # RPC. Round 5 measured `nvim --server ... --remote-expr "execute('messages')"`
  # hanging for its full two-minute timeout, so the documented recovery paths --
  # reading `lain://approval`, driving `:LainApprove` -- are unavailable exactly
  # while a refusal is on screen. The rail must therefore be safe for ANY
  # sentence, not merely for the short ones the surfaces currently send.
  #
  # THESE EXAMPLES ATTACH A UI AND THE REST OF THIS FILE DOES NOT, deliberately.
  # Measured on nvim 0.12: with no UI attached nvim never raises the prompt at
  # all -- a 300-character echo reads `blocking = false` at every width -- so a
  # headless editor cannot witness this defect at all. `nvim_ui_attach` is also
  # what makes `&columns` real, which is the width the rail has to fit into.
  #
  # `nvim_get_mode` and `nvim_input` are the only two calls nvim answers WHILE
  # it is blocked on that prompt; every other request queues behind the main
  # loop, which IS the operational half of the finding. So delivery is a
  # `notify` and not a `request` -- a request would never come back -- the
  # witness is `nvim_get_mode`, and every example clears the prompt in an
  # `ensure`, because one left standing hangs the frontend's own teardown and
  # reads as a mystery timeout rather than as the expectation that failed.
  describe "the refusal rail's width" do
    # The sentence round 5 actually measured at 225 characters, from
    # `:LainReviewVerdict approve` over a partially reviewed changeset: a
    # CONDITION, then the ` -- ` this rail separates with, then the REMEDY.
    def overlong_refusal
      "approve is refused over a changeset that is not fully reviewed: lib/empty.rb is unreviewed " \
        "-- mark every hunk, or open the session with " \
        "Lain::Review::Verdict::Policy::Permissive.new if this run means to judge regardless"
    end

    # 60 rather than the cockpit's real 110 so the fixture sentence can stay
    # readable while still being far wider than the message area. `lain up`
    # gives the nvim pane 110 columns when it splits the window with chat, and
    # `v:echospace` there is 98 -- 'showcmd' reserves eleven cells plus one in
    # the last screen line, which is why the ceiling is `v:echospace` and not
    # `&columns`.
    def attach_ui(columns:, lines: 20)
      inspector.session.request(:nvim_ui_attach, columns, lines, { "rgb" => true, "ext_linegrid" => true })
    end

    def deliver(sentence)
      inspector.session.notify(:nvim_exec_lua, "_G.__lain.review_refused(...)", [sentence])
    end

    # Sampled across a WINDOW, and never exited early on a `false`: because
    # `nvim_get_mode` is answered while the main loop is busy, it can be
    # answered BEFORE the delivery queued ahead of it has even run, and an early
    # "not blocking" would be a pass taken before the subject acted. Observed
    # exactly that once, on the red run, in one example out of five. Half a
    # second is orders of magnitude more than an `nvim_exec_lua` notify needs,
    # and any blocking sample inside the window is the answer.
    def settled_mode(window: 0.5)
      deadline = Time.now + window
      modes = [inspector.session.request(:nvim_get_mode)]
      while Time.now < deadline
        sleep 0.02
        modes << inspector.session.request(:nvim_get_mode)
      end
      modes.find { |mode| mode["blocking"] } || modes.last
    end

    def delivering(sentence)
      deliver(sentence)
      yield settled_mode
    ensure
      inspector.session.request(:nvim_input, "\r")
    end

    def messages
      inspector.exec_lua("return vim.api.nvim_exec2('messages', { output = true }).output", [])
    end

    # `mode` is checked alongside `blocking` because nvim spells the
    # hit-enter family with a leading "r" -- "r" for the prompt itself, "rm" for
    # `-- More --`, "r?" for a confirm query -- and only one of those three is
    # the one this fixture happens to raise today.
    it "does not raise a hit-enter prompt for a refusal wider than the message area" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        attach_ui(columns: 60)

        delivering(overlong_refusal) do |mode|
          expect(mode).to include("blocking" => false)
          expect(mode["mode"]).not_to start_with("r")
        end
      end
    end

    # The whole point of shortening the echoed line is that nothing is
    # lost by it: `:messages` is where a human goes for the sentence they could
    # not read on one line, so the sentence has to actually be there, whole.
    it "keeps the whole sentence in :messages even when the echoed line is shortened" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        attach_ui(columns: 60)

        delivering(overlong_refusal) { |mode| expect(mode).to include("blocking" => false) }

        expect(messages).to include("lain: #{overlong_refusal}")
      end
    end

    # A refusal that fits is untouched -- prefix, sentence, nothing else --
    # on BOTH halves of the rail, which is why `:messages` is pinned here beside
    # the answer. `review_refused` answers with the line it put on SCREEN, and
    # that is not a test-only accessor: the fitted line is echoed with
    # `history = false` and so is deliberately absent from `:messages`, leaving
    # the return the only witness of what a human actually saw. Pinning both
    # here also says what "unchanged" means -- one line, one copy, same text.
    it "echoes a refusal that fits with its prefix and nothing else" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        attach_ui(columns: 60)

        shown = inspector.exec_lua("return _G.__lain.review_refused(...)", ["save the review before marking it done"])

        expect(shown).to eq("lain: save the review before marking it done")
        expect(messages.lines.map(&:chomp)).to include("lain: save the review before marking it done")
      end
    end

    # BLOCKER 1 from the panel review, and the shape the cell count could not
    # see: `nvim_echo` renders a newline as a LINE BREAK, so a short sentence
    # carrying two of them outgrows a one-line message area while
    # `strdisplaywidth` -- which measures one axis -- reports it as fitting.
    # Fifty-three cells at 110 columns paged every time.
    #
    # Reachable in production, not theoretical. `CLI::HumanReplies#serve_editor_command`
    # rescues `StandardError, ScriptError` and puts `e.message` straight onto
    # this rail, and a `ScriptError#message` from Ruby 4's error formatter is
    # FIVE lines (measured: the source excerpt plus its carets).
    it "does not page on a refusal that is short but carries newlines" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        attach_ui(columns: 110)

        delivering("first line of the refusal\nsecond line names the remedy") do |mode|
          expect(mode).to include("blocking" => false)
          expect(mode["mode"]).not_to start_with("r")
        end
      end
    end

    # The same defect at its wider end, and the one that says the fix is not
    # "shorten harder": elision alone never helped here, because a head-and-tail
    # cut of a many-lined sentence still carries newlines in both halves.
    it "does not page on a refusal of many short lines, and folds them onto one" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        attach_ui(columns: 110)
        many = (1..8).map { |n| "line #{n} short" }.join("\n")

        delivering(many) { |mode| expect(mode).to include("blocking" => false) }
        shown = inspector.exec_lua("return _G.__lain.review_refused(...)", [many])

        expect(shown).not_to include("\n")
        expect(messages).to include("line 8 short")
      end
    end

    # The whole sentence keeps its own SHAPE in `:messages` -- folding is what
    # the one-line echo does, not what the record does, or a human sent to
    # `:messages` for a five-line syntax error would find it run together.
    it "records a multi-line refusal with its line breaks intact" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        attach_ui(columns: 110)

        delivering("first line of the refusal\nsecond line names the remedy") do |mode|
          expect(mode).to include("blocking" => false)
        end

        expect(messages.lines.map(&:chomp))
          .to include("lain: first line of the refusal", "second line names the remedy")
      end
    end

    # THE THIRD AXIS, and the one the two before it could not reach. A refusal
    # can outgrow the message area by CELLS, by BREAKS, or by being taller than
    # the whole editor -- and the third is a different prompt under a different
    # option. `-- More --` (`mode == "rm"`) is governed by 'more', not by
    # 'messagesopt', so swapping the latter never touched it; the recorded copy
    # is deliberately the UNFOLDED original, so once a sentence has `&lines`
    # lines it paged exactly as before. Measured: clean at 19 lines in a
    # 20-line pane and blocking at 20, clean at 49 in a 50-line pane and
    # blocking at 50, and `set nomore` makes it vanish -- which is what names
    # the mechanism rather than guessing at it. At 60 lines in a 20-line pane
    # twenty `<CR>`s did not clear it.
    #
    # Reachable by the same route as the two-line case: the real five-line
    # `ScriptError#message` blocks in any pane under six rows.
    #
    # The sting worth recording: the hit-enter comment above already named
    # `"rm"` as `-- More --` and no example exercised it. A named-but-unexercised
    # mode is how this got missed twice.
    #
    # Both halves are asserted here on purpose, so this one example is the
    # whole property: it does not block, AND `:messages` still holds the
    # original with its breaks intact -- because the cheap fix (folding the
    # recorded copy too) would buy the first by destroying the second.
    it "does not page on a refusal taller than the pane" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        attach_ui(columns: 110, lines: 10)
        tall = (1..20).map { |n| "line #{n} of a very tall refusal" }.join("\n")

        delivering(tall) do |mode|
          expect(mode).to include("blocking" => false)
          expect(mode["mode"]).not_to start_with("r")
        end

        expect(messages.lines.map(&:chomp))
          .to include("lain: line 1 of a very tall refusal", "line 20 of a very tall refusal")
      end
    end

    # BLOCKER 2 from the panel review. `recorded` swaps GLOBAL options -- two of
    # them now, 'messagesopt' and 'more' -- and an error escaping the echo they
    # wrap left the swap in place for the rest of the session. At which point
    # nvim stops prompting for ANY message from ANY source, and every over-long
    # or over-tall message silently vanishes instead. One failed refusal
    # disabling a whole session's message prompts is a worse failure than the
    # one this card set out to fix.
    #
    # BOTH options are read back, because a partial restore is the live failure
    # mode once there is more than one: restoring the option the last blocker
    # named while stranding the one this blocker named would pass a one-option
    # assertion and leave the `-- More --` prompt disabled forever.
    #
    # The fault is injected around `nvim_echo` itself because that is the only
    # thing between the swap and the restore; the injection is undone inside the
    # same lua block, so nothing leaks into the assertions below it.
    it "puts both swapped options back even when the recording echo raises, and keeps the prompt working" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        attach_ui(columns: 60)
        before = { "messagesopt" => inspector.evaluate("&messagesopt"), "more" => inspector.evaluate("&more") }

        after = inspector.exec_lua(<<~LUA, [overlong_refusal])
          local real = vim.api.nvim_echo
          vim.api.nvim_echo = function(...) real(...) error("injected: the echo failed", 0) end
          pcall(_G.__lain.review_refused, ...)
          vim.api.nvim_echo = real
          return { messagesopt = vim.o.messagesopt, more = vim.o.more and 1 or 0 }
        LUA

        expect(after).to eq(before)

        # What the leak actually costs, asserted rather than argued: nvim must
        # still prompt on an over-long message that has nothing to do with lain.
        inspector.session.notify(:nvim_exec_lua, "vim.api.nvim_echo({ { ('q'):rep(400) } }, true, {})", [])
        begin
          expect(settled_mode).to include("blocking" => true)
        ensure
          inspector.session.request(:nvim_input, "\r")
        end
      end
    end

    # The escalation trigger this card was given, as an example: a refusal that
    # names a condition but not its remedy is the loop this rail exists to
    # break, and every sentence on it puts the remedy LAST. So a shortened line
    # must keep both ends -- a head-first clip would drop exactly the half that
    # says what to do next.
    it "keeps both the condition and the remedy when it shortens the line" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        attach_ui(columns: 60)

        # The notify proves it does not block; only then is it safe to ask for
        # the answer, because a `request` into a paged rail never comes back.
        delivering(overlong_refusal) { |mode| expect(mode).to include("blocking" => false) }
        shown = inspector.exec_lua("return _G.__lain.review_refused(...)", [overlong_refusal])

        # Both ENDS of the sentence survive -- the condition it opens with and
        # the remedy it closes with -- and what went is the middle, marked.
        expect(shown).to start_with("lain: approve is")
        expect(shown).to end_with("judge regardless")
        expect(shown).to include(" ... ")
        expect(inspector.exec_lua("return vim.fn.strdisplaywidth(...)", [shown]))
          .to be <= inspector.evaluate("v:echospace")
      end
    end

    # On the wide sentence specifically: the traceback-free rule already
    # pinned for refusals that FIT must survive the path that shortens one.
    it "stays traceback-free on the path that shortens a refusal" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        attach_ui(columns: 60)

        delivering(overlong_refusal) { |mode| expect(mode).to include("blocking" => false) }

        expect(messages).to include("lain:")
        expect(messages).not_to include("stack traceback")
      end
    end
  end

  # HumanReplies as the Repl builds it, minus nothing that matters here: the
  # editor rail is the frontend's own inbox, and the review is bound exactly as
  # an opener would bind it.
  def replies_for(frontend, review, token)
    store = Lain::Store.new
    parent = Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
    tty = Lain::Frontend::TTY.new(channel: Lain::Channel.new, output: StringIO.new, input: StringIO.new,
                                  history_path: File.join(Dir.tmpdir, "lain-review-seam-history"))
    replies = Lain::CLI::HumanReplies.new(tty:, conductor: instance_double(Lain::CLI::Conductor),
                                          ask_human: Lain::Tools::AskHuman.new(parent:),
                                          questions: Async::Queue.new)
    replies.bind_editor(frontend.command_inbox)
    replies.bind_review(review, token:)
    replies
  end

  # Runs the reply surfaces for real and answers with the delta the review's
  # own promise resolved to -- the value the agent-side awaiter would get.
  def settled_delta(frontend, review, token, timeout: 8)
    Sync do |task|
      replies = replies_for(frontend, review, token)
      # session_surfaces: the editor rail is the conversation's.
      surfaces = replies.session_surfaces(task)
      deadline = Async::Clock.now + timeout
      task.sleep(0.02) until token.resolved? || Async::Clock.now > deadline
      surfaces.compact.each(&:stop)
      # Never `await` an unresolved promise here: it parks this fiber forever
      # and the whole example hangs with no failure to read. A settle that did
      # not happen is the finding, so say so.
      raise "the review never settled from the editor's done gesture" unless token.resolved?

      token.await
    end
  end

  # The review buffer's identity, or nil while the split has not opened yet.
  # `vim.fn.bufnr(path)` answers -1 until nvim has actually loaded the file, and
  # `vim.b[-1]` raises "Invalid buffer id: -1" -- an exec_lua error escapes
  # wait_until_editor instead of retrying, which is a flake, not a failure. Answering
  # nil is what makes the wait a wait.
  def review_state(path)
    inspector.exec_lua(<<~LUA, [path])
      local buf = vim.fn.bufnr(...)
      if buf == -1 then return nil end
      return {
        generation = vim.b[buf].lain_review_generation,
        slug = vim.b[buf].lain_review_epic_slug,
        focused = vim.api.nvim_get_current_buf() == buf,
      }
    LUA
  end

  # Settled only once the split is open, focused, AND stamped: three facts that
  # land in that order, and an example that read any one of them early would
  # assert against a half-opened review.
  def opened_review(path)
    wait_until_editor do
      state = review_state(path)
      state if state && state["generation"] && state["focused"]
    end
  end
end
