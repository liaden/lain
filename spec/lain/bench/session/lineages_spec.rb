# frozen_string_literal: true

require "json"
require "tmpdir"

# The one reader of a session's subagent lineages, over the shape a chat
# actually records: a `:spawn` naming the parent head it spawned from, a
# completion `message` naming that spawn and the child's final turn, and the
# child's turns as `child_turn` records. Every file here is written by a real
# {Lain::SessionRecord::Scribe} observing a real spawn.
RSpec.describe Lain::Bench::Session::Lineages do
  def text(body) = [{ "type" => "text", "text" => body }]

  def two_spawns
    RecordedSpawnSession.new(
      parent_responses: [tool_response(["tu_1", "subagent", { "prompt" => "investigate the login bug" }]),
                         tool_response(["tu_2", "subagent", { "prompt" => "audit the payment path" }]),
                         text_response("parent done")],
      child_responses: [text_response("the token TTL was zero"), text_response("the retry was unbounded")]
    ).run
  end

  def lineages_of(session) = described_class.of(Lain::Bench::Session.load(session.lines))

  def texts(turns) = turns.map { |turn| turn.content.first["text"] }

  describe "a chat that spawned two one-shot subagents" do
    let(:session) { two_spawns }
    let(:lineages) { lineages_of(session).to_a }

    it "yields one lineage per completed spawn, in the order the completions were recorded" do
      expect(lineages.size).to eq(2)
      expect(lineages.map { |lineage| texts(lineage.child_turns) })
        .to eq([["investigate the login bug", "the token TTL was zero"],
                ["audit the payment path", "the retry was unbounded"]])
    end

    it "pairs each completion with the :spawn it cites and the child's final turn" do
      lineages.each do |lineage|
        expect(lineage.spawn.kind).to eq(:spawn)
        expect(lineage.completion.causal_parents).to include(lineage.spawn.digest)
        expect(lineage.child_turns.last.digest).to eq(lineage.completion.body.fetch("final"))
      end
    end

    it "names the parent turn each child was spawned from, a turn on the parent's own chain" do
      parent_chain = session.agent.timeline.ancestor_digests

      expect(lineages.map(&:spawned_from)).to all(satisfy { |digest| parent_chain.include?(digest) })
      expect(lineages.map(&:spawned_from).uniq.size).to eq(2)
    end

    it "walks a fresh child to its own root" do
      expect(lineages.map { |lineage| lineage.child_turns.first.parent }).to all(be_nil)
    end

    it "is Enumerable, so a caller folds it without materializing an Array it may not want" do
      expect(lineages_of(session).map(&:spawned_from)).to eq(lineages.map(&:spawned_from))
    end
  end

  describe "an inherit-prefix child" do
    let(:session) do
      RecordedSpawnSession.new(prefix: :inherit,
                               parent_responses: [tool_response(["tu_1", "subagent", { "prompt" => "go" }]),
                                                  text_response("parent done")],
                               child_responses: [text_response("child done")]).run
    end

    it "stops the child's turns at the parent head its spawn names" do
      lineage = lineages_of(session).first

      expect(lineage.child_turns.first.parent).to eq(lineage.spawned_from)
      expect(lineage.child_turns.map(&:digest) & session.agent.timeline.ancestor_digests).to be_empty
      # The first child turn answers the inherited call that spawned it; the
      # child's own work follows.
      expect(texts(lineage.child_turns).compact).to eq(["go", "child done"])
    end
  end

  # The same work from one head IS one spawn -- the ruling the spawn's address
  # rests on -- so its twin completion is one lineage rather than a duplicate.
  it "reads identical twins from one head as one lineage" do
    same = { "prompt" => "same" }
    session = RecordedSpawnSession.new(
      parent_responses: [tool_response(["tu_1", "subagent", same], ["tu_2", "subagent", same]),
                         text_response("parent done")],
      child_responses: [text_response("same answer"), text_response("same answer")]
    ).run

    expect(lineages_of(session).count).to eq(1)
  end

  # A child that failed leaves a completion so the fleet can retire it, but it
  # answered nothing: consolidation and improvement read finished work, and a
  # failed child's transcript is not that.
  describe "a child that failed" do
    def echo_forever = tool_response(["e1", "echo", { "text" => "again" }])

    it "yields the lineage that finished and not the one that hit its ceiling" do
      session = RecordedSpawnSession.new(
        parent_responses: [tool_response(["tu_1", "subagent", { "prompt" => "investigate the login bug" }]),
                           tool_response(["tu_2", "subagent", { "prompt" => "loop on the payment path" }]),
                           text_response("parent done")],
        child_responses: [text_response("the token TTL was zero"), echo_forever]
      ).run

      expect(session.records.count { |record| record.dig("payload", "lifecycle") == "failed" }).to eq(1)
      expect(lineages_of(session).map { |lineage| texts(lineage.child_turns) })
        .to eq([["investigate the login bug", "the token TTL was zero"]])
    end

    it "reads a file whose only completion failed, yielding nothing and refusing nothing" do
      session = RecordedSpawnSession.new(
        parent_responses: [tool_response(["tu_1", "subagent", { "prompt" => "go" }]), text_response("parent done")],
        child_responses: []
      ).run

      expect(session.records.count { |record| record.dig("payload", "lifecycle") == "failed" }).to eq(1)
      expect { Lain::Bench::Session.load(session.lines) }.not_to raise_error
      Dir.mktmpdir do |dir|
        expect(described_class.read(session.write(File.join(dir, "failed.ndjson"))).to_a).to eq([])
      end
    end
  end

  it "yields nothing for a session that spawned nothing" do
    session = RecordedSpawnSession.new(parent_responses: [text_response("no spawn")], child_responses: []).run

    expect(lineages_of(session).to_a).to eq([])
  end

  describe ".read" do
    around do |example|
      Dir.mktmpdir do |dir|
        @dir = dir
        example.run
      end
    end

    it "reads a session file's lineages" do
      path = two_spawns.write(File.join(@dir, "s1.ndjson"))

      expect(described_class.read(path).count).to eq(2)
    end

    # A live or SIGKILLed session has no closer yet; the lineages it already
    # completed are as recorded as a closed session's.
    it "reads the completed lineages of a session still open" do
      lines = two_spawns.lines.reject { |line| JSON.parse(line)["type"] == "session_closed" }
      path = File.join(@dir, "open.ndjson")
      File.write(path, lines.join)

      expect(described_class.read(path).count).to eq(2)
    end

    it "refuses a torn child_turn line by name, never reading the session as holding fewer lineages" do
      lines = two_spawns.lines
      torn = lines.index { |line| JSON.parse(line)["type"] == Lain::SessionRecord::CHILD_TURN_TYPE }
      lines[torn] = "#{lines[torn][0, lines[torn].size / 2]}\n"
      path = File.join(@dir, "torn.ndjson")
      File.write(path, lines.join)

      expect { described_class.read(path) }
        .to raise_error(Lain::Bench::Session::Corrupt, /#{Regexp.escape(path)}: line \d+ is torn/)
    end

    # A chat's file is read while it is still being written, or after it was
    # killed mid-spawn. Every agent writes a tool round's turn before its tools
    # run, so a spawn in flight already cites a turn the file holds, and the
    # open file is read by the same rules as a closed one.
    describe "a session still being written" do
      def spawn(id, prompt) = tool_response([id, "subagent", { "prompt" => prompt }])

      def snapshot = tool_response(["tu_snap", "snapshot", {}])

      def snapshot_at(session)
        File.join(@dir, "live.ndjson").tap { |path| File.write(path, session.snapshots.first) }
      end

      def child_texts(path) = described_class.read(path).map { |lineage| texts(lineage.child_turns).compact }

      it "reads the lineage it completed while a later child is still running" do
        session = RecordedSpawnSession.new(
          parent_responses: [spawn("tu_a", "first child"), spawn("tu_b", "second child"), text_response("done")],
          child_responses: [text_response("first done"), snapshot, text_response("second done")]
        ).run

        expect(child_texts(snapshot_at(session))).to eq([["first child", "first done"]])
      end

      # Damage no live writer produces, refused by name in an open file.
      describe "damage in an open file" do
        let(:live) do
          RecordedSpawnSession.new(
            parent_responses: [spawn("tu_a", "first child"), spawn("tu_b", "second child"), text_response("done")],
            child_responses: [text_response("first done"), snapshot, text_response("second done")]
          ).run.snapshots.first.each_line.map { |line| JSON.parse(line) }
        end

        def in_flight(records) = records.reverse.find { |record| record["kind"] == "spawn" }

        def completion(records) = records.find { |record| record.dig("payload", "final") }

        def written(records)
          File.join(@dir, "damaged.ndjson").tap do |path|
            File.write(path, records.map { |record| "#{JSON.generate(record)}\n" }.join)
          end
        end

        it "reads the undamaged snapshot these shapes are cut from" do
          expect(described_class.read(written(live)).count).to eq(1)
        end

        it "refuses a nil among a record's causal parents" do
          completion(live)["causal_parents"] += [nil]

          expect { described_class.read(written(live)) }.to raise_error(Lain::Bench::Session::Corrupt, /causal_parents/)
        end

        it "refuses a message citing a digest no record carries" do
          completion(live)["causal_parents"] = [completion(live)["causal_parents"].first, "blake3:#{"d" * 64}"]

          expect { described_class.read(written(live)) }.to raise_error(Lain::Bench::Session::Corrupt, /never landed/)
        end

        it "refuses a completion whose final turn never landed" do
          final = completion(live).dig("payload", "final")
          live.reject! { |record| record["digest"] == final }

          expect { described_class.read(written(live)) }.to raise_error(Lain::Bench::Session::Corrupt, /never landed/)
        end

        it "refuses a completion whose final names a turn other than the one it cites" do
          fake = "blake3:#{"f" * 64}"
          completion(live)["payload"]["final"] = fake
          completion(live)["causal_parents"] = [completion(live)["causal_parents"].first, fake].sort

          expect { described_class.read(written(live)) }.to raise_error(Lain::Bench::Session::Corrupt, /never landed/)
        end

        # The turn is priced as it commits, so its usage record still names it:
        # a usage record is no stand-in for the turn a spawn cites.
        it "refuses an in-flight spawn whose parent turn is missing, though its usage names it" do
          head = in_flight(live).dig("payload", "spawned_from")
          live.reject! { |record| record["type"] == "turn" && record["digest"] == head }

          expect { described_class.read(written(live)) }.to raise_error(Lain::Bench::Session::Corrupt, /never landed/)
        end

        it "refuses a torn line with whole records after it, naming the line" do
          path = written(live)
          lines = File.readlines(path)
          torn = lines.index { |line| JSON.parse(line)["type"] == Lain::SessionRecord::CHILD_TURN_TYPE }
          lines[torn] = "#{lines[torn][0, 40]}\n"
          File.write(path, lines.join)

          expect { described_class.read(path) }
            .to raise_error(Lain::Bench::Session::Corrupt, /#{Regexp.escape(path)}: line #{torn + 1} is torn/)
        end

        it "reads past a torn last line, which a killed writer leaves" do
          path = written(live)
          File.write(path, "#{File.read(path)}{\"type\":\"child_tu")

          expect(described_class.read(path).count).to eq(1)
        end
      end

      it "reads a grandchild that finished while its own parent child is still running" do
        session = RecordedSpawnSession.new(
          parent_responses: [spawn("tu_c", "child task"), text_response("done")],
          child_responses: [spawn("tu_g", "grandchild task"), snapshot, text_response("child done")],
          grandchild_responses: [text_response("grandchild done")]
        ).run

        expect(child_texts(snapshot_at(session))).to eq([["grandchild task", "grandchild done"]])
      end
    end

    # A resumed file's Store is rebuilt across its chain, but its lineages are
    # the completions IT records: every other reader of a session file is
    # scoped to that file, and reading the chain's would count a prior file's
    # lineage once per file that continues it.
    describe "a resumed session" do
      let(:prior) { two_spawns.tap { |session| session.write(File.join(@dir, "prior.ndjson")) } }

      def resumed(parent_responses, child_responses)
        RecordedSpawnSession.new(resuming: [prior, "prior.ndjson"], parent_responses:, child_responses:).run("again")
      end

      it "reads the lineages the resumed file itself recorded, its Store landed through the prior file" do
        session = resumed([tool_response(["tu_r", "subagent", { "prompt" => "resumed child" }]), text_response("ok")],
                          [text_response("resumed done")])
        path = session.write(File.join(@dir, "resumed.ndjson"))

        expect(described_class.read(path).map { |lineage| texts(lineage.child_turns) })
          .to eq([["resumed child", "resumed done"]])
      end

      it "reads none from a resumed file that spawned nothing itself" do
        path = resumed([text_response("nothing to spawn")], []).write(File.join(@dir, "resumed.ndjson"))

        expect(described_class.read(path).count).to eq(0)
        expect(described_class.read(File.join(@dir, "prior.ndjson")).count).to eq(2)
      end
    end
  end

  # The graders read a journal SLICE, often with no header at all, so this door
  # rebuilds a Store only when the slice records a completed spawn to read.
  describe ".recorded_in" do
    it "reads the lineages a spawning session's records carry" do
      expect(described_class.recorded_in(two_spawns.records).count).to eq(2)
    end

    it "reads a header-less slice with no completion as holding none, without rebuilding it" do
      slice = Lain::Timeline.empty.commit(role: :user, content: text("hi")).to_a
                            .map { |turn| Lain::SessionRecord.turn(turn) }
      allow(Lain::Bench::Session::Loader).to receive(:new).and_call_original

      expect(described_class.recorded_in(slice).to_a).to eq([])
      expect(Lain::Bench::Session::Loader).not_to have_received(:new)
    end

    it "refuses a completion whose child turns are missing from the slice" do
      records = two_spawns.records.reject { |record| record["type"] == Lain::SessionRecord::CHILD_TURN_TYPE }

      expect { described_class.recorded_in(records).to_a }.to raise_error(Lain::Bench::Session::Corrupt)
    end
  end
end
