# frozen_string_literal: true

# `runtime/60_question.lua` -- lain://question: the document a set resolves to, and
# the gestures that move through it.
RSpec.describe Lain::Frontend::Neovim, :nvim do
  include NeovimRuntime

  around { |example| headless_editor("lain-nvim-question-spec") { example.run } }

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
      wait_until_editor { question_state }
    end

    it "opens a set as a writable markdown buffer holding its rendered document" do
      frontend.run do
        wait_until_editor { buffer_lines("lain://journal").any? }
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
        wait_until_editor { buffer_lines("lain://journal").any? }
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
        wait_until_editor { buffer_lines("lain://journal").any? }
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
        wait_until_editor { buffer_lines("lain://journal").any? }
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
        wait_until_editor { buffer_lines("lain://journal").any? }
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
        wait_until_editor { buffer_lines("lain://journal").any? }
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
        wait_until_editor { buffer_lines("lain://journal").any? }
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
        wait_until_editor { buffer_lines("lain://journal").any? }
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
        wait_until_editor { buffer_lines("lain://journal").any? }
        opened_question(asked)

        unload_question

        notice = wait_until_editor do
          notices.pop(true)
        rescue ThreadError
          nil
        end
        expect(notice).to eq(Lain::Frontend::Neovim::QuestionView::ABANDONED_NOTICE)
        expect(frontend.question_view).not_to be_open
      end
    end
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
end
