# frozen_string_literal: true

require "stringio"

# A chat whose run raises past the REPL must leave a session file that says it
# crashed: the real launch bracket, conductor, chronicle and scribe, over a journal on a StringIO.
RSpec.describe Lain::CLI::ChatLaunch, "closing a crashed chat", :seam do
  let(:journal_io) { StringIO.new }
  let(:chronicle) { Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io: journal_io)) }
  let(:conductor) do
    Lain::CLI::Conductor.new(tty: instance_spy(Lain::Frontend::TTY), chronicle:, signals: instance_spy(Lain::CLI::Signals))
  end
  let(:wiring) { instance_double(Lain::CLI::Wiring, conductor:) }

  before do
    chronicle.start(context: Lain::Context.new(model: "m", max_tokens: 16), toolset: Lain::Toolset.new([]))
  end

  def launch = described_class.new({ journal: false }, wiring_factory: ->(**) { wiring })

  it "writes session_closed with reason crashed and the error class, and the error still escapes" do
    allow(wiring).to receive(:run).and_raise(NoMethodError, "boom")

    expect { launch.call { |_notice| nil } }.to raise_error(NoMethodError, "boom")
    expect(journal_records(journal_io, "session_closed"))
      .to contain_exactly(include("reason" => "crashed", "error" => "NoMethodError"))
  end

  it "writes a plain exit closer, with no error, when the run ends normally" do
    allow(wiring).to receive(:run)

    launch.call { |_notice| nil }

    expect(journal_records(journal_io, "session_closed"))
      .to contain_exactly(satisfy { |record| record["reason"] == "exit" && !record.key?("error") })
  end
end
