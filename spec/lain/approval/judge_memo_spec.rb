# frozen_string_literal: true

RSpec.describe Lain::Approval::JudgeMemo do
  let(:ordinary) { Lain::Sensitivity::Verdict.new(level: :ordinary, reason: :none) }

  def place(**changes)
    Lain::Approval::Judge::Place.new(root: "/repo", cwd: "/repo", requester: "main", outside: [],
                                     classified: { "/repo/notes.txt" => ordinary }, **changes)
  end

  def key(tool: "bash", input: { "command" => "make test" }, **changes)
    described_class.key(tool:, input:, place: place(**changes))
  end

  it "remembers an approved key, and only that key" do
    memo = described_class.new
    memo.approve(key)

    expect([memo.approved?(key), memo.approved?(key(input: { "command" => "make lint" }))]).to eq([true, false])
  end

  it "never remembers a nil key" do
    memo = described_class.new
    memo.approve(nil)

    expect(memo.approved?(nil)).to be(false)
  end

  it "remembers nothing when off" do
    memo = described_class.off
    memo.approve(key)

    expect(memo.approved?(key)).to be(false)
  end

  it "keys the same call in the same place alike, whatever the input's key spelling" do
    expect(key(input: { command: "make test" })).to eq(key)
  end

  it "keys apart another tool, requester, cwd, classification, facts or request" do
    gated = Lain::Sensitivity::Verdict.new(level: :ordinary, reason: :exempt)
    request = Lain::Approval::Judge::Request.new(text: "run the tests", model_written: false)
    facts = Lain::Approval::Judge::Facts.new([], masked: ["/repo/.env"])
    others = [key(tool: "read_file"), key(requester: "researcher"), key(cwd: "/repo/sub"),
              key(classified: { "/repo/notes.txt" => gated }), key(facts:), key(request:)]

    expect(others.uniq.size).to eq(6)
    expect(others).not_to include(key)
  end

  it "keys apart a change to any member of the place" do
    changed = { root: "/other", cwd: "/repo/sub", requester: "researcher", outside: ["/etc/hosts"],
                facts: Lain::Approval::Judge::Facts.new([], masked: ["/repo/.env"]),
                request: Lain::Approval::Judge::Request.new(text: "run the tests", model_written: false),
                human_checkout: "/home/u/repo", read_roots: ["/state/epics"], related: ["/home/u/shared"],
                classified: { "/repo/notes.txt" => Lain::Sensitivity::Verdict.new(level: :ordinary, reason: :exempt) },
                opaque: true }

    expect(changed.keys).to match_array(Lain::Approval::Judge::Place.members)
    changed.each { |member, value| expect(key(member => value)).not_to eq(key), "#{member} did not change the key" }
  end

  it "has no key for an input that has no canonical form" do
    expect([key(input: { "command" => Object.new }), key(input: { "command" => "\xFF".b.force_encoding("UTF-8") })])
      .to eq([nil, nil])
  end

  it "is shared across threads without losing an approval" do
    memo = described_class.new
    keys = Array.new(8) { key(input: { "command" => "make t#{_1}" }) }

    keys.map { |each| Thread.new { memo.approve(each) } }.each(&:join)

    expect(keys.map { memo.approved?(_1) }).to all(be(true))
  end
end
