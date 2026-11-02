# frozen_string_literal: true

require "stringio"
require "tmpdir"

RSpec.describe Lain::CLI::Watch::LineageFilter do
  address = ->(char) { "blake3:#{char * 64}" }
  parent = address.call("0")
  head = address.call("1")
  spawn_s = address.call("5")
  spawn_shadow = "blake3:5#{"b" * 63}"

  message = lambda do |digest:, from:, to: parent, causal_parents: [], kind: :message|
    Lain::Telemetry::Message.new(digest:, kind:, from:, to:, payload: { "text" => "hi" }, causal_parents:,
                                 correlation: parent)
  end
  spawn = lambda do |digest|
    message.call(digest:, kind: :spawn, from: parent, to: nil, causal_parents: [head])
  end

  let(:shadowed) { [] }

  def filter(selector, shadowed = [])
    described_class.new(selector:, on_shadowed: ->(digest) { shadowed << digest })
  end

  it "admits the first matching spawn and what chains to it by to, from or a causal parent" do
    watched = filter("5")
    records = [spawn.call(spawn_s),
               message.call(digest: address.call("2"), from: parent, to: spawn_s),
               message.call(digest: address.call("3"), from: spawn_s),
               message.call(digest: address.call("4"), from: "other", causal_parents: [address.call("3")])]

    expect(records.map { watched.admit?(_1) }).to eq([true, true, true, true])
    expect(watched.anchor).to eq(spawn_s)
  end

  # A resume carries on the child its ceiling stopped, so watching that child follows it on.
  it "follows a watched child that stopped into its resume, through to the resume's answer" do
    watched = filter("5", shadowed)
    final = address.call("f")
    resumed = address.call("6")
    records = [spawn.call(spawn_s),
               message.call(digest: address.call("3"), from: "child", causal_parents: [spawn_s, final]),
               message.call(digest: resumed, kind: :spawn, from: parent, to: nil, causal_parents: [final, spawn_s]),
               message.call(digest: address.call("7"), from: "child", causal_parents: [resumed, address.call("e")])]

    expect([records.map { watched.admit?(_1) }, shadowed]).to eq([[true, true, true, true], []])
  end

  # A grandchild of the stopped run, and one of its resume, both chain to the watched child.
  it "admits a grandchild spawned before the stop and one spawned by the resume" do
    watched = filter("5")
    resumed = address.call("6")
    records = [spawn.call(spawn_s),
               message.call(digest: address.call("8"), kind: :spawn, from: spawn_s, to: nil, causal_parents: [head]),
               message.call(digest: resumed, kind: :spawn, from: parent, to: nil,
                            causal_parents: [address.call("f"), spawn_s]),
               message.call(digest: address.call("9"), kind: :spawn, from: resumed, to: nil, causal_parents: [head])]

    expect(records.map { watched.admit?(_1) }).to eq([true, true, true, true])
  end

  it "names a later matching spawn once and admits nothing that chains only to it" do
    watched = filter("5", shadowed)
    admitted = [spawn.call(spawn_s), spawn.call(spawn_shadow),
                message.call(digest: address.call("6"), from: spawn_shadow)].map { watched.admit?(_1) }

    expect([admitted, shadowed]).to eq([[true, false, false], [spawn_shadow]])
  end

  it "admits the anchoring spawn again without naming it shadowed" do
    watched = filter("5", shadowed)

    expect([Array.new(2) { watched.admit?(spawn.call(spawn_s)) }, shadowed]).to eq([[true, true], []])
  end

  # A spawn's causal parent is the parent's head: absorbing it would pull the parent's chain in.
  it "admits nothing that chains only to the spawn's causal parent" do
    watched = filter("5")
    watched.admit?(spawn.call(spawn_s))

    expect(watched.admit?(message.call(digest: address.call("7"), from: "other", causal_parents: [head]))).to be(false)
  end

  it "admits no record but a message, whatever fields it shares with the lineage" do
    watched = filter("5")
    watched.admit?(spawn.call(spawn_s))
    turn = Lain::Telemetry::Untyped.new(fields: { "type" => "turn", "digest" => address.call("8"),
                                                  "causal_parents" => [spawn_s] })

    expect(watched.admit?(turn)).to be(false)
  end

  it "matches a bare hex selector against a digest recorded with its scheme" do
    expect(filter("5555").admit?(spawn.call(spawn_s))).to be(true)
  end

  it "is anchored only once a spawn matched" do
    watched = filter("5")
    anchored = [watched.anchored?, watched.tap { _1.admit?(spawn.call(spawn_s)) }.anchored?]

    expect(anchored).to eq([false, true])
  end

  # The live view and the read-back agree because both are the one projection, stepped or folded whole.
  describe "a lineage followed live" do
    let(:session) do
      RecordedSpawnSession.new(
        parent_responses: [tool_response(["tu_1", "subagent", { "prompt" => "investigate the login bug" }]),
                           tool_response(["tu_2", "subagent", { "prompt" => "audit the payment path" }]),
                           text_response("parent done")],
        child_responses: [text_response("the token TTL was zero"), text_response("the retry was unbounded")]
      ).run
    end

    def admitted_by_watch(path, selector)
      admitted = []
      view = Class.new { define_method(:lines) { |record| admitted << record and [] } }.new
      Lain::CLI::Watch.new(selector:, path:, sink: StringIO.new, view:, sleeper: ->(_) { raise "polled" }).run
      admitted
    end

    it "admits the records of the lineage read back from the closed file" do
      Dir.mktmpdir do |dir|
        path = session.write(File.join(dir, "s.ndjson"))
        lineage = Lain::Bench::Session::Lineages.read(path).first
        folded = Lain::Journal::Projection::Lineage.over(
          Lain::Journal.records(File.foreach(path), typed: true)
        )[lineage.spawn.digest]

        admitted = admitted_by_watch(path, lineage.spawn.digest)

        expect(admitted).to eq(folded.records)
        expect(admitted.map(&:digest).values_at(0, -1)).to eq([lineage.spawn.digest, lineage.completion.digest])
      end
    end
  end
end
