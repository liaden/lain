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
  let(:tool) { build_tool }

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

  # ---- I6: the delivery-commit consumption seam ------------------------------

  # The sync gate completing means THIS tool_result carries the answer into
  # the conversation -- so the tool remembers Q's digest for the Agent's
  # delivery commit to cite as a causal parent (the :turn edge that is the
  # ONLY thing Projection#pending counts as consumption). Handed over exactly
  # once: the edge belongs to the one commit that delivers the answer.
  describe "#take_answered_questions" do
    def complete_exchange(question, answer)
      Sync do |task|
        run = task.async { tool.call({ "question" => question }, invocation) }
        tool.reply(answer)
        run.wait
      end
    end

    it "is empty before any answer is delivered" do
      expect(tool.take_answered_questions).to eq([])
    end

    it "hands over the answered question's digest exactly once" do
      complete_exchange("which file?", "config.rb")

      expect(tool.take_answered_questions).to eq([tool.last_question.digest])
      expect(tool.take_answered_questions).to eq([])
    end

    it "accumulates when two exchanges complete before one hand-over" do
      complete_exchange("which file?", "config.rb")
      first = tool.last_question.digest
      complete_exchange("which port?", "5432")

      expect(tool.take_answered_questions).to eq([first, tool.last_question.digest])
    end

    it "hands over nothing for an ask/reply that never passed the sync gate" do
      Sync do
        tool.ask("which file?")
        tool.reply("config.rb")
      end

      # No perform ran, so no tool_result delivers this answer -- there is no
      # delivery commit for the edge to ride.
      expect(tool.take_answered_questions).to eq([])
    end
  end

  # ---- T13 scope expansion: the observer reaches the ChainWriter -------------

  # AskHuman builds its own ChainWriter, so the session scribe can only attach
  # through the tool's constructor -- the same seam Lineage exposes. Q and A are
  # exactly the events a Timeline walk can never find (panel B1), which is why
  # this observer is the ONLY way they reach the session record.
  describe "the injectable observer (T13)" do
    it "sees Q and then A, in write order, as the exchange happens" do
      seen = []
      tool = described_class.new(parent:, observer: seen.method(:push))

      Sync do
        tool.ask("which file?")
        tool.reply("config.rb")
      end

      expect(seen).to eq([tool.last_question, tool.last_answer])
      expect(seen.map(&:kind)).to eq(%i[message message])
    end

    it "flows through Notifying's kwarg forwarding unchanged" do
      seen = []
      notifying = Lain::Tools::AskHuman::Notifying.new(notify: ->(_q) {}, parent:,
                                                       observer: seen.method(:push))

      Sync do
        notifying.ask("which file?")
        notifying.reply("config.rb")
      end

      expect(seen.size).to eq(2)
    end

    it "defaults to no observer, every existing path byte-identical" do
      Sync do
        tool.ask("which file?")
        expect(tool.reply("config.rb").kind).to eq(:message)
      end
    end
  end

  # ---- T6: one call carries a question SET ----------------------------------

  # A set exists for cost, not taxonomy (ruling 1): AskHuman is not
  # parallel_safe?, so N questions asked separately are N barriers -- the human
  # answers, the model round-trips, asks again. One set collapses that to one
  # barrier, so the tool has to accept several questions and emit them as ONE
  # message to the human.
  describe "question sets" do
    let(:database) do
      Lain::Question.new(id: "db", body: "## Which database?\n\nBoth are on the box.",
                         options: [Lain::Question::Option.new(id: "pg", label: "PostgreSQL"),
                                   Lain::Question::Option.new(id: "sqlite", label: "SQLite")])
    end
    let(:migrations) do
      Lain::Question.new(id: "migrations", body: "Which migrations may run?", arity: "multi",
                         options: [Lain::Question::Option.new(id: "add_index", label: "Add the index"),
                                   Lain::Question::Option.new(id: "drop_col", label: "Drop the column")])
    end
    let(:set) { Lain::Question::Set.new(questions: [database, migrations]) }

    # Two paragraphs and a closing instruction -- the shape the description now
    # invites, and the shape a one-line clamp destroys.
    let(:long_body) do
      "Approve these acceptance criteria for test generation?\n\n" \
        "The generator emits one example per branch today, which doubles the suite for every " \
        "guard clause added. The alternative is one table-driven example per method: shorter " \
        "to read, but it loses the failure message that names the branch.\n\n" \
        "Reply approve or deny, and say which shape you want if you deny."
    end
    # The model's wire form for the same two questions, so the schema and the
    # value object are exercised against each other rather than in isolation.
    let(:set_input) { { "questions" => set.to_body.fetch("questions") } }

    # A set reaches #ask wrapped, never bare: the value #ask is handed is also
    # the value the arrival seam announces, so it has to be a String.
    def announced(set) = described_class::Announcement.new(set)

    it "emits one :message addressed to the human carrying both questions" do
      parent
      before_size = store.size

      Sync { tool.ask(announced(set)) }

      q = tool.last_question
      expect(q.kind).to eq(:message)
      expect(q.to).to eq("human")
      expect(q.body.fetch("questions").map { |question| question.fetch("id") }).to eq(%w[db migrations])
      # Still ONE message: an envelope plus its out-of-line payload, however
      # much richer the payload got.
      expect(store.size).to eq(before_size + 2)
      expect(projection.mailbox(:human).to_a.map(&:digest)).to eq([q.digest])
    end

    # inbox_view.rb reads `body.fetch("question", "(no question text)")` and the
    # inbox line shape (sender, age, text, two-space padded) is pinned, so the
    # key survives as a rendered one-line summary of the whole set.
    it "keeps a single-line summary under the old \"question\" key" do
      Sync { tool.ask(announced(set)) }

      summary = tool.last_question.body.fetch("question")
      expect(summary).to be_a(String)
      expect(summary).not_to match(/[\r\n]/)
      expect(summary).to start_with("## Which database?")
      expect(summary).to include("+1 more")
    end

    it "summarises a lone question without a count" do
      Sync { tool.ask(announced(Lain::Question::Set.new(questions: [database]))) }

      expect(tool.last_question.body.fetch("question")).to eq("## Which database?")
    end

    it "rebuilds the set that was asked from the emitted body" do
      Sync { tool.ask(announced(set)) }

      expect(Lain::Question::Set.from_body(tool.last_question.body)).to eq(set)
    end

    it "accepts the set from the model as tool input" do
      Sync do |task|
        run = task.async { tool.call(set_input, invocation) }
        tool.reply("sqlite")
        run.wait
      end

      expect(Lain::Question::Set.from_body(tool.last_question.body)).to eq(set)
    end

    # The model receives TEXT: Tool::Result refuses a Hash, so whatever the
    # answer path resolves with has to reach the conversation as a String.
    it "returns the human's answer as an ok Tool::Result naming the selection" do
      result = Sync do |task|
        run = task.async { tool.call(set_input, invocation) }
        tool.reply("sqlite -- smaller footprint, and no migrations for now")
        run.wait
      end

      expect(result).to be_ok
      expect(result.content).to be_a(String)
      expect(result.content).to include("sqlite")
    end

    # NOT coverage of anything AskHuman owns -- this pins `Tool::Result.ok`'s
    # String contract (tool.rb:248), and it passes with every T6 line reverted.
    # It is here to mark the seam a later card lands on: when the answer path
    # stops resolving with a typed String and starts resolving with a
    # Question::AnswerSet, `perform`'s last line must call `#render` on it, and
    # this is what fails if it does not.
    it "pins Tool::Result's String contract, which is where an answer set must be rendered" do
      expect do
        Sync do |task|
          run = task.async { tool.call(set_input, invocation) }
          tool.reply({ "db" => "sqlite" })
          run.wait
        end
      end.to raise_error(Lain::Tool::InvalidResult)
    end

    it "still takes a bare free-text question, and the typed reply resolves it" do
      result = Sync do |task|
        run = task.async { tool.call({ "question" => "which file?" }, invocation) }
        tool.reply("config.rb")
        run.wait
      end

      asked = Lain::Question::Set.from_body(tool.last_question.body)
      expect(asked.size).to eq(1)
      expect(asked.first).to be_free_text
      expect(asked.first.body).to eq("which file?")
      expect(result.content).to eq("config.rb")
    end

    it "refuses a call that asks nothing" do
      expect { Sync { tool.call({}, invocation) } }
        .to raise_error(Lain::Tool::InvalidInput, /asks nothing/)
    end

    it "refuses a call that asks both ways at once" do
      expect { Sync { tool.call(set_input.merge("question" => "or this?"), invocation) } }
        .to raise_error(Lain::Tool::InvalidInput, /asks two ways/)
    end

    it "refuses a set whose questions share an id, naming the offender" do
      duplicated = { "questions" => [database.to_body, database.to_body] }

      expect { Sync { tool.call(duplicated, invocation) } }
        .to raise_error(Lain::Tool::InvalidInput, /"db"/)
    end

    # The arrival seam. AskHuman::Notifying hands the notifier ITS OWN #ask
    # argument verbatim, and that value reaches Wiring#announce, which both
    # enqueues it for the TTY arrival line ("? #{question}") and drops it into
    # a dunstify ARGV element. Both were String-shaped before sets existed: a
    # Question::Set there renders as a Data inspect and puts a non-String in an
    # argv. Widening the queue is T11's card, which owns both ends -- until
    # then this seam stays a String, and it stays one BY CONSTRUCTION.
    it "announces a String at the notify seam when the model asks a set" do
      announced = []
      notifying = Lain::Tools::AskHuman::Notifying.new(notify: announced.method(:push), parent:)

      Sync do |task|
        run = task.async { notifying.call(set_input, invocation) }
        notifying.reply("sqlite")
        run.wait
      end

      expect(announced.size).to eq(1)
      expect(announced.first).to be_a(String)
      expect(announced.first).to eq(notifying.last_question.body.fetch("question"))
      # And the set is still reachable off it -- what T11 reads when it widens
      # the queue to carry the set and its asker.
      expect(announced.first.set).to eq(set)
    end

    it "refuses a bare set, so no caller can put a non-String on the arrival seam" do
      expect { Sync { tool.ask(set) } }.to raise_error(ArgumentError, /Announcement/)
    end

    # B1. Pre-T6 `perform` announced the model's raw `question` String and all
    # four human surfaces showed it whole: the TTY arrival line (tty.rb:519),
    # the /inbox drain's line_for (tty.rb:545), nvim's InboxView
    # (inbox_view.rb:104) and the dunstify argv (notify.rb:144). A question cut
    # to its first line is one a human cannot answer -- and the description now
    # invites tables and fenced diffs. So the clamp belongs to the inbox LINE,
    # never to the announcement.
    it "announces a long question verbatim, and clamps only the inbox line" do
      seen = []
      notifying = Lain::Tools::AskHuman::Notifying.new(notify: seen.method(:push), parent:)

      Sync do |task|
        run = task.async { notifying.call({ "question" => long_body }, invocation) }
        notifying.reply("approve")
        run.wait
      end

      # What the arrival line, the /inbox drain and dunstify all show:
      expect(seen.first).to be_a(String)
      expect(seen.first).to eq(long_body)
      # What nvim's inbox row shows, where the line shape is pinned:
      summary = notifying.last_question.body.fetch("question")
      expect(summary).not_to match(/[\r\n]/)
      expect(summary.length).to be <= described_class::Announcement::WIDTH
      # ... and the whole body is on the event either way.
      expect(notifying.last_question.body.dig("questions", 0, "body")).to eq(long_body)
    end

    it "announces a long question verbatim through the #ask duck too" do
      seen = []
      notifying = Lain::Tools::AskHuman::Notifying.new(notify: seen.method(:push), parent:)

      Sync { notifying.ask(long_body) }

      expect(seen.first).to eq(long_body)
      expect(notifying.last_question.body.fetch("question")).not_to match(/[\r\n]/)
    end

    # The verbatim arm is `set.size == 1`, NOT "the question has no options" --
    # every other example here is free-text, so the two are indistinguishable to
    # the suite without this one. A single question with options did not exist
    # before question sets, so announcing its body in full regresses nothing and
    # gives the /inbox drain the whole question now rather than at T14.
    it "announces a lone question with options verbatim too, not only a free-text one" do
      seen = []
      notifying = Lain::Tools::AskHuman::Notifying.new(notify: seen.method(:push), parent:)
      one = { "questions" => [{ "id" => "ship", "body" => long_body, "arity" => "single",
                                "options" => [{ "id" => "yes", "label" => "Ship it" },
                                              { "id" => "no", "label" => "Hold" }] }] }

      Sync do |task|
        run = task.async { notifying.call(one, invocation) }
        notifying.reply("approve")
        run.wait
      end

      expect(seen.first).to eq(long_body)
      expect(notifying.last_question.body.fetch("question")).not_to match(/[\r\n]/)
    end

    it "derives the inbox line once, on the announcement itself" do
      announcement = announced(set)

      Sync { tool.ask(announcement) }

      expect(tool.last_question.body.fetch("question")).to eq(announcement.summary)
    end

    # `+str` is the ordinary idiom for "a mutable copy of this frozen string",
    # and it -- alone with String#encode -- hands back THIS class with the ivars
    # dropped. The husk answers respond_to?(:set) and holds nil, so it must be
    # refused at the door rather than dying inside Question::Set.
    it "refuses an announcement copy that lost its set" do
      announcement = announced(set)

      expect { Sync { tool.ask(+announcement) } }
        .to raise_error(ArgumentError, /lost the question set/)
      expect { Sync { tool.ask(announcement.encode("UTF-8")) } }
        .to raise_error(ArgumentError, /lost the question set/)
    end

    it "still reads the set off a copy that carried it" do
      Sync { tool.ask(announced(set).dup) }

      expect(Lain::Question::Set.from_body(tool.last_question.body)).to eq(set)
    end

    # #ask's own refusal routes callers straight to this constructor, so it has
    # to answer in the same voice rather than "undefined method 'first'".
    it "refuses to announce anything that is not a question set" do
      expect { described_class::Announcement.new("hello") }
        .to raise_error(ArgumentError, /Question::Set/)
      expect { described_class::Announcement.new(database) }
        .to raise_error(ArgumentError, /Question::Set/)
    end

    it "is a deeply frozen, plain-String-transparent value" do
      announcement = announced(set)

      expect(Ractor.shareable?(announcement)).to be(true)
      expect(announcement).to eq(announcement.to_s)
      expect({ announcement.to_s => 1 }[announcement]).to eq(1)
    end

    it "declares both forms in the schema, with the arity enum on the elements" do
      properties = described_class::Input.to_json_schema.fetch("properties")
      items = properties.fetch("questions").fetch("items")

      expect(properties.keys).to eq(%w[question questions])
      expect(items.fetch("properties").fetch("arity").fetch("enum")).to eq(Lain::Question::ARITIES)
      expect(items.fetch("required")).to eq(%w[id body])
    end

    # The description is the highest-leverage lever on tool-call accuracy, and
    # a set is a new affordance: nothing else tells the model that a body is
    # markdown, when to send several, or that options may be left off.
    it "teaches the affordance in its description" do
      description = tool.description

      expect(description).to include("markdown")
      expect(description).to include("`question`")
      expect(description).to include("`questions`")
      expect(description).to match(/`options`.*optional|optional.*`options`/)
    end
  end
end
