# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Shell::Stages do
  around do |example|
    Dir.mktmpdir do |made|
      @root = File.realpath(made)
      example.run
    end
  end

  let(:fresh) { Lain::Shell::Executable::Resolver::NeverFresh }
  let(:resolver) { Lain::Shell::Executable::Resolver.new(root: @root, fresh:) }
  let(:worker_env) { Lain::WorkerEnv.new(cwd: @root, env: {}) }

  def of(command, home: nil) = described_class.of(command, worker_env:, resolver:, home:)

  it "resolves a quoted script as the file its interpreter runs" do
    File.write(File.join(@root, "x.sh"), "true\n")

    read = of("bash 'x.sh' # note")

    expect(read).to be_known
    expect(read.stages.map { _1.executable.run_files.map(&:path) }).to eq([[File.join(@root, "x.sh")]])
    expect(read.stages.map(&:argv)).to eq([%w[bash x.sh]])
  end

  it "resolves each stage where it runs, and leaves the shell's builtins out" do
    FileUtils.mkdir_p(File.join(@root, "sub"))

    read = of("cd sub && umask 022 && ls")

    expect(read.stages.map { [_1.argv, _1.directory] }).to eq([[%w[ls], File.join(@root, "sub")]])
    expect(read.stages.first.executable.resolved).to end_with("/ls")
  end

  it "keeps a stage it cannot place, unplaced and unresolved" do
    read = of("cd sub && ls ; ls")

    expect(read.stages.map(&:placed?)).to eq([true, false])
    expect(read.stages.last.executable.klass).to eq(:unresolved)
  end

  it "cannot tell for a recursive glob, an expansion, a NUL byte or a command that is not a String" do
    ["ls **/x", "cat $X", "ls\0x", 5, nil].each do |command|
      expect(of(command)).to equal(described_class::UNKNOWN), command.inspect
    end
  end

  it "cannot tell when resolving a stage raises" do
    raising = Class.new { define_method(:for) { |_worker_env| raise IOError, "resolver gone" } }.new

    expect(described_class.of("ruby x.rb", worker_env:, resolver: raising)).to equal(described_class::UNKNOWN)
  end

  describe ".for_input" do
    def for_input(input) = described_class.for_input(input, worker_env:, resolver:, home: nil)

    it "reads the command and the call's own cwd from a tool input" do
      FileUtils.mkdir_p(File.join(@root, "sub"))

      [{ "command" => "ls", "cwd" => "sub" }, { command: "ls", cwd: "sub" }].each do |input|
        expect(for_input(input).stages.map(&:directory)).to eq([File.join(@root, "sub")]), input.inspect
      end
    end

    it "cannot tell for an input with no command, or a cwd no tool could resolve" do
      [{}, { "command" => "ls", "cwd" => 5 }, "ls"].each do |input|
        expect(for_input(input)).to equal(described_class::UNKNOWN), input.inspect
      end
    end
  end
end
