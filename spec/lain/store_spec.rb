# frozen_string_literal: true

RSpec.describe Lain::Store do
  subject(:store) { described_class.new }

  def turn(body) = Lain::Turn.new(role: :user, content: [{ "type" => "text", "text" => body }])

  it "starts empty" do
    expect(store.size).to eq(0)
  end

  it "returns the digest from #put" do
    t = turn("hi")
    expect(store.put(t)).to eq(t.digest)
  end

  it "stores and fetches" do
    t = turn("hi")
    store.put(t)
    expect(store.fetch(t.digest)).to eq(t)
  end

  # The digest already names the content, so writing twice cannot mean anything
  # different. Idempotence is what makes a shared store safe across branches.
  it "is idempotent" do
    t = turn("hi")
    store.put(t)
    store.put(t)
    expect(store.size).to eq(1)
  end

  it "treats equal content as one object" do
    store.put(turn("hi"))
    store.put(turn("hi"))
    expect(store.size).to eq(1)
  end

  it "raises on a missing object" do
    expect { store.fetch("sha256:nope") }
      .to raise_error(Lain::Store::MissingObject, /no object/)
  end

  it "answers key?" do
    t = turn("hi")
    expect(store.key?(t.digest)).to be(false)
    store.put(t)
    expect(store.key?(t.digest)).to be(true)
  end

  it "survives concurrent writers" do
    turns = Array.new(50) { |i| turn("body-#{i}") }
    threads = turns.each_slice(10).map do |slice|
      Thread.new { slice.each { |t| store.put(t) } }
    end
    threads.each(&:join)

    expect(store.size).to eq(50)
    expect(turns).to all(satisfy { |t| store.key?(t.digest) })
  end
end
