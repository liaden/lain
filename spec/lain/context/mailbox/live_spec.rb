# frozen_string_literal: true

RSpec.describe Lain::Context::Mailbox::Live do
  let(:store) { Lain::Store.new }
  let(:recorded) { [] }
  let(:live) do
    described_class.new(recipient: Lain::Event::ChainWriter.method(:correlation_of), observer: recorded.method(:<<))
  end

  def prompted(text = "hi", on: Lain::Timeline.empty(store:))
    on.commit(role: :user, content: [{ "type" => "text", "text" => text }])
  end

  def consumed(timeline, snapshot)
    timeline.commit(role: :assistant, content: [{ "type" => "text", "text" => "ok" }],
                    causal_parents: snapshot.folded)
  end

  def texts(snapshot) = snapshot.pending.map { |event| event.body.fetch("text") }

  it "answers an empty snapshot without walking the timeline when nothing was ever posted" do
    walkless = Object.new
    snapshot = live.capture(walkless)

    expect(snapshot.folded).to eq([])
    expect(live.pending?(walkless)).to be(false)
  end

  it "queues a post and returns at once, writing nothing" do
    expect(live.post(from: "human", text: "use Syncthing")).to be_nil
    expect(recorded).to eq([])
  end

  it "addresses a queued note at capture, journals it, and folds it" do
    timeline = prompted
    live.post(from: "human", text: "use Syncthing")
    snapshot = live.capture(timeline)

    note = snapshot.pending.sole
    expect([note.kind, note.from, note.to]).to eq([:message, "human", timeline.correlation])
    expect(note.body.fetch("text")).to eq("use Syncthing")
    expect(recorded).to eq([note])
    expect(store.fetch(note.digest)).to eq(note)
  end

  it "stops folding a note once a turn on the chain names it" do
    timeline = prompted
    live.post(from: "human", text: "once")
    after = consumed(timeline, live.capture(timeline))

    expect(live.capture(after).folded).to eq([])
    expect(live.pending?(after)).to be(false)
  end

  it "says a note is pending while it is queued and while it is folded but unconsumed" do
    timeline = prompted
    live.post(from: "human", text: "waiting")
    expect(live.pending?(timeline)).to be(true)

    live.capture(timeline)
    expect(live.pending?(timeline)).to be(true)
  end

  describe "a note posted before the first commit" do
    it "waits in the queue until a capture has a recipient, then folds" do
      empty = Lain::Timeline.empty(store:)
      live.post(from: "human", text: "early")

      expect(live.capture(empty).folded).to eq([])
      expect(recorded).to eq([])

      timeline = prompted(on: empty)
      expect(live.capture(timeline).pending.map(&:to)).to eq([timeline.correlation])
    end
  end

  it "keeps the same words posted twice as 2 notes" do
    timeline = prompted
    live.post(from: "human", text: "continue")
    first = live.capture(timeline)
    after = consumed(timeline, first)
    live.post(from: "human", text: "continue")
    second = live.capture(after)

    expect(texts(second)).to eq(["continue"])
    expect(second.folded).not_to eq(first.folded)
  end

  it "never folds an answer or a completion message, even one addressed to the same chain" do
    timeline = prompted
    writer = Lain::Event::ChainWriter.new
    writer.put(timeline, kind: :message, from: "human", to: timeline.correlation, causal_parents: [],
                         body: { "answer" => "yes" })
    writer.put(timeline, kind: :message, from: "child", to: timeline.correlation, causal_parents: [],
                         body: { "result" => "done", "final" => "f", "lifecycle" => "completed" })
    live.post(from: "human", text: "the note")

    expect(texts(live.capture(timeline))).to eq(["the note"])
  end

  # Pending is judged against the CURRENT chain, whatever a note was addressed
  # to: a chain that lost the turn that folded it, or that started over at a
  # new root, has no context that ever saw it.
  describe "a chain that moved under a note" do
    it "refolds a note whose consuming turn a rewind removed" do
      timeline = prompted
      live.post(from: "human", text: "seen once")
      snapshot = live.capture(timeline)
      after = consumed(timeline, snapshot)

      expect(live.capture(after.rewind(1)).folded).to eq(snapshot.folded)
    end

    it "folds a captured note into a chain with a new root" do
      timeline = prompted("first")
      live.post(from: "human", text: "stranded")
      captured = live.capture(timeline)
      restarted = prompted("first and again")

      expect(restarted.correlation).not_to eq(timeline.correlation)
      expect(live.capture(restarted).folded).to eq(captured.folded)
    end
  end

  it "loses and repeats none of 200 notes posted from 2 threads while captures run" do
    timeline = prompted
    folded = []
    start = Queue.new
    posters = Array.new(2) do |thread|
      Thread.new do
        start.pop
        100.times { |i| live.post(from: "human", text: "#{thread}-#{i}") }
      end
    end
    live.post(from: "human", text: "first")
    opening = live.capture(timeline)
    folded.concat(texts(opening))
    timeline = consumed(timeline, opening)
    2.times { start << :go }
    until posters.none?(&:alive?) && !live.pending?(timeline)
      snapshot = live.capture(timeline)
      folded.concat(texts(snapshot))
      timeline = consumed(timeline, snapshot)
    end
    posters.each(&:join)

    expect(folded.size).to eq(201)
    expect(folded.uniq.size).to eq(201)
  end

  # A resumed chat starts a fresh inbox over a chain an earlier one wrote to:
  # the same words at the same sequence must still be a new note.
  it "folds a note a fresh Live posts on a chain where an earlier Live's identical note was consumed" do
    timeline = prompted
    earlier = described_class.new(recipient: Lain::Event::ChainWriter.method(:correlation_of), observer: ->(_) {})
    earlier.post(from: "human", text: "continue")
    resumed = consumed(timeline, earlier.capture(timeline))
    live.post(from: "human", text: "continue")

    expect(texts(live.capture(resumed))).to eq(["continue"])
  end

  it "keeps a note queued when recording it fails, and loses none queued behind it" do
    calls = 0
    failing = described_class.new(recipient: Lain::Event::ChainWriter.method(:correlation_of),
                                  observer: ->(_) { raise IOError, "disk full" if (calls += 1) == 1 })
    timeline = prompted
    %w[a b c].each { |text| failing.post(from: "human", text:) }

    expect { failing.capture(timeline) }.to raise_error(IOError)
    expect(texts(failing.capture(timeline))).to eq(%w[a b c])
  end
end
