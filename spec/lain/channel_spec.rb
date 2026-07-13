# frozen_string_literal: true

RSpec.describe Lain::Channel do
  it "rejects a non-positive capacity" do
    expect { described_class.new(capacity: 0) }.to raise_error(ArgumentError)
    expect { described_class.new(capacity: -1) }.to raise_error(ArgumentError)
    expect { described_class.new(capacity: 1.5) }.to raise_error(ArgumentError)
  end

  describe "#push / #pop" do
    it "returns events in FIFO order" do
      channel = described_class.new(capacity: 4)
      channel.push(:a).push(:b)
      channel << :c

      expect([channel.pop, channel.pop, channel.pop]).to eq(%i[a b c])
    end
  end

  describe "#drain" do
    it "non-blockingly returns all currently-queued events and empties the channel" do
      channel = described_class.new(capacity: 8)
      channel.push(1).push(2).push(3)

      expect(channel.drain).to eq([1, 2, 3])
      expect(channel.size).to eq(0)
      expect(channel.drain).to eq([]) # does not block on an empty channel
    end
  end

  describe "overflow policy (block the producer)" do
    it "blocks #push when full until a consumer drains space" do
      channel = described_class.new(capacity: 1)
      channel.push(:first) # fills the queue

      producer_ran = false
      producer = Thread.new do
        channel.push(:second) # must block: queue is full
        producer_ran = true
      end

      # Give the producer a chance to run; it must still be blocked.
      Thread.pass until producer.status == "sleep"
      expect(producer_ran).to be(false)

      expect(channel.pop).to eq(:first) # frees a slot
      producer.join(1)
      expect(producer_ran).to be(true)
      expect(channel.pop).to eq(:second)
    end
  end

  describe "#close" do
    it "wakes a blocked producer with ClosedQueueError instead of deadlocking" do
      channel = described_class.new(capacity: 1)
      channel.push(:only)

      raised = nil
      producer = Thread.new do
        channel.push(:blocked)
      rescue ClosedQueueError => e
        raised = e
      end

      Thread.pass until producer.status == "sleep"
      channel.close
      producer.join(1)

      expect(raised).to be_a(ClosedQueueError)
    end

    it "lets consumers drain remaining events, then yields nil, and is idempotent" do
      channel = described_class.new(capacity: 4)
      channel.push(:x)
      channel.close
      channel.close # idempotent

      expect(channel).to be_closed
      expect(channel.pop).to eq(:x)
      expect(channel.pop).to be_nil
    end
  end

  describe "concurrent producers" do
    it "preserves per-producer ordering under contention" do
      producers = 8
      per_producer = 200
      channel = described_class.new(capacity: 16) # small, to force backpressure

      # Drain concurrently: with a capacity far below the total, producers rely
      # on backpressure being relieved by a live consumer (join-then-drain would
      # deadlock, which is exactly the block-the-producer policy working).
      collected = []
      consumer = Thread.new do
        while (event = channel.pop)
          collected << event
        end
      end

      threads = Array.new(producers) do |producer_id|
        Thread.new do
          per_producer.times { |seq| channel.push([producer_id, seq]) }
        end
      end
      threads.each(&:join)
      channel.close
      consumer.join

      expect(collected.size).to eq(producers * per_producer)
      # Every producer's events must appear in the order it pushed them, even
      # though they are interleaved with other producers'.
      producers.times do |producer_id|
        seqs = collected.select { |id, _| id == producer_id }.map(&:last)
        expect(seqs).to eq((0...per_producer).to_a)
      end
    end
  end

  describe Lain::Channel::Null do
    it "absorbs pushes and returns itself, chainable like a real channel" do
      null = described_class.new
      expect(null.push(:event) << :another).to equal(null)
    end

    it "exposes one shared frozen instance for defaults" do
      expect(described_class.instance).to equal(described_class.instance)
      expect(described_class.instance).to be_frozen
      expect(described_class.instance << :event).to equal(described_class.instance)
    end
  end
end
