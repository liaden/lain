# frozen_string_literal: true

# The rspec_mini fixture project: three examples, two passing and one failing,
# executed BY Grader::TestHarness (never by the host suite -- these files end in
# _check.rb, outside the host's *_spec.rb glob, and the sibling .rspec points
# rspec at that pattern).
#
# It deliberately prints deprecation-style noise to stdout at load time. That
# noise is the point: the AC requires a project whose own stdout is noisy to
# grade identically to a quiet one, which holds because TestHarness reads the
# machine-readable result from a FILE (--format json --out), never from stdout.
$stdout.puts "DEPRECATION WARNING: Calculator#legacy_add is deprecated and will be removed in 2.0."
$stdout.puts "NOTE: this stdout noise must not corrupt the JSON result TestHarness parses."

RSpec.describe "Calculator" do
  it "adds two numbers" do
    expect(1 + 1).to eq(2)
  end

  it "multiplies two numbers" do
    expect(2 * 3).to eq(6)
  end

  it "divides evenly (intentionally failing)" do
    expect(7 / 2).to eq(4)
  end
end
