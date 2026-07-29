# frozen_string_literal: true

require "tmpdir"

# The single-selector half of session discovery, owned once. `lain friction`,
# `lain consolidate` and `lain improve` each ask the same question -- "which ONE
# file does this selector name?" -- and each answered it with its own
# byte-identical `resolve`/`dir`/`SessionNotFound` triple, so three copies of a
# user-facing contract (which shorthands work, and what the refusal says) could
# drift with nothing failing. {Lain::CLI::SessionJournals} owns the other half:
# EVERY journal in the directory, for a fold that must not miss one.
RSpec.describe Lain::CLI::SessionFile do
  subject(:resolved) { described_class.resolve(selector, paths:) }

  let(:paths) { instance_double(Lain::Paths, sessions_dir: @dir) }
  let(:selector) { "20260721T000000-1" }

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  def write(name) = File.join(@dir, name).tap { |path| File.write(path, "{}\n") }

  describe "the three resolutions" do
    it "resolves a bare filename under this project's session dir" do
      path = write("20260721T000000-1.ndjson")

      expect(described_class.resolve("20260721T000000-1.ndjson", paths:)).to eq(path)
    end

    it "resolves a filename missing its .ndjson suffix" do
      path = write("20260721T000000-1.ndjson")

      expect(resolved).to eq(path)
    end

    it "resolves an explicit path directly, wherever it lives" do
      Dir.mktmpdir do |elsewhere|
        path = File.join(elsewhere, "kept.ndjson")
        File.write(path, "{}\n")

        expect(described_class.resolve(path, paths:)).to eq(path)
      end
    end

    it "never resolves a directory that happens to answer to the name" do
      FileUtils.mkdir_p(File.join(@dir, "#{selector}.ndjson"))

      expect { resolved }.to raise_error(described_class::SessionNotFound)
    end
  end

  describe "the one refusal" do
    it "raises SessionNotFound naming the selector and every candidate, in the order it tried them" do
      tried = ["nope", File.join(@dir, "nope"), File.join(@dir, "nope.ndjson")].join(", ")

      expect { described_class.resolve("nope", paths:) }
        .to raise_error(described_class::SessionNotFound, /"nope" -- looked at #{Regexp.escape(tried)}/)
    end

    it "is a Lain::Error, so the exe maps it to a message rather than a backtrace" do
      expect(described_class::SessionNotFound.ancestors).to include(Lain::Error)
    end
  end

  # The Command::Surface doctrine: a forgotten collaborator is a loud
  # ArgumentError at the call, never a resolution against some default root.
  it "requires paths:, rather than defaulting to this process's project" do
    expect { described_class.resolve("nope") }.to raise_error(ArgumentError, /paths/)
  end
end
