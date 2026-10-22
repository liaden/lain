# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# The single-selector half of session discovery, owned once. `lain friction`,
# `lain consolidate` and `lain improve` each ask the same question -- "which ONE
# file does this selector name?" -- and each answered it with its own
# byte-identical `resolve`/`dir`/`SessionNotFound` triple, so three copies of a
# user-facing contract (which shorthands work, and what the refusal says) could
# drift with nothing failing. {Lain::CLI::SessionJournals} owns the other half:
# EVERY journal in the directory, for a fold that must not miss one.
RSpec.describe Lain::CLI::SessionFile do
  subject(:resolved) { described_class.resolve(selector, paths:, project:) }

  let(:paths) { instance_double(Lain::Paths, session_dirs: [@dir]) }
  let(:selector) { "20260721T000000-1" }
  let(:project) { Lain::Paths::Place.new(root: @dir, cwd: @dir) }

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

      expect(described_class.resolve("20260721T000000-1.ndjson", paths:, project:)).to eq(path)
    end

    it "resolves a filename missing its .ndjson suffix" do
      path = write("20260721T000000-1.ndjson")

      expect(resolved).to eq(path)
    end

    it "resolves an explicit path directly, wherever it lives" do
      Dir.mktmpdir do |elsewhere|
        path = File.join(elsewhere, "kept.ndjson")
        File.write(path, "{}\n")

        expect(described_class.resolve(path, paths:, project:)).to eq(path)
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

      expect { described_class.resolve("nope", paths:, project:) }
        .to raise_error(described_class::SessionNotFound, /"nope" -- looked at #{Regexp.escape(tried)}/)
    end

    it "is a Lain::Error, so the exe maps it to a message rather than a backtrace" do
      expect(described_class::SessionNotFound.ancestors).to include(Lain::Error)
    end
  end

  # The Command::Surface doctrine: a forgotten collaborator is a loud
  # ArgumentError at the call, never a resolution against some default root.
  it "requires paths:, rather than defaulting to this process's project" do
    expect { described_class.resolve("nope", project:) }.to raise_error(ArgumentError, /paths/)
  end

  describe "the root's directory and the working directory's" do
    def second_directory_resolution(name)
      Dir.mktmpdir do |state|
        real = File.realpath(state)
        root = File.join(real, "project")
        sub = File.join(root, "sub")
        FileUtils.mkdir_p([root, sub])
        store = Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(real, "state") })
        path = File.join(store.sessions_dir(project: store.project_hash(sub)), name)
        File.write(path, "{}\n")
        place = Lain::Paths::Place.new(root:, cwd: sub)

        [path, described_class.resolve(name.delete_suffix(".ndjson"), paths: store, project: place)]
      end
    end

    it "resolves a bare filename held only by the working directory's" do
      expected, resolved = second_directory_resolution("20260721T000000-1.ndjson")

      expect(resolved).to eq(expected)
    end

    it "names the candidates in both directories when nothing answers" do
      Dir.mktmpdir do |state|
        store = Lain::Paths.new(env: { "XDG_STATE_HOME" => state })
        place = Lain::Paths::Place.new(root: File.realpath(state), cwd: File.realpath(Dir.tmpdir))

        expect { described_class.resolve("nope", paths: store, project: place) }
          .to raise_error(described_class::SessionNotFound) { |error|
            expect(error.message.scan("nope.ndjson").length).to eq(2)
          }
      end
    end
  end
end
