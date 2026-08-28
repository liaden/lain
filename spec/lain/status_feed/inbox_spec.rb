# frozen_string_literal: true

# The human inbox as {Lain::StatusFeed} publishes it: Event::Projection#pending
# folded incrementally, retired ONLY by a committed turn's causal edges -- and
# reached through the two carriers that name those edges, a replayed `:turn`
# Event and the {Lain::Telemetry::TurnUsage} head a live chat actually
# delivers. The parity that makes the number worth publishing is pinned next
# door, in spec/lain/frontend/neovim/inbox_view_spec.rb.
RSpec.describe Lain::StatusFeed::Inbox do
  let(:store) { Lain::Store.new }

  def text(body) = [{ "type" => "text", "text" => body }]

  # A real Q :message resident in the store, AskHuman's own write shape -- the
  # Store enforces referential integrity over causal edges, so a turn citing a
  # question needs the question actually resident, exactly as in production.
  def stored_question(question: "which db?", to: "human")
    parent = Lain::Timeline.empty(store:).commit(role: :user, content: text("seed #{question}"))
    Lain::Event::ChainWriter.new.put(parent, kind: :message, from: "orchestrator", to:,
                                             causal_parents: [], body: { "question" => question })
  end

  # The delivery commit: a chain whose head turn cites what it folded in.
  def commit_citing(*digests)
    Lain::Timeline.empty(store:)
                  .commit(role: :user, content: text("hi"))
                  .commit(role: :assistant, content: text("asking"), causal_parents: digests)
                  .head_digest
  end

  describe "#arrived" do
    it "counts a message addressed to the human" do
      inbox = described_class.new(store:)

      inbox.arrived(stored_question)

      expect(inbox.pending_size).to eq(1)
    end

    it "ignores a message addressed anywhere else" do
      inbox = described_class.new(store:)

      inbox.arrived(stored_question(to: "worker"))

      expect(inbox.pending_size).to eq(0)
    end

    it "dedups a redelivered question by digest -- a journal replay grows no phantom entry" do
      inbox = described_class.new(store:)
      question = stored_question

      2.times { inbox.arrived(question) }

      expect(inbox.pending_size).to eq(1)
    end

    # The out-of-order case a replayed log produces, and the reason consumption
    # is a standing Set rather than a removal from whatever is pending now.
    it "never lists a question a committed turn already cited, however late the question arrives" do
      inbox = described_class.new(store:)
      question = stored_question
      inbox.committed(commit_citing(question.digest))

      inbox.arrived(question)

      expect(inbox.pending_size).to eq(0)
    end
  end

  describe "#retire" do
    it "retires the digests a replayed :turn Event names among its causal parents" do
      inbox = described_class.new(store:)
      question = stored_question
      inbox.arrived(question)

      inbox.retire([question.digest])

      expect(inbox.pending_size).to eq(0)
    end
  end

  # The THIRD carrier, and the one this object needs no new code to admit. A
  # relayed subagent question is consumed by the child's own answering turn,
  # which never reaches the tee -- what reaches it is that turn's consumption
  # edges alone, and they are already the Enumerable of digests `#retire` takes.
  # Pinned here so the reuse is a contract rather than an accident: an arm that
  # grew its own retirement path would be free to drift from the nvim view's,
  # which is the one thing the parity spec next door cannot tolerate.
  describe "a spawned turn's consumption edges" do
    def child_consumption(*digests)
      base = Lain::Event.turn(role: "assistant", content: [{ "type" => "text", "text" => "answered" }])
      Lain::Telemetry::QuestionsConsumed.from_event(
        Lain::Event.new(kind: :turn, payload_digest: base.payload_digest, body: base.body, causal_parents: digests)
      )
    end

    it "retires through the same standing set the committed head's chain writes" do
      inbox = described_class.new(store:)
      question = stored_question
      inbox.arrived(question)

      inbox.retire(child_consumption(question.digest).digests)

      expect(inbox.pending_size).to eq(0)
    end

    # The out-of-order case, for the carrier a spawned chain uses: a replayed
    # log can deliver the child's turn before the question it relayed.
    it "never lists a question a spawned turn's edges already named" do
      inbox = described_class.new(store:)
      question = stored_question
      inbox.retire(child_consumption(question.digest).digests)

      inbox.arrived(question)

      expect(inbox.pending_size).to eq(0)
    end
  end

  describe "#committed" do
    it "retires the questions the committed head's chain cites -- the live chat's carrier (F76)" do
      inbox = described_class.new(store:)
      question = stored_question
      inbox.arrived(question)

      inbox.committed(commit_citing(question.digest))

      expect(inbox.pending_size).to eq(0)
    end

    it "retires nothing for a commit whose chain cites no question" do
      inbox = described_class.new(store:)
      inbox.arrived(stored_question)

      inbox.committed(commit_citing)

      expect(inbox.pending_size).to eq(1)
    end

    # StatusFeed rides the JournalTee, which re-raises a sink's failure into the
    # agent loop -- so an unresolvable head may cost a status line, never a turn.
    it "treats a head no bound store holds as a miss, never a raise" do
      inbox = described_class.new(store: Lain::Store.new)
      question = stored_question
      inbox.arrived(question)

      expect { inbox.committed(commit_citing(question.digest)) }.not_to raise_error
      expect(inbox.pending_size).to eq(1)
    end

    it "is idempotent across both carriers, so a replay delivering both retires once" do
      inbox = described_class.new(store:)
      question = stored_question
      inbox.arrived(question)

      inbox.committed(commit_citing(question.digest))
      inbox.retire([question.digest])

      expect(inbox.pending_size).to eq(0)
    end
  end

  # A digest the store genuinely HOLDS, naming a BODY rather than a turn --
  # {Lain::Event::ChainWriter} puts one for every message it writes. It is what
  # a commit record naming the wrong address looks like from in here, and the
  # walk answers it with `NoMethodError: undefined method 'parent' for an
  # instance of Lain::Event::Payload` -- past a rescue that named only
  # MissingObject, out through {Lain::CLI::JournalTee}, into the agent loop.
  describe "a head the walk cannot make sense of" do
    it "is a miss, not a raise -- a status line may never cost the agent its turn" do
      inbox = described_class.new(store:)
      question = stored_question
      inbox.arrived(question)

      expect { inbox.committed(question.payload_digest) }.not_to raise_error
      expect(inbox.pending_size).to eq(1)
    end
  end

  describe "#bind_store" do
    # ChatLaunch builds the feed that owns this object before Wiring exists, so
    # the run's Store arrives afterwards. Until it does, an empty Store resolves
    # no head at all -- absence answered by a real object, not a nil check.
    it "counts arrivals and retires nothing while no run Store has been bound" do
      inbox = described_class.new
      question = stored_question
      inbox.arrived(question)

      inbox.committed(commit_citing(question.digest))

      expect(inbox.pending_size).to eq(1)
    end

    it "retires against the run's Store once it is handed over" do
      inbox = described_class.new
      question = stored_question
      inbox.arrived(question)
      head = commit_citing(question.digest)

      inbox.bind_store(store)
      inbox.committed(head)

      expect(inbox.pending_size).to eq(0)
    end
  end

  # The address is StatusFeed's constant, resolved lexically rather than
  # re-spelled here -- one address, and a rename cannot drift the two apart.
  it "reads the human's address off StatusFeed's own constant" do
    inbox = described_class.new(store:)

    inbox.arrived(stored_question(to: Lain::StatusFeed::INBOX_RECIPIENT))

    expect(inbox.pending_size).to eq(1)
  end
end
