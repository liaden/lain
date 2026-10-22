# frozen_string_literal: true

require "async"
require "tmpdir"

RSpec.describe Lain::Tool::Offload do
  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # Filesystem calls no scheduler hook offloads, for as long as asked: the shape
  # of a walk that would hold the reactor if it ran on the reactor's thread.
  def walk_for(seconds, dir)
    deadline = monotonic + seconds
    Dir.glob(File.join(dir, "**", "*")) while monotonic < deadline
  end

  def rescued
    yield
  rescue ArgumentError
    nil
  end

  # Held, the one gap is nearly the whole call (share near 1.0); released, under 0.1 even on a loaded box.
  def longest_tick_gap_share
    stamps = []
    Sync do |task|
      ticker = task.async do
        loop do
          stamps << monotonic
          task.sleep(0.01)
        end
      end
      yield task
      stamps << monotonic
      ticker.stop
    end
    stamps.each_cons(2).map { |a, b| b - a }.max / (stamps.last - stamps.first)
  end

  it "answers what the work returns" do
    expect(described_class.call { 6 * 7 }).to eq(42)
  end

  it "re-raises the work's own error, with its class and message" do
    expect { described_class.call { raise Errno::EACCES, "/tmp/secret" } }
      .to raise_error(Errno::EACCES, %r{/tmp/secret})
  end

  it "does not report the work's error on stderr on the way past" do
    expect { rescued { described_class.call { raise ArgumentError, "quiet" } } }.not_to output.to_stderr
  end

  it "keeps a sibling fiber running while the work holds its thread" do
    Dir.mktmpdir("lain-offload") do |dir|
      File.write(File.join(dir, "a.txt"), "a")

      expect(longest_tick_gap_share { described_class.call { walk_for(0.5, dir) } }).to be < 0.3
    end
  end

  # Matching lines is Ruby holding the lock between threads, which a thread
  # hands over only at the end of its time slice.
  it "keeps a sibling fiber running while the work never gives up the lock between threads" do
    spin = -> { (deadline = monotonic + 0.5) && (nil while monotonic < deadline) }

    expect(longest_tick_gap_share { described_class.call(&spin) }).to be < 0.3
  end

  it "kills the work's thread when the task waiting on it is stopped" do
    started = Thread::Queue.new
    Sync do |task|
      waiter = task.async do
        described_class.call do
          started << Thread.current
          sleep 30
        end
      end
      worker = started.pop
      waiter.stop

      expect(worker.join(1)).to eq(worker)
      expect(worker).not_to be_alive
    end
  end
end
