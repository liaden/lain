# frozen_string_literal: true

require "json"
require "stringio"

# Loader is the collaborator Session.load delegates the rebuild to: it folds
# parsed journal records back into a Recording, re-committing every turn so
# content-addressing doubles as the integrity check. Session_spec covers the
# seam end to end; this pins the Loader directly -- constructed from entries,
# not reached through Session.load -- so the unit has its own coverage.
RSpec.describe Lain::Bench::Session::Loader do
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse") }
  let(:workspace) { Lain::Workspace.empty }
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:usage) { Lain::Usage.new(input_tokens: 120, output_tokens: 30) }

  let(:run) do
    responses = [tool_response(["tu_1", "echo", { "text" => "hi" }], usage:, model: "claude-opus-4-8"),
                 text_response("done", usage:, model: "claude-opus-4-8")]
    record_journaled_run(responses, journal:, toolset:, context:, workspace:)
  end

  let(:agent) { run.first }
  let(:provider) { run.last }

  # The Loader's own input duck: the Journal.parse entries, here the raw NDJSON
  # lines Session.load hands it from a file.
  def entries
    Lain::Bench::Session.write(journal, timeline: agent.timeline, context:, toolset:, workspace:)
    journal_io.string.each_line
  end

  def recording = described_class.new(entries).recording

  describe "#recording round-trips a recorded session" do
    it "rebuilds the timeline to the recorded head digest" do
      expect(recording.timeline.head_digest).to eq(agent.timeline.head_digest)
    end

    it "rebuilds the baseline to the requests the provider actually received, in order" do
      expect(recording.baseline).to eq(provider.requests)
    end

    it "rebuilds a toolset answering the recorded schema and the recorded context inputs" do
      rebuilt = recording
      expect(rebuilt.toolset.to_schema).to eq(toolset.to_schema)
      expect(rebuilt.context.model).to eq("claude-opus-4-8")
      expect(rebuilt.context.system).to eq("be terse")
      expect(rebuilt.context_class).to eq("Lain::Context")
    end

    it "folds capability_degraded records into the degraded set" do
      degraded = { "type" => "capability_degraded", "capability" => "prompt_caching" }
      lines = entries.to_a + ["#{JSON.generate(degraded)}\n"]
      expect(described_class.new(lines).recording.degraded).to include(:prompt_caching)
    end

    it "accepts already-parsed Hash entries, not only raw lines" do
      hashes = entries.map { |line| JSON.parse(line) }
      expect(described_class.new(hashes).recording.timeline.head_digest).to eq(agent.timeline.head_digest)
    end

    it "skips foreign records the parse duck answers nil for" do
      lines = ["not json at all\n", "[1, 2, 3]\n"] + entries.to_a
      expect(described_class.new(lines).recording.timeline.head_digest).to eq(agent.timeline.head_digest)
    end
  end

  describe "the injectable context factory" do
    it "defaults to rebuilding a plain Context with the recorded transport fields (byte-identical)" do
      ctx = recording.context
      expect(ctx).to be_a(Lain::Context)
      expect(ctx.model).to eq("claude-opus-4-8")
      expect(ctx.system).to eq("be terse")
      expect(ctx.max_tokens).to eq(1024)
    end

    it "hands the recorded transport fields to a custom factory and uses the Context it returns" do
      seen = nil
      sentinel = Lain::Context.new(model: "custom-pipeline", max_tokens: 7)
      factory = lambda do |**fields|
        seen = fields
        sentinel
      end

      rebuilt = described_class.new(entries, context_factory: factory).recording

      expect(rebuilt.context).to be(sentinel)
      expect(seen).to include(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse")
    end
  end

  describe "integrity" do
    def forge(type)
      records = entries.map { |line| JSON.parse(line) }
      target = records.select { |record| record["type"] == type }.last
      yield target
      records
    end

    it "raises Corrupt naming the recorded digest when a turn's content was edited under it" do
      records = forge("turn") { |turn| turn["content"] = [{ "type" => "text", "text" => "forged" }] }
      digest = records.select { |r| r["type"] == "turn" }.last.fetch("digest")
      expect { described_class.new(records).recording }
        .to raise_error(Lain::Bench::Session::Corrupt, /#{Regexp.escape(digest)}/)
    end

    it "raises Corrupt naming the expected head when the tail turn is truncated" do
      records = entries.map { |line| JSON.parse(line) }
      records.delete(records.select { |r| r["type"] == "turn" }.last)
      records.delete(records.select { |r| r["type"] == "request_sent" }.last)
      expect { described_class.new(records).recording }
        .to raise_error(Lain::Bench::Session::Corrupt, /#{Regexp.escape(agent.timeline.head_digest)}/)
    end

    it "raises Corrupt when two session headers claim one journal" do
      records = entries.map { |line| JSON.parse(line) }
      duplicate = records.find { |record| record["type"] == "session" }
      expect { described_class.new(records + [duplicate]).recording }
        .to raise_error(Lain::Bench::Session::Corrupt, /header/)
    end

    it "raises Corrupt rather than fabricating a context when no header is present" do
      expect { described_class.new([]).recording }.to raise_error(Lain::Bench::Session::Corrupt, /header/)
    end
  end

  # T14: the live session format's open sessions and resume chains. Built
  # directly from {Lain::SessionRecord} and {Lain::Event::ChainWriter}, not
  # through {Lain::Bench::Session.write} -- these shapes are the live
  # scribe's (T13), never the offline recorder's, which this describe's
  # sibling blocks already cover under "bench files load unchanged".
  describe "open sessions and resume chains" do
    def text(body) = [{ "type" => "text", "text" => body }]

    # Every record here is round-tripped through the SAME JSON encode/decode
    # a real file gives a Loader -- {Lain::Journal.parse}'s Hash path only
    # string-keys the TOP level, so a raw Ruby Hash (a Symbol `kind`, say)
    # would exercise a shape no file on disk actually has.
    def roundtrip(records) = records.map { |record| JSON.parse(JSON.generate(record)) }

    def open_header(resumed_from: nil)
      header = Lain::SessionRecord.header(context:, toolset:, workspace:, head: nil)
      resumed_from.nil? ? header : header.merge("resumed_from" => resumed_from)
    end

    describe "an open (crashed) session" do
      it "loads flagged open, with the timeline head the last verified turn" do
        chain = Lain::Timeline.empty(store: Lain::Store.new)
                              .commit(role: :user, content: text("hi"))
                              .commit(role: :assistant, content: text("hello"))
        records = roundtrip([open_header] + chain.to_a.map { |turn| Lain::SessionRecord.turn(turn) })

        loaded = described_class.new(records).recording

        expect(loaded.open?).to be(true)
        expect(loaded.timeline.head_digest).to eq(chain.head_digest)
      end

      it "loads a header-only session (0 turns) flagged open with a nil head" do
        loaded = described_class.new(roundtrip([open_header])).recording

        expect(loaded.open?).to be(true)
        expect(loaded.timeline.head_digest).to be_nil
      end

      # run_interrupted.head is JOIN-OPTIONAL: a SIGKILL between the Agent's
      # commit+journal atom and catch_up can leave a run_interrupted naming a
      # head with no turn record in the file. Tolerated by never consulting
      # it -- the record marks one ASK, not the session's open/closed state.
      it "tolerates a run_interrupted whose head has no turn record, still open" do
        chain = Lain::Timeline.empty(store: Lain::Store.new).commit(role: :user, content: text("hi"))
        interrupted = Lain::Telemetry::RunInterrupted.new(head: "blake3:#{"f" * 64}").to_journal
        records = roundtrip([open_header, Lain::SessionRecord.turn(chain.head), interrupted])

        loaded = described_class.new(records).recording

        expect(loaded.open?).to be(true)
        expect(loaded.timeline.head_digest).to eq(chain.head_digest)
      end
    end

    # A CLOSED live session's anchor lives in the session_closed record's OWN
    # head, never the header ({SessionRecord}'s format contract: the header is
    # written open and never rewritten) -- the most load-bearing Anchor branch.
    describe "a gracefully closed live session" do
      let(:chain) do
        Lain::Timeline.empty(store: Lain::Store.new)
                      .commit(role: :user, content: text("hi"))
                      .commit(role: :assistant, content: text("hello"))
      end

      def closed_records(head)
        closed = Lain::Telemetry::SessionClosed.new(head:, reason: :exit).to_journal
        roundtrip([open_header] + chain.to_a.map { |turn| Lain::SessionRecord.turn(turn) } + [closed])
      end

      it "verifies against session_closed's own head when the header head is nil, not flagged open" do
        loaded = described_class.new(closed_records(chain.head_digest)).recording

        expect(loaded.open?).to be(false)
        expect(loaded.timeline.head_digest).to eq(chain.head_digest)
      end

      it "raises Corrupt when session_closed's head disagrees with the rebuilt chain" do
        wrong = "blake3:#{"0" * 64}"

        expect { described_class.new(closed_records(wrong)).recording }
          .to raise_error(Lain::Bench::Session::Corrupt) { |error| expect(error.message).to include(wrong, chain.head_digest) }
      end
    end

    describe "a resume chain" do
      let(:a_chain) { Lain::Timeline.empty(store: Lain::Store.new).commit(role: :user, content: text("first")) }
      let(:a_records) { roundtrip([open_header] + a_chain.to_a.map { |turn| Lain::SessionRecord.turn(turn) }) }
      let(:resolver) { ->(basename) { basename == "a.ndjson" ? a_records : raise("unexpected #{basename}") } }

      def resumed_header(head) = open_header(resumed_from: { "file" => "a.ndjson", "head" => head })

      it "loads file A then file B as one conversation, every digest verified" do
        b_chain = a_chain.commit(role: :assistant, content: text("second"))
        b_records = roundtrip([resumed_header(a_chain.head_digest), Lain::SessionRecord.turn(b_chain.head)])

        loaded = described_class.new(b_records, resolve: resolver).recording

        expect(loaded.timeline.to_a.map(&:digest)).to eq(b_chain.to_a.map(&:digest))
      end

      it "refuses when resumed_from's recorded head does not match A's actual head, naming both digests" do
        wrong = "blake3:#{"0" * 64}"
        new_turn = a_chain.commit(role: :assistant, content: text("second")).head
        b_records = roundtrip([resumed_header(wrong), Lain::SessionRecord.turn(new_turn)])

        expect { described_class.new(b_records, resolve: resolver).recording }
          .to raise_error(Lain::Bench::Session::Corrupt) { |error| expect(error.message).to include(wrong, a_chain.head_digest) }
      end

      it "raises ArgumentError naming the seam when resumed_from is present but no resolver was given" do
        b_records = roundtrip([resumed_header(a_chain.head_digest)])

        expect { described_class.new(b_records).recording }.to raise_error(ArgumentError, /a\.ndjson/)
      end

      it "refuses a resolver answering nil, naming the missing file" do
        b_records = roundtrip([resumed_header(a_chain.head_digest)])

        expect { described_class.new(b_records, resolve: ->(_basename) {}).recording }
          .to raise_error(Lain::Bench::Session::Corrupt, /a\.ndjson/)
      end

      # A cyclic chain must refuse as a CLASSIFIED error, never recurse to a
      # SystemStackError -- an Exception, not a StandardError, so no caller
      # can rescue it as the refusal the card demands.
      describe "cyclic chains" do
        it "refuses a self-referential chain (A resumed_from A), naming the revisited file" do
          records = roundtrip([resumed_header(a_chain.head_digest)] +
                              a_chain.to_a.map { |turn| Lain::SessionRecord.turn(turn) })
          cyclic_resolver = ->(basename) { basename == "a.ndjson" ? records : raise("unexpected #{basename}") }

          expect { described_class.new(records, resolve: cyclic_resolver).recording }
            .to raise_error(Lain::Bench::Session::Corrupt, /a\.ndjson/)
        end

        it "refuses a two-cycle (A resumed_from B, B resumed_from A), naming the revisited file" do
          a_records = roundtrip([open_header(resumed_from: { "file" => "b.ndjson", "head" => "blake3:#{"1" * 64}" })])
          b_records = roundtrip([open_header(resumed_from: { "file" => "a.ndjson", "head" => "blake3:#{"2" * 64}" })])
          cyclic_resolver = lambda do |basename|
            { "a.ndjson" => a_records, "b.ndjson" => b_records }.fetch(basename)
          end

          expect { described_class.new(a_records, resolve: cyclic_resolver).recording }
            .to raise_error(Lain::Bench::Session::Corrupt, /b\.ndjson/)
        end
      end

      # Allowed, not refused: a never-closed predecessor still resumes,
      # because B's own recorded head retroactively re-anchors A's otherwise
      # unverified tail (any A-side truncation changes A's rebuilt head, which
      # then disagrees with what B recorded at resume time).
      it "resumes from an OPEN (never-closed) predecessor, B's recorded head re-anchoring A" do
        b_chain = a_chain.commit(role: :assistant, content: text("second"))
        b_records = roundtrip([resumed_header(a_chain.head_digest), Lain::SessionRecord.turn(b_chain.head)])

        loaded = described_class.new(b_records, resolve: resolver).recording

        expect(loaded.timeline.head_digest).to eq(b_chain.head_digest)
        expect(loaded.open?).to be(true)
      end
    end

    # T15: a `rewound` record ({from:, to:}) is a fold-position move, folded
    # in FILE order beside the turn records -- the fold checks out `to` and
    # subsequent turns verify as extending it. The turns above the rewind stay
    # in the Store and in fold membership, which is what keeps a child forked
    # above the rewind loadable (the T3 panel's probe_rewind_membership,
    # proven end-to-end below).
    describe "a rewound session stays loadable" do
      let(:store) { Lain::Store.new }
      let(:full) do
        Lain::Timeline.empty(store:)
                      .commit(role: :user, content: text("q1"))
                      .commit(role: :assistant, content: text("a1"))
                      .commit(role: :user, content: text("q2"))
                      .commit(role: :assistant, content: text("a2"))
      end
      let(:target) { full.rewind(2) }
      let(:retried) do
        target.commit(role: :user, content: text("q2, take two"))
              .commit(role: :assistant, content: text("a2, take two"))
      end

      def turn_records(chain) = chain.to_a.map { |turn| Lain::SessionRecord.turn(turn) }

      def rewound_records(to: target.head_digest, from: full.head_digest, tail: retried.to_a.last(2))
        roundtrip([open_header] + turn_records(full) +
                  [Lain::SessionRecord.rewound(from:, to:)] +
                  tail.map { |turn| Lain::SessionRecord.turn(turn) })
      end

      it "folds turn AND rewound records in file order, resuming at the post-rewind head" do
        loaded = described_class.new(rewound_records).recording

        expect(loaded.timeline.head_digest).to eq(retried.head_digest)
        expect(loaded.timeline.to_a.map(&:digest)).to eq(retried.to_a.map(&:digest))
      end

      it "keeps the pre-rewind head reachable: in the Store, and vouched by fold membership" do
        loader = described_class.new(rewound_records)

        expect(loader.timeline.store.key?(full.head_digest)).to be(true)
        expect(loader.on_chain?(full.head_digest)).to be(true)
      end

      it "folds an identical-content retry: the same digest re-recorded after the rewound record" do
        records = roundtrip([open_header] + turn_records(full) +
                            [Lain::SessionRecord.rewound(from: full.head_digest, to: full.rewind(1).head_digest),
                             Lain::SessionRecord.turn(full.head)])

        loaded = described_class.new(records).recording

        expect(loaded.timeline.head_digest).to eq(full.head_digest)
      end

      it "folds a rewind to the empty session (to: nil), fresh turns extending from the root" do
        fresh = Lain::Timeline.empty(store:).commit(role: :user, content: text("clean slate"))
        records = roundtrip([open_header] + turn_records(full) +
                            [Lain::SessionRecord.rewound(from: full.head_digest, to: nil),
                             Lain::SessionRecord.turn(fresh.head)])

        loaded = described_class.new(records).recording

        expect(loaded.timeline.head_digest).to eq(fresh.head_digest)
      end

      it "verifies a closed rewound session against the post-rewind anchor" do
        closed = Lain::Telemetry::SessionClosed.new(head: retried.head_digest, reason: :exit).to_journal
        records = rewound_records + roundtrip([closed])

        loaded = described_class.new(records).recording

        expect(loaded.open?).to be(false)
        expect(loaded.timeline.head_digest).to eq(retried.head_digest)
      end

      it "raises Corrupt when a rewound record's `from` disagrees with the fold position, naming both" do
        wrong = "blake3:#{"0" * 64}"

        expect { described_class.new(rewound_records(from: wrong)).recording }
          .to raise_error(Lain::Bench::Session::Corrupt) { |error| expect(error.message).to include(wrong, full.head_digest) }
      end

      it "raises Corrupt when a rewound record's target was never verified on this chain" do
        unverified = "blake3:#{"f" * 64}"

        expect { described_class.new(rewound_records(to: unverified, tail: [])).recording }
          .to raise_error(Lain::Bench::Session::Corrupt, /#{Regexp.escape(unverified)}/)
      end

      # T15 panel (Linus): rewind, continue, rewind deeper -- the fold lands
      # on the final head and BOTH abandoned branches stay vouched, because
      # children forked above either rewind depend on it.
      it "folds two rewound records, every abandoned branch still vouched" do
        t1 = full.rewind(3)
        branch = target.commit(role: :user, content: text("q2 take two"))
                       .commit(role: :assistant, content: text("a2 take two"))
        final = t1.commit(role: :assistant, content: text("a1 rewrite"))
        loader = described_class.new(
          roundtrip([open_header] + turn_records(full) +
                    [Lain::SessionRecord.rewound(from: full.head_digest, to: target.head_digest)] +
                    branch.to_a.last(2).map { |turn| Lain::SessionRecord.turn(turn) } +
                    [Lain::SessionRecord.rewound(from: branch.head_digest, to: t1.head_digest),
                     Lain::SessionRecord.turn(final.head)])
        )

        expect(loader.timeline.head_digest).to eq(final.head_digest)
        expect(loader.on_chain?(full.head_digest)).to be(true)
        expect(loader.on_chain?(branch.head_digest)).to be(true)
        expect(loader.timeline.store.key?(full.head_digest)).to be(true)
      end

      # T15 panel (Jeremy): the record's edge semantics, pinned.
      it "folds a first-record rewound ({from: nil, to: nil}) to the empty session" do
        fresh = Lain::Timeline.empty(store:).commit(role: :user, content: text("clean"))
        records = roundtrip([open_header, Lain::SessionRecord.rewound(from: nil, to: nil),
                             Lain::SessionRecord.turn(fresh.head)])

        expect(described_class.new(records).recording.timeline.head_digest).to eq(fresh.head_digest)
      end

      it "refuses a first-record rewound naming a digest this file never verified" do
        records = roundtrip([open_header, Lain::SessionRecord.rewound(from: nil, to: full.head_digest)])

        expect { described_class.new(records).recording }
          .to raise_error(Lain::Bench::Session::Corrupt, /never\s+verified/m)
      end

      it "folds a no-op rewound (to == from == head) without moving anything" do
        records = roundtrip([open_header] + turn_records(full) +
                            [Lain::SessionRecord.rewound(from: full.head_digest, to: full.head_digest)])

        expect(described_class.new(records).recording.timeline.head_digest).to eq(full.head_digest)
      end

      it "refuses a rewound SPLICED mid-file whose from is a verified turn that is not the fold head" do
        records = roundtrip([open_header] + turn_records(full))
        spliced = records[0..2] +
                  roundtrip([Lain::SessionRecord.rewound(from: full.rewind(3).head_digest, to: nil)]) +
                  records[3..]

        expect { described_class.new(spliced).recording }
          .to raise_error(Lain::Bench::Session::Corrupt, /fold order has been disturbed/)
      end

      it "refuses a rewound whose target is only verified LATER in the file (forward reference)" do
        t1_record, *rest = roundtrip(turn_records(full))
        forward = roundtrip([Lain::SessionRecord.rewound(from: full.rewind(3).head_digest,
                                                         to: full.head_digest)])

        expect { described_class.new([open_header, t1_record, *forward, *rest]).recording }
          .to raise_error(Lain::Bench::Session::Corrupt, /never\s+verified/m)
      end

      # T15 panel finding 4, recorded as contract: the Loader ACCEPTS a
      # forward "rewound" (a redo onto a branch the fold already verified)
      # that the Scribe refuses to WRITE, because its skip-set pruned the
      # target. Read-tolerance and write-strictness deliberately differ --
      # verification stays sound either way (the target was proven) -- and
      # this example is where that asymmetry is pinned; ChainFold's
      # verified_target comment names it on the lib side.
      it "accepts a forward 'rewound' (redo) that the Scribe would refuse to write" do
        retry_turn = target.commit(role: :user, content: text("take two"))
        records = roundtrip([open_header] + turn_records(full) +
                            [Lain::SessionRecord.rewound(from: full.head_digest, to: target.head_digest),
                             Lain::SessionRecord.turn(retry_turn.head),
                             Lain::SessionRecord.rewound(from: retry_turn.head_digest, to: full.head_digest)])

        expect(described_class.new(records).recording.timeline.head_digest).to eq(full.head_digest)
      end

      # The T3 panel's probe_rewind_membership, end-to-end with the real fold:
      # parent forks child at F, parent rewinds BELOW F and keeps going --
      # the child must stay loadable, and the parent by its own fold too.
      it "keeps a child forked above the rewind loadable after the parent rewinds below the fork point" do
        fork_point = full.rewind(2) # F
        below = full.rewind(3)
        parent_records = roundtrip([open_header] + turn_records(full) +
                                   [Lain::SessionRecord.rewound(from: full.head_digest, to: below.head_digest),
                                    Lain::SessionRecord.turn(
                                      below.commit(role: :assistant, content: text("a1 prime")).head
                                    )])
        child = fork_point.commit(role: :assistant, content: text("child continuation"))
        child_records = roundtrip(
          [open_header(resumed_from: { "file" => "a.ndjson", "head" => fork_point.head_digest }),
           Lain::SessionRecord.turn(child.head)]
        )
        resolver = ->(basename) { basename == "a.ndjson" ? parent_records : raise("unexpected #{basename}") }

        loaded = described_class.new(child_records, resolve: resolver).recording

        expect(loaded.timeline.head_digest).to eq(child.head_digest)
        expect(described_class.new(parent_records).recording.timeline.head.content).to eq(text("a1 prime"))
      end
    end

    describe "message records rejoin the Store" do
      let(:chain) { Lain::Timeline.empty(store: Lain::Store.new).commit(role: :user, content: text("ask me")) }
      let(:writer) { Lain::Event::ChainWriter.new }
      let(:question) do
        writer.put(chain, kind: :message, from: chain.correlation, to: "human",
                          causal_parents: [chain.head_digest], body: { "question" => "which file?" })
      end
      let(:answer) do
        writer.put(chain, kind: :message, from: "human", to: chain.correlation,
                          causal_parents: [question.digest], body: { "answer" => "the readme" })
      end

      it "are fetchable by digest with their causal edges intact" do
        records = roundtrip([open_header, Lain::SessionRecord.turn(chain.head),
                             Lain::Telemetry::Message.from_event(question).to_journal,
                             Lain::Telemetry::Message.from_event(answer).to_journal])

        loaded = described_class.new(records).recording

        expect(loaded.messages.map(&:digest)).to eq([question.digest, answer.digest])
        expect(loaded.timeline.store.fetch(question.digest).causal_parents).to eq(question.causal_parents)
        expect(loaded.timeline.store.fetch(answer.digest).causal_parents).to eq([question.digest])
      end

      it "fails an edited message record's digest check with Corrupt" do
        records = roundtrip([open_header, Lain::SessionRecord.turn(chain.head),
                             Lain::Telemetry::Message.from_event(question).to_journal])
        records.last["payload"] = { "question" => "forged" }

        expect { described_class.new(records).recording }
          .to raise_error(Lain::Bench::Session::Corrupt, /message record/)
      end
    end

    describe "an existing bench (offline) recording" do
      it "loads unchanged: not flagged open, and carries no messages" do
        loaded = recording

        expect(loaded.open?).to be(false)
        expect(loaded.messages).to eq([])
      end
    end
  end

  # The memory read path, event-sourced from the recording itself: successful
  # memory_write tool_use inputs ARE the write log, and content addressing
  # makes the journaled memory_root chain the proof -- replaying the same
  # writes into a fresh Index must land on the same roots, byte for byte.
  describe "memory replay" do
    def memory_input(id)
      { "id" => id, "description" => "notes on #{id}", "body" => "body of #{id}" }
    end

    let(:recorder) { Lain::Memory::Recorder.new }
    let(:memory_toolset) { Lain::Toolset.new([Lain::Tools::MemoryWrite.new(recorder:)]) }
    let(:memory_journal) { Lain::Memory::JournalMemoryRoot.new(journal:, recorder:) }

    let(:memory_responses) do
      [tool_response(["tu_1", "memory_write", memory_input("aspirin-dosing")], usage:, model: "claude-opus-4-8"),
       tool_response(["tu_2", "memory_write", memory_input("warfarin-inr")], usage:, model: "claude-opus-4-8"),
       text_response("done", usage:, model: "claude-opus-4-8")]
    end

    # One recorded memory-bearing run: the live records (request_sent /
    # turn_usage, plus memory_root when run_journal is the decorator) and the
    # session header and turn records Session.write appends.
    def record_memory_run(run_journal)
      agent, = record_journaled_run(memory_responses, journal: run_journal,
                                                      toolset: memory_toolset, context:, workspace:)
      Lain::Bench::Session.write(journal, timeline: agent.timeline, context:, toolset: memory_toolset, workspace:)
    end

    def parsed_records
      journal_io.string.each_line.map { |line| JSON.parse(line) }
    end

    def memory_records
      record_memory_run(memory_journal)
      parsed_records
    end

    def journaled_roots(records)
      records.select { |record| record["type"] == "memory_root" }
    end

    it "replays roots equal to the journaled memory_root chain, answered by #memory_root_at" do
      records = memory_records
      loaded = described_class.new(records).recording

      roots = journaled_roots(records)
      expect(roots.size).to eq(3)
      roots.each do |record|
        expect(loaded.memory_root_at(record.fetch("turn_digest"))).to eq(record.fetch("root"))
      end
    end

    it "checks out as-of-turn-N: turn 3 sees the turn-2 write and not the turn-4 write" do
      loaded = described_class.new(memory_records).recording
      between = loaded.timeline.to_a[2] # the tool_result turn between the two writes

      snapshot = loaded.memory_at(between.digest)
      expect(snapshot.fetch("aspirin-dosing").body).to eq("body of aspirin-dosing")
      expect(snapshot.key?("warfarin-inr")).to be(false)
    end

    context "when one memory_write was refused (its tool_result is an error)" do
      let(:memory_responses) do
        # A multi-line description fails Memory::Item's one-line invariant, so
        # the tool answers an error Result and the recorder never advances.
        refused = { "id" => "leaky-item", "description" => "two\nlines", "body" => "b" }
        [tool_response(["tu_1", "memory_write", memory_input("aspirin-dosing")],
                       ["tu_2", "memory_write", refused], usage:, model: "claude-opus-4-8"),
         text_response("done", usage:, model: "claude-opus-4-8")]
      end

      it "keeps the refused id out of every checkout while roots still verify" do
        records = memory_records
        loaded = described_class.new(records).recording

        journaled_roots(records).each do |record|
          expect(loaded.memory_root_at(record.fetch("turn_digest"))).to eq(record.fetch("root"))
        end
        loaded.timeline.to_a.each do |turn|
          expect(loaded.memory_at(turn.digest).key?("leaky-item")).to be(false)
        end
      end
    end

    it "raises Corrupt naming the turn digest when a memory_root record was altered on disk" do
      records = memory_records
      target = journaled_roots(records).last
      target["root"] = "blake3:#{"0" * 64}"

      expect { described_class.new(records).recording }
        .to raise_error(Lain::Bench::Session::Corrupt, /#{Regexp.escape(target.fetch("turn_digest"))}/)
    end

    it "loads a memory-free journal with an empty index at every turn" do
      loaded = recording
      loaded.timeline.to_a.each do |turn|
        expect(loaded.memory_root_at(turn.digest)).to be_nil
        expect(loaded.memory_at(turn.digest)).to be_empty
      end
    end

    context "when the recording predates the memory_root decorator" do
      it "replays writes unverified and checkouts reflect them" do
        record_memory_run(journal)
        records = parsed_records
        expect(journaled_roots(records)).to be_empty

        loaded = described_class.new(records).recording
        head = loaded.timeline.to_a.last
        expect(loaded.memory_at(head.digest).to_h.keys).to match_array(%w[aspirin-dosing warfarin-inr])
      end
    end

    it "raises Corrupt when the memory_root chain covers only some write-bearing turns" do
      records = memory_records
      records.delete(journaled_roots(records).first)

      expect { described_class.new(records).recording }
        .to raise_error(Lain::Bench::Session::Corrupt, /memory_root/)
    end
  end
end
