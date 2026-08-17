# frozen_string_literal: true

require "json"

# The one EDITABLE lain:// view: `lain://request` renders the pending request as
# pretty JSON, and `:LainResend` turns the edited bytes back into a record.
#
# Pure by construction -- no editor, no RPC, no agent -- so unlike its siblings
# this needs no `:nvim` tag and runs on every plain `rspec`. It had no spec at
# all before, which is why the two threads' shared baseline and the
# malformed-edit no-op below were only ever claims in a comment.
#
# The baseline is built through {Telemetry::RequestSent.from} off a REAL
# {Lain::Request}, not a hand-written Hash: the payload is `#cache_payload`, a
# fixed six-key canonical Hash, and the digest is taken over exactly that. A
# hand-rolled three-key payload would still round-trip through #resend while
# quietly breaking the #rebuild digest identity below -- which is the one claim
# here that a fixture can fake.
RSpec.describe Lain::Frontend::Neovim::RequestBuffer do
  subject(:buffer) { described_class.new(journal:) }

  # The journal duck is `#<<` and nothing more (see #initialize's @param), so an
  # Array is the honest double -- and the only one that can be read back.
  let(:journal) { [] }

  def request(**overrides)
    Lain::Request.new(model: "m", max_tokens: 16, stream: true, extra: { "temperature" => 0 },
                      messages: [{ role: "user", content: "hi" }], **overrides)
  end

  def request_sent(**overrides) = Lain::Telemetry::RequestSent.from(request(**overrides))

  def lines_for(payload) = JSON.pretty_generate(payload).split("\n")

  describe "#initial" do
    # Deliberately NOT empty JSON: with no baseline #resend is already a no-op,
    # and a plausible-looking empty request would invite editing one that does
    # not exist.
    it "names the buffer and says there is nothing yet, rather than rendering an empty request" do
      expect(buffer.initial).to eq(described_class::REQUEST => ["(no request yet)"])
    end
  end

  describe "#updates" do
    it "renders a RequestSent as pretty JSON lines under the request buffer" do
      sent = request_sent
      update = buffer.updates(sent)

      expect(update.keys).to eq([described_class::REQUEST])
      expect(JSON.parse(update.fetch(described_class::REQUEST).join("\n"))).to eq(sent.payload)
    end

    it "renders MULTI-line pretty JSON, not one dense line -- the buffer is meant to be edited" do
      expect(buffer.updates(request_sent).fetch(described_class::REQUEST).size).to be > 1
    end

    it "moves nothing for any other event" do
      expect(buffer.updates(Lain::Telemetry::Dropped.new(count: 1))).to eq({})
      expect(buffer.updates("not an event")).to eq({})
    end
  end

  describe "#resend" do
    # No request seen yet: there is nothing to rebuild FROM, so the resend is a
    # no-op rather than an invented record.
    it "answers nil before any request has been seen, and journals nothing" do
      expect(buffer.resend(lines_for(request.cache_payload))).to be_nil
      expect(journal).to be_empty
    end

    context "with a baseline in hand" do
      let(:baseline) { request_sent }

      before { buffer.updates(baseline) }

      it "turns the edited buffer into a RequestResent, journaled like any other request" do
        edited = baseline.payload.merge("max_tokens" => 999)

        resent = buffer.resend(lines_for(edited))

        expect(resent).to be_a(Lain::Telemetry::RequestResent)
        expect(resent.payload).to eq(edited)
        expect(journal).to eq([resent])
      end

      # Its own discriminator, so mining never reads a hand-edit as a failed
      # real dispatch -- while still being a RequestSent for every projection.
      it "is a RequestSent for projection, but discriminated as a resend for mining" do
        resent = buffer.resend(lines_for(baseline.payload))

        expect(resent).to be_a(Lain::Telemetry::RequestSent)
        expect(resent.class).to be(Lain::Telemetry::RequestResent)
      end

      # The digest is the content address of what the human actually edited, not
      # the baseline's -- otherwise two different requests would share one.
      it "recomputes the digest over the EDITED payload" do
        edited = baseline.payload.merge("max_tokens" => 999)

        resent = buffer.resend(lines_for(edited))

        expect(resent.digest).to eq(Lain::Canonical.digest(edited))
        expect(resent.digest).not_to eq(baseline.digest)
      end

      # An UNEDITED resend must address to exactly the baseline: same bytes,
      # same content address, or the diff would report a change that is not one.
      it "reproduces the baseline's own digest when nothing was edited" do
        expect(buffer.resend(lines_for(baseline.payload)).digest).to eq(baseline.digest)
      end

      # stream/extra are transport, deliberately not shown in the buffer, so they
      # can only come from the baseline.
      it "carries the baseline's transport fields, which the buffer never showed" do
        resent = buffer.resend(lines_for(baseline.payload))

        expect(resent.stream).to be(true)
        expect(resent.extra).to eq("temperature" => 0)
      end

      # A malformed edit must not raise on the resend-worker thread: that
      # thread's death would strand the resend inbox entirely.
      it "answers nil for a malformed edit rather than raising, and journals nothing" do
        expect(buffer.resend(["{ not json"])).to be_nil
        expect(journal).to be_empty
      end

      it "leaves the baseline intact after a malformed edit, so the next valid resend still works" do
        buffer.resend(["{ not json"])

        expect(buffer.resend(lines_for(baseline.payload))).to be_a(Lain::Telemetry::RequestResent)
      end
    end
  end

  describe "#rebuild" do
    let(:baseline) { request_sent }

    before { buffer.updates(baseline) }

    it "turns a resent record back into a live Request, transport fields and all" do
      resent = buffer.resend(lines_for(baseline.payload))

      rebuilt = buffer.rebuild(resent)

      expect(rebuilt).to be_a(Lain::Request)
      expect(rebuilt.model).to eq("m")
      expect(rebuilt.max_tokens).to eq(16)
      expect(rebuilt.stream).to be(true)
      expect(rebuilt.extra).to eq("temperature" => 0)
    end

    # The claim {#build} makes in its own comment -- "the same content address
    # Request#digest would give it" -- and the reason "edit it, resend, watch
    # what changed" can be trusted. It holds only because the payload IS
    # `#cache_payload`, so this is the example that would catch a drift between
    # what the buffer renders and what Request addresses over.
    it "round-trips: the rebuilt Request's digest is the record's own" do
      resent = buffer.resend(lines_for(baseline.payload))

      expect(buffer.rebuild(resent).digest).to eq(resent.digest)
    end

    it "round-trips an EDITED request too, so the resent digest addresses the edit" do
      edited = baseline.payload.merge("max_tokens" => 999)

      resent = buffer.resend(lines_for(edited))

      expect(buffer.rebuild(resent).digest).to eq(resent.digest)
      expect(buffer.rebuild(resent).max_tokens).to eq(999)
    end

    # RAISES rather than returning nil: the caller decides what a
    # parses-but-is-not-a-request edit means (the bridge folds it into a
    # refusal notice; Unbridged never calls this at all).
    it "raises on a payload that is JSON but not request-shaped, leaving the caller to decide" do
      resent = buffer.resend(['{"not":"a request"}'])

      expect { buffer.rebuild(resent) }.to raise_error(StandardError)
    end
  end

  # The baseline is the ONE piece of state the drain thread (#updates) and the
  # resend worker (#resend) share, and the Mutex exists for exactly it. Without
  # the guard this interleaving is what corrupts a resend.
  describe "the baseline across two threads" do
    it "always resends against a WHOLE baseline, never a half-written one" do
      buffer.updates(request_sent)
      writer = Thread.new { 200.times { |i| buffer.updates(request_sent(max_tokens: i + 1)) } }

      resends = Array.new(200) { buffer.resend(lines_for(request.cache_payload)) }
      writer.join

      # Every resend saw SOME complete baseline: none nil, all carrying the
      # transport fields only a real baseline can supply.
      expect(resends).to all(be_a(Lain::Telemetry::RequestResent))
      expect(resends.map(&:stream).uniq).to eq([true])
      expect(resends.map(&:extra).uniq).to eq([{ "temperature" => 0 }])
    end
  end
end
