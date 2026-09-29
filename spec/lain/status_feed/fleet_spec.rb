# frozen_string_literal: true

# The fleet as {Lain::StatusFeed} publishes it: the digest of every DISTINCT
# `:spawn` the tee has carried. Keyed by digest, so a journal replay
# redelivering one real spawn never grows a phantom second entry -- and keyed
# by CONTENT address, so two separately constructed Event objects naming the
# same spawn are one member, which is the whole point of content addressing.
#
# Which events reach this object is the feed's routing, not this object's, and
# it stays pinned next door in spec/lain/status_feed_spec.rb's "fleet" block.
RSpec.describe Lain::StatusFeed::Fleet do
  def spawn_event(id)
    Lain::Event.new(kind: :spawn, payload_digest: "blake3:spawn-#{id}", from: "parent", to: nil)
  end

  # One of a pair of twins: two adoptions of one arm from one head, whose
  # bodies differ in nothing but the per-adoption ordinal
  # {Lain::Tools::Subagent::Lineage} writes into an actor's `:spawn`. The
  # payload is addressed the way {Lain::Event::ChainWriter} addresses one --
  # digest OF the body -- rather than by a hand-written literal, because the
  # ordinal is only a separator if a real hash carries it that far, and a
  # fixture that stamped its own distinct digests would prove nothing. Only the
  # addressing is borrowed: the envelope fields ChainWriter also stamps
  # (`causal_parents`, `correlation`) are omitted, since twins would share them
  # and they cannot separate anything.
  def adoption(ordinal)
    payload = Lain::Event::Payload.new(
      kind: :spawn,
      body: { "prefix" => "fresh", "posture" => "schema", "only" => [],
              "spawned_from" => "blake3:head", "adoption" => ordinal,
              "lifecycle" => Lain::StatusFeed::SpawnLifecycle::LAUNCHED }
    )
    Lain::Event.new(kind: :spawn, from: "parent", to: nil,
                    payload_digest: payload.digest, body: payload.body)
  end

  def message_event(id, body:, causal_parents:)
    Lain::Event.new(kind: :message, payload_digest: "blake3:msg-#{id}", body:, causal_parents:,
                    from: "child", to: "parent")
  end

  # A one-shot's completion, shaped as Tools::Subagent::Lineage#message writes
  # one: the result, the child's final head, and the terminal mark, citing the
  # :spawn and that head as its causal parents.
  def completion(spawn, id: "done")
    message_event(id, body: { "result" => "the answer", "final" => "blake3:final",
                              "lifecycle" => Lain::StatusFeed::SpawnLifecycle::STOPPED },
                      causal_parents: [spawn.digest, "blake3:final"])
  end

  # An actor's farewell, shaped as Tools::Subagent::Actor#stop writes one: no
  # result key at all, only the mark, citing the address -- which IS the spawn
  # digest, since Actor#launch takes `@spawn.digest` as `@address`.
  def farewell(spawn)
    message_event("farewell", body: { "text" => "actor stopped",
                                      "lifecycle" => Lain::StatusFeed::SpawnLifecycle::STOPPED },
                              causal_parents: [spawn.digest, "blake3:head"])
  end

  # The reply an actor writes on EVERY turn it answers, not only its last.
  def settled(spawn)
    message_event("settled", body: { "text" => "here you go",
                                     "lifecycle" => Lain::StatusFeed::SpawnLifecycle::SETTLED },
                             causal_parents: [spawn.digest, "blake3:head"])
  end

  describe "#digests" do
    it "is empty before anything has launched -- a fresh fleet claims nothing" do
      expect(described_class.new.digests).to eq([])
    end

    # The extraction is a real object rather than a moved instance variable,
    # and this example is what says so: no StatusFeed is constructed anywhere
    # in it, so the answer can only come from the fleet itself.
    it "answers what it holds with no StatusFeed involved" do
      fleet = described_class.new
      launch = spawn_event("a")

      fleet.launched(launch)

      expect(fleet.digests).to eq([launch.digest])
    end
  end

  describe "#launched" do
    it "names each distinct spawn, in the order they arrived" do
      fleet = described_class.new
      first = spawn_event("a")
      second = spawn_event("b")

      fleet.launched(first)
      fleet.launched(second)

      expect(fleet.digests).to eq([first.digest, second.digest])
    end

    # The other side of the dedup below, and the one that used to be missing:
    # two spawns separated by nothing but the ordinal are TWO members. What this
    # pins is the FOLD, not what the actor path feeds it -- the fixture builds
    # the pair directly and never routes through {Lain::Tools::Subagent::Lineage},
    # so stripping the ordinal from an actor's spawn body would leave this green
    # and redden the end-to-end example in
    # spec/lain/supervisor_reactor_spec.rb instead. Here the claim is narrower
    # and worth its own line: a difference that small IS a difference to a set
    # keyed by content address.
    it "carries two adoptions of one arm as two members, ordinal apart" do
      fleet = described_class.new
      first = adoption(1)
      second = adoption(2)

      fleet.launched(first)
      fleet.launched(second)

      expect(fleet.digests).to eq([first.digest, second.digest])
    end

    it "dedups a redelivered spawn by digest -- a journal replay grows no phantom entry" do
      fleet = described_class.new

      fleet.launched(spawn_event("a"))
      fleet.launched(spawn_event("a")) # a fresh Event object, same content address

      expect(fleet.digests).to eq([spawn_event("a").digest])
    end
  end

  # The side that did not exist until a spawn's lineage could be asked whether
  # it had finished. Journal-derived by necessity: the feed may not consult a
  # live registry, so a departure is only ever a fact read off a record.
  describe "#completed" do
    it "drops a one-shot whose completion names the spawn" do
      fleet = described_class.new
      launch = spawn_event("a")
      fleet.launched(launch)

      fleet.completed(completion(launch))

      expect(fleet.digests).to eq([])
    end

    it "drops an actor whose farewell names the spawn it took as its address" do
      fleet = described_class.new
      launch = spawn_event("a")
      fleet.launched(launch)

      fleet.completed(farewell(launch))

      expect(fleet.digests).to eq([])
    end

    # "settled" rides every actor turn, so reading it as terminal would retire
    # a long-lived actor on its first reply -- a worse defect than never
    # retiring it at all.
    it "keeps an actor that merely settled a turn" do
      fleet = described_class.new
      launch = spawn_event("a")
      fleet.launched(launch)

      fleet.completed(settled(launch))

      expect(fleet.digests).to eq([launch.digest])
    end

    it "keeps a member a plain tell names, since a tell is conversation and not a transition" do
      fleet = described_class.new
      launch = spawn_event("a")
      fleet.launched(launch)

      fleet.completed(message_event("tell", body: { "text" => "still working" },
                                            causal_parents: [launch.digest]))

      expect(fleet.digests).to eq([launch.digest])
    end

    # The standing @seen set is what makes this true rather than the live one:
    # a redelivered :spawn names a child this run has already accounted for,
    # and re-listing it would resurrect one that is gone.
    it "never re-enters a spawn that already completed, however often it is redelivered" do
      fleet = described_class.new
      launch = spawn_event("a")
      fleet.launched(launch)
      fleet.completed(completion(launch))

      fleet.launched(spawn_event("a"))

      expect(fleet.digests).to eq([])
    end

    # Retirement is attributable, not fleet-wide. The example above it has a
    # roster of one, so it cannot tell "the right member left" from "a member
    # left"; twins can, and they are the pair where getting it wrong costs a
    # live child its place on the HUD rather than merely an undercount.
    it "retires only the twin its farewell names, leaving the survivor on the roster" do
      fleet = described_class.new
      first = adoption(1)
      second = adoption(2)
      fleet.launched(first)
      fleet.launched(second)

      fleet.completed(farewell(first))

      expect(fleet.digests).to eq([second.digest])
    end

    # The one-shot twins: two subagent calls in one assistant turn spawn from
    # one head. Written by the REAL writer, for the reason {#adoption} hashes a
    # real body -- the work is only a separator if the digest carries it here.
    it "counts two one-shots of different work from one head as two, and retires each on its own completion" do
      store = Lain::Store.new
      head = Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => "go" }])
      child = Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => "work" }])
      lineage = Lain::Tools::Subagent::Lineage.new(
        policy: Lain::Tool::SpawnPolicy.new(prefix: :fresh, posture: :schema, only: [])
      )
      fleet = described_class.new
      aspirin = lineage.spawn(head, prompt: "survey the aspirin trials")
      statin = lineage.spawn(head, prompt: "survey the statin trials")
      [aspirin, statin].each { |spawn| fleet.launched(spawn) }

      expect(fleet.digests).to eq([aspirin.digest, statin.digest])

      fleet.completed(lineage.message(head, aspirin, child, Data.define(:text).new(text: "three trials")))

      expect(fleet.digests).to eq([statin.digest])
    end

    it "lists a relaunch of a failed actor's work as a second running member" do
      store = Lain::Store.new
      head = Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => "go" }])
      policy = Lain::Tool::SpawnPolicy.new(prefix: :fresh, posture: :schema, only: [])
      fleet = described_class.new
      first = Lain::Tools::Subagent::Lineage.new(policy:, lane: "issue.demo.a")
                                            .spawn(head, prompt: "go", lifecycle: "launched")
      fleet.launched(first)
      fleet.completed(farewell(first))
      relaunch = Lain::Tools::Subagent::Lineage.new(policy:, lane: "issue.demo.a")
                                               .spawn(head, prompt: "go", lifecycle: "launched")
      fleet.launched(relaunch)

      expect(fleet.digests).to eq([relaunch.digest])
    end

    # A child that hit its ceiling never answers, and its completion says so. A
    # fleet that waited for an answer would count it running for the rest of
    # the session.
    it "drops a one-shot whose failed completion names the spawn" do
      fleet = described_class.new
      launch = spawn_event("a")
      fleet.launched(launch)

      fleet.completed(message_event("failed", body: { "lifecycle" => Lain::StatusFeed::SpawnLifecycle::FAILED,
                                                      "error" => "Lain::Agent::Budget::Exceeded" },
                                              causal_parents: [launch.digest]))

      expect(fleet.digests).to eq([])
    end

    # The same work from one head is one spawn, so twins share one entry, and
    # the first of them to end -- here by failing -- retires it, exactly as the
    # first to answer does.
    it "retires identical twins' one shared entry when one of them fails" do
      store = Lain::Store.new
      head = Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => "go" }])
      lineage = Lain::Tools::Subagent::Lineage.new(
        policy: Lain::Tool::SpawnPolicy.new(prefix: :fresh, posture: :schema, only: [])
      )
      fleet = described_class.new
      twins = Array.new(2) { lineage.spawn(head, prompt: "survey the aspirin trials") }
      twins.each { |spawn| fleet.launched(spawn) }

      fleet.completed(lineage.ended(head, twins.first, Lain::Timeline.empty(store:),
                                    lifecycle: Lain::StatusFeed::SpawnLifecycle::FAILED, error: "Lain::Error"))

      expect(fleet.digests).to eq([])
    end

    it "leaves a member alone when the completion names some other spawn" do
      fleet = described_class.new
      launch = spawn_event("a")
      fleet.launched(launch)

      fleet.completed(completion(spawn_event("z")))

      expect(fleet.digests).to eq([launch.digest])
    end

    # A completion for a spawn this fleet never carried must not poison the
    # digest against a spawn that arrives afterwards -- the tee has no ordering
    # promise across a warm start, and a terminal read as a retirement of
    # something never launched would silently swallow the next real launch.
    it "records nothing from a completion for a spawn it never saw" do
      fleet = described_class.new
      unseen = spawn_event("a")

      fleet.completed(completion(unseen))

      expect(fleet.digests).to eq([])

      fleet.launched(unseen)

      expect(fleet.digests).to eq([unseen.digest])
    end

    # Both shapes reach StatusFeed's :message arm: it dispatches on `#kind`
    # alone, so a raw Event and the Telemetry::Message the actor path promotes
    # it into both land here. They carry the body under DIFFERENT readers --
    # `#body` on the Event, `#payload` on the record -- and this is the example
    # that says the fleet reads them alike rather than raising on one.
    it "reads a Telemetry::Message exactly as it reads the Event it was promoted from" do
      fleet = described_class.new
      launch = spawn_event("a")
      fleet.launched(launch)

      fleet.completed(Lain::Telemetry::Message.from_event(farewell(launch)))

      expect(fleet.digests).to eq([])
    end
  end

  describe "#tree" do
    # The tree's parent edge is the only thing the `:spawn` body cannot carry:
    # it names the HEAD it was spawned from, and which spawn owns that head is
    # a fact only the child's own progress records tell.
    def spawn_from(_id, head)
      payload = Lain::Event::Payload.new(kind: :spawn, body: { "spawned_from" => head })
      Lain::Event.new(kind: :spawn, from: "parent", to: nil, payload_digest: payload.digest, body: payload.body)
    end

    def progress(spawn, **) = Lain::Telemetry::ChildProgress.new(spawn: spawn.digest, **)

    let(:now) { Time.utc(2026, 9, 20, 12, 0, 0) }

    it "is empty before anything has launched" do
      expect(described_class.new.tree).to eq([])
    end

    it "opens a row running, at depth nought, with the role and task its dispatch named" do
      fleet = described_class.new(clock: -> { now })
      launch = spawn_event("a")
      fleet.launched(launch)

      fleet.progressed(progress(launch, role: "dev", task_line: "port the parser", worker: "dev.1", turns: 0))

      expect(fleet.tree).to eq([{ "spawn" => launch.digest, "role" => "dev", "task" => "port the parser",
                                  "worker" => "dev.1", "state" => "running", "turns" => 0, "depth" => 0,
                                  "started" => "2026-09-20T12:00:00Z" }])
    end

    it "puts a grandchild under the child whose head it was spawned from, with each one's turns" do
      fleet = described_class.new(clock: -> { now })
      child = spawn_event("dev")
      fleet.launched(child)
      fleet.progressed(progress(child, role: "dev", task_line: "port the parser", turns: 0))
      fleet.progressed(progress(child, turns: 1, head: "blake3:dev-t1"))
      grandchild = spawn_from("test", "blake3:dev-t1")
      fleet.launched(grandchild)
      fleet.progressed(progress(grandchild, role: "test_engineer", task_line: "write the specs", turns: 0))

      expect(fleet.tree.map { |row| row.values_at("role", "state", "turns", "depth") })
        .to eq([["dev", "running", 1, 0], ["test_engineer", "running", 0, 1]])
    end

    # The child stands on a new head every turn, and only the one it is
    # standing on now can be spawned from -- so a grandchild launched after the
    # parent moved on still lands under it.
    it "places a grandchild against the head its parent is standing on now" do
      fleet = described_class.new(clock: -> { now })
      child = spawn_event("dev")
      fleet.launched(child)
      fleet.progressed(progress(child, turns: 1, head: "blake3:dev-t1"))
      fleet.progressed(progress(child, turns: 2, head: "blake3:dev-t2"))

      fleet.launched(spawn_from("test", "blake3:dev-t2"))

      expect(fleet.tree.map { |row| row["depth"] }).to eq([0, 1])
    end

    # A spawn whose head nobody reported is nobody's child: the run's own chain
    # spawns from a head no progress record ever names.
    it "roots a spawn whose head no child ever reported" do
      fleet = described_class.new(clock: -> { now })
      fleet.launched(spawn_from("a", "blake3:the-chat-head"))

      expect(fleet.tree.map { |row| row["depth"] }).to eq([0])
    end

    it "reads failed for a child that raised, and keeps its row where it was" do
      fleet = described_class.new(clock: -> { now })
      launch = spawn_event("a")
      fleet.launched(launch)

      fleet.completed(message_event("ended", body: { "lifecycle" => Lain::StatusFeed::SpawnLifecycle::FAILED,
                                                     "error" => "Lain::Agent::Budget::Exhausted" },
                                             causal_parents: [launch.digest]))

      expect([fleet.tree.map { |row| row["state"] }, fleet.digests]).to eq([["failed"], []])
    end

    it "reads done for a one-shot that answered, and stopped for one that was cancelled" do
      fleet = described_class.new(clock: -> { now })
      answered = spawn_event("a")
      cancelled = spawn_event("b")
      [answered, cancelled].each { |launch| fleet.launched(launch) }

      fleet.completed(completion(answered))
      fleet.completed(message_event("stop", body: { "lifecycle" => Lain::StatusFeed::SpawnLifecycle::STOPPED },
                                            causal_parents: [cancelled.digest]))

      expect(fleet.tree.map { |row| row["state"] }).to eq(%w[done stopped])
    end

    # The struct is rewritten every turn, so a session's whole spawn history in
    # it is a growing write per turn. Running rows are never dropped; the
    # oldest ended ones are.
    it "keeps every running row and only the most recent ended ones" do
      fleet = described_class.new(clock: -> { now })
      launches = Array.new(described_class::ENDED_SHOWN + 3) do |index|
        spawn_event("s#{index}").tap { |launch| fleet.launched(launch) }
      end

      launches.each { |launch| fleet.completed(completion(launch, id: launch.digest)) }

      expect(fleet.tree.size).to eq(described_class::ENDED_SHOWN)
    end

    it "ignores a progress record for a spawn it never carried" do
      fleet = described_class.new(clock: -> { now })

      fleet.progressed(progress(spawn_event("z"), turns: 4, head: "blake3:t4"))

      expect(fleet.tree).to eq([])
    end

    # It is read from `StatusFeed#observed`, which runs on every event the tee
    # carries -- a bash tool's stdout included -- while the fold moves only on
    # a spawn, a completion or a progress record.
    describe "the memo" do
      it "hands back the same rows without rebuilding them" do
        fleet = described_class.new(clock: -> { now })
        fleet.launched(spawn_event("a"))

        expect(fleet.tree).to be(fleet.tree)
      end

      it "is dropped by each of the three records that move the fold" do
        fleet = described_class.new(clock: -> { now })
        launch = spawn_event("a")
        fleet.launched(launch)
        after_launch = fleet.tree

        fleet.progressed(progress(launch, role: "dev", turns: 1, head: "blake3:t1"))
        after_progress = fleet.tree
        fleet.completed(completion(launch))

        expect([after_launch, after_progress, fleet.tree].map { |rows| rows.first["state"] })
          .to eq(%w[running running done])
        expect(after_progress.first["role"]).to eq("dev")
      end
    end
  end

  describe Lain::StatusFeed::Fleet::Row do
    let(:published) do
      { "spawn" => "blake3:s", "role" => "dev", "task" => "port the parser", "worker" => "dev.1",
        "state" => "running", "turns" => 3, "depth" => 1, "started" => "2026-09-20T12:00:00Z" }
    end

    it "draws one line, indented by its depth, aged against the instant it is handed" do
      row = described_class.at(published, now: Time.utc(2026, 9, 20, 12, 0, 45))

      expect(row.to_s).to eq("  dev  running  3t  45s  port the parser")
    end

    # A row this renderer cannot age still draws: it is a status surface, and a
    # torn instant must cost the age rather than the row.
    it "ages to nothing rather than raising on an instant it cannot read" do
      row = described_class.at(published.merge("started" => "not a time"), now: Time.utc(2026, 9, 20))

      expect(row.to_s).to eq("  dev  running  3t  port the parser")
    end

    # The input pane's header IS the frame the chat publishes, and a pane
    # redraws on a changed frame -- so a column that ticks costs a redraw a
    # second. `lain://status` keeps the age, where a redraw is free.
    it "leaves the age out for a surface that cannot afford to redraw" do
      expect(described_class.undated(published).to_s).to eq("  dev  running  3t  port the parser")
    end

    # The published struct is JSON read back off disk by a separate process,
    # so the record's own scrub is not the last word before a terminal.
    it "draws a published task holding an escape sequence inert" do
      row = described_class.undated(published.merge("task" => "clean\e[1A\e[2KPWNED"))

      expect(row.to_s).to eq("  dev  running  3t  cleanPWNED")
    end

    # Ninety-six characters of CJK are 214 terminal columns, and the indent
    # and four columns are drawn beside them.
    it "clamps the whole drawn row to its column budget, not the task to a character count" do
      row = described_class.undated(published.merge("task" => "\u65E5\u672C\u8A9E" * 40))

      expect(Lain::Ext::Prompt.width(row.to_s)).to be <= described_class::COLUMNS
      expect(row.to_s).to end_with("\u2026")
    end

    it "leaves a row inside the budget exactly as composed" do
      expect(described_class.undated(published).to_s).not_to end_with("\u2026")
    end
  end
end
