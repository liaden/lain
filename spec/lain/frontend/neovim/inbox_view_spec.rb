# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

# I6: the human inbox. lain://inbox IS {Event::Projection#pending}("human")
# rendered -- a :message addressed to the human lists until a committed :turn
# names its digest a causal parent (the delivery commit; see agent_spec's
# "ask_human consumption" examples for the production emitter). A REPLY alone
# never retires an item: it is a :message, and consumption counts :turn edges
# ONLY -- the same pinned rule {StatusFeed}'s inbox_count follows, which is
# what the parity examples at the bottom hold the two surfaces to.
RSpec.describe Lain::Frontend::Neovim::InboxView do
  let(:store) { Lain::Store.new }
  # A fixed wall clock so age rendering is arithmetic, never a race.
  let(:now) { Time.at(1_000) }
  let(:view) { described_class.new(store:, clock: -> { now }) }

  def text(body) = [{ "type" => "text", "text" => body }]

  def question_record(digest, from: "orchestrator", question: "which db?", to: "human")
    Lain::Telemetry::Message.new(digest:, kind: :message, from:, to:,
                                 payload: { "question" => question }, causal_parents: [], correlation: nil)
  end

  def turn_usage(digest)
    Lain::Telemetry::TurnUsage.new(digest:, model: "m", stop_reason: :end_turn, usage: {})
  end

  # A real Q :message in the shared Store, AskHuman's own write shape -- the
  # Store enforces referential integrity over causal edges, so a turn citing a
  # question needs the question actually resident, exactly as in production.
  def stored_question(question: "which db?", from: "orchestrator")
    parent = Lain::Timeline.empty(store:).commit(role: :user, content: text("seed #{question}"))
    Lain::Event::ChainWriter.new.put(parent, kind: :message, from:, to: "human",
                                             causal_parents: [], body: { "question" => question })
  end

  # A committed chain whose head turn cites `digests` -- the delivery commit's
  # shape, synthesized here (the Agent's own emitter is pinned in agent_spec).
  def citing_timeline(*digests)
    Lain::Timeline.empty(store:)
                  .commit(role: :user, content: text("hi"))
                  .commit(role: :assistant, content: text("asking"))
                  .commit(role: :user, content: [{ "type" => "tool_result", "tool_use_id" => "tu_1",
                                                   "content" => "the answer" }],
                          causal_parents: digests)
  end

  describe "#initial" do
    it "exists from attach with the at-rest empty note" do
      expect(view.initial).to eq(described_class::NAME => ["(no questions pending)"])
    end
  end

  describe "arrivals" do
    it "lists a question addressed to the human with its sender" do
      lines = view.update(question_record("blake3:q1", from: "researcher", question: "deploy now?"))

      expect(lines.size).to eq(1)
      expect(lines.first).to include("researcher").and include("deploy now?")
    end

    it "lists two questions from two agents, each with sender and age" do
      view.update(question_record("blake3:q1", from: "researcher", question: "deploy now?"))
      lines = view.update(question_record("blake3:q2", from: "orchestrator", question: "which db?"))

      expect(lines.size).to eq(2)
      expect(lines.join("\n")).to include("researcher").and include("orchestrator")
      expect(lines).to all(match(/\b\d+[smh]\b/))
    end

    it "renders age from the injected clock, not a live one" do
      wall = Time.at(880)
      early = described_class.new(store:, clock: -> { wall })
      early.update(question_record("blake3:q1"))
      wall = Time.at(1_000)

      lines = early.update(question_record("blake3:q2", from: "late"))

      expect(lines.first).to include("2m")
    end

    it "ignores a message addressed elsewhere" do
      expect(view.update(question_record("blake3:w1", to: "worker"))).to be_nil
    end

    it "ignores a redelivered question (same digest, no phantom second item)" do
      view.update(question_record("blake3:q1"))

      expect(view.update(question_record("blake3:q1"))).to be_nil
    end
  end

  describe "the pinned consumption rule (a REPLY is a :message, not consumption)" do
    it "keeps an answered question listed until a :turn cites it" do
      view.update(question_record("blake3:q1"))

      reply = Lain::Telemetry::Message.new(digest: "blake3:a1", kind: :message, from: "human",
                                           to: "orchestrator", payload: { "answer" => "postgres" },
                                           causal_parents: ["blake3:q1"], correlation: nil)

      expect(view.update(reply)).to be_nil
    end

    it "retires the item when a TurnUsage names a head whose chain cites it" do
      question = stored_question
      view.update(Lain::Telemetry::Message.from_event(question))

      lines = view.update(turn_usage(citing_timeline(question.digest).head_digest))

      expect(lines).to eq(["(no questions pending)"])
    end

    it "never lists a question a turn already consumed (out-of-order delivery)" do
      question = stored_question
      view.update(turn_usage(citing_timeline(question.digest).head_digest))

      expect(view.update(Lain::Telemetry::Message.from_event(question))).to be_nil
    end

    it "returns nil for a turn that consumes nothing pending" do
      view.update(question_record("blake3:q1"))
      unrelated = stored_question(question: "unrelated?")

      expect(view.update(turn_usage(citing_timeline(unrelated.digest).head_digest))).to be_nil
    end

    it "survives a TurnUsage whose digest the store cannot resolve (drain-thread safety)" do
      view.update(question_record("blake3:q1"))

      expect { view.update(turn_usage("blake3:absent")) }.not_to raise_error
      expect(view.update(turn_usage("blake3:absent"))).to be_nil
    end
  end

  # AC: "the state feed's inbox_count matches the pending projection after each
  # arrival and drain." One logical stream, two consumers on their production
  # diets: StatusFeed folds the Event log, the view folds the tee's records
  # (Telemetry::Message + TurnUsage over the shared Store). They must agree at
  # EVERY step -- including the reply step, where both still count 1.
  describe "parity with StatusFeed's inbox_count" do
    around do |example|
      Dir.mktmpdir { |dir| @dir = dir and example.run }
    end

    let(:path) { File.join(@dir, "state.json") }
    let(:feed) { Lain::StatusFeed.new(path:) }

    def inbox_count = JSON.parse(File.read(path)).fetch("inbox_count")

    def pending_in(view_lines)
      view_lines == ["(no questions pending)"] ? 0 : view_lines.size
    end

    it "agrees after arrival, after the bare reply, and after the consuming turn" do
      question = stored_question
      feed << question
      lines = view.update(Lain::Telemetry::Message.from_event(question))
      expect(pending_in(lines)).to eq(inbox_count).and eq(1)

      answer = Lain::Event.new(kind: :message, payload_digest: "blake3:ap",
                               body: { "answer" => "postgres" }, from: "human", to: "orchestrator",
                               causal_parents: [question.digest])
      feed << answer
      expect(view.update(Lain::Telemetry::Message.from_event(answer))).to be_nil
      expect(inbox_count).to eq(1) # the human answered; nothing consumed it yet

      citing = citing_timeline(question.digest)
      feed << citing.head
      lines = view.update(turn_usage(citing.head_digest))
      expect(pending_in(lines)).to eq(inbox_count).and eq(0)
    end
  end
