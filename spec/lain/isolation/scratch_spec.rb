# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Isolation::Scratch do
  subject(:scratch) { described_class.new(root: @root) }

  around do |example|
    Dir.mktmpdir("lain-scratch-spec") do |dir|
      @root = File.join(File.realpath(dir), "scratch")
      example.run
    end
  end

  describe "#acquire" do
    it "leases a fresh directory under its root, as the worker's cwd and its checkout" do
      lease = scratch.acquire

      expect(File.directory?(lease.worker_env.cwd)).to be(true)
      expect(File.dirname(lease.worker_env.cwd)).to eq(@root)
      expect(lease.worker_env.checkout).to eq(lease.worker_env.cwd)
      expect(lease.origin.path).to eq(lease.worker_env.cwd)
    end

    # The checkout is what a leased worker's commands are judged in, so two
    # leases must never share one.
    it "leases a different directory every time" do
      expect(scratch.acquire.worker_env.cwd).not_to eq(scratch.acquire.worker_env.cwd)
    end

    # A worker's paths are compared by their real spelling, so a root reached
    # through a link must not leave a lease naming the link.
    it "names the directory by its real path" do
      target = File.join(File.dirname(@root), "real")
      Dir.mkdir(target)
      File.symlink(target, @root)

      expect(scratch.acquire.worker_env.cwd).to start_with("#{target}/")
    end

    it "runs its commands under the process environment" do
      expect(scratch.acquire.worker_env.env).to eq(ENV.to_h)
    end
  end

  # A spike's notes are the only copy of its work, so letting go of the lease
  # must not delete them.
  it "keeps the directory and what was written there when the lease is released" do
    lease = scratch.acquire
    File.write(File.join(lease.worker_env.cwd, "notes.md"), "spike\n")

    lease.release

    expect(File.read(File.join(lease.worker_env.cwd, "notes.md"))).to eq("spike\n")
  end

  it "sits under lain's own directory in the system temporary root by default" do
    expect(described_class::ROOT).to eq(File.join(Dir.tmpdir, "lain", "scratch"))
  end

  it "tells the model where it is, and that nothing of the project was copied" do
    lease = scratch.acquire
    expect(scratch.reminder(lease)).to include(lease.worker_env.cwd, "scratch directory",
                                               "none of its files were copied")
  end
end
