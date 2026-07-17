# frozen_string_literal: true

require "open3"
require "rbconfig"

# FIX 3 (review round 1): "C3 ends with a reproducible driver script the demo
# can run live" is a plan-contract requirement, not polish -- a demo table
# that only exists as a private method inside stagger_spec.rb (and a fixture
# EchoTool that cannot load outside RSpec, see bin/demo-fanout's own comment)
# is not something Joel can hand anyone or run at a terminal. This spec is
# the same "spawn a real subprocess, assert on its output" shape
# spec/lain/seams/prelude_invariant_spec.rb already uses for the same reason:
# `RbConfig.ruby`, never a bare "ruby", because the shell's default ruby is
# 3.2.3 (CLAUDE.md) and version skew would present as a confusing failure
# that has nothing to do with the driver itself.
RSpec.describe "bin/demo-fanout" do
  def driver_path
    File.expand_path("../../../../bin/demo-fanout", __dir__)
  end

  def repo_root
    File.expand_path("../../../..", __dir__)
  end

  def run_driver
    Open3.capture3(RbConfig.ruby, driver_path, chdir: repo_root)
  end

  it "exists and is executable" do
    expect(File.executable?(driver_path)).to be(true)
  end

  it "runs to completion, exit 0, printing the staggered-vs-control comparison table" do
    stdout, stderr, status = run_driver

    expect(status).to be_success, "driver failed (#{status.exitstatus}): #{stderr}"
    expect(stderr).to be_empty

    expect(stdout).to include("=== fixture ===")
    expect(stdout).to include("4 siblings, 1 distinct template chain head(s)")

    expect(stdout).to include("=== STAGGERED (through Stagger) ===")
    expect(stdout).to include("writes=1 reads=3")

    expect(stdout).to include("=== UNSTAGGERED CONTROL ===")
    expect(stdout).to include("writes=4 reads=0")
  end
end
