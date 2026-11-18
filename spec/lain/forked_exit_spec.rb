# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::ForkedExit, :seam do
  before { skip "this host cannot fork" unless Process.respond_to?(:fork) }

  around do |example|
    Dir.mktmpdir("forked-exit") do |dir|
      @dir = dir
      example.run
    end
  end

  # The child's err is a file, so what a crash wrote is read back after the child is reaped.
  def left(out: $stdout, before: -> {}, &work)
    err = File.join(@dir, "err")
    pid = fork do
      before.call
      File.open(err, "w") { |file| described_class.new(out:, err: file).call(&work) }
    end
    Process.wait2(pid).last.tap { @said = File.read(err) }
  end

  it "exits 0 when the work returns" do
    expect(left { :done }.exitstatus).to eq(0)
  end

  it "keeps a SystemExit's status" do
    expect(left { exit 3 }.exitstatus).to eq(3)
  end

  it "writes a crash to the given err and exits 1" do
    expect(left { raise ArgumentError, "the work broke" }.exitstatus).to eq(1)
    expect(@said).to include("the work broke (ArgumentError)")
  end

  it "ends by the signal that ended the work" do
    expect(left { raise SignalException, "TERM" }.termsig).to eq(Signal.list.fetch("TERM"))
  end

  it "flushes a buffered out before it leaves" do
    File.open(File.join(@dir, "out"), "w") do |out|
      out.sync = false
      left(out:) { out.puts("buffered") }
    end

    expect(File.read(File.join(@dir, "out"))).to eq("buffered\n")
  end

  it "runs no at_exit hook of the parent" do
    marker = File.join(@dir, "at_exit")
    left(before: -> { at_exit { File.write(marker, "ran") } }) { :done }

    expect(File.exist?(marker)).to be(false)
  end
end
