# frozen_string_literal: true

RSpec.describe Lain::Channel::DropOldest do
  it "rejects a non-positive capacity" do
    expect { described_class.new(capacity: 0) }.to raise_error(ArgumentError, /capacity/)
    expect { described_class.new(capacity: -1) }.to raise_error(ArgumentError, /capacity/)
  end

  it "satisfies the same duck as Channel" do
    channel = described_class.new(capacity: 4)
    %i[push << pop drain close closed? size length capacity].each do |message|
      expect(channel).to respond_to(message)
    end
  end

  describe "under capacity" do
    it "returns events in FIFO order" do
      channel = described_class.new(capacity: 8)
      channel.push(:a).push(:b).push(:c)
      expect(channel.drain).to eq(%i[a b c])
    end

    it "never blocks the producer" do
      channel = described_class.new(capacity: 2)
      expect { channel.push(:a).push(:b).push(:c).push(:d) }.not_to raise_error
    end
  end

  describe "overflow: drop the OLDEST" do
    it "evicts the oldest event and keeps the newest" do
      channel = described_class.new(capacity: 3)
      channel.push(:a).push(:b).push(:c).push(:d).push(:e)

      drained = channel.drain
      events = drained.grep_v(Lain::Event::Dropped)
      expect(events).to eq(%i[c d e])
    end

    it "surfaces a Dropped marker carrying the count, ahead of the survivors" do
      channel = described_class.new(capacity: 2)
      channel.push(:a).push(:b).push(:c).push(:d) # drops :a and :b

      drained = channel.drain
      expect(drained.first).to be_a(Lain::Event::Dropped)
      expect(drained.first.count).to eq(2)
      expect(drained.drop(1)).to eq(%i[c d])
    end

    it "resets the dropped count after it is surfaced" do
      channel = described_class.new(capacity: 1)
      channel.push(:a).push(:b) # drops :a
      first = channel.drain
      expect(first.first).to be_a(Lain::Event::Dropped)

      channel.push(:c)
      second = channel.drain
      expect(second).to eq(%i[c])
    end
  end

  describe "#drain" do
    it "is empty when nothing is queued and nothing was dropped" do
      expect(described_class.new(capacity: 2).drain).to eq([])
    end

    it "with a block, blocks and yields every event until closed-and-drained (same duck as Channel)" do
      channel = described_class.new(capacity: 8)
      channel.push(:a).push(:b)

      collected = []
      drainer = Thread.new { channel.drain { |event| collected << event } }

      sleep(0.02) until collected.size == 2
      expect(drainer.status).to eq("sleep")

      channel.push(:c)
      channel.close
      drainer.join(1)

      expect(collected).to eq(%i[a b c])
      expect(drainer.status).to be(false)
    end
  end

  describe "#pop" do
    it "blocks until an event arrives" do
      channel = described_class.new(capacity: 4)
      producer = Thread.new do
        sleep(0.02)
        channel.push(:late)
      end
      expect(channel.pop).to eq(:late)
      producer.join
    end

    it "surfaces a Dropped marker before the next event" do
      channel = described_class.new(capacity: 1)
      channel.push(:a).push(:b) # drops :a

      marker = channel.pop
      expect(marker).to be_a(Lain::Event::Dropped)
      expect(marker.count).to eq(1)
      expect(channel.pop).to eq(:b)
    end

    it "returns nil once closed and drained" do
      channel = described_class.new(capacity: 2)
      channel.push(:a)
      channel.close
      expect(channel.pop).to eq(:a)
      expect(channel.pop).to be_nil
    end

    it "wakes a blocked consumer on close" do
      channel = described_class.new(capacity: 2)
      waiter = Thread.new { channel.pop }
      sleep(0.02)
      channel.close
      expect(waiter.value).to be_nil
    end
  end

  describe "#close" do
    it "raises ClosedQueueError on a subsequent push" do
      channel = described_class.new(capacity: 2)
      channel.close
      expect { channel.push(:a) }.to raise_error(ClosedQueueError)
    end

    it "is idempotent" do
      channel = described_class.new(capacity: 2)
      channel.close
      expect { channel.close }.not_to raise_error
      expect(channel).to be_closed
    end
  end

  describe "concurrent producers do not lose the count" do
    # Every push either lands or increments the drop count. Over many threads the
    # survivors plus the dropped count must equal everything pushed -- the honest
    # analog of backpressure: nothing vanishes without being counted.
    it "accounts for every pushed event as delivered or dropped" do
      channel = described_class.new(capacity: 16)
      total = 8 * 200

      threads = Array.new(8) do |t|
        Thread.new { 200.times { |i| channel.push([t, i]) } }
      end
      threads.each(&:join)

      delivered = 0
      dropped = 0
      channel.drain.each do |event|
        if event.is_a?(Lain::Event::Dropped)
          dropped += event.count
        else
          delivered += 1
        end
      end
      expect(delivered + dropped).to eq(total)
    end
  end
end
