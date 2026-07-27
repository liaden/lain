# frozen_string_literal: true

require "prism"
require "pathname"

# exe/lain is a script, not a lib file: it ends in `LainCLI.start(ARGV)` guarded
# by `$PROGRAM_NAME == __FILE__`, so this `load` defines the Thor class WITHOUT
# parsing rspec's ARGV or touching the network. Same seam spec/lain/cli_spec.rb
# uses.
load File.expand_path("../../../exe/lain", __dir__)

# Mechanical guard: a flag the run READS must be a flag the CLI DECLARES.
#
# This exists because the gap it closes is silent in both directions. Thor never
# calls `check_unknown_options!` here, so an undeclared switch is not refused --
# `lain chat --isolation worktree` on the code that read `options[:isolation]`
# without declaring it ran the whole session with Isolation::Null and said
# nothing. From the other side, every reader falls through to a default
# (`knob`, `||`, `fetch`), so the flag's absence looks exactly like the operator
# not passing it. Nothing raises, nothing is journalled, and the feature simply
# is not there -- which is how four flags shipped unreachable in the
# compaction-tiers chunk (the `method_option` lines were orchestrator-owned and
# never landed, while every card's own specs stayed green because they build
# Backend and Wiring from plain option hashes).
#
# So the check is on the SOURCE, not on a list someone maintains: we parse each
# file under lib/lain/cli/ and collect the option keys it actually reads. A
# hand-written manifest of expected flags would be the same class of artifact
# that already drifted.
#
# Prism rather than a grep: `options[:foo]` appears in prose comments in these
# files, and a receiverless `[]` on some other collection is not an option read.
# Ripper would do (spec/output_discipline_spec.rb uses it) but Prism's node
# types name what we are matching on, so the matcher reads as the rule.
module ChatFlags
  ROOT = Pathname.new(File.expand_path("../../..", __dir__))

  # The CLI subtree: every object a command hands its parsed options hash to.
  SOURCES = ROOT.glob("lib/lain/cli/**/*.rb").sort.freeze

  # Keys read under lib/lain/cli/ that `chat` deliberately does not declare,
  # mapped to the commands that do. An entry is a CLAIM, and the examples below
  # check it both ways: the named commands really declare the flag, and the key
  # is really still read. An empty allowlist would be better; this one is honest.
  ELSEWHERE = { dry_run: %w[consolidate improve] }.freeze

  # Option reads whose key is not a literal, pinned with their reason. A
  # dynamic read is a hole in this guard -- the key cannot be resolved from the
  # source, so an undeclared flag could hide behind one -- and the point of
  # pinning the known site is that a NEW hole fails this spec rather than
  # quietly widening the blind spot.
  DYNAMIC = {
    "lib/lain/cli/backend.rb" =>
      "the %i[temperature seed] sampler pair, read by key so one loop covers both; both are declared on chat"
  }.freeze

  # One resolved option read. A nil `key` means the index was not a literal.
  Read = Struct.new(:path, :line, :key) do
    def to_s = "#{path}:#{line} reads options[#{key ? key.inspect : "<dynamic>"}]"
  end

  # Collects the three shapes an option read takes in this codebase:
  # `options[:foo]` / `@options[:foo]`, `.fetch(:foo, default)` on either, and
  # Backend's own `knob(:foo, default)` helper.
  class Scanner < Prism::Visitor
    attr_reader :reads

    def initialize(path)
      @path = path
      @reads = []
      super()
    end

    def visit_call_node(node)
      @reads << read(node) if option_read?(node)
      super
    end

    private

    def option_read?(node)
      case node.name
      when :[], :fetch then options?(node.receiver)
      when :knob then node.receiver.nil?
      else false
      end
    end

    # `@options` is the ivar every long-lived CLI object holds; `options` is the
    # reader Thor mixes in and the local a few methods take.
    def options?(receiver)
      case receiver
      when Prism::InstanceVariableReadNode then receiver.name == :@options
      when Prism::CallNode, Prism::LocalVariableReadNode then receiver.name == :options
      else false
      end
    end

    def read(node)
      first = node.arguments&.arguments&.first
      key = first.is_a?(Prism::SymbolNode) ? first.unescaped.to_sym : nil
      Read.new(@path, node.location.start_line, key)
    end
  end

  # @return [Array<Read>] every option read in the CLI subtree
  def self.reads
    SOURCES.flat_map do |path|
      scanner = Scanner.new(path.relative_path_from(ROOT).to_s)
      Prism.parse_file(path.to_s).value.accept(scanner)
      scanner.reads
    end
  end
