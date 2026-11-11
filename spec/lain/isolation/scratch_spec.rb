# frozen_string_literal: true

require "fileutils"
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

    it "raises Unwritable naming its root and the errno's own reason when it cannot make one" do
      allow(Dir).to receive(:mktmpdir).and_raise(Errno::EROFS)

      expect { scratch.acquire }.to raise_error(described_class::Unwritable) { |e|
        expect([e.dir, e.reason]).to eq([@root, "read-only file system"])
      }
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

    it "names each directory with the prefix it was given" do
      named = described_class.new(root: @root, prefix: "research-").acquire

      expect(File.basename(named.worker_env.cwd)).to start_with("research-")
      expect(File.basename(scratch.acquire.worker_env.cwd)).to start_with("plan-")
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

  describe "#release" do
    it "names every file written under the lease, absolute, one per line" do
      lease = scratch.acquire
      dir = lease.worker_env.cwd
      FileUtils.mkdir_p(File.join(dir, "notes"))
      File.write(File.join(dir, "research.md"), "r\n")
      File.write(File.join(dir, "notes", "a.md"), "a\n")

      expect(scratch.release(lease)).to eq("#{dir}/notes/a.md\n#{dir}/research.md")
    end

    it "names at most 50 files, then how many more there were" do
      lease = scratch.acquire
      dir = lease.worker_env.cwd
      51.times { |i| File.write(File.join(dir, format("f%02d.md", i)), "x") }

      lines = scratch.release(lease).lines(chomp: true)

      expect(lines.size).to eq(51)
      expect(lines.first).to eq("#{dir}/f00.md")
      expect(lines.last).to eq("... and 1 more under #{dir}")
    end

    it "lists a link by its own path and does not walk into what it points at" do
      lease = scratch.acquire
      dir = lease.worker_env.cwd
      outside = File.join(File.dirname(@root), "outside")
      FileUtils.mkdir_p(outside)
      File.write(File.join(outside, "secret.md"), "x")
      File.symlink(outside, File.join(dir, "link"))

      expect(scratch.release(lease)).to eq("#{dir}/link")
    end

    it "releases the lease, and a second listing neither errors nor changes the answer" do
      lease = scratch.acquire
      File.write(File.join(lease.worker_env.cwd, "a.md"), "x")

      expect([scratch.release(lease), scratch.release(lease)].uniq.size).to eq(1)
      expect(lease).to be_released
    end

    describe "discarding, as at quit" do
      it "deletes the lease's directory and nothing beside or behind it" do
        lease = scratch.acquire
        sibling = scratch.acquire.worker_env.cwd
        outside = File.join(File.dirname(@root), "outside").tap { FileUtils.mkdir_p(_1) }
        File.write(File.join(outside, "kept.txt"), "kept\n")
        File.symlink(outside, File.join(lease.origin.path, "link"))

        told = scratch.release(lease, discard: true)

        expect(told).to include(lease.origin.path, "was discarded")
        expect([File.exist?(lease.origin.path), File.directory?(sibling), File.directory?(@root)])
          .to eq([false, true, true])
        expect(File.read(File.join(outside, "kept.txt"))).to eq("kept\n")
      end

      # A claim that the directory went while a file survived would hide the
      # very secret the discard is for.
      it "says the directory could not be discarded, and why, when part of it stays" do
        lease = scratch.acquire
        locked = File.join(lease.origin.path, "locked").tap { FileUtils.mkdir_p(_1) }
        File.write(File.join(locked, ".env"), "TOKEN=x\n")
        File.chmod(0o500, locked)

        told = scratch.release(lease, discard: true)

        expect(told).to include(lease.origin.path, "could not be discarded", "ermission denied")
        expect(told).not_to include("was discarded")
        expect(File.exist?(File.join(locked, ".env"))).to be(true)
      ensure
        File.chmod(0o700, locked) if locked && File.directory?(locked)
      end
    end

    it "answers nothing when nothing was written, and keeps the directory" do
      lease = scratch.acquire

      expect(scratch.release(lease)).to eq("")
      expect(File.directory?(lease.worker_env.cwd)).to be(true)
    end
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
