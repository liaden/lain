# frozen_string_literal: true

RSpec.describe Lain::Confine::Sandbox do
  let(:journal) { RecordingChannel.new }
  let(:fence) { "/srv/lain-fence" }
  let(:runner) { ->(argv) { [argv.include?("--status") ? '{"abi":3}' : "", true] } }
  let(:probe) { Lain::Confine::Probe.new(fence:, journal:, runner:, ptrace_scope: -> { "0" }) }
  let(:masks) { Lain::Confine::MaskList.new(root: "/srv/project", policy: -> { :the_policy }) }
  let(:inner) { Lain::Exec::Local.new }
  let(:sandbox) { described_class.new(root: "/srv/project", home: "/home/h", masks:, probe:, fence:, journal:) }

  def degraded = journal.events.grep(Lain::Telemetry::CapabilityDegraded)

  describe "#wrap" do
    it "wraps the exec in the sandbox when the probe offers every layer" do
      exec = sandbox.wrap(inner, requirer: "Spec")

      expect(exec).to be_a(Lain::Exec::Sandboxed)
      expect(exec.instance_variable_get(:@inner)).to be(inner)
      expect(exec.instance_variable_get(:@launcher)).to be_a(Lain::Confine::Bwrap)
      expect(degraded).to be_empty
    end

    it "hands the profiles the mask list it was given and the home" do
      profiles = sandbox.wrap(inner, requirer: "Spec").instance_variable_get(:@profiles)

      expect(profiles.instance_variable_get(:@masks)).to be(masks)
      expect([profiles.instance_variable_get(:@home), profiles.instance_variable_get(:@root)])
        .to eq(["/home/h", "/srv/project"])
    end

    context "when the box lacks a layer" do
      let(:runner) { ->(_argv) { ["", false] } }

      it "returns the inner exec and journals the sandbox as degraded under the requirer" do
        expect(sandbox.wrap(inner, requirer: "Spec")).to be(inner)
        expect(degraded.find { _1.capability == :sandbox }).to have_attributes(requirer: "Spec")
      end

      it "journals the degraded record to the notes sink when one is given, not the journal" do
        notes = RecordingChannel.new
        noting = described_class.new(root: "/srv/project", home: "/home/h", masks:, probe:, fence:, journal:, notes:)
        noting.wrap(inner, requirer: "Spec")

        expect(notes.events.grep(Lain::Telemetry::CapabilityDegraded).map(&:capability)).to eq([:sandbox])
        expect(journal.events.grep(Lain::Telemetry::CapabilityDegraded).map(&:capability)).not_to include(:sandbox)
      end
    end
  end

  describe ".degraded" do
    it "journals the sandbox as unavailable for the reason given and answers the exec it was handed" do
      exec = described_class.degraded(inner, journal:, requirer: "Spec", because: "no box")

      expect(exec).to be(inner)
      expect(degraded.map(&:to_h)).to contain_exactly(
        a_hash_including(capability: :sandbox, requirer: "Spec", provider: "no box")
      )
    end
  end

  describe "#prime" do
    it "starts the mask classification of a sandbox it built" do
      sandbox.wrap(inner, requirer: "Spec")
      sandbox.prime

      expect(masks.instance_variable_get(:@priming)).to be_a(Thread)
    end

    it "starts nothing when no sandbox was built" do
      sandbox.prime

      expect(masks.instance_variable_get(:@priming)).to be_nil
    end
  end
end