end

RSpec.describe "lain chat's flag surface" do
  let(:reads) { ChatFlags.reads }
  let(:resolved) { reads.reject { |read| read.key.nil? } }
  let(:declared) { LainCLI.commands.fetch("chat").options.keys.to_set }

  # The real Thor parser over the real command, so the argv spelling
  # (`--summarizer-max-tokens`), the type coercion, and the indifferent-access
  # hash the lib reads with SYMBOLS are all exercised together. A plain option
  # hash in a unit spec proves none of the three.
  def parse(*argv) = Thor::Options.new(LainCLI.commands.fetch("chat").options).parse(argv)

  describe "the declared flags cover what the code reads" do
    it "declares every option key the CLI objects read" do
      undeclared = resolved.reject { |read| declared.include?(read.key) || ChatFlags::ELSEWHERE.key?(read.key) }
      # The reads themselves are the failure message: a bare `be_empty` on a set
      # of symbols would name the flag but not the construction site reading it.
      expect(undeclared.map(&:to_s)).to eq([])
    end

    it "finds the flags at all, so an empty scan cannot pass this spec vacuously" do
      expect(resolved.map(&:key)).to include(:provider, :model, :isolation, :summarizer_provider)
    end

    it "backs each allowlisted key with a command that really declares it" do
      ChatFlags::ELSEWHERE.each do |key, commands|
        commands.each do |name|
          expect(LainCLI.commands.fetch(name).options.keys).to include(key)
        end
      end
    end

    it "keeps no stale allowlist entry" do
      expect(ChatFlags::ELSEWHERE.keys - resolved.map(&:key)).to be_empty
    end

    it "leaves the blind spot exactly where it is pinned" do
      dynamic = reads.select { |read| read.key.nil? }
      expect(dynamic.map(&:path).uniq).to eq(ChatFlags::DYNAMIC.keys)
    end
  end

  describe "--isolation" do
    it "defaults to the resolver's own DEFAULT rather than a second copy of it" do
      expect(parse[:isolation]).to eq(Lain::CLI::IsolationBackend::DEFAULT)
    end

    it "names every backend the resolver accepts in its help text" do
      help = LainCLI.commands.fetch("chat").options.fetch(:isolation).description
      expect(help).to include(*Lain::CLI::IsolationBackend::BACKENDS)
    end

    it "reaches the resolver as a backend selection" do
      Dir.mktmpdir do |root|
        expect(Lain::CLI::IsolationBackend.resolve(parse[:isolation], root:)).to be_a(Lain::Isolation::Null)
      end
    end

    it "carries a selected backend name through to the resolver" do
      expect(parse("--isolation", "worktree")[:isolation]).to eq("worktree")
    end

    it "is refused by name when the operator misspells it" do
      Dir.mktmpdir do |root|
        expect { Lain::CLI::IsolationBackend.resolve(parse("--isolation", "nope")[:isolation], root:) }
          .to raise_error(Lain::CLI::IsolationBackend::Unknown, /"nope".*none.*worktree/m)
      end
    end
  end

  describe "--compact-strategy" do
    it "defaults to the resolver's own DEFAULT rather than a second copy of it" do
      expect(parse[:compact_strategy]).to eq(Lain::CLI::CompactionStrategy::DEFAULT)
    end

    it "names every strategy the resolver accepts in its help text" do
      help = LainCLI.commands.fetch("chat").options.fetch(:compact_strategy).description
      expect(help).to include(*Lain::CLI::CompactionStrategy::STRATEGIES)
    end

    it "carries a selected strategy name through to the resolver" do
      expect(parse("--compact-strategy", "elide")[:compact_strategy]).to eq("elide")
    end

    # `elide` needs no `tier:` factory, so this reaches the real resolver with
    # no oracle machinery to fake -- the same "no extra collaborators" shape
    # `--isolation`'s own resolver call above has with its default backend.
    it "reaches the resolver as a strategy selection" do
      resolved = Lain::CLI::CompactionStrategy.resolve(parse("--compact-strategy", "elide")[:compact_strategy])
      expect(resolved).to be_a(Lain::Compaction::Strategy::Elide)
    end

    it "is refused by name when the operator misspells it" do
      expect { Lain::CLI::CompactionStrategy.resolve(parse("--compact-strategy", "nope")[:compact_strategy]) }
        .to raise_error(Lain::CLI::CompactionStrategy::Unknown, /"nope".*summarizing.*elide/m)
    end
  end

  describe "the summarizer tier flags" do
    it "defaults the provider to Backend's own constant" do
      expect(parse[:summarizer_provider]).to eq(Lain::CLI::Backend::DEFAULT_SUMMARIZER_PROVIDER)
    end

    it "points the summarizer at a paid provider independently of --provider" do
      # Bedrock is env-configured and reads its region at construction (offline,
      # no request), so a placeholder is enough to build the object -- the same
      # stub spec/lain/cli_spec.rb's provider examples use.
      backend = Lain::CLI::Backend.new(parse("--provider", "ollama", "--summarizer-provider", "bedrock"))
      with_env("AWS_BEARER_TOKEN_BEDROCK" => "tok", "AWS_REGION" => "us-east-1") do
        expect(backend.provider).to be_a(Lain::Provider::Ollama)
        expect(backend.summarizer_provider).to be_a(Lain::Provider::Bedrock)
      end
    end

    it "declares no default model, so the model resolves to the summarizer provider's own" do
      expect(parse[:summarizer_model]).to be_nil
      expect(Lain::CLI::Backend.new(parse).summarizer_model).to eq(Lain::Provider::Ollama::DEFAULT_MODEL)
      expect(Lain::CLI::Backend.new(parse("--summarizer-provider", "bedrock")).summarizer_model)
        .to eq(Lain::Provider::Bedrock::DEFAULT_MODEL)
    end

    it "never lets the chat's --model name the summarizer's" do
      backend = Lain::CLI::Backend.new(parse("--provider", "ollama", "--model", "qwen3:8b"))
      expect(backend.context.model).to eq("qwen3:8b")
      expect(backend.summarizer_model).to eq(Lain::Provider::Ollama::DEFAULT_MODEL)
    end

    it "coerces the token ceiling to an Integer, and defaults it to the oracle's" do
      expect(parse[:summarizer_max_tokens]).to eq(Lain::Oracle::Model::DEFAULT_MAX_TOKENS)
      expect(parse("--summarizer-max-tokens", "256")[:summarizer_max_tokens]).to eq(256)
      expect(Lain::CLI::Backend.new(parse("--summarizer-max-tokens", "256")).summarizer_max_tokens).to eq(256)
    end

    it "refuses an unknown summarizer provider by the flag's own name" do
      expect { Lain::CLI::Backend.new(parse("--summarizer-provider", "notreal")) }
        .to raise_error(Lain::CLI::UnknownProvider, /unknown summarizer provider "notreal"/)
    end

    it "refuses a non-positive ceiling at construction, not at the first summary" do
      expect { Lain::CLI::Backend.new(parse("--summarizer-max-tokens", "0")) }
        .to raise_error(Lain::CLI::Backend::InvalidCeiling, /must be positive/)
    end
  end
end
