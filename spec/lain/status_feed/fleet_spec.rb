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

  def message_event(id, body:, causal_parents:)
    Lain::Event.new(kind: :message, payload_digest: "blake3:msg-#{id}", body:, causal_parents:,
                    from: "child", to: "parent")
  end

  # A one-shot's completion, shaped as Tools::Subagent::Lineage#message writes
  # one: the result, the child's final head, and the terminal mark, citing the
  # :spawn and that head as its causal parents.
  def completion(spawn, id: "done")
    message_event(id, body: { "result" => "the answer", "final" => "blake3:final",
                              "lifecycle" => Lain::Telemetry::SpawnLifecycle::STOPPED },
                      causal_parents: [spawn.digest, "blake3:final"])
  end

  # An actor's farewell, shaped as Tools::Subagent::Actor#stop writes one: no
  # result key at all, only the mark, citing the address -- which IS the spawn
  # digest, since Actor#launch takes `@spawn.digest` as `@address`.
  def farewell(spawn)
    message_event("farewell", body: { "text" => "actor stopped",
                                      "lifecycle" => Lain::Telemetry::SpawnLifecycle::STOPPED },
                              causal_parents: [spawn.digest, "blake3:head"])
  end

  # The reply an actor writes on EVERY turn it answers, not only its last.
  def settled(spawn)
    message_event("settled", body: { "text" => "here you go",
                                     "lifecycle" => Lain::Telemetry::SpawnLifecycle::SETTLED },
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
end
