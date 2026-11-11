# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Lain::CLI::HerdrLink do
  let(:plugin_dir) { File.join(Lain::Paths::Shipped::GEM_ROOT, "plugin", "herdr") }

  around do |example|
    Dir.mktmpdir("lain-herdr-link") do |dir|
      @bin = File.join(dir, "bin")
      @log = File.join(dir, "calls")
      FileUtils.mkdir_p(@bin)
      saved = ENV.fetch("PATH")
      ENV["PATH"] = @bin
      example.run
    ensure
      ENV["PATH"] = saved
    end
  end

  def stub_herdr
    path = File.join(@bin, "herdr")
    File.write(path, "#!/bin/sh\necho \"$*\" >> #{@log}\necho listed\n")
    File.chmod(0o755, path)
  end

  def calls = File.exist?(@log) ? File.readlines(@log, chomp: true) : []

  def start(*words) = described_class.start(words, debug: true)

  it "links the shipped plugin folder" do
    stub_herdr
    expect { start("link") }.to output(/linked/).to_stdout

    expect(calls).to eq(["plugin link #{plugin_dir}"])
  end

  it "unlinks by id" do
    stub_herdr
    expect { start("unlink") }.to output(/unlinked/).to_stdout

    expect(calls).to eq(["plugin unlink lain"])
  end

  it "shows herdr's plugin list" do
    stub_herdr
    expect { start("status") }.to output(/listed/).to_stdout

    expect(calls).to eq(["plugin list"])
  end

  it "refuses, writing nothing, when herdr is not installed" do
    expect { start("link") }.to raise_error(Thor::Error, /herdr was not found/)
    expect(calls).to eq([])
  end

  it "raises herdr's own complaint when herdr exits non-zero" do
    path = File.join(@bin, "herdr")
    File.write(path, "#!/bin/sh\necho boom >&2\nexit 2\n")
    File.chmod(0o755, path)

    expect { start("link") }.to raise_error(Thor::Error, /plugin link .* failed: boom/)
  end

  it "exits 1 on failure" do
    expect(described_class.exit_on_failure?).to be(true)
  end
end