end

# The buffer end of I6, on the same real headless-nvim harness as
# neovim_buffers_spec (see its header for the second-connection idiom): the
# inbox primes at attach, lists arrivals, and drains through :LainReply.
RSpec.describe Lain::Frontend::Neovim, :nvim do
  around do |example|
    socket = File.join(Dir.tmpdir, "lain-nvim-inbox-spec-#{Process.pid}-#{rand(1_000_000)}.sock")
    pid = spawn("nvim", "--headless", "--clean", "--listen", socket, out: File::NULL, err: File::NULL)
    Timeout.timeout(10) { sleep 0.02 until File.exist?(socket) }
    @socket = socket
    example.run
  ensure
    begin
      Process.kill("TERM", pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
    FileUtils.rm_f(socket)
  end

  let(:channel) { Lain::Channel.new }
  let(:store) { Lain::Store.new }

  def inspector
    @inspector ||= Neovim.attach_unix(@socket)
  end

  def buffer_lines(name)
    inspector.exec_lua(<<~LUA, [name])
      local name = ...
      local buf = vim.fn.bufnr(name)
      if buf == -1 then return {} end
      return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    LUA
  end

  def wait_until(timeout: 8)
    deadline = Time.now + timeout
    result = yield
    until result
      raise "timed out waiting for editor state" if Time.now > deadline

      sleep 0.02
      result = yield
    end
    result
  end

  def text(body) = [{ "type" => "text", "text" => body }]

  def parent_chain(seed)
    Lain::Timeline.empty(store:).commit(role: :user, content: text(seed))
  end

  def push_question(tool)
    channel.push(Lain::Telemetry::Message.from_event(tool.last_question))
  end

  describe "lain://inbox" do
    it "primes at attach with the empty note" do
      frontend = Lain::Frontend::Neovim.new(channel:, socket_path: @socket, store:)

      frontend.run do
        wait_until { buffer_lines("lain://inbox").any? }
        expect(buffer_lines("lain://inbox")).to eq(["(no questions pending)"])
      end
    end

    it "lists two questions from two agents with their senders while both promises stay pending" do
      asker_a = Lain::Tools::AskHuman.new(parent: parent_chain("a"))
      asker_b = Lain::Tools::AskHuman.new(parent: parent_chain("b"))
      promises = Sync { [asker_a.ask("deploy now?"), asker_b.ask("which db?")] }
      frontend = Lain::Frontend::Neovim.new(channel:, socket_path: @socket, store:)

      frontend.run do
        push_question(asker_a)
        push_question(asker_b)

        rendered = wait_until do
          lines = buffer_lines("lain://inbox")
          lines if lines.size == 2
        end
        expect(rendered.join("\n")).to include("deploy now?").and include("which db?")
        expect(rendered.join("\n"))
          .to include(asker_a.last_question.from[0, 19]).and include(asker_b.last_question.from[0, 19])
        # The agents kept working: neither promise resolved by merely listing.
        expect(promises.map(&:resolved?)).to eq([false, false])
      end
    end

    # AC2, end to end at the editor: :LainReply resolves the promise, the
    # answer lands as the A :message, and the DELIVERY COMMIT (the spec plays
    # the Agent's part here; agent_spec pins the production emitter) is what
    # takes the item out of the pending view.
    it "drains through :LainReply -- promise resolved, answer journaled, item retired by the citing turn" do
      parent = parent_chain("a")
      asker = Lain::Tools::AskHuman.new(parent:)
      promise = Sync { asker.ask("which db?") }
      frontend = Lain::Frontend::Neovim.new(channel:, socket_path: @socket, store:)

      frontend.run do |handle|
        push_question(asker)
        wait_until { buffer_lines("lain://inbox").join.include?("which db?") }

        inspector.command("LainReply postgres")
        verb, args = Timeout.timeout(5) { handle.command_inbox.pop }
        expect(verb).to eq("reply")
        expect(args).to eq(["postgres"])

        Sync { asker.reply(args.first) }
        expect(promise.resolved?).to be(true)
        expect(promise.await).to eq("postgres")
        expect(asker.last_answer.kind).to eq(:message)
        expect(asker.last_answer.causal_parents).to include(asker.last_question.digest)

        citing = parent.commit(role: :user, content: [{ "type" => "tool_result", "tool_use_id" => "tu_1",
                                                        "content" => "postgres" }],
                               causal_parents: [asker.last_question.digest])
        channel.push(Lain::Telemetry::TurnUsage.new(digest: citing.head_digest, model: "m",
                                                    stop_reason: :end_turn, usage: {}))

        wait_until { buffer_lines("lain://inbox") == ["(no questions pending)"] }
      end
    end

    it "binds a buffer-local reply map when the human enters the inbox (the drain autocmd)" do
      frontend = Lain::Frontend::Neovim.new(channel:, socket_path: @socket, store:)

      frontend.run do
        wait_until { buffer_lines("lain://inbox").any? }
        inspector.command("buffer lain://inbox")

        buffer_local = wait_until do
          inspector.exec_lua("local m = vim.fn.maparg('r', 'n', false, true); return m and m.buffer or 0", [])
        end
        expect(buffer_local).to eq(1)
      end
    end
  end
end
