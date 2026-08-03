# frozen_string_literal: true

require "async"
require "fileutils"
require "neovim"
require "socket"
require "timeout"
require "tmpdir"

# The runtime.lua contract, protocol 3 (T5): User autocmds, b:lain_view on
# every lain:// buffer, the richer shared syntax, and lain://workspace's
# lua-side home. Same headless-nvim harness as neovim_spec.rb: a real editor
# on a unix socket, observed through a SECOND independent connection so every
# assertion is about what the editor actually did.
RSpec.describe Lain::Frontend::Neovim, :nvim do
  around do |example|
    socket = File.join(Dir.tmpdir, "lain-nvim-runtime-spec-#{Process.pid}-#{rand(1_000_000)}.sock")
    pid = spawn("nvim", "--headless", "--clean", "--listen", socket, out: File::NULL, err: File::NULL)
    Timeout.timeout(10) { sleep 0.02 until File.exist?(socket) }
    @socket = socket
    example.run
  ensure
    @inspector = nil
    if pid
      begin
        Process.kill("TERM", pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
    FileUtils.rm_f(socket)
  end

  let(:channel) { Lain::Channel.new }

  # Every buffer the runtime owns -- the contract surface this file pins.
  def all_views
    %w[lain://journal lain://timeline lain://workspace lain://diff lain://inbox lain://request]
  end

  # The six documented lain* groups (T5's AC): tool attribution, digests,
  # roles, event kinds, ages, sender attribution.
  def syntax_groups
    %w[lainToolName lainDigest lainRole lainEventKind lainAge lainSender]
  end

  def inspector
    @inspector ||= Neovim.attach_unix(@socket)
  end

  # The failure NAMES the buffers the editor actually has. A bare "timed out"
  # is unreadable when the cause is a buffer that was never created or was
  # created under the wrong name (E32 territory) -- the panel broke
  # nvim_buf_set_name deliberately and got three identical mystery timeouts.
  def wait_until(timeout: 8)
    deadline = Time.now + timeout
    result = yield
    until result
      raise "timed out waiting for editor state; nvim has #{live_buffer_names.inspect}" if Time.now > deadline

      sleep 0.02
      result = yield
    end
    result
  end

  def live_buffer_names
    inspector.exec_lua("return vim.tbl_map(vim.api.nvim_buf_get_name, vim.api.nvim_list_bufs())", [])
  rescue StandardError => e
    "unreadable (#{e.class})"
  end

  def buffer_lines(name)
    inspector.exec_lua(<<~LUA, [name])
      local buf = vim.fn.bufnr(...)
      if buf == -1 then return {} end
      return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    LUA
  end

  # Record every User LainAttach / LainRender payload BEFORE the frontend
  # attaches, exactly as a human's config would from their own dotfiles.
  def install_recorder
    inspector.exec_lua(<<~LUA, [])
      _G.__seen = { LainAttach = {}, LainRender = {} }
      for pattern, log in pairs(_G.__seen) do
        vim.api.nvim_create_autocmd("User", {
          pattern = pattern,
          callback = function(ev) table.insert(log, ev.data) end,
        })
      end
      return true
    LUA
  end

  def seen
    inspector.exec_lua("return _G.__seen", [])
  end

  describe "user autocmds get a stable surface" do
    it "fires User LainAttach and User LainRender with buffer names in the payload" do
      install_recorder
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until { seen["LainAttach"].any? && seen["LainRender"].any? }

        attach = seen["LainAttach"].first
        expect(attach["protocol"]).to eq(described_class::PROTOCOL)
        expect(attach["buffers"]).to match_array(all_views)

        # Priming posts every view at attach, so each named buffer announces
        # its own render, name in the payload.
        rendered = wait_until do
          names = seen["LainRender"].map { |data| data["name"] }
          names if (all_views - names).empty?
        end
        expect(rendered).to include(*all_views)
      end
    end

    it "sets b:lain_view on every lain:// buffer" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        views = wait_until do
          found = inspector.exec_lua(<<~LUA, [])
            local out = {}
            for _, buf in ipairs(vim.api.nvim_list_bufs()) do
              local name = vim.api.nvim_buf_get_name(buf)
              if name:match("^lain://") then out[name] = vim.b[buf].lain_view end
            end
            return out
          LUA
          found if found.size == all_views.size && found.values.none?(&:nil?)
        end

        expect(views.keys).to match_array(all_views)
        views.each { |name, view| expect(view).to eq(name) }
      end
    end

    # Panel probe G: the advertised dispatch pattern is
    #   autocmd FileType lain -> read vim.b.lain_view
    # and setting 'filetype' fires FileType SYNCHRONOUSLY, so the claim must
    # land BEFORE the filetype assignment in the buffer constructors -- a
    # claim after it leaves every FileType callback reading nil.
    it "sets b:lain_view before the FileType autocmd fires" do
      inspector.exec_lua(<<~LUA, [])
        _G.__ft_views = {}
        vim.api.nvim_create_autocmd("FileType", {
          pattern = "lain",
          callback = function(ev)
            table.insert(_G.__ft_views, vim.b[ev.buf].lain_view or "NIL-AT-FILETYPE-TIME")
          end,
        })
        return true
      LUA
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        # The four "lain"-filetype buffers: journal, timeline, workspace, inbox.
        views = wait_until do
          found = inspector.exec_lua("return _G.__ft_views", [])
          found if found.size >= 4
        end
        expect(views).to all(start_with("lain://"))
      end
    end
  end

  def group_links
    inspector.exec_lua(<<~LUA, [syntax_groups])
      local groups = ...
      local out = {}
      for _, group in ipairs(groups) do
        out[group] = vim.api.nvim_get_hl(0, { name = group }).link
      end
      return out
    LUA
  end

  describe "richer highlighting" do
    it "links all six documented lain* groups and defines their matches on lain buffers" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until { buffer_lines("lain://timeline").any? }

        links = group_links
        syntax_groups.each { |group| expect(links.fetch(group)).to be_a(String), "#{group} is not linked" }

        # The matches attach to the "lain" filetype buffers (timeline here).
        defined = inspector.exec_lua(<<~LUA, [])
          local buf = vim.fn.bufnr("lain://timeline")
          return vim.api.nvim_buf_call(buf, function()
            return vim.fn.execute("syntax list")
          end)
        LUA
        syntax_groups.each { |group| expect(defined).to include(group) }
      end
    end

    # `highlight default link`'s observable contract (nvim_get_hl does not
    # surface the default flag): a link the human's config already made wins;
    # the runtime's defaults must never clobber it.
    it "yields to a user's pre-existing links for every group" do
      syntax_groups.each { |group| inspector.command("highlight link #{group} ErrorMsg") }
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until { buffer_lines("lain://timeline").any? }
        group_links.each { |group, link| expect(link).to eq("ErrorMsg"), "#{group} was clobbered (links to #{link})" }
      end
    end
  end

  describe "workspace view has a lua-side home" do
    it "renders lain://workspace through set_view as a first-class lain buffer, not an orphan" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        # Session::Null has no reminders, so priming renders the empty state.
        # Before the fix, named_buf("lain://workspace") looked up a name the
        # runtime's tables never held: `vim.bo[buf].filetype = nil` silently
        # left the filetype "", so the buffer rendered but lived OUTSIDE the
        # lain contract -- no syntax, no view marker. That is the orphan.
        wait_until { buffer_lines("lain://workspace") == ["(no reminders)"] }

        state = inspector.exec_lua(<<~LUA, [])
          local buf = vim.fn.bufnr("lain://workspace")
          return {
            filetype = vim.bo[buf].filetype,
            buftype = vim.bo[buf].buftype,
            modifiable = vim.bo[buf].modifiable,
            lain_view = vim.b[buf].lain_view,
          }
        LUA

        expect(state["filetype"]).to eq("lain")
        expect(state["buftype"]).to eq("nofile")
        expect(state["modifiable"]).to be(false)
        expect(state["lain_view"]).to eq("lain://workspace")
      end
    end
  end

  describe "protocol lockstep" do
    it "bumps PROTOCOL to 6 and attaches without a mismatch warning" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until { inspector.get_var("lain_rpc_version") == "6" }
        expect(described_class::PROTOCOL).to eq("6")
        messages = inspector.exec_lua("return vim.api.nvim_exec2('messages', { output = true }).output", [])
        expect(messages).not_to include("mismatch")
      end
    end
  end

  # The review buffer's identity, or nil while the split has not opened yet.
  # `vim.fn.bufnr(path)` answers -1 until nvim has actually loaded the file, and
  # `vim.b[-1]` raises "Invalid buffer id: -1" -- an exec_lua error escapes
  # wait_until instead of retrying, which is a flake, not a failure. Answering
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
    wait_until do
      state = review_state(path)
      state if state && state["generation"] && state["focused"]
    end
  end

  def next_command(frontend)
    wait_until do
      frontend.command_inbox.pop(true)
    rescue ThreadError
      nil
    end
  end

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
      surfaces = replies.surfaces(task)
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

  # T15: the compose round trip against a REAL editor. lain://compose is the
  # one lain:// buffer nvim must be able to `:write`, and the two escalation
  # triggers the card names are both setup errors that show up here as nvim's
  # own E382/E32 -- so the buffer options are asserted, not assumed.
  # nil until the buffer exists at all, which is also how the "nothing opens it
  # uninvited" example asserts its absence.
  def compose_state
    inspector.exec_lua(<<~LUA, %w[buftype modifiable modified])
      local buf, out = vim.fn.bufnr("lain://compose"), {}
      if buf == -1 then return nil end
      for _, option in ipairs({ ... }) do out[option] = vim.bo[buf][option] end
      out.name = vim.api.nvim_buf_get_name(buf)
      out.lain_view = vim.b[buf].lain_view
      out.generation = vim.b[buf].lain_compose_generation
      return out
    LUA
  end

  # `:w` from inside the compose buffer -- the human's own gesture. Returned as
  # the pcall pair so a failing write (E382 on nofile, E32 unnamed) surfaces as
  # its message rather than as a mystery timeout.
  def write_compose
    inspector.exec_lua(<<~LUA, [])
      local buf = vim.fn.bufnr("lain://compose")
      local ok, err = pcall(function()
        vim.api.nvim_buf_call(buf, function() vim.cmd("write") end)
      end)
      return { ok = ok, err = tostring(err) }
    LUA
  end

  def edit_compose(lines)
    inspector.exec_lua(<<~LUA, [lines])
      local lines = ...
      local buf = vim.fn.bufnr("lain://compose")
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      return true
    LUA
  end

  def unload_compose
    inspector.exec_lua(<<~LUA, [])
      local buf = vim.fn.bufnr("lain://compose")
      vim.api.nvim_buf_delete(buf, { force = true })
      return true
    LUA
  end

  describe "the compose round trip" do
    let(:compose) { frontend.compose }
    let(:frontend) { described_class.new(channel:, socket_path: @socket) }

    it "opens the current draft in a writable, named lain://compose buffer" do
      frontend.run do
        wait_until { buffer_lines("lain://journal").any? }
        expect(compose.open("draft text")).to eq(compose.marker)

        state = wait_until { compose_state }
        expect(buffer_lines("lain://compose")).to eq(["draft text"])
        expect(state["name"]).to eq("lain://compose")
        # E382 (nofile refuses :write, so BufWriteCmd never fires) and E32 (an
        # unnamed acwrite buffer) are the two ways this setup goes wrong.
        expect(state["buftype"]).to eq("acwrite")
        expect(state["modifiable"]).to be(true)
        expect(state["modified"]).to be(false)
        expect(state["lain_view"]).to eq("lain://compose")
        expect(state["generation"]).to eq(1)
      end
    end

    it "returns the edited text to the prompt when the buffer is written" do
      frontend.run do
        compose.open("draft text")
        wait_until { compose_state }

        edit_compose(["edited text", "second line"])
        # include, not `["ok"]).to be(true)`: on failure this prints nvim's own
        # message (E382 when buftype regresses to nofile) instead of discarding
        # it behind "Expected false to equal true".
        expect(write_compose).to include("ok" => true)

        expect(compose.settle(compose.marker)).to eq("edited text\nsecond line")
        # The write is answered, not persisted: the buffer is clean again so
        # nvim never asks the human about unsaved changes on the way out.
        expect(compose_state["modified"]).to be(false)
      end
    end

    # PANEL BLOCKER 1: unloading the buffer must send NOTHING. The draft is
    # kept for recovery, never dispatched -- the human decided against it.
    it "sends nothing when the buffer is unloaded without being written" do
      frontend.run do
        compose.open("draft text")
        wait_until { compose_state }

        unload_compose

        expect(compose.settle(compose.marker) { :re_prompted }).to eq(:re_prompted)
        expect(compose.draft).to eq("draft text")
      end
    end

    # PANEL BLOCKER 2: clearing 'modified' before the rpcrequest meant a write
    # that never reached lain still looked saved, so nvim would not warn on :q
    # and the text was simply gone. The buffer must stay dirty when the write
    # fails.
    it "leaves the buffer dirty when the write cannot reach lain" do
      frontend = described_class.new(channel:, socket_path: @socket)
      frontend.run do
        frontend.compose.open("draft")
        wait_until { compose_state }
      end
      # frontend.run has returned: the RPC thread is stopped, the channel gone.

      edit_compose(["text the human typed and thinks is saved"])
      result = write_compose

      expect(result["ok"]).to be(false)
      expect(compose_state).to include("modified" => true)
    end

    # The precise consequence of BLOCKER 2's fix, measured rather than claimed:
    # a failed write leaves the buffer 'modified', so nvim refuses to DISCARD
    # it (E89) -- but plain :q still succeeds, because bufhidden = "hide" makes
    # quitting a window a hide, not an abandon. My first comment here said :q
    # was refused; it is not.
    it "refuses to discard an unsaved compose buffer, though :q still hides it" do
      frontend = described_class.new(channel:, socket_path: @socket)
      frontend.run do
        frontend.compose.open("draft")
        wait_until { compose_state }
      end

      edit_compose(["text the human typed and thinks is saved"])
      write_compose

      discard = inspector.exec_lua(<<~LUA, [])
        local buf = vim.fn.bufnr("lain://compose")
        local ok, err = pcall(vim.cmd, "bdelete " .. buf)
        return { ok = ok, err = tostring(err) }
      LUA
      expect(discard["ok"]).to be(false)
      expect(discard["err"]).to include("E89")
      expect(compose_state).to include("modified" => true)
    end

    # PANEL SHOULD-FIX 4: the generation stamped on the buffer is what lets a
    # late answer from an earlier compose be dropped rather than mistaken for
    # this one's.
    it "stamps each compose with its own generation, and reuses the one buffer" do
      frontend.run do
        compose.open("draft A")
        wait_until { compose_state }
        expect(compose_state["generation"]).to eq(1)
        buffers = live_buffer_names

        compose.settle("changed my mind")
        compose.open("draft B")
        wait_until { buffer_lines("lain://compose") == ["draft B"] }

        expect(compose_state["generation"]).to eq(2)
        expect(live_buffer_names).to match_array(buffers)
      end
    end

    # PANEL P6: renders and the compose post share ONE queue and ONE thread, so
    # a compose racing a flood of renders must neither reorder nor touch the
    # session off-thread. The compose post is also the only non-blocking push
    # onto that queue, which is exactly what a flood would otherwise stall.
    it "survives a compose posted into a flood of concurrent renders" do
      frontend.run do
        wait_until { buffer_lines("lain://journal").any? }
        flood = Thread.new do
          400.times do |i|
            channel.push(Lain::Telemetry::ToolOutput.new(tool_use_id: "t#{i}", stream: :stdout, bytes: "render #{i}"))
          end
        end
        marker = compose.open("draft under load")
        flood.join

        wait_until { buffer_lines("lain://compose") == ["draft under load"] }
        edit_compose(["answer under load"])
        expect(write_compose).to include("ok" => true)
        expect(Timeout.timeout(10) { compose.settle(marker) }).to eq("answer under load")
      end
    end

    # PANEL P3overlap: the second #open reuses the SAME nvim buffer (found by
    # name), so the first compose's BufUnload never fires and only the
    # generation separates the two round trips.
    it "runs two round trips in a row without crossing their answers" do
      frontend.run do
        %w[A B].each do |round|
          marker = compose.open("draft #{round}")
          wait_until { buffer_lines("lain://compose") == ["draft #{round}"] }
          edit_compose(["answer #{round}"])
          expect(write_compose).to include("ok" => true)
          expect(Timeout.timeout(10) { compose.settle(marker) }).to eq("answer #{round}")
        end
      end
    end

    it "keeps lain://compose out of the primed buffer set, so nothing opens it uninvited" do
      install_recorder

      frontend.run do
        wait_until do
          names = seen["LainRender"].map { |data| data["name"] }
          names if (all_views - names).empty?
        end

        expect(seen["LainAttach"].first["buffers"]).to match_array(all_views)
        expect(compose_state).to be_nil
      end
    end

    # PANEL SHOULD-FIX 6, recorded rather than defended against: `:wall` and
    # autosave plugins DO fire BufWriteCmd, and the round trip takes that as
    # the human's answer. Pinned so the behaviour is a known limitation rather
    # than a surprise -- lain attaches to the human's own nvim, plugins and all.
    it "settles on a :wall mid-compose, half-typed text and all (known limitation)" do
      frontend.run do
        compose.open("draft")
        wait_until { compose_state }
        edit_compose(["half a thought, still typ"])
        inspector.exec_lua("pcall(function() vim.cmd('wall') end)", [])

        expect(compose.settle(compose.marker)).to eq("half a thought, still typ")
      end
    end

    # The positive half of the same axis: bufhidden=hide plus nvim's default
    # 'hidden' means autowriteall + a buffer switch does NOT fire a write, so
    # the compose is still in flight and the buffer still dirty. Asserted on
    # the EDITOR's state rather than through #settle, which would (correctly)
    # block for the whole bound with no answer to find.
    it "does not settle when autowriteall meets a buffer switch" do
      frontend.run do
        compose.open("draft")
        wait_until { compose_state }
        inspector.exec_lua("vim.o.autowriteall = true", [])
        edit_compose(["half a thought, still typ"])
        inspector.exec_lua(<<~LUA, [])
          vim.api.nvim_buf_call(vim.fn.bufnr("lain://compose"), function()
            vim.cmd("buffer lain://journal")
          end)
        LUA
        sleep 0.3

        expect(compose_state).to include("modified" => true)
        expect(compose).to be_pending
      end
    end
  end

  # T12: lain://question against a REAL editor. It is `acwrite` for
  # lain://compose's reason -- `:w` IS the submit -- and it is the one lain://
  # buffer whose write can be REFUSED, because the grammar reads the document
  # back BEFORE the ack. nil until the buffer exists at all.
  #
  # expandtab/shiftwidth ride here rather than being assumed: the comment slot
  # is two-space-indented prose and {Question::Document} refuses a tab-indented
  # line BY NAME rather than dedenting it, so a human whose own config indents
  # with tabs would write a comment the grammar then rejects on `:w`.
  def question_state
    inspector.exec_lua(<<~LUA, %w[buftype filetype modifiable modified expandtab shiftwidth])
      local buf, out = vim.fn.bufnr("lain://question"), {}
      if buf == -1 then return nil end
      for _, option in ipairs({ ... }) do out[option] = vim.bo[buf][option] end
      out.name = vim.api.nvim_buf_get_name(buf)
      out.lain_view = vim.b[buf].lain_view
      out.digest = vim.b[buf].lain_question_digest
      return out
    LUA
  end

  # `:w` from inside the question buffer -- the human's own gesture. Returned as
  # the pcall pair, because every failure mode this card owns (a document the
  # grammar refused, a write nobody typed, a write that reached nobody) arrives
  # as a raising write. `bang:` is `:w!`, the deliberate override.
  def write_question(bang: false)
    inspector.exec_lua(<<~LUA, [bang ? "!" : ""])
      local bang = ...
      local buf = vim.fn.bufnr("lain://question")
      local ok, err = pcall(function()
        vim.api.nvim_buf_call(buf, function() vim.cmd("write" .. bang) end)
      end)
      return { ok = ok, err = tostring(err) }
    LUA
  end

  def edit_question(lines)
    inspector.exec_lua(<<~LUA, [lines])
      local lines = ...
      local buf = vim.fn.bufnr("lain://question")
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      return true
    LUA
  end

  def unload_question
    inspector.exec_lua(<<~LUA, [])
      local buf = vim.fn.bufnr("lain://question")
      vim.api.nvim_buf_delete(buf, { force = true })
      return true
    LUA
  end

  # foldclosed() per line, read in the window that HOLDS the buffer -- never
  # nvim_buf_call, whose temporary window carries no window-local fold options
  # at all, because folds are a window fact. `close_all:` is OFF by default so
  # the AT-REST state is observable: a helper that always zM'd was how the
  # panel found the document opening with the human's cursor inside a closed
  # fold, asserted nowhere.
  def question_fold_closes(close_all: false)
    inspector.exec_lua(<<~LUA, [close_all])
      local close_all = ...
      local win = vim.fn.win_findbuf(vim.fn.bufnr("lain://question"))[1]
      if win == nil then return {} end
      vim.api.nvim_set_current_win(win)
      if close_all then vim.cmd("normal! zM") end
      return vim.tbl_map(vim.fn.foldclosed, vim.fn.range(1, vim.fn.line("$")))
    LUA
  end

  # One entry per fold the surface actually built: a line IS a fold start when
  # the fold closing over it starts at itself. This one DOES close everything
  # first, deliberately -- enumerating folds is what it is for, and an open fold
  # reports nothing at all through foldclosed(). The at-rest example beside it
  # is what pins the state the human actually lands in.
  def question_fold_starts
    question_fold_closes(close_all: true).each_with_index.select { |start, i| start == i + 1 }.map(&:first)
  end

  def question_cursor
    inspector.exec_lua(<<~LUA, [])
      local win = vim.fn.win_findbuf(vim.fn.bufnr("lain://question"))[1]
      return win and vim.api.nvim_win_get_cursor(win) or nil
    LUA
  end

  # ]] and [[ as the QUESTION buffer defines them. nvim's own markdown ftplugin
  # maps both, so "the motion works" is not evidence lain bound anything.
  def question_motions
    inspector.exec_lua(<<~LUA, [])
      local out = {}
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(vim.fn.bufnr("lain://question"), "n")) do
        if map.lhs == "]]" or map.lhs == "[[" then out[map.lhs] = map.desc end
      end
      return out
    LUA
  end

  describe "the question round trip" do
    def option(id, label) = Lain::Question::Option.new(id:, label:)

    def question(id, body, options: [], arity: Lain::Question::SINGLE)
      Lain::Question.new(id:, body:, options:, arity:)
    end

    let(:storage) do
      question("storage", "Which storage engine?",
               options: [option("pg", "Postgres"), option("sqlite", "SQLite")])
    end
    let(:retention) do
      question("retention", "How long do we keep events?", arity: Lain::Question::MULTI,
                                                           options: [option("30d", "Thirty days"),
                                                                     option("forever", "Forever")])
    end
    let(:notes) { question("notes", "Anything else?") }
    let(:asked) { Lain::Question::Set.new(questions: [storage]) }
    let(:three) { Lain::Question::Set.new(questions: [storage, retention, notes]) }
    let(:digest) { "blake3:c0ffee" }
    let(:document) { rendered(asked) }
    let(:ticked) { document.map { |line| line.sub("- [ ] `pg`", "- [x] `pg`") } }
    # The abandon notice has no caller to return to, so the notifier IS the
    # observable -- a Queue rather than an Array because it is pushed from the
    # RPC thread and read from this one.
    let(:notices) { Thread::Queue.new }
    let(:frontend) do
      described_class.new(channel:, socket_path: @socket, question_notify: notices.method(:push))
    end

    # The document as the buffer holds it: one Array element per line, no
    # terminators -- {QuestionView#lines_of}'s own split.
    def rendered(set) = Lain::Question::Document.unanswered(set).lines.map { |line| line.delete_suffix("\n") }

    def opened_question(set)
      expect(frontend.question_view.open(set, digest)).to be_nil
      wait_until { question_state }
    end

    it "opens a set as a writable markdown buffer holding its rendered document" do
      frontend.run do
        wait_until { buffer_lines("lain://journal").any? }
        state = opened_question(asked)

        expect(buffer_lines("lain://question")).to eq(document)
        expect(state["name"]).to eq("lain://question")
        expect(state["filetype"]).to eq("markdown")
        # E382 (nofile refuses :write, so BufWriteCmd never fires) and E32 (an
        # unnamed acwrite buffer) are the two ways this setup goes wrong.
        expect(state["buftype"]).to eq("acwrite")
        expect(state["modifiable"]).to be(true)
        expect(state["modified"]).to be(false)
        expect(state["lain_view"]).to eq("lain://question")
        expect(state["digest"]).to eq(digest)
        expect(state["expandtab"]).to be(true)
        expect(state["shiftwidth"]).to eq(2)
      end
    end

    # Folds do not come for free: they install only where RECORD_START names the
    # view. Without a question entry the human gets whatever their own markdown
    # config does, and the "folded" claim is false.
    it "carries one fold per question, each starting at that question's heading" do
      frontend.run do
        wait_until { buffer_lines("lain://journal").any? }
        opened_question(three)

        lines = buffer_lines("lain://question")
        headings = lines.each_index.select { |index| lines[index].start_with?("## `") }.map { |index| index + 1 }
        expect(headings.size).to eq(3)
        expect(question_fold_starts).to eq(headings)
        # The motions ride RECORD_START too, and lain's own must win: nvim's
        # markdown ftplugin binds ]] and [[ on this filetype, so without the
        # explicit bind the human gets markdown's sections, not lain's records.
        expect(question_motions).to eq("]]" => "lain: next record", "[[" => "lain: previous record")
      end
    end

    # A form is not a log. The older-closed/newest-open default is right for a
    # timeline the human follows downward and wrong here: it handed them a
    # document to fill in with the cursor on line 1 INSIDE a closed fold, two
    # collapsed summaries above the only open question. A `dd` there deletes a
    # whole question the human never saw. Asserted WITHOUT zM, which is the
    # whole point -- the previous spec could not see this state at all.
    it "comes to rest on the first question, open, with the cursor in it" do
      frontend.run do
        wait_until { buffer_lines("lain://journal").any? }
        opened_question(three)

        lines = buffer_lines("lain://question")
        headings = lines.each_index.select { |index| lines[index].start_with?("## `") }.map { |index| index + 1 }
        closes = question_fold_closes

        expect(question_cursor).to eq([1, 0])
        expect(closes.first(headings[1] - 1)).to all(eq(-1))
        expect(closes[headings[1] - 1]).to eq(headings[1])
        expect(closes[headings[2] - 1]).to eq(headings[2])
      end
    end

    # The third leg of the untouched-write rule, and the ordinary path: ANY real
    # edit makes a plain `:w` work exactly as before.
    it "hands the edited lines and the set's digest to Ruby when the buffer is written" do
      frontend.run do
        wait_until { buffer_lines("lain://journal").any? }
        opened_question(asked)

        edit_question(ticked)
        expect(write_question).to include("ok" => true)

        verb, args = next_command(frontend)
        expect(verb).to eq("question_answered")
        expect(args.first).to eq(digest)
        expect(args.last.fetch("storage").option_ids).to eq(["pg"])
        # The write is answered, not persisted: the buffer is clean again.
        expect(question_state).to include("modified" => false)
      end
    end

    # The central AC, and the one the ack-before-route path could not satisfy:
    # a MalformedDocument must reach the editor as the write's own failure.
    it "fails the write naming the line, leaving the human's text in a dirty buffer" do
      frontend.run do
        wait_until { buffer_lines("lain://journal").any? }
        opened_question(asked)

        typed = ticked + ["not a line this grammar has a slot for"]
        edit_question(typed)
        result = write_question

        expect(result["ok"]).to be(false)
        expect(result["err"]).to include("line #{typed.size}")
        expect(question_state).to include("modified" => true)
        expect(buffer_lines("lain://question")).to eq(typed)
        # Nothing was submitted, so the set is still the one this buffer answers.
        expect(frontend.question_view.digest).to eq(digest)
      end
    end

    # `:w` is the gesture, and a write NOBODY TYPED is not that gesture. An
    # untouched document parses perfectly -- AnswerSet fills an untouched
    # question in as explicitly unanswered, by design -- so a stock `:wall` or
    # any autosave plugin used to tell the model the human declined every
    # question, close the view, and answer their real `:w` with STALE. That is
    # not blocking a submit (ruling 9); it is refusing to invent intent.
    it "refuses a write nobody typed into, and names the override" do
      frontend.run do
        wait_until { buffer_lines("lain://journal").any? }
        opened_question(three)

        result = write_question

        expect(result["ok"]).to be(false)
        expect(result["err"]).to include(":w!")
        # The refusal never even reaches Ruby -- the editor knows the human
        # typed nothing -- so nothing can be queued, and a non-blocking pop is
        # the assertion rather than a timeout somebody has to wait out.
        expect { frontend.command_inbox.pop(true) }.to raise_error(ThreadError)
        expect(frontend.question_view.digest).to eq(digest)
        expect(buffer_lines("lain://question")).to eq(rendered(three))
      end
    end

    # Declining everything stays possible, and stays CHOSEN.
    it "submits an untouched document on :w!, answering every question as unanswered" do
      frontend.run do
        wait_until { buffer_lines("lain://journal").any? }
        opened_question(three)

        expect(write_question(bang: true)).to include("ok" => true)

        verb, args = next_command(frontend)
        expect(verb).to eq("question_answered")
        expect(args.last.map(&:option_ids)).to eq([[], [], []])
        expect(args.last.map(&:comment)).to eq([nil, nil, nil])
        expect(frontend.question_view).not_to be_open
      end
    end

    it "leaves the buffer dirty when the write cannot reach lain" do
      frontend.run do
        wait_until { buffer_lines("lain://journal").any? }
        opened_question(asked)
      end
      # frontend.run has returned: the RPC thread is stopped, the channel gone.

      edit_question(ticked)
      result = write_question

      expect(result["ok"]).to be(false)
      expect(result["err"]).to include("NOT saved")
      expect(question_state).to include("modified" => true)
    end

    it "signals abandon carrying the set's digest when the buffer is unloaded" do
      frontend.run do
        wait_until { buffer_lines("lain://journal").any? }
        opened_question(asked)

        unload_question

        notice = wait_until do
          notices.pop(true)
        rescue ThreadError
          nil
        end
        expect(notice).to eq(Lain::Frontend::Neovim::QuestionView::ABANDONED_NOTICE)
        expect(frontend.question_view).not_to be_open
      end
    end
  end

  # Show a lain:// buffer in the (sole headless) window -- what a human's
  # :buffer lain://timeline does -- so the window-local fold surface applies.
  def display(name)
    inspector.exec_lua(<<~LUA, [name])
      local buf = vim.fn.bufnr(...)
      vim.api.nvim_win_set_buf(0, buf)
      return buf
    LUA
  end

  # foldclosed() per line in the displaying window: -1 for open, else the
  # closed fold's first line -- the observable the fold examples assert on.
  def fold_closes(count)
    inspector.exec_lua(<<~LUA, [count])
      local count, out = ..., {}
      for lnum = 1, count do out[lnum] = vim.fn.foldclosed(lnum) end
      return out
    LUA
  end

  def window_fold_options
    inspector.exec_lua("return { method = vim.wo.foldmethod, expr = vim.wo.foldexpr, text = vim.wo.foldtext }", [])
  end

  def render_timeline(lines)
    inspector.exec_lua("local lines = ...; _G.__lain.set_view('lain://timeline', lines); return true", [lines])
  end

  def fold_open_at(line)
    inspector.exec_lua(<<~LUA, [line])
      local line = ...
      vim.api.nvim_win_set_cursor(0, { line, 0 })
      vim.cmd("silent! foldopen!")
      return true
    LUA
  end

  describe "folds" do
    let(:turns) { ["user: hi", "assistant: hello there", "user: and then?", "assistant: done"] }

    it "installs the foldexpr surface on record-shaped lain buffers" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until { buffer_lines("lain://timeline").any? }
        display("lain://timeline")

        options = wait_until do
          opts = window_fold_options
          opts if opts["method"] == "expr"
        end
        expect(options["expr"]).to include("__lain.foldexpr")
        expect(options["text"]).to include("__lain.foldtext")
      end
    end

    # The amended contract: the older-closed/newest-open DEFAULT applies once,
    # at first display; a render may at most re-open the newest record. The
    # editor itself preserves per-fold open/closed state across a whole-buffer
    # replace (panel probe I), so preservation -- not re-defaulting -- is what
    # a render must exhibit.
    it "defaults once at display, then preserves fold state across re-renders" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until { buffer_lines("lain://timeline").any? }
        render_timeline(turns)
        display("lain://timeline")
        wait_until { fold_closes(4) == [1, 2, 3, -1] }

        # A new turn arrives open; the closed older turns stay closed, the
        # previously-open turn stays open -- no forced re-close.
        render_timeline(turns + ["user: one more"])
        wait_until { fold_closes(5) == [1, 2, 3, -1, -1] }
        messages = inspector.exec_lua("return vim.api.nvim_exec2('messages', { output = true }).output", [])
        expect(messages).not_to match(/E\d+/)
      end
    end

    # Panel probe H: a turn the human opened by hand must survive the agent's
    # next render -- the stomp this fix round exists to kill.
    it "keeps a manually opened turn open across a re-render" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until { buffer_lines("lain://timeline").any? }
        render_timeline(turns)
        display("lain://timeline")
        wait_until { fold_closes(4) == [1, 2, 3, -1] }

        fold_open_at(2)
        wait_until { fold_closes(4) == [1, -1, 3, -1] }

        render_timeline(turns + ["user: one more"])
        wait_until { fold_closes(5) == [1, -1, 3, -1, -1] }
      end
    end

    # Probe H's zR case: opening everything is a foldlevel statement, and a
    # render must not write foldlevel back down.
    it "lets zR stick across renders" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until { buffer_lines("lain://timeline").any? }
        render_timeline(turns)
        display("lain://timeline")
        wait_until { fold_closes(4) == [1, 2, 3, -1] }

        inspector.exec_lua("vim.cmd('normal! zR'); return true", [])
        render_timeline(turns + ["user: one more"])
        wait_until { buffer_lines("lain://timeline").size == 5 }
        expect(inspector.exec_lua("return vim.wo.foldlevel", [])).to be >= 1
        expect(fold_closes(5)).to eq([-1, -1, -1, -1, -1])
      end
    end

    it "groups journal lines by attribution run and preserves runs across appends" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        channel.push(Lain::Telemetry::ToolOutput.new(tool_use_id: "t1", stream: :stdout, bytes: "a\nb"))
        channel.push(Lain::Telemetry::ToolOutput.new(tool_use_id: "t2", stream: :stdout, bytes: "c\nd"))
        wait_until { buffer_lines("lain://journal").size == 4 }
        display("lain://journal")

        # One fold per [id stream] run: t1's two lines closed together, t2's open.
        wait_until { fold_closes(4) == [1, 1, -1, -1] }

        # An append never re-closes what the display state holds (probe H).
        channel.push(Lain::Telemetry::ToolOutput.new(tool_use_id: "t3", stream: :stdout, bytes: "e"))
        wait_until { buffer_lines("lain://journal").size == 5 && fold_closes(5) == [1, 1, -1, -1, -1] }
      end
    end

    # Panel probe J: window-local fold options are sticky per window -- when
    # the human navigates the window away to a normal buffer, lain's expr
    # surface must not ride along and flatten their own folds. The :vsplit is
    # the probe's sharpest case: a split copies window OPTIONS but NOT window
    # VARIABLES, so the new window carries lain's foldexpr with no saved
    # prior options -- an orphaned surface that must self-heal on leave.
    it "restores the window's prior fold options when it leaves the lain view, split windows included" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until { buffer_lines("lain://timeline").any? }
        render_timeline(turns)
        display("lain://timeline")
        wait_until { window_fold_options["method"] == "expr" }

        options = inspector.exec_lua(<<~LUA, [])
          vim.cmd("vsplit")
          local buf = vim.api.nvim_create_buf(true, false)
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "def outer", "  a = 1", "end" })
          vim.api.nvim_win_set_buf(0, buf)
          return { method = vim.wo.foldmethod, expr = vim.wo.foldexpr }
        LUA

        expect(options["method"]).to eq("manual")
        expect(options["expr"]).not_to include("__lain")
      end
    end

    # Panel probe I: the kill switch must un-install LIVE -- flipping
    # vim.g.lain_fold mid-session restores the window and drops lain's folds
    # on the next fold event, not merely at the next fresh display.
    it "un-installs live when vim.g.lain_fold flips to false mid-session" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until { buffer_lines("lain://timeline").any? }
        render_timeline(turns)
        display("lain://timeline")
        wait_until { fold_closes(4) == [1, 2, 3, -1] }

        inspector.exec_lua("vim.g.lain_fold = false; return true", [])
        render_timeline(turns + ["user: one more"])

        wait_until { window_fold_options["method"] == "manual" }
        expect(fold_closes(5)).to eq([-1, -1, -1, -1, -1])
      end
    end

    it "stays hands-off when vim.g.lain_fold is false" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until { buffer_lines("lain://timeline").any? }
        inspector.exec_lua("vim.g.lain_fold = false; return true", [])
        display("lain://timeline")
        render_timeline(turns)

        wait_until { buffer_lines("lain://timeline") == turns }
        expect(window_fold_options["method"]).to eq("manual")
        expect(fold_closes(4)).to eq([-1, -1, -1, -1])
      end
    end
  end
end
