# frozen_string_literal: true

RSpec.describe Lain::CLI::Backend::SkillLocals do
  let(:tier) { instance_double(Lain::CLI::Backend::OllamaTier, concurrency: "has no concurrency limit that lain enforces") }

  def locals(root: Dir.pwd, epic_home: -> { "/home/epics" }, tier: self.tier)
    described_class.new(root, epic_home) { tier }.to_h
  end

  it "names the four values a skill template may read bare" do
    expect(locals.keys).to contain_exactly(:epic_home, :gate_window, :provider_width, :researcher_limits)
  end

  it "resolves each value only when it is read" do
    reads = []
    values = locals(epic_home: -> { (reads << :home) && "/h" }, tier: nil)

    expect(reads).to be_empty
    expect(values.fetch(:epic_home).call).to eq("/h")
  end

  it "asks the tier for the provider's concurrency on every read" do
    allow(tier).to receive(:concurrency).and_return("runs 3 requests at once", "runs 2 requests at once")
    width = locals.fetch(:provider_width)

    expect([width.call, width.call]).to eq(["runs 3 requests at once", "runs 2 requests at once"])
  end

  it "names the approval timeout without a trailing zero" do
    Dir.mktmpdir do |root|
      write_config(root, "approval timeout: 900.0\n")

      expect(locals(root:).fetch(:gate_window).call).to eq("900")
    end
  end

  it "follows the configured researcher iterations and the answer bound, not a literal" do
    stub_const("Lain::Tools::Subagent::ANSWER_BOUND", Lain::Tool::Bounds::Artifact.new(limit: 2048))
    Dir.mktmpdir do |root|
      write_config(root, "budget iterations: { \"researcher\" => 80 }\n")

      expect(locals(root:).fetch(:researcher_limits).call).to eq("80 iterations and a 2048-byte answer")
    end
  end

  it "says the built-in researcher figure when the project configures none" do
    expect(locals.fetch(:researcher_limits).call).to start_with("60 iterations")
  end
end
