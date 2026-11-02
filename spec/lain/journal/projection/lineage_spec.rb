# frozen_string_literal: true

RSpec.describe Lain::Journal::Projection::Lineage do
  address = ->(char) { "blake3:#{char * 64}" }
  parent = address.call("0")
  head = address.call("1")
  spawn_s = address.call("5")
  spawn_t = address.call("7")
  reply_s = address.call("a")
  final_s = address.call("f")

  message = lambda do |digest:, from:, to: parent, causal_parents: [], payload: { "text" => "näive ✓" }, kind: :message|
    Lain::Telemetry::Message.new(digest:, kind:, from:, to:, payload:, causal_parents:, correlation: parent)
  end
  spawn = lambda do |digest|
    message.call(digest:, kind: :spawn, from: parent, to: nil, causal_parents: [head],
                 payload: { "prefix" => "fresh", "posture" => "schema", "spawned_from" => head })
  end

  tell = message.call(digest: address.call("2"), from: parent, to: spawn_s, causal_parents: [spawn_s])
  reply = message.call(digest: reply_s, from: spawn_s, causal_parents: [spawn_s])
  addendum = message.call(digest: address.call("b"), from: "otherchain", causal_parents: [reply_s])
  other = message.call(digest: address.call("c"), from: spawn_t, causal_parents: [spawn_t])
  completion = message.call(digest: address.call("d"), from: "childchain", causal_parents: [spawn_s, final_s],
                            payload: { "result" => "3 papers ✓", "final" => final_s, "lifecycle" => "stopped" })
  turn = Lain::Telemetry::Untyped.new(fields: { "type" => "turn", "digest" => head, "parent" => nil })
  session = [turn, spawn.call(spawn_s), spawn.call(spawn_t), tell, reply, other, addendum, completion]

  describe "the laws" do
    include_examples "an incremental fold",
                     projection: described_class,
                     population: -> { [session, session.values_at(1, 3, 4, 7), session.values_at(2, 5, 6)] }
  end

  describe "over a session" do
    subject(:lineages) { described_class.over(session) }

    it "follows a spawn to the records that chain to it, in the order they landed" do
      expect(lineages[spawn_s].records).to eq([spawn.call(spawn_s), tell, reply, addendum, completion])
    end

    it "keeps 2 spawns' lineages apart" do
      expect(lineages[spawn_t].records).to eq([spawn.call(spawn_t), other])
    end

    # A spawn's causal parent is the PARENT's head, and absorbing it would pull the parent's chain in.
    it "consults a spawn's causal parents and never absorbs them" do
      head_message = message.call(digest: address.call("e"), from: parent, causal_parents: [head])

      expect(lineages.step(head_message)[spawn_s].records).not_to include(head_message)
    end

    it "reads a spawn complete once a message citing it ends it, and not before" do
      expect([described_class.over(session.first(7))[spawn_s].complete?, lineages[spawn_s].complete?])
        .to eq([false, true])
      expect(lineages.completing(completion.digest) { nil }).to eq(spawn_s)
    end

    it "reads a tell citing the spawn as no completion" do
      expect(lineages.completing(tell.digest) { :none }).to eq(:none)
    end

    it "answers an empty, incomplete lineage for a spawn it never saw" do
      expect([lineages[address.call("9")].records, lineages[address.call("9")].complete?]).to eq([[], false])
    end

    it "carries every lineage a record does not join over as the same value" do
      stepped = lineages.step(message.call(digest: address.call("e"), from: spawn_t, causal_parents: [spawn_t]))

      expect(stepped[spawn_s]).to equal(lineages[spawn_s])
      expect(stepped[spawn_t]).not_to equal(lineages[spawn_t])
    end

    it "answers itself for a record that is not a message" do
      expect(lineages.step(turn)).to be(lineages)
    end
  end

  # An actor child that spawns its own child: the grandchild's records chain to the child through
  # the grandchild's spawn, and its completion ends the grandchild alone.
  describe "a grandchild" do
    grandchild = address.call("6")
    final_g = address.call("8")
    nested = spawn.call(grandchild).with(from: spawn_s)
    ended = message.call(digest: address.call("9"), from: "grandchain", causal_parents: [grandchild, final_g],
                         payload: { "result" => "nested ✓", "final" => final_g, "lifecycle" => "stopped" })
    subject(:lineages) { described_class.over([spawn.call(spawn_s), nested, ended]) }

    it "is in the child's lineage without ending it" do
      expect([lineages[spawn_s].records,
              lineages[spawn_s].completions]).to eq([[spawn.call(spawn_s), nested, ended], []])
    end

    it "reads its completion as ending the grandchild's spawn" do
      expect(lineages.completing(ended.digest) { nil }).to eq(grandchild)
    end
  end

  # A child its ceiling stopped, resumed: the resume's spawn starts at the stopped child's final
  # head and cites the stopped spawn, so it continues that lineage rather than opening a fresh one.
  describe "a resumed child" do
    resumed = address.call("4")
    final_r = address.call("e")
    stopped = message.call(digest: address.call("3"), from: "childchain", causal_parents: [spawn_s, final_s],
                           payload: { "lifecycle" => "failed", "error" => "Lain::Budget::Exceeded",
                                      "final" => final_s })
    resume = message.call(digest: resumed, kind: :spawn, from: parent, to: nil, causal_parents: [final_s, spawn_s],
                          payload: { "prefix" => "fresh", "posture" => "schema", "spawned_from" => final_s,
                                     "resumed_from" => spawn_s })
    answered = message.call(digest: address.call("8"), from: "childchain", causal_parents: [resumed, final_r],
                            payload: { "result" => "licenses ✓", "final" => final_r, "lifecycle" => "stopped" })
    subject(:lineages) { described_class.over([spawn.call(spawn_s), stopped, resume, answered]) }

    it "is in the stopped spawn's lineage, with its answer" do
      expect(lineages[spawn_s].records).to eq([spawn.call(spawn_s), stopped, resume, answered])
      expect(lineages.member?(spawn_s, resumed)).to be(true)
    end

    it "is ended by its own answer, which ends the stopped spawn no further" do
      expect(lineages.completing(answered.digest) { nil }).to eq(resumed)
      expect(lineages[spawn_s].completions).to eq([stopped.digest])
    end
  end
end
