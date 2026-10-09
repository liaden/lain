# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Isolation::SuiteLock, :seam do
  around do |example|
    Dir.mktmpdir("lain-suite-lock") do |home|
      @state_home = File.realpath(home)
      example.run
    end
  end

  let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => @state_home, "HOME" => @state_home }) }
  let(:path) { File.join(paths.state_home, "locks", "suite.lock") }

  # The child leaves through exit! so this suite's exit hooks never run in it.
  def interval_in_child
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      described_class.for(paths:).hold do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        sleep 0.3
        writer.write(Marshal.dump([started, Process.clock_gettime(Process::CLOCK_MONOTONIC)]))
      end
      writer.close
    ensure
      exit!(0)
    end
    writer.close
    [pid, reader]
  end

  it "keeps two processes' held runs from overlapping" do
    first_pid, first = interval_in_child
    second_pid, second = interval_in_child
    spans = [first, second].map { |io| Marshal.load(io.read) } # rubocop:disable Security/MarshalLoad
    [first_pid, second_pid].each { |pid| Process.wait(pid) }

    early, late = spans.sort
    expect(late.first).to be >= early.last
  end

  it "creates the lock file under the state home on demand, naming no holder after the release" do
    expect(File.exist?(path)).to be(false)

    lock = described_class.for(paths:)
    during = lock.hold { lock.holder }

    expect(during).to include("pid=#{Process.pid}")
    expect([File.exist?(path), lock.holder]).to eq([true, ""])
  end

  it "raises Paths::Unwritable when the state home cannot be a directory" do
    File.write(File.join(@state_home, "lain"), "in the way")

    expect { described_class.for(paths:) }.to raise_error(Lain::Paths::Unwritable)
  end
end
