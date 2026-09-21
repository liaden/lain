# frozen_string_literal: true

require "stringio"

# A hand-edited resend must journal DISTINGUISHABLY from a real dispatch:
# JournalRequests documents "a request_sent with no following turn_usage is
# how a failure reads", and this record is the EDIT's projection, never the
# wire's, so recording it as a plain request_sent would fabricate one failed
# dispatch per hand-edit. The stamp is the record TYPE itself -- an
# inheriting event with its own journal discriminator -- rather than a marker
# in `extra`, because `extra` is documented as exactly what Request.new needs
# to rebuild the request, and a provenance flag there would ride onto the
# wire on any rebuild-and-dispatch. Whether the edit then ALSO dispatched
# (the ResendBridge) is a following resend_dispatched marker plus the
# dispatch's own ordinary request_sent/turn_usage pair, pinned by that
# marker's own spec.
RSpec.describe Lain::Telemetry::RequestResent do
  subject(:event) { described_class.new(digest: "d", payload: { "model" => "m" }, stream: true, extra: {}) }

  it "IS a RequestSent, so every diff/render projection treats it identically" do
    expect(event).to be_a(Lain::Telemetry::RequestSent)
  end

  it "journals under its own discriminator, never as request_sent" do
    expect(event.journal_type).to eq("request_resent")
    expect(event.to_journal.fetch("type")).to eq("request_resent")
  end

  it "is distinguishable by any Loader reading the journal back" do
    io = StringIO.new
    journal = Lain::Journal.new(io:)
    journal << Lain::Telemetry::RequestSent.new(digest: "real", payload: {}, stream: true, extra: {})
    journal << event

    entries = io.string.lines
    expect(Lain::Journal.records(entries, type: "request_sent").map { |r| r.fetch("digest") }.to_a).to eq(["real"])
    expect(Lain::Journal.records(entries, type: "request_resent").map { |r| r.fetch("digest") }.to_a).to eq(["d"])
  end
end
