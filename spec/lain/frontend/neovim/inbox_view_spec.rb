# frozen_string_literal: true

require "fileutils"
require "json"
require "timeout"
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

  # The editor as {QuestionView} addresses it, recorded rather than driven --
  # question_view_spec's own double, because the `<CR>` gesture is only "the
  # set opens" if the document that lands in the editor is that set's.
  let(:editor) do
    Class.new do
      attr_reader :opened

      def initialize(refusal: nil)
        @refusal = refusal
        @opened = []
      end

      def open_question(lines, digest)
        @opened << [lines, digest]
        @refusal
      end

      def documents = @opened.map(&:first)
      def digests = @opened.map(&:last)
    end.new
  end

  let(:questions) { Lain::Frontend::Neovim::QuestionView.new(rpc: editor) }
  let(:view) { described_class.new(store:, clock: -> { now }, questions:) }

  def text(body) = [{ "type" => "text", "text" => body }]

  # The sender column as the buffer prints it -- the leading field of
  # {InboxView#line_for}'s two-space-padded row.
  def senders(lines) = lines.map { |line| line.split("  ").first }

  def one_question(id, body) = Lain::Question::Set.new(questions: [Lain::Question.new(id:, body:)])

  def parent_chain(seed) = Lain::Timeline.empty(store:).commit(role: :user, content: text(seed))

  def record(event) = Lain::Telemetry::Message.from_event(event)

  # A Q written by the REAL asker, which is what pins the body spellings this
  # view names for itself ({RECIPIENT}, {ASKED_BY}) against the tool that
  # writes them rather than against a hand-built hash.
  def ask_on(parent, set, agent: nil)
    asker = Lain::Tools::AskHuman.new(parent:, agent:)
    Sync { asker.ask(Lain::Tools::AskHuman::Announcement.new(set)) }
    asker.last_question
  end

  def asked(set, agent: nil, seed: "seed") = ask_on(parent_chain(seed), set, agent:)

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

  # T15/ruling 12: `<CR>` (and `r`, repointed to it) opens the set the cursor
  # sits on. The LINE is what rides back from the editor -- :LainPin's recorded
  # rule -- beside the one other thing that says WHICH rendering the human is
  # looking at: the GENERATION this view stamped that rendering's buffer with
  # (T16). Without it the view must guess between the rendering it just handed
  # out and the one still on screen, and guessing is how `<CR>` opens the
  # neighbour.
  describe "the line -> digest index" do
    it "answers, for every rendered line, the digest of the item on that line" do
      first = asked(one_question("db", "which db?"), seed: "a")
      second = asked(one_question("when", "deploy now?"), seed: "b")
      view.update(record(first))
      lines = view.update(record(second))

      expect((1..lines.size).map { |line| view.digest_at(line, generation: view.generation) })
        .to eq([first.digest, second.digest])
      expect(lines.first).to include("which db?")
      expect(lines.last).to include("deploy now?")
    end

    it "names no set off either end of the rendering" do
      view.update(record(asked(one_question("db", "which db?"))))

      expect(view.digest_at(0, generation: view.generation)).to be_nil
      expect(view.digest_at(2, generation: view.generation)).to be_nil
    end

    it "names nothing at rest, where the buffer holds only the placeholder" do
      view.initial

      expect(view.digest_at(1, generation: view.generation)).to be_nil
    end

    it "names nothing for a rendering it cannot identify, rather than the nearest one it has" do
      view.update(record(asked(one_question("db", "which db?"))))

      expect(view.digest_at(1, generation: 9_999)).to be_nil
    end

    it "empties with the placeholder, so a drained inbox names no set on line 1" do
      question = asked(one_question("db", "which db?"))
      view.update(record(question))
      view.update(turn_usage(citing_timeline(question.digest).head_digest))

      expect(view.digest_at(1, generation: view.generation)).to be_nil
    end

    # The stamp is what the editor's buffer carries and sends back, so it has
    # to MOVE with the rendering: a stamp that repeated would name two
    # different sets on one line, which is the whole defect it exists to close.
    it "stamps every rendering with its own generation, the placeholder included" do
      view.initial
      at_rest = view.generation
      view.update(record(asked(one_question("db", "which db?"), seed: "a")))
      one_item = view.generation
      view.update(record(asked(one_question("when", "deploy now?"), seed: "b")))
      two_items = view.generation

      expect([at_rest, one_item, two_items].uniq.size).to eq(3)
      expect([at_rest, one_item, two_items].sort).to eq([at_rest, one_item, two_items])
    end
  end

  describe "#open -- the <CR>/r gesture on lain://inbox" do
    it "opens the document of the set rendered on that line, stamped with its digest" do
      view.update(record(asked(one_question("db", "which db?"), seed: "a")))
      second = asked(one_question("when", "deploy now?"), seed: "b")
      view.update(record(second))

      opened = view.open(2, generation: view.generation)

      expect(opened).to be_opened
      expect(opened.digest).to eq(second.digest)
      expect(editor.digests).to eq([second.digest])
      expect(editor.documents.last.join("\n")).to include("`when`").and include("deploy now?")
    end

    it "opens nothing from the empty-state placeholder, and reports the line naming no set" do
      view.initial

      opened = view.open(1, generation: view.generation)

      expect(opened).not_to be_opened
      expect(editor.opened).to be_empty
      expect(opened.report).to include("line 1")
    end

    # The placeholder and a one-item list are BOTH one line high, so the height
    # could never separate them; the stamp does, exactly. Under the height key
    # this pair was the ambiguity the view had to REFUSE (two held renderings
    # disagreeing about line 1); under the stamp each names its own rendering,
    # so the placeholder answers "no set here" and the list opens its item --
    # two right answers where there used to be one refusal.
    it "tells a held placeholder from a held one-item list of the same height" do
      view.initial
      at_rest = view.generation
      question = asked(one_question("db", "which db?"), seed: "a")
      view.update(record(question))

      expect(view.open(1, generation: at_rest)).not_to be_opened
      expect(view.digest_at(1, generation: at_rest)).to be_nil
      expect(view.digest_at(1, generation: view.generation)).to eq(question.digest)
    end

    it "hands back the question surface's own refusal rather than reporting an open that did not happen" do
      view.update(record(asked(one_question("db", "which db?"), seed: "a")))
      view.update(record(asked(one_question("when", "deploy now?"), seed: "b")))
      view.open(1, generation: view.generation)

      opened = view.open(2, generation: view.generation)

      expect(opened).not_to be_opened
      expect(opened.report).to include(Lain::Frontend::Neovim::QuestionView::BUFFER)
      expect(editor.digests.size).to eq(1)
    end
  end

  # The panel's index probe (.review-T15/index_probe.rb §3), ported. The render
  # that removes a retired row is QUEUED, not landed -- `Neovim#post` hands it
  # to the render queue and the RPC thread writes it a tick later -- so between
  # the retire and the redraw the human is holding a rendering this view has
  # already moved past. Resolving their keypress against the NEW one opens the
  # neighbouring set into a single-slot buffer, and then refuses the right one
  # with OCCUPIED; nothing anywhere says a word about it.
  describe "a set retired between the render and the keypress" do
    let(:keep) { asked(one_question("k", "keep?"), seed: "c") }
    let(:drop) { asked(one_question("d", "drop?"), seed: "d") }

    # Both listed, then the first consumed by a citing turn: the buffer still
    # shows two rows, this view has already produced the one-row rendering.
    # Answers the generation of the TWO-ROW rendering -- the one the human is
    # looking at, and the only thing their keypress can honestly name.
    def retire_the_first
      list_both
      view.generation.tap { view.update(turn_usage(citing_timeline(keep.digest).head_digest)) }
    end

    def list_both
      view.update(record(keep))
      view.update(record(drop))
    end

    it "says the set on that row is gone rather than opening the row below it" do
      two_listed = retire_the_first

      opened = view.open(1, generation: two_listed)

      expect(opened).not_to be_opened
      expect(opened.report).to include("no longer pending")
      expect(editor.opened).to be_empty
    end

    it "still opens the survivor from the row the human is looking at" do
      two_listed = retire_the_first

      opened = view.open(2, generation: two_listed)

      expect(opened.digest).to eq(drop.digest)
      expect(editor.digests).to eq([drop.digest])
    end

    it "opens the survivor from its new row once the render that removed the other has landed" do
      retire_the_first

      opened = view.open(1, generation: view.generation)

      expect(opened.digest).to eq(drop.digest)
      expect(editor.digests).to eq([drop.digest])
    end

    it "refuses a rendering it no longer holds rather than guessing which one that is" do
      retire_the_first

      opened = view.open(1, generation: 7_777)

      expect(opened).not_to be_opened
      expect(opened.report).to include("7777")
      expect(editor.opened).to be_empty
    end

    # ⚠️ THE GATE (T15's panel probe, ported). The HEIGHT was a weak key and
    # this is the sequence that broke it: `[keep, drop]` -> retire keep ->
    # `[drop]` -> a third set arrives -> `[drop, third]`. The human is still
    # holding the FIRST rendering, which is two lines high -- and so is the
    # newest. Under the height key the human's rendering had aged out of the
    # two held, the height ALIASED onto `[drop, third]`, and `open(1,
    # showing: 2)` answered `opened? == true` having put `drop`'s document --
    # the row BELOW the one they pressed on -- in the editor, reported as a
    # success. The stamp cannot alias: it names the rendering or nothing.
    it "opens no document at all for a row whose set retired and whose height a later rendering reused" do
      two_listed = retire_the_first
      view.update(record(asked(one_question("t", "third?"), seed: "e")))

      opened = view.open(1, generation: two_listed)

      expect(opened).not_to be_opened
      expect(opened.digest).to be_nil
      expect(editor.opened).to be_empty
    end
  end

  # {#update} runs on the frontend's drain thread and {#open} on the reactor
  # (the editor consumer's fiber), over one Hash that `arrive`/`consume` mutate
  # and `render` iterates. {QuestionView} took a lock for exactly this seam
  # after a panel walked a check-then-act there into a lost question.
  #
  # Proven rather than asserted: the clock is called from INSIDE the render, so
  # parking there parks the whole update mid-rewrite -- and a gesture arriving
  # then must not get through until it lets go.
  describe "the two threads that reach this object" do
    it "does not let a gesture read the index while an update is rewriting it" do
      inside = Thread::Queue.new
      go = Thread::Queue.new
      parking = 1
      clock = lambda do
        parking -= 1
        (inside << :in) && go.pop if parking.zero?
        now
      end
      parked = described_class.new(store:, clock:, questions:)
      question = asked(one_question("db", "which db?"))

      updating = Thread.new { parked.update(record(question)) }
      inside.pop
      gesturing = Thread.new { parked.open(1, generation: parked.generation) }

      expect(gesturing.join(0.25)).to be_nil
      go << :go
      expect(updating.join(2)).to be(updating)
      expect(gesturing.join(2)).to be(gesturing)
    end
  end

  # T16: the advance, which is the submit's own continuation rather than a
  # cursor -- so it names no line and no rendering, and it must skip the set
  # just answered, because a reply retires nothing (the pinned consumption
  # rule) and that set is therefore still listed.
  describe "#open_next -- the set that follows a submitted one" do
    it "opens the one still pending that this view lists first" do
      first = asked(one_question("db", "which db?"), seed: "a")
      second = asked(one_question("when", "deploy now?"), seed: "b")
      view.update(record(first))
      view.update(record(second))
      view.answered(first.digest)

      opened = view.open_next

      expect(opened.digest).to eq(second.digest)
      expect(editor.documents.last.join("\n")).to include("deploy now?")
    end

    it "opens nothing, and says the inbox holds nothing further, when the answered set was the last" do
      only = asked(one_question("db", "which db?"))
      view.update(record(only))
      view.answered(only.digest)

      opened = view.open_next

      expect(opened).not_to be_opened
      expect(opened.report).to eq(described_class::Gestures::NOTHING_NEXT)
      expect(editor.opened).to be_empty
    end

    it "opens nothing at all from an empty inbox" do
      view.initial

      expect(view.open_next).not_to be_opened
      expect(editor.opened).to be_empty
    end

    # The panel's PROBE N, ported. The advance used to be told ONE digest -- the
    # set just answered -- which is the same mistake in miniature that the whole
    # card is about: an item leaves this view only when a committed TURN cites
    # it, and that is a model round trip away (for a set another agent asked,
    # it may not arrive until THAT agent commits). So every set answered in a
    # burst is still listed, not just the last one, and skipping only the last
    # one walks the human backwards: A -> B -> A -> B, with C unreachable and
    # each re-open a FRESH UNANSWERED document over the ticks they just made.
    # It was silent too -- the second answer to A is dropped as AlreadyResolved.
    # The human's `:w` on whatever is on screen, then the consumer's own two
    # steps in their production order -- record the answer, open the next. The
    # write is what closes {QuestionView}'s slot, so this is also why the
    # advance can open anything at all (ruling 2 refuses over an open set).
    def submit_and_advance(digest)
      expect(questions.wrote(editor.documents.last, digest)).to be_nil
      view.answered(digest)
      view.open_next
    end

    it "walks forward through a burst rather than back onto a set already answered" do
      first = asked(one_question("a", "which db?"), seed: "a")
      second = asked(one_question("b", "deploy now?"), seed: "b")
      third = asked(one_question("c", "ship it?"), seed: "c")
      [first, second, third].each { |question| view.update(record(question)) }
      view.open(1, generation: view.generation)

      expect(submit_and_advance(first.digest).digest).to eq(second.digest)
      expect(submit_and_advance(second.digest).digest).to eq(third.digest)
      expect(editor.digests).to eq([first.digest, second.digest, third.digest])
    end

    it "runs out honestly once every listed set has been answered" do
      first = asked(one_question("a", "which db?"), seed: "a")
      second = asked(one_question("b", "deploy now?"), seed: "b")
      [first, second].each do |question|
        view.update(record(question))
        view.answered(question.digest)
      end

      opened = view.open_next

      expect(opened).not_to be_opened
      expect(opened.report).to eq(described_class::Gestures::NOTHING_NEXT)
    end

    # The row stays listed until the delivery commit lands, so the human can
    # still put their cursor on it. Re-rendering it would hand them a fresh
    # unanswered document over the answer they already gave -- PROBE O's finding
    # -- so the gesture is refused with the reason instead.
    it "refuses the row of a set already answered, rather than re-opening it unanswered" do
      question = asked(one_question("a", "which db?"))
      view.update(record(question))
      view.answered(question.digest)

      opened = view.open(1, generation: view.generation)

      expect(opened).not_to be_opened
      expect(opened.report).to include("answered")
      expect(editor.opened).to be_empty
    end

    it "stops offering an answered set once the consuming turn retires its row" do
      question = asked(one_question("a", "which db?"))
      view.update(record(question))
      view.answered(question.digest)
      view.update(turn_usage(citing_timeline(question.digest).head_digest))

      expect(view.open_next).not_to be_opened
      expect(view.digest_at(1, generation: view.generation)).to be_nil
    end

    # The example above is true whether or not the tombstone is pruned, which is
    # how it stayed green while the set grew for the whole session. Nothing
    # black-box can see the pruning -- `@consumed` already refuses a re-listed
    # digest, so a stale tombstone changes no behaviour, only memory -- so this
    # one reaches in on purpose rather than pretending to observe it.
    it "drops the answered tombstone with the row, rather than holding it for the session" do
      answered_then_retired = Array.new(3) do |i|
        asked(one_question("q#{i}", "which db?"), seed: "s#{i}").tap do |question|
          view.update(record(question))
          view.answered(question.digest)
          view.update(turn_usage(citing_timeline(question.digest).head_digest))
        end
      end

      expect(answered_then_retired.size).to eq(3)
      expect(view.instance_variable_get(:@answered)).to be_empty
    end

    # The set just answered is still listed until a committed turn cites it, so
    # skipping it is what stops the advance handing the human the document they
    # have this second finished.
    it "never re-opens the set it was told was answered" do
      only = asked(one_question("db", "which db?"))
      view.update(record(only))

      expect(view.open_next.digest).to eq(only.digest)
      view.answered(only.digest)
      expect(view.open_next).not_to be_opened
    end
  end

  # THE INVARIANT THE WHOLE GESTURE RESTS ON: nothing holding this view's lock
  # may wait on the editor. `#open` takes `@slot` and calls {QuestionView#open},
  # which takes ITS OWN non-reentrant lock and posts the document -- so if that
  # post could block on a full render queue, a keypress would hold both locks
  # while waiting for the RPC thread, which is the one thread that empties that
  # queue AND the thread that serves the editor's own writes. The queue is
  # drained once per RPC tick, so "full" is a state a burst reaches, not a
  # hypothetical.
  #
  # Both objects already answer this the only way that is safe -- the post is
  # {RenderQueue#post_question}'s NON-BLOCKING push, refused rather than
  # awaited -- and both say so in prose. This is the prose made mechanical,
  # over the REAL inlet with a saturated queue: a refusal in bounded time, so a
  # regression fails in two seconds instead of hanging a CI worker forever (a
  # hung worker reports as "fewer examples, zero failures", which is not a
  # failure anyone reads).
  describe "the render queue is full and the human presses enter" do
    let(:inlet) { Lain::Frontend::Neovim::RenderInlet.new(waker: -> {}, capacity: 1) }
    let(:questions) { Lain::Frontend::Neovim::QuestionView.new(rpc: inlet) }

    it "refuses in bounded time rather than holding the lock until the editor drains" do
      inlet.post_view("lain://inbox", ["saturating the queue"])
      view.update(record(asked(one_question("db", "which db?"))))

      opened = Timeout.timeout(2) { view.open(1, generation: view.generation) }

      expect(opened).not_to be_opened
      expect(opened.report).to eq(Lain::Frontend::Neovim::QuestionView::DETACHED)
    end

    # The advance runs on the same fiber, under the same two locks, and is the
    # path a submitted document takes -- so it owes the same guarantee.
    it "refuses the advance in bounded time too" do
      inlet.post_view("lain://inbox", ["saturating the queue"])
      view.update(record(asked(one_question("db", "which db?"))))

      opened = Timeout.timeout(2) { view.open_next }

      expect(opened).not_to be_opened
    end
  end

  # The other half of a defect the TTY closed alone (T10): `event.from` is the
  # asker chain's ROOT digest, and an `:inherit` child is `parent.fork`, so a
  # child and its parent share one PERMANENTLY. Two askers over ONE parent
  # chain is that situation exactly, and `:inherit` is the default posture for
  # a @role spawn -- the common path, not a corner of one.
  describe "who the sender column names" do
    it "renders the asker's name, not the correlation an inherit child shares with its parent" do
      shared = parent_chain("shared")
      first = ask_on(shared, one_question("db", "which db?"), agent: "lain")
      second = ask_on(shared, one_question("when", "deploy now?"), agent: "researcher")
      view.update(record(first))
      lines = view.update(record(second))

      expect(first.from).to eq(second.from)
      expect(senders(lines)).to eq(%w[lain researcher])
    end

    it "falls back to the envelope's attribution for a record that carries no name" do
      lines = view.update(question_record("blake3:q1", from: "orchestrator"))

      expect(senders(lines)).to eq(["orchestrator"])
    end
  end

  # Ruling 3: what fills the sender column moved; the row did not.
  describe "the rendered row" do
    it "still reads sender, age and the set's summary, with the padding the runtime anchors on" do
      lines = view.update(record(asked(one_question("db", "which db?"), agent: "researcher")))

      expect(lines).to eq(["researcher  0s  which db?"])
      expect(lines.first).to match(/  \d+[smh]  /)
    end

    it "names a set's further questions through the summary it already carried, not a new column" do
      set = Lain::Question::Set.new(questions: [Lain::Question.new(id: "db", body: "which db?"),
                                                Lain::Question.new(id: "when", body: "deploy now?")])

      lines = view.update(record(asked(set, agent: "researcher")))

      expect(lines).to eq(["researcher  0s  which db? (+1 more)"])
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
    pid = spawn("nvim", "--headless", "--clean", "-n", "--listen", socket, out: File::NULL, err: File::NULL)
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

  # Switches to the buffer, seats the cursor, and feeds `keys` through nvim's
  # OWN mapping resolution (feedkeys, never `:normal!`, which bypasses
  # mappings) -- buffers_spec's helper, for its reason: this must exercise the
  # actual buffer-local map.
  def feed(bufname, keys, cursor: [])
    inspector.exec_lua(<<~LUA, [bufname, keys, cursor])
      local bufname, keys, cursor = ...
      vim.cmd("buffer " .. bufname)
      if cursor[1] then
        vim.api.nvim_win_set_cursor(0, cursor)
      end
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
    LUA
  end

  def parent_chain(seed)
    Lain::Timeline.empty(store:).commit(role: :user, content: text(seed))
  end

  def push_question(tool)
    channel.push(Lain::Telemetry::Message.from_event(tool.last_question))
  end

  describe "lain://inbox" do
    it "primes at attach with the empty note" do
      frontend = described_class.new(channel:, socket_path: @socket, store:)

      frontend.run do
        wait_until { buffer_lines("lain://inbox").any? }
        expect(buffer_lines("lain://inbox")).to eq(["(no questions pending)"])
      end
    end

    it "lists two questions from two agents with their senders while both promises stay pending" do
      asker_a = Lain::Tools::AskHuman.new(parent: parent_chain("a"))
      asker_b = Lain::Tools::AskHuman.new(parent: parent_chain("b"))
      promises = Sync { [asker_a.ask("deploy now?"), asker_b.ask("which db?")] }
      frontend = described_class.new(channel:, socket_path: @socket, store:)

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
      frontend = described_class.new(channel:, socket_path: @socket, store:)

      frontend.run do |handle|
        push_question(asker)
        wait_until { buffer_lines("lain://inbox").join.include?("which db?") }

        inspector.command("LainReply postgres")
        verb, args = Timeout.timeout(5) { handle.command_inbox.pop }
        expect(verb).to eq("reply")
        expect(args).to eq(["postgres"])

        Sync { asker.reply(args.first, asker.last_question.digest) }
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
      frontend = described_class.new(channel:, socket_path: @socket, store:)

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

  # T15/ruling 12, at the editor. What rides back is the LINE (:LainPin's rule)
  # -- the Ruby side's line -> digest index is the only thing that may name a
  # set -- and both keys invoke the COMMAND, so a human typing :LainOpen by
  # hand takes provably the same path. Beside it rides the RENDERING STAMP
  # (T16): the generation the view put on that buffer, read back off the view
  # itself here, because "the editor sends back what the render stamped" is the
  # property, not any particular number.
  describe "the open gesture on lain://inbox" do
    def inbox_stamp(handle) = handle.buffers.generation_of(Lain::Frontend::Neovim::InboxView::NAME)

    def two_pending
      asker_a = Lain::Tools::AskHuman.new(parent: parent_chain("a"))
      asker_b = Lain::Tools::AskHuman.new(parent: parent_chain("b"))
      Sync { [asker_a.ask("deploy now?"), asker_b.ask("which db?")] }
      push_question(asker_a)
      push_question(asker_b)
      wait_until { buffer_lines("lain://inbox").size == 2 }
    end

    it "enqueues an open command naming the cursor's line when the human presses enter" do
      frontend = described_class.new(channel:, socket_path: @socket, store:)

      frontend.run do |handle|
        two_pending

        feed("lain://inbox", "<CR>", cursor: [2, 0])

        expect(Timeout.timeout(5) { handle.command_inbox.pop }).to eq(["open", [2, inbox_stamp(handle)]])
      end
    end

    it "opens the same set from r, which no longer prompts for a one-line answer" do
      frontend = described_class.new(channel:, socket_path: @socket, store:)

      frontend.run do |handle|
        two_pending

        feed("lain://inbox", "r", cursor: [2, 0])

        expect(Timeout.timeout(5) { handle.command_inbox.pop }).to eq(["open", [2, inbox_stamp(handle)]])
      end
    end

    # No sleep: the placeholder gesture is followed by a real command, and the
    # FIRST thing to reach the inbox must be that real one (the :LainPin
    # refusal example's idiom).
    it "sends nothing at all from the empty-state placeholder" do
      frontend = described_class.new(channel:, socket_path: @socket, store:)

      frontend.run do |handle|
        wait_until { buffer_lines("lain://inbox").any? }

        feed("lain://inbox", "<CR>", cursor: [1, 0])
        inspector.command("LainSend")

        expect(Timeout.timeout(5) { handle.command_inbox.pop }).to eq(["send"])
      end
    end

    # :Lain* commands are GLOBAL (runtime.lua's `define`) and this one reads the
    # CURRENT window's cursor, so hand-typed from lain://journal it would open
    # whatever inbox line shares that number -- a set the human never looked at.
    it "refuses to open from a buffer that is not the inbox, and says so" do
      frontend = described_class.new(channel:, socket_path: @socket, store:)

      frontend.run do |handle|
        two_pending
        wait_until { buffer_lines("lain://journal").any? }

        feed("lain://journal", ":LainOpen<CR>", cursor: [1, 0])
        feed("lain://inbox", "<CR>", cursor: [1, 0])

        expect(Timeout.timeout(5) { handle.command_inbox.pop }).to eq(["open", [1, inbox_stamp(handle)]])
      end
    end
  end
end
