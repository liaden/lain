# frozen_string_literal: true

require "fileutils"

# The harness ThreeArm and MutationReinsertion share: one lease binding, one seal taken from the base.
RSpec.describe Lain::Grader::Sealed do
  def subject_project = File.expand_path("../../fixtures/altitude/subjects/order-total", __dir__)

  def level_in(root) = Lain::Config.test_layout(root:, paths: Lain::Paths.new).mapping.level("unit")

  def lease_over(checkout)
    Lain::Isolation::Lease.new(worker_env: Lain::WorkerEnv.new(cwd: checkout, env: ENV.to_h),
                               on_release: -> {}, origin: Lain::Isolation::Lease::Origin.new(path: checkout))
  end

  let(:level) { level_in(subject_project) }
  let(:runs) { ->(**) { Object.new.tap { |run| run.define_singleton_method(:grade) { |*, **| :ran } } } }
  let(:sealed) { described_class.new(lease: lease_over(subject_project), level:, base: subject_project, runs:) }

  it "takes the seal from one manifest of the base" do
    allow(Lain::Grader::LeaseHarness).to receive(:manifest).and_call_original

    built = sealed

    expect(Lain::Grader::LeaseHarness).to have_received(:manifest).once
    expect(built.identity["sealed"]).to eq(Lain::Canonical.digest(Lain::Grader::LeaseHarness.manifest(subject_project,
                                                                                                      level:)))
  end

  it "names its class, the level and the seal, deeply frozen" do
    expect(sealed.identity).to include("class" => "Lain::Grader::Sealed", "level" => level.name.to_s)
    expect(Ractor.shareable?(sealed.identity)).to be(true)
  end

  it "hands the pristine manifest to the runs factory" do
    seen = nil
    described_class.new(lease: lease_over(subject_project), level:, base: subject_project,
                        runs: lambda { |pristine:, **|
                          seen = pristine
                          runs.call
                        })

    expect(seen).to eq(Lain::Grader::LeaseHarness.manifest(subject_project, level:))
  end

  it "grades through the lease harness" do
    expect(sealed.grade).to eq(:ran)
  end
end
