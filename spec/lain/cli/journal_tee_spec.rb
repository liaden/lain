# frozen_string_literal: true

require "stringio"

# JournalTee fans one event onto BOTH legs -- the durable Journal record and the
# frontend's live-view Channel -- extracted from exe/lain (see
# Lain::CLI::Backend's precedent) so it carries a spec the way lib/ does.
#
# The channel leg is the one that dies: quitting nvim closes its
# Channel::DropOldest (Frontend::Neovim's own contract -- see
# spec/lain/frontend/neovim_spec.rb's "teardown under editor death" examples,
# which this class must not change). A closed channel's `<<` raises
# ClosedQueueError, and that used to escape through Accounting#observe and kill
# the whole chat. The journal leg must always land; only a closed CHANNEL is
# survivable, and only via ClosedQueueError -- nothing else is swallowed.
RSpec.describe Lain::CLI::JournalTee do
  let(:io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io:, clock: -> { "T" }) }

  def journal_lines
    io.string.each_line.map(&:chomp)
  end

  it "survives a dead channel: the journal receives the record and no error escapes" do
    channel = Lain::Channel::DropOldest.new
    channel.close
    tee = described_class.new(journal, channel)

    expect { tee << { "type" => "turn_usage" } }.not_to raise_error
    expect(journal_lines.size).to eq(1)
    expect(JSON.parse(journal_lines.first)).to include("type" => "turn_usage")
  end

  it "writes the journal leg first: a channel whose << raises ClosedQueueError still leaves the record journaled" do
    channel = instance_double(Lain::Channel::DropOldest)
    allow(channel).to receive(:<<).and_raise(ClosedQueueError)
    tee = described_class.new(journal, channel)

    tee << { "type" => "turn_usage" }

    expect(journal_lines.size).to eq(1)
    expect(JSON.parse(journal_lines.first)).to include("type" => "turn_usage")
  end

  it "delivers to both legs while both are open" do
    channel = Lain::Channel::DropOldest.new
    tee = described_class.new(journal, channel)

    tee << { "type" => "turn_usage" }

    expect(journal_lines.size).to eq(1)
    expect(channel.size).to eq(1)
  end

  it "returns self, so events chain the same way a Journal or Channel does" do
    channel = Lain::Channel::DropOldest.new
    tee = described_class.new(journal, channel)

    expect(tee << { "type" => "turn_usage" }).to be(tee)
  end

  # Escalation guard, not an AC: only ClosedQueueError from the channel leg is
  # swallowed. Anything else is a real bug and must propagate.
  it "does not swallow errors other than ClosedQueueError from the channel leg" do
    channel = instance_double(Lain::Channel::DropOldest)
    allow(channel).to receive(:<<).and_raise(ArgumentError, "boom")
    tee = described_class.new(journal, channel)

    expect { tee << { "type" => "turn_usage" } }.to raise_error(ArgumentError, "boom")
  end
end
