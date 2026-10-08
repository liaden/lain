# frozen_string_literal: true

require "async"

# A walk's filesystem calls are ones no scheduler hook offloads, so a tool that
# walked on the chat's reactor would hold every other fiber until it finished.
# The including group provides `tool` and `tmpdir`.
RSpec.shared_context "with a slowed walk" do
  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # Each walk first spends `seconds` in Dir.glob, a call no scheduler hook
  # offloads, so the walk holds whichever thread runs it.
  def slow_walks(seconds)
    allow(Lain::FileWalk).to receive(:new).and_wrap_original do |original, **options|
      original.call(**options).tap do |walk|
        allow(walk).to receive(:each).and_wrap_original do |each, *args, &block|
          @walked = true
          deadline = monotonic + seconds
          Dir.glob(File.join(tmpdir, "*")) while monotonic < deadline
          each.call(*args, &block)
        end
      end
    end
  end

  def ticks_while
    ticks = 0
    Sync do |task|
      ticker = task.async do
        loop do
          ticks += 1
          task.sleep(0.01)
        end
      end
      yield
      ticker.stop
    end
    ticks
  end
end

# `input` builds the tool's input for a directory holding `a.rb`.
#
# The walk is longer than the bar needs, so one stall of the ticker under load
# cannot sink it: 50 ticks over 1.5s asks a third of the ticker's free rate.
RSpec.shared_examples "a walk run off the reactor" do |input|
  include_context "with a slowed walk"

  it "keeps a sibling fiber running while its walk runs" do
    File.write(File.join(tmpdir, "a.rb"), "def needle(argument)\nend\n")
    slow_walks(1.5)
    result = nil

    ticks = ticks_while do
      result = dispatch_call(tool.name, input.call(tmpdir), toolset: Lain::Toolset.new([tool]))
    end

    expect(@walked).to be(true)
    expect(result.error?).to be(false)
    expect(ticks).to be >= 50
  end
end
