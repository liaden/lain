# frozen_string_literal: true

require "json"

# The two rebuilders a Loader owns cite each OTHER, so neither can run first.
# A `message` record's causal_parents can name a turn (Agent's
# `causal_parents: inbox.folded`) and a turn's can name a message
# (Agent::ToolRunner's delivery edge), which makes the fold a cycle no
# sequencing of two whole passes satisfies -- the session that spawned, or that
# answered an ask_human, was simply unloadable.
#
# What replaced the ordering is a fixpoint: advance the chain as far as its
# parents allow, land every flat event whose parents are present, and repeat
# until neither moves; only then force the remainder so a genuinely dangling
# edge still refuses. This file pins that, and lives beside loader_spec.rb
# rather than inside it because the property is about the two folds TOGETHER,
# not about either one's own contract.
RSpec.describe Lain::Bench::Session::Loader do
  let(:store) { Lain::Store.new }
  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse") }
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
  let(:workspace) { Lain::Workspace.empty }
  let(:writer) { Lain::Event::ChainWriter.new }

  # The live cycle at its smallest: a turn is asked from, the question cites
  # that turn, the answer cites the question, and the turn that folds the
  # answer cites it back.
  let(:asked) { Lain::Timeline.empty(store:).commit(role: :user, content: text("which db?")) }

  let(:question) do
    writer.put(asked, kind: :message, from: "agent", to: "human",
                      causal_parents: [asked.head_digest], body: { "question" => "which db?" })
  end

  let(:answer) do
    writer.put(asked, kind: :message, from: "human", to: "agent",
                      causal_parents: [question.digest], body: { "answer" => "postgres" })
  end

  let(:folded) do
    asked.commit(role: :assistant, content: text("postgres it is"), causal_parents: [answer.digest])
  end

  def text(body) = [{ "type" => "text", "text" => body }]

  # Every record goes through the SAME JSON encode/decode a real file gives a
  # Loader, so nothing here exercises a Hash shape no journal on disk has.
  def roundtrip(records) = records.map { |record| JSON.parse(JSON.generate(record)) }

  # `resumed_from` merges in only when given -- absence is no key, never a nil
  # value, which is the shape a real header on disk has.
  def header(resumed_from: nil)
    record = Lain::SessionRecord.header(context:, toolset:, workspace:, head: nil)
    resumed_from.nil? ? record : record.merge("resumed_from" => resumed_from)
  end

  def turn_record(timeline) = Lain::SessionRecord.turn(timeline.head)

  def message_record(event) = Lain::Telemetry::Message.from_event(event).to_journal

  # File order as a writer produces it: each message between the turn it cites
  # and the turn that cites it.
  def written_order
    roundtrip([header, turn_record(asked), message_record(question), message_record(answer),
               turn_record(folded)])
  end

  describe "a turn citing a message the same journal records" do
    it "builds the recording with that turn on the chain, and the messages beside it" do
      loaded = described_class.new(written_order).recording

      expect(loaded.timeline.head_digest).to eq(folded.head_digest)
      expect(loaded.timeline.to_a.map(&:digest)).to eq(folded.to_a.map(&:digest))
      expect(loaded.messages.map(&:digest)).to eq([question.digest, answer.digest])
    end

    it "leaves the cited message fetchable with its own causal edges intact" do
      loaded = described_class.new(written_order).recording

      expect(loaded.timeline.store.fetch(answer.digest).causal_parents).to eq([question.digest])
      expect(loaded.timeline.head.causal_parents).to eq([answer.digest])
    end
  end

  # Panel fix round, the BLOCKER. A precondition three public methods each have
  # to REMEMBER is a precondition one of them will forget, and #on_chain? did:
  # it reached the fold directly, so on a healthy spawned session 8 of the 24
  # orders in which the Loader's four public questions can be asked still raised
  # the F23 refusal -- and the loader stayed poisoned for every later question.
  # Production was masked only by ResumeChain#prior_timeline happening to ask
  # #timeline one line earlier, an accident of a call site, which is the very
  # order-dependence this card exists to delete. The fixpoint now lives on the
  # readers that hand out either fold, so no path can reach an unconverged one.
  describe "the order the Loader's public questions are asked in" do
    let(:spawned) do
      child = Lain::Timeline.empty(store:).commit(role: :user, content: text("helper brief"))
      lineage = writer.put(asked, kind: :message, from: "child", to: "agent",
                                  causal_parents: [child.head_digest, asked.head_digest],
                                  body: { "summary" => "done" })
      continued = asked.commit(role: :assistant, content: text("done"), causal_parents: [lineage.digest])
      [continued, roundtrip([header, turn_record(asked),
                             Lain::Telemetry::ChildTurn.from_event(child.head).to_journal,
                             message_record(lineage), turn_record(continued)])]
    end

    it "answers #on_chain? asked FIRST, before any other question has driven the fold" do
      continued, records = spawned

      expect(described_class.new(records).on_chain?(continued.head_digest)).to be(true)
    end

    it "gives one answer to all four questions in every order they can be asked" do
      continued, records = spawned

      answers = %i[timeline messages store on_chain?].permutation.map do |order|
        loader = described_class.new(records)
        by_question = order.to_h do |question|
          [question, question == :on_chain? ? loader.on_chain?(continued.head_digest) : loader.public_send(question)]
        end
        [by_question[:timeline].head_digest, by_question[:messages].map(&:digest),
         by_question[:on_chain?], by_question[:store].size]
      end

      expect(answers.uniq.size).to eq(1)
    end
  end

  # File position stopped being an integrity check for flat events when the
  # spawn cycle forced a solver (MessageReplay's class note); the fixpoint
  # extends the same tolerance ACROSS the two folds. What each file still owns
  # is the order its own log comes back in.
  describe "the same records, written in a different order" do
    def trailing_order
      roundtrip([header, turn_record(asked), turn_record(folded),
                 message_record(answer), message_record(question)])
    end

    it "reaches the same timeline head, and hands each file its own message order back" do
      written = described_class.new(written_order).recording
      trailing = described_class.new(trailing_order).recording

      expect(trailing.timeline.head_digest).to eq(written.timeline.head_digest)
      expect(written.messages.map(&:digest)).to eq([question.digest, answer.digest])
      expect(trailing.messages.map(&:digest)).to eq([answer.digest, question.digest])
    end
  end

  # The refusal must survive the fixpoint, and it must survive it in ONE
  # currency. Which exception a damaged journal raises cannot become an
  # accident of whether the stuck record happened to be a turn or a message:
  # CLI::Resume, Bench::CLI and Supervisor::Restart rescue different sets.
  describe "a causal parent no record in the file carries" do
    let(:absent) { "blake3:#{"a" * 64}" }

    it "refuses a turn citing it as Corrupt, naming the record index, its role and the digest" do
      records = roundtrip([header, turn_record(asked), turn_record(folded)])

      expect { described_class.new(records).recording }
        .to raise_error(Lain::Bench::Session::Corrupt) { |error|
          expect(error.message).to include("turn record 1", "assistant", answer.digest)
        }
    end

    it "refuses a message citing it as Corrupt too, rather than as a bare Store::MissingObject" do
      payload = Lain::Event::Payload.new(kind: :message, body: { "answer" => "postgres" })
      stranded = Lain::Event.new(kind: :message, carried_payload: payload,
                                 from: "human", to: "agent", causal_parents: [absent])
      records = roundtrip([header, turn_record(asked), message_record(stranded)])

      expect { described_class.new(records).recording }
        .to raise_error(Lain::Bench::Session::Corrupt) { |error|
          expect(error).not_to be_a(Lain::Store::MissingObject)
          expect(error.message).to include("message record 0", absent)
        }
    end
  end

  # Timeline#commit puts the payload BEFORE the envelope, and only the
  # envelope's put validates the causal edge -- so discovering a blocked turn by
  # attempting the commit and rescuing strands an Event::Payload in the Store,
  # once per sweep of a fixpoint. The fold must pre-check instead.
  #
  # Panel fix round: an earlier version of this pinned only "the loaded Store
  # holds exactly the journal's objects", which CANNOT fail -- a turn's payload
  # digest is independent of the chain head and Store#put is idempotent, so a
  # speculative implementation that retried would leave the same Store. So the
  # guard now instruments the PUTS, one level down at the fold itself, where the
  # speculative commit would actually show.
  describe "what a blocked turn puts before it is unblocked" do
    # Anonymous rather than a named constant: it exists for this describe and
    # has no business in the global namespace (RSpec/LeakyConstantDeclaration),
    # the same shape message_replay_spec's counting store uses.
    logging_store = Class.new(SimpleDelegator) do
      attr_reader :puts_log

      def initialize(store)
        super
        @puts_log = []
      end

      def put(object)
        @puts_log << object.digest
        __getobj__.put(object)
      end
    end

    let(:logged) { logging_store.new(Lain::Store.new) }

    # The chain alone, with the message record withheld: turn 0 lands, turn 1 is
    # blocked on a message only MessageReplay can land.
    let(:fold) do
      records = roundtrip([turn_record(asked), turn_record(folded)])
      Lain::Bench::Session::ChainFold.new(records:, base: Lain::Timeline.empty(store: logged))
    end

    # Landing the blocking message the way MessageReplay lands one: payload
    # first, then the envelope. Rebuilt rather than carried -- Event::ChainWriter
    # addresses its payload by digest instead of holding it.
    def land(event)
      logged.put(Lain::Event::Payload.new(kind: event.kind, body: event.body))
      logged.put(event)
    end

    it "puts nothing at all for the blocked turn, and leaves its payload out of the Store" do
      fold.advance
      after_first = logged.puts_log.size

      expect(fold.advance).to be(false)
      expect(logged.puts_log.size).to eq(after_first)
      expect(logged.key?(folded.head.payload_digest)).to be(false)
    end

    it "puts the blocked turn exactly once, when the message it cites finally lands" do
      fold.advance
      land(question)
      land(answer)

      expect(fold.advance).to be(true)
      expect(logged.key?(folded.head.payload_digest)).to be(true)
      expect(logged.puts_log.tally.select { |_, count| count > 1 }).to be_empty
    end

    # The boundary the pre-check draws, stated from the other side: the forced
    # pass DOES strand the payload of a turn that can never commit. That is the
    # one tolerated orphan, and it is tolerated because the load refuses -- the
    # Store is thrown away. Doing it once per sweep, on a load that then
    # succeeds, is what the pre-check prevents.
    it "strands that payload only on the forced pass, which refuses" do
      fold.advance

      expect { fold.timeline }.to raise_error(Lain::Bench::Session::Corrupt, /never landed/)
      expect(logged.key?(folded.head.payload_digest)).to be(true)
    end
  end

  # End to end, and weaker on purpose -- see the describe above for why this one
  # cannot catch a speculative retry. What it does still catch is a rebuild that
  # leaves ANY object behind that the journal did not name.
  describe "what a converged load leaves in the Store" do
    it "holds exactly the events and payloads the journal carries" do
      rebuilt = described_class.new(written_order).recording.timeline.store
      expected = [*folded.to_a, question, answer].flat_map { |event| [event.digest, event.payload_digest] }

      expect(expected.reject { |digest| rebuilt.key?(digest) }).to be_empty
      expect(rebuilt.size).to eq(expected.uniq.size)
    end
  end

  # Panel fix round, NIT #7: a recorded decision rather than drift. Because the
  # fixpoint builds BOTH folds before either answers, a chained load now replays
  # (and forces) the prior file's flat events even when only this file's
  # #timeline is asked -- so a prior file with a dangling message record now
  # refuses where it used to answer. That eagerness is necessary, not incidental:
  # a turn in THIS file can cite a message in the PRIOR one, which the old
  # timeline-then-messages ordering could never resolve. The second example is
  # the capability the first one's cost buys.
  describe "a resume chain, where the prior file's flat events now load eagerly" do
    let(:prior_head) { asked }

    def chained(prior_extra:, own_turn:)
      prior = roundtrip([header, turn_record(prior_head), *prior_extra])
      own = roundtrip([header(resumed_from: { "file" => "a.ndjson", "head" => prior_head.head_digest }),
                       turn_record(own_turn)])
      described_class.new(own, resolve: ->(name) { name == "a.ndjson" ? prior : raise("unexpected #{name}") })
    end

    it "refuses this file's #timeline when the PRIOR file's message record dangles" do
      absent = "blake3:#{"cd" * 32}"
      payload = Lain::Event::Payload.new(kind: :message, body: { "x" => 1 })
      stranded = Lain::Event.new(kind: :message, carried_payload: payload,
                                 from: "a", to: "b", causal_parents: [absent])

      own = prior_head.commit(role: :assistant, content: text("later"))

      expect { chained(prior_extra: [message_record(stranded)], own_turn: own).timeline }
        .to raise_error(Lain::Bench::Session::Corrupt, /never landed/)
    end

    it "is what lets a turn in this file cite a message the PRIOR file recorded" do
      citing = prior_head.commit(role: :assistant, content: text("postgres it is"),
                                 causal_parents: [question.digest])
      loaded = chained(prior_extra: [message_record(question)], own_turn: citing)

      expect(loaded.timeline.head_digest).to eq(citing.head_digest)
    end
  end
end
