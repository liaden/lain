# frozen_string_literal: true

require "prism"
require "stringio"
require "tmpdir"

# B3 (chunk-bench-arms-subcommand): the `bench arms` door onto
# Bench::CLI#arms_report. The command is a FLAG PARSER -- it names no Arm, no
# Grader and no Provider (exe/lain:80-85) -- so what is under test here is the
# wiring: which flags are declared, which of them reach the entry point, and
# what the entry point is handed for a journal.
#
# exe/lain is a script, not a lib file: it ends in `LainCLI.start(ARGV)` guarded
# by `$PROGRAM_NAME == __FILE__`, so `load` defines the Thor classes WITHOUT
# parsing rspec's ARGV or touching the network -- the seam spec/lain/cli_spec.rb
# and spec/lain/cli/chat_flags_spec.rb already use. Guarded, because those two
# already load it and a third unconditional `load` adds a third round of
# "already initialized constant" warnings to the suite's stderr.
#
# NOTHING HERE SPENDS MONEY. `bench arms` is the highest-spend path in the repo
# (three arms x N tasks against a real provider), so every example either stops
# at the Bench::CLI seam with a double, or -- for the three that must drive the
# real assembly -- injects a Provider::Mock through it.
load File.expand_path("../../../exe/lain", __dir__) unless defined?(LainCLI::Bench)

# The mechanical half of this spec: a flag the executable READS must be a flag
# it DECLARES, and a flag it DECLARES must be one that something reads.
#
# spec/lain/cli/chat_flags_spec.rb carries the first direction for the chat
# path, but it globs `lib/lain/cli/**/*.rb` (chat_flags_spec.rb:39) and CANNOT
# see exe/lain, which it merely `load`s. So every option read in the executable
# -- `sessions --all`, `watch --session`, `improvements --project`, and this
# card's own -- is guarded by nothing but this file. The historical failure it
# is all written for: "four flags shipped unreachable ... the `method_option`
# lines were orchestrator-owned and never landed", green specs throughout,
# because a missing flag is indistinguishable from an operator who did not pass
# one.
#
# Prism over the SOURCE rather than a hand-maintained list, for that spec's
# reason: a manifest of expected flags is the same class of artifact that
# already drifted.
module ArmsCommand
  EXE = File.expand_path("../../../exe/lain", __dir__)

  # One invocation of the command: what it said, and how it ended.
  Captured = Struct.new(:stdout, :stderr, :exited)

  # The commands whose reads go through a declarative flag->keyword map rather
  # than a literal key, and the map each forwards through. A dynamic read is a
  # HOLE in this guard -- the key cannot be resolved from the source -- so the
  # maps are checked entry by entry, and the pin below fails when a NEW dynamic
  # site appears.
  MAPS = { "arms" => "ARMS_FLAGS", "record" => "RECORD_FLAGS" }.freeze

  # One resolved option read in exe/lain, and the method it was read in. A nil
  # `key` means the index was not a literal symbol.
  Read = Struct.new(:site, :key) do
    def to_s = "##{site} reads options[#{key ? key.inspect : "<dynamic>"}]"
  end

  # Collects `options[:foo]` / `options.fetch(:foo, ...)` across the WHOLE
  # executable. An earlier draft narrowed this to `class Bench`, on the claim
  # that the outer class's reads were chat's and were covered where chat's flags
  # are declared. That claim was false -- `:all`, `:session`, `:project`,
  # `:kind` and `:socket` belong to sessions/watch/improvements/up, none of
  # which the chat guard looks at -- and the narrowing left eleven reads guarded
  # by nothing at all.
  class Scanner < Prism::Visitor
    attr_reader :reads

    def initialize
      @reads = []
      @site = nil
      super
    end

    def visit_def_node(node)
      enclosing = @site
      @site = node.name
      super
      @site = enclosing
    end

    def visit_call_node(node)
      @reads << read(node) if option_read?(node)
      super
    end

    private

    def option_read?(node)
      %i[[] fetch].include?(node.name) && options?(node.receiver)
    end

    def options?(receiver)
      case receiver
      when Prism::CallNode, Prism::LocalVariableReadNode then receiver.name == :options
      when Prism::InstanceVariableReadNode then receiver.name == :@options
      else false
      end
    end

    def read(node)
      first = node.arguments&.arguments&.first
      Read.new(@site, first.is_a?(Prism::SymbolNode) ? first.unescaped.to_sym : nil)
    end
  end

  # @return [Array<Read>] every option read in exe/lain
  def self.reads
    scanner = Scanner.new
    Prism.parse_file(EXE).value.accept(scanner)
    scanner.reads
  end

  # @return [Hash{String=>Hash}] each map-driven command's flag->keyword map
  def self.maps = MAPS.transform_values { |name| LainCLI::Bench.const_get(name) }
