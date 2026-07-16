# frozen_string_literal: true

require "async"

# OM-4: ask_human is a promise. The tool emits the question as a :message to the
# human's inbox and hands back a pending Promise; awaiting it parks the fiber,
# not the reactor. Both the question (Q) and the answer (A) are replayable
# :message Store events -- the promise is process-local coordination only, never
# the record. The sync gate falls out as the degenerate case: await immediately
# and it is an ordinary synchronous question-answer, with no extra API.
RSpec.describe Lain::Tools::AskHuman do
  # A shared Store and a two-turn parent chain whose head the tool reads to
  # attribute the question -- the same live-parent-handle seam Subagent uses.
  let(:store) { Lain::Store.new }
  let(:parent) do
    Lain::Timeline.empty(store:)
                  .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
                  .commit(role: :assistant, content: [{ "type" => "text", "text" => "yo" }])
  end
  let(:invocation) { Lain::Tool::Invocation.new(context: Lain::Session::Null.instance) }

  # The asker's identity is its chain's correlation (root digest) -- the
  # convention Lineage pins; the reply is addressed back to it.
  let(:asker) { parent.head.correlation || parent.head_digest }

  def build_tool(parent: self.parent)
    described_class.new(parent:)
  end

  def projection
    Lain::Event::Projection.new(store_events)
  end

  # The Store has no enumerator of its own; the events reachable from the parent
  # head are turns, and the message events the tool wrote are what we assert
  # over, so rebuild the log from the digests we know about via the tool.
  def store_events
    [tool.last_question, tool.last_answer].compact
  end

  let(:tool) { build_tool }

  it "has a model-facing name and description" do
    expect(tool.name).to eq("ask_human")
    expect(tool.description).to be_a(String)
    expect(tool.description).not_to be_empty
  end

  # ---- Scenario: ask does not block -----------------------------------------

  describe "#ask (the async-continue seam)" do
    it "emits a :message to the human and returns a pending promise without blocking" do
      parent # force the two-turn chain into the Store before counting
      before_size = store.size

      Sync do
        promise = tool.ask("which file?")

        expect(promise).to be_a(Lain::Promise)
        expect(promise.resolved?).to be(false)
        expect(tool.pending?).to be(true)
      end

      q = tool.last_question
      expect(q.kind).to eq(:message)
      expect(q.to).to eq("human")
      expect(q.from).to eq(asker)
      expect(q.body.fetch("question")).to eq("which file?")
      # The message lands as two objects: the envelope and its out-of-line payload.
      expect(store.size).to eq(before_size + 2)
    end

    it "puts the question in the human's mailbox projection" do
      Sync { tool.ask("which file?") }

      inbox = projection.mailbox(:human).to_a
      expect(inbox.map(&:digest)).to include(tool.last_question.digest)
      expect(inbox.size).to eq(1)
      expect(inbox.last.body.fetch("question")).to eq("which file?")
    end
  end

  # ---- Scenario: await parks the fiber, not the reactor ---------------------

  it "parks the awaiting fiber while a concurrent fiber does work" do
    Sync do |task|
      log = []
      promise = tool.ask("which file?")

      waiter = task.async do
        log << :awaiting
        log << [:answer, promise.await]
      end
      worker = task.async { log << :worker_ran }
      worker.wait

      expect(log).to eq(%i[awaiting worker_ran])
      expect(promise.resolved?).to be(false)

      tool.reply("config.rb")
      waiter.wait
      expect(log.last).to eq([:answer, "config.rb"])
    end
  end

  # ---- Scenario: a reply resolves -------------------------------------------

  describe "#reply" do
    it "resolves the pending promise with the answer" do
      Sync do
        promise = tool.ask("which file?")
        tool.reply("config.rb")

        expect(promise.resolved?).to be(true)
        expect(promise.await).to eq("config.rb")
      end
    end

    it "records Q and A as replayable :message events, Q in the human mailbox and A back to the asker" do
      Sync do
        tool.ask("which file?")
        tool.reply("config.rb")
      end

      q = tool.last_question
      a = tool.last_answer

      expect([q.kind, a.kind]).to eq(%i[message message])
      # Q is addressed to the human; A is the human's reply back to the asker.
      expect(projection.mailbox(:human).to_a.map(&:digest)).to eq([q.digest])
      expect(projection.mailbox(asker).to_a.map(&:digest)).to eq([a.digest])
      # A names Q among its causal parents, so the exchange chains back.
      expect(a.from).to eq("human")
      expect(a.causal_parents).to include(q.digest)
      expect(a.body.fetch("answer")).to eq("config.rb")
    end

    it "raises loudly when nothing is awaiting a reply" do
      expect { tool.reply("nobody asked") }.to raise_error(described_class::NoPendingQuestion)
    end

    # The append-only Store is the record: a rejected reply must be rejected
    # BEFORE its A event is written, or the refusal itself pollutes the log.
    it "rejects a second reply before writing anything to the Store" do
      Sync do
        tool.ask("which file?")
        tool.reply("config.rb")
      end
      after_first = store.size

      expect { tool.reply("config.rb, again") }.to raise_error(Lain::Promise::AlreadyResolved)
      expect(store.size).to eq(after_first)
      expect(tool.last_answer.body.fetch("answer")).to eq("config.rb")
    end
  end

  # ---- Scenario: the sync gate is the degenerate case -----------------------

  describe "#call (the tool dispatch: emit then await, one mechanism)" do
    it "returns the human's answer as an ok Tool::Result" do
      Sync do |task|
        run = task.async { tool.call({ "question" => "which file?" }, invocation) }

        # The child ran synchronously up to its await, so the question is
        # already pending -- no sleep, no timing race.
        expect(tool.pending?).to be(true)
        tool.reply("config.rb")

        result = run.wait
        expect(result).to be_ok
        expect(result.content).to eq("config.rb")
      end
    end

    it "is a plain synchronous answer when the reply is already in hand (await immediately)" do
      Sync do
        promise = tool.ask("which file?")
        tool.reply("config.rb")

        # Awaiting an already-resolved promise returns at once: the degenerate
        # sync gate, no extra API.
        expect(promise.await).to eq("config.rb")
      end
    end
  end
end
