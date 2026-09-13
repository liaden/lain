# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# A REAL {Lain::Tool} including the seam, kept out of the RSpec block for
# Lint/ConstantDefinitionInBlock and out of the `Lain::` namespace on purpose:
# tool_bounds_discipline_spec.rb sweeps ObjectSpace for `Lain::`-named Tool
# subclasses, and a spec-local probe must never join that subject set.
module FileTargetSpecSupport
  class Probe < Lain::Tool
    include Lain::Tool::FileTarget

    def name = "probe"

    def description = "a spec-local tool that exercises the file-target seam and nothing else"

    # The four seam methods are private -- a tool reaches them from its own
    # #perform, never a collaborator. These name what is being asked of them.
    def resolve(invocation, path) = target(invocation, path)

    def guard(path, expecting:) = problem_with(path, expecting:)

    def source(path) = utf8_source(path)

    def attempt(verb, path, *also, &block) = failing(verb, path, *also, &block)
  end
end

RSpec.describe Lain::Tool::FileTarget do
  subject(:probe) { FileTargetSpecSupport::Probe.new }

  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = File.realpath(dir)
      example.run
    end
  end

  attr_reader :tmpdir

  def write(name, content = "x")
    path = File.join(tmpdir, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def invocation_with(session) = Lain::Tool::Invocation.new(tool_use_id: "tu_1", context: session)

  def session_at(cwd) = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd:, env: ENV.to_h))

  describe "#target" do
    it "resolves a relative path against the session's WorkerEnv cwd" do
      expect(probe.resolve(invocation_with(session_at(tmpdir)), "inner.txt")).to eq("#{tmpdir}/inner.txt")
    end

    it "honors an absolute path as given" do
      expect(probe.resolve(invocation_with(session_at("/nowhere")), "#{tmpdir}/a.txt")).to eq("#{tmpdir}/a.txt")
    end

    # {Tools::Glob} spelled `input.path || "."` before this seam existed;
    # WorkerEnv#resolve already answers the nil arm, so the branch is gone
    # rather than moved.
    it "answers the cwd itself when no path was given" do
      expect(probe.resolve(invocation_with(session_at(tmpdir)), nil)).to eq(tmpdir)
    end

    it "falls back to the process cwd when the invocation carries no session" do
      Dir.chdir(tmpdir) do
        expect(probe.resolve(nil, "a.txt")).to eq("#{tmpdir}/a.txt")
      end
    end
  end

  describe "#problem_with" do
    it "passes an existing readable file expected as a file" do
      expect(probe.guard(write("a.rb"), expecting: :file)).to be_nil
    end

    it "names a missing file as no such file" do
      expect(probe.guard("#{tmpdir}/nope", expecting: :file)).to eq("no such file: #{tmpdir}/nope")
    end

    it "names a missing directory as no such directory" do
      expect(probe.guard("#{tmpdir}/nope", expecting: :directory)).to eq("no such directory: #{tmpdir}/nope")
    end

    # {Tools::Grep} and {Tools::AstSearch} take either, so their sentence names
    # both and no wrong-type rule fires at all.
    it "names a missing either-target as no such file or directory" do
      expect(probe.guard("#{tmpdir}/nope", expecting: :either)).to eq("no such file or directory: #{tmpdir}/nope")
    end

    it "refuses a directory handed to a file expectation as a directory, not merely as unreadable" do
      expect(probe.guard(tmpdir, expecting: :file)).to eq("is a directory, not a file: #{tmpdir}")
    end

    it "refuses a file handed to a directory expectation" do
      path = write("a.rb")
      expect(probe.guard(path, expecting: :directory)).to eq("not a directory: #{path}")
    end

    it "accepts a directory under the either expectation" do
      expect(probe.guard(tmpdir, expecting: :either)).to be_nil
    end

    # The memory guard {Tools::ReadFile} bounds by size with, which no other
    # expectation wants: File.size is 0 for a fifo, so it would sail through.
    it "refuses a fifo under the regular-file expectation, which :file admits" do
      path = File.join(tmpdir, "pipe")
      File.mkfifo(path)

      expect(probe.guard(path, expecting: :regular_file))
        .to eq("not a regular file (a device, socket or fifo has no size to bound): #{path}")
      expect(probe.guard(path, expecting: :file)).to be_nil
    end

    describe "an unreadable target", if: Process.uid != 0 do
      it "names a file as not readable in the file wording" do
        path = write("a.rb")
        File.chmod(0o000, path)

        expect(probe.guard(path, expecting: :file)).to eq("file is not readable: #{path}")
      end

      it "names a directory as not readable in the directory wording" do
        sub = File.join(tmpdir, "sub")
        FileUtils.mkdir_p(sub)
        File.chmod(0o000, sub)

        expect(probe.guard(sub, expecting: :directory)).to eq("directory is not readable: #{sub}")
      ensure
        File.chmod(0o700, sub)
      end

      it "names an either-target as not readable with no noun at all" do
        path = write("a.rb")
        File.chmod(0o000, path)

        expect(probe.guard(path, expecting: :either)).to eq("not readable: #{path}")
      end
    end
  end

  describe "#failing" do
    it "returns whatever the block returns when nothing goes wrong" do
      expect(probe.attempt("read", "/x") { Lain::Tool::Result.ok("fine") }).to eq(Lain::Tool::Result.ok("fine"))
    end

    it "turns a SystemCallError into an error Result naming the verb and the path" do
      result = probe.attempt("write", "/x") { raise Errno::EACCES, "/x" }

      expect(result).to have_attributes(is_error: true, content: a_string_starting_with("could not write /x: "))
    end

    it "turns an IOError into the same shape" do
      result = probe.attempt("list", "/x") { raise IOError, "closed" }

      expect(result).to have_attributes(is_error: true, content: "could not list /x: closed")
    end

    # {Tools::FileSymbols} rides EncodingError along on the structural read --
    # to the model it is the same answer as any other "this file cannot be
    # read" -- so the extra classes are an ARGUMENT rather than a hardcoded set.
    it "rescues only the extra classes it was given" do
      result = probe.attempt("read", "/x", EncodingError) { raise EncodingError, "bad bytes" }

      expect(result).to have_attributes(is_error: true, content: "could not read /x: bad bytes")
      expect { probe.attempt("read", "/x") { raise EncodingError, "bad bytes" } }.to raise_error(EncodingError)
    end

    it "lets an unrelated error escape" do
      expect { probe.attempt("read", "/x") { raise ArgumentError, "nope" } }.to raise_error(ArgumentError)
    end
  end

  describe "#utf8_source" do
    it "tags the bytes UTF-8 rather than Encoding.default_external" do
      path = write("a.rb", "# café\n")

      expect(probe.source(path).encoding).to eq(Encoding::UTF_8)
    end
  end

  describe "three of the eight tools, driven whole through the seam" do
    # Driven through the real tool, because the point of the
    # seam is that the tools stopped re-deriving this.
    describe "read_file" do
      subject(:tool) { Lain::Tools::ReadFile.new }

      it "resolves a relative path against the session cwd, not the process cwd" do
        write("inner.txt", "inside\n")
        outside = Dir.mktmpdir
        File.write(File.join(outside, "inner.txt"), "outside\n")

        Dir.chdir(outside) do
          result = tool.call({ path: "inner.txt" }, invocation_with(session_at(tmpdir)))

          expect(result.content).to include("inside")
          expect(result.content).not_to include("outside")
        end
      ensure
        FileUtils.remove_entry(outside)
      end

      it "honors an absolute path as given" do
        path = write("abs.txt", "absolute\n")

        result = tool.call({ path: }, invocation_with(session_at("/")))

        expect(result.content).to include("absolute")
      end
    end

    it "refuses a missing list_files target with one sentence naming the resolved path" do
      result = Lain::Tools::ListFiles.new.call({ path: "nope" }, invocation_with(session_at(tmpdir)))

      expect(result).to have_attributes(is_error: true, content: "no such directory: #{tmpdir}/nope")
    end

    it "names the verb write_file was performing when the write is denied", if: Process.uid != 0 do
      path = write("locked.txt", "old\n")
      File.chmod(0o000, path)
      session = Lain::Session.new.record_read(path)

      result = Lain::Tools::WriteFile.new.call({ path:, content: "new" }, invocation_with(session))

      expect(result).to have_attributes(is_error: true, content: a_string_starting_with("could not write #{path}: "))
    end
  end
end