end

RSpec.describe "lain bench arms" do
  let(:command) { LainCLI::Bench.commands.fetch("arms") }
  let(:declared) { command.options.keys.to_set }

  # The REAL Thor parser over the real command, so the argv spelling
  # (`--max-tokens`), the type coercion, and the exit contract are exercised
  # together; a plain options hash would prove none of the three.
  def run(*argv) = capturing { LainCLI::Bench.start(argv) }

  # Thor's shell reads $stdout/$stderr at call time, so swapping the globals is
  # what captures it.
  def capturing(out = StringIO.new, err = StringIO.new, &block)
    original = [$stdout, $stderr]
    $stdout = out
    $stderr = err
    exited = exit_from(&block)
    ArmsCommand::Captured.new(out.string, err.string, exited)
  ensure
    $stdout, $stderr = original
  end

  # A SystemExit is this command's exit CONTRACT (Thor maps a Lain::Error to a
  # message on stderr and a nonzero status), so it is a value here, not a crash.
  def exit_from
    yield
    nil
  rescue SystemExit => e
    e
  end

  # Scenario: the subcommand is discoverable and declares its cost.
  describe "discoverability" do
    it "is listed among the bench subcommands" do
      expect(run("help").stdout).to include("arms")
    end

    # Thor TRUNCATES descriptions in the command listing (`bench help` cuts at
    # the terminal width), so the cost sentence is asserted on the declaration
    # itself -- which is what `bench help arms` prints in full.
    it "declares that it spends real API money, as record does" do
      expect(command.description).to include("spends real API money")
      expect(run("help", "arms").stdout).to include("spends real API money")
    end

    it "names every backend the resolver accepts in the isolation flag's help" do
      expect(declared).to include(:isolation)
      expect(command.options.fetch(:isolation).description)
        .to include(*Lain::CLI::IsolationBackend::BACKENDS)
    end

    # The same rule the isolation flag follows, and worth its own example: help
    # text that restates an authority's set is help text that can come to
    # disagree with it.
    it "names every provider the backend accepts in the provider flag's help" do
      expect(command.options.fetch(:provider).description)
        .to include(*Lain::CLI::Backend::PROVIDERS)
    end

    # THE TRAP THIS CARD IS WRITTEN AROUND. chat declares `--isolation` with
    # `default: IsolationBackend::DEFAULT` (exe/lain:257-261); the same line here
    # would make options[:isolation] never nil, and the unset-vs-"none"
    # distinction Bench::CLI#arm_isolation preserves would be gone -- every run
    # leasing a real backend, the Driver's own no-lease default unreachable from
    # the command line, and nothing raising.
    it "declares --isolation with NO default, so an unset flag stays unset" do
      expect(command.options.fetch(:isolation).default).to be_nil
      expect(Thor::Options.new(command.options).parse([])).not_to have_key(:isolation)
    end

    it "declares --journal, and says which flag needs it" do
      expect(declared).to include(:journal)
      expect(command.options.fetch(:journal).description).to include("--isolation")
    end

    # record's ceiling is 1024 and this one's is 4096; two flags with one
    # spelling in one subcommand family, so the help says why they differ.
    it "explains why its max_tokens ceiling is not record's" do
      expect(command.options.fetch(:max_tokens).default).to eq(Lain::Bench::SpawnSeam::DEFAULT_MAX_TOKENS)
      expect(command.options.fetch(:max_tokens).description).to include("record")
    end
  end

  # Scenario: every flag the command reads is a flag it declares.
  describe "the declared flags cover what the executable reads" do
    let(:reads) { ArmsCommand.reads }
    let(:literal) { reads.filter_map(&:key) }
    let(:declared_anywhere) do
      (LainCLI.commands.values + LainCLI::Bench.commands.values).flat_map { |cmd| cmd.options.keys }.to_set
    end

    it "declares every literal option key the executable reads" do
      undeclared = reads.reject { |read| read.key.nil? || declared_anywhere.include?(read.key) }
      # The reads themselves are the failure message: a bare `be_empty` over
      # symbols would name the flag but not the site reading it.
      expect(undeclared.map(&:to_s)).to eq([])
    end

    # BOTH directions. A flag in the map that nothing declares is unreachable
    # (F7's failure); a flag DECLARED that no map forwards and no line reads is
    # its mirror -- advertised in `bench help arms`, accepted on the command
    # line, and silently dropped.
    it "declares every flag its map forwards, and forwards or reads every flag it declares" do
      ArmsCommand.maps.each do |name, map|
        options = LainCLI::Bench.commands.fetch(name).options.keys
        expect(map.keys - options).to eq([])
        expect(options - map.keys - literal).to eq([])
      end
    end

    it "leaves the map-driven reads exactly where they are pinned" do
      dynamic = reads.select { |read| read.key.nil? }
      expect(dynamic.map(&:site).map(&:to_s).uniq.sort).to eq(ArmsCommand::MAPS.keys.sort)
    end

    # Keys from three different commands, so a scan that silently stopped
    # matching -- or that narrowed back to one class -- cannot pass this.
    # `:isolation` is deliberately NOT here: it is map-driven, and the example
    # above is what covers it.
    it "finds the reads at all, so an empty scan cannot pass this spec vacuously" do
      expect(literal).to include(:journal, :all, :session, :nvim)
    end
  end

  # What the entry point was actually handed. The command is a flag parser, so
  # the kwargs ARE the behaviour under test.
  describe "what reaches Bench::CLI#arms_report" do
    let(:calls) { [] }
    let(:entry) { instance_double(Lain::Bench::CLI) }

    before do
      allow(Lain::Bench::CLI).to receive(:new).and_return(entry)
      allow(entry).to receive(:arms_report) do |**kwargs|
        calls << kwargs
        "the report"
      end
    end

    def kwargs = calls.last

    it "hands the entry point the fixture path it was given, and says the report" do
      result = run("arms", "suite/tasks.yml")

      expect(kwargs).to include(fixture_path: "suite/tasks.yml")
      expect(result.stdout).to include("the report")
    end

    # Scenario: an unset isolation flag reaches the entry point as nil.
    #
    # nil is what leaves Arm::Driver's own default in place; anything else --
    # a Thor default, a `|| DEFAULT` -- silently isolates every run.
    it "passes no isolation name when the flag is unset" do
      run("arms", "suite/tasks.yml")

      expect(kwargs).to include(isolation: nil)
    end

    # A journal handed in with NO isolation name is an ArgumentError one layer
    # down (Bench::CLI#arm_isolation refuses to drop it), so an unset --journal
    # must not manufacture one.
    it "opens no journal when no --journal is given" do
      run("arms", "suite/tasks.yml")

      expect(kwargs).to include(journal: nil)
    end

    # Every flag in the map, through the real Thor parser: a silently dropped
    # --seed is a reproducibility hole on a bench whose whole claim is
    # repeatability, and a dropped --provider is money spent on the wrong model.
    it "carries every declared flag through to the entry point" do
      run("arms", "suite/tasks.yml", "--provider", "ollama", "--api-base", "http://localhost:11434",
          "--model", "qwen3", "--max-tokens", "321", "--system", "be terse",
          "--temperature", "0.25", "--seed", "99", "--isolation", "none")

      expect(kwargs).to include(provider_name: "ollama", api_base: "http://localhost:11434",
                                model: "qwen3", max_tokens: 321, system: "be terse",
                                temperature: 0.25, seed: 99, isolation: "none")
    end

    it "defaults max_tokens to the live seam's own ceiling, not record's" do
      run("arms", "suite/tasks.yml")

      expect(kwargs).to include(max_tokens: Lain::Bench::SpawnSeam::DEFAULT_MAX_TOKENS)
    end
  end

  # The lease telemetry is the deliverable of an isolated run -- IsolationBackend
  # decorates BY NEED, so an unjournalled resolve emits no Telemetry::IsolationLease
  # at all -- and the Journal's contract is that the record parses line by line.
  # That is why it gets its own FILE and never a shared stream: `render` maps a
  # Lain::Error to Thor's message-on-stderr contract, so stderr carries this
  # command's diagnostics by construction and could not stay parseable NDJSON.
  describe "--journal" do
    let(:calls) { [] }
    let(:entry) { instance_double(Lain::Bench::CLI) }
    let(:lease) { Lain::Telemetry::IsolationLease.new(kind: :acquired, worker_key: "w-1", backend: "B") }

    around { |example| Dir.mktmpdir("lain-arms-journal") { |dir| (@dir = dir) && example.run } }

    def journal_path = File.join(@dir, "leases.ndjson")

    def kwargs = calls.last

    # The entry point RECORDS, the way IsolationBackend's journal decorator does,
    # so what is under test is the whole wire: the flag, the file it opened, and
    # the bytes that reach it.
    def stub_entry(&recording)
      allow(Lain::Bench::CLI).to receive(:new).and_return(entry)
      allow(entry).to receive(:arms_report) do |**kwargs|
        calls << kwargs
        recording&.call(kwargs.fetch(:journal))
        "the report"
      end
    end

    it "opens a real Journal on the named path, never handing the entry point a bare String" do
      stub_entry
      run("arms", "suite/tasks.yml", "--isolation", "none", "--journal", journal_path)

      expect(kwargs.fetch(:journal)).to be_a(Lain::Journal)
    end

    it "records the lease telemetry into that file, one NDJSON line per record" do
      stub_entry { |journal| journal << lease }
      run("arms", "suite/tasks.yml", "--isolation", "none", "--journal", journal_path)

      expect(JSON.parse(File.read(journal_path).lines.last))
        .to include("type" => "isolation_lease", "worker_key" => "w-1")
    end

    # The wound the Journal's own doc names ("NEVER stderr"): stderr carries
    # Thor's error message and whatever a gem warns mid-run, and one such line
    # makes JSON.parse fail on it. The report is stdout's, the telemetry is the
    # file's, and neither stream carries the other's bytes.
    it "leaves stdout the report and stderr empty" do
      stub_entry { |journal| journal << lease }
      result = run("arms", "suite/tasks.yml", "--isolation", "none", "--journal", journal_path)

      expect(result.stdout).to include("the report")
      expect(result.stderr).to eq("")
      expect(File.read(journal_path)).to include("isolation_lease")
    end

    # A refusal must not leave a zero-byte artifact behind: Journal#close removes
    # a file it created and never wrote to, which is the "a refusal never orphans
    # a fresh journal" rule the chat path already keeps.
    it "removes the journal it created when the run fails before recording anything" do
      stub_entry { raise Lain::Bench::CLI::Refusal, "no arms for you" }
      result = run("arms", "suite/tasks.yml", "--isolation", "none", "--journal", journal_path)

      expect(result.stderr).to include("no arms for you")
      expect(File.exist?(journal_path)).to be(false)
    end

    # Bench::CLI#arm_isolation CRASHES on a journal with no isolation name to
    # resolve it against, deliberately -- it refuses to silently drop the option
    # -- and that is right for the library, whose caller is a programmer. It
    # rested on nothing in argv being able to reach it, and --journal is what
    # broke that premise. So the door is closed HERE, in front of the library
    # refusal, which stays exactly as it is and stays the authority.
    it "refuses --journal without --isolation in one clean line, naming the backends" do
      stub_entry
      result = run("arms", "suite/tasks.yml", "--journal", journal_path)

      expect(result.stderr).to include("--isolation", *Lain::CLI::IsolationBackend::BACKENDS)
      expect(result.exited.status).not_to eq(0)
    end

    # The distinction the example above cannot make on its own: an ArgumentError
    # escaping the command is ALSO a nonzero exit with the flags in the text.
    # What must not happen is that it reads as a crash.
    it "presents that refusal as a Thor error, never as a backtrace" do
      stub_entry
      result = run("arms", "suite/tasks.yml", "--journal", journal_path)

      expect(result.stderr.lines.size).to eq(1)
      expect(result.stderr).not_to include("ArgumentError", "lib/lain")
    end

    it "reaches no entry point and creates no journal file when it refuses the pairing" do
      stub_entry
      run("arms", "suite/tasks.yml", "--journal", journal_path)

      expect(calls).to be_empty
      expect(File.exist?(journal_path)).to be(false)
    end

    it "keeps a journal that did record something, however the run ended" do
      stub_entry do |journal|
        journal << lease
        raise Lain::Bench::CLI::Refusal, "no arms for you"
      end
      run("arms", "suite/tasks.yml", "--isolation", "none", "--journal", journal_path)

      expect(File.exist?(journal_path)).to be(true)
    end
  end

  # Scenario: an unknown isolation name fails without running an arm.
  #
  # The examples that drive the REAL assembly, so they prove the flags reach the
  # resolver rather than a double's expectation. A Provider::Mock is injected
  # through the entry point: the assembly resolves a provider BEFORE it resolves
  # the isolation name, and a live one would be key-gated (or paid for).
  describe "an unknown isolation name" do
    let(:provider) { Lain::Provider::Mock.new(responses: []) }
    let(:live) { Lain::Bench::CLI.new }
    let(:fixture) { File.join(__dir__, "..", "..", "fixtures", "arms", "tasks.yml") }

    around { |example| Dir.mktmpdir("lain-arms-journal") { |dir| (@dir = dir) && example.run } }

    def journal_path = File.join(@dir, "leases.ndjson")

    before do
      allow(Lain::Bench::CLI).to receive(:new).and_return(live)
      allow(live).to receive(:arms_report).and_wrap_original do |original, **kwargs|
        original.call(provider:, **kwargs)
      end
      allow(Lain::Arm::Driver).to receive(:new).and_call_original
    end

    it "fails naming the advertised set, with no backtrace and a nonzero exit" do
      result = run("arms", fixture, "--isolation", "nope", "--journal", journal_path)

      expect(result.stderr).to match(/nope/).and match(/none/).and match(/worktree/)
      expect(result.exited).to be_a(SystemExit)
      expect(result.exited.status).not_to eq(0)
    end

    # The stderr check is this example's PRECONDITION, not a repeat of the one
    # above: without it, "no arm ran" passes just as well for a command that
    # does not exist at all.
    it "runs no arm and asks no provider" do
      result = run("arms", fixture, "--isolation", "nope", "--journal", journal_path)

      expect(result.stderr).to match(/worktree/)
      expect(Lain::Arm::Driver).not_to have_received(:new)
      expect(provider.call_count).to eq(0)
    end

    # An isolated run with nowhere to record its leases is refused by Bench::CLI
    # BEFORE the name is validated, so this -- not the advertised set -- is what
    # an operator who forgot --journal meets. It names the flag it wants, which
    # is the flag right there in the same help output.
    it "asks for the journal first when --isolation arrives without one" do
      result = run("arms", fixture, "--isolation", "nope")

      expect(result.stderr).to include("journal")
      expect(Lain::Arm::Driver).not_to have_received(:new)
      expect(provider.call_count).to eq(0)
    end
  end
end
