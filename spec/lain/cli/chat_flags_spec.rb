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
  # `up`'s three arrived when {Lain::CLI::Up.from_options} took the flag ->
  # contract translation off the exe, the same shape consolidate/improve
  # already used -- so the reads moved from a file this glob CANNOT see into
  # one it can. That is a net gain in coverage, not a loss: `up`'s flags now
  # get the read-implies-declared direction they never had, which is what the
  # "backs each allowlisted key" example below actually checks.
  #
  # `nvim` is deliberately absent -- `chat` declares it too, so it resolves
  # through `declared` with no claim needed here.
  #
  # `no_nvim` USED to be here and is gone with the flag: `up`'s `--nvim` is a
  # boolean now, so `--no-nvim` is Thor's own negation of it rather than a
  # separately declared key `up` reads. `nvim_socket` is what replaced its
  # value form, and it is `up`'s alone -- `chat --nvim SOCKET` still spells the
  # same thing with the flag it always had.
  ELSEWHERE = { dry_run: %w[consolidate improve], session: %w[up watch],
                socket: %w[up], nvim_socket: %w[up] }.freeze

  # Option reads whose key is not a literal, pinned with their reason. A
  # dynamic read is a hole in this guard -- the key cannot be resolved from the
  # source, so an undeclared flag could hide behind one -- and the point of
  # pinning the known site is that a NEW hole fails this spec rather than
  # quietly widening the blind spot.
  DYNAMIC = {
    "lib/lain/cli/backend.rb" =>
      "the %i[temperature seed num_batch num_ctx] sampler set, read by key so one loop covers all four; " \
      "every one of them is declared on chat"
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
    # TWO DIFFERENT CLAIMS, and the example this replaces conflated them into
    # one that asserted a broken shape.
    #
    # What the CLI must produce for an unset flag is **nil**. A Thor `default:`
    # materializes the key, so the reader can never see "no strategy was named"
    # and {Lain::CLI::Backend::SpanSummarizer}'s whole opt-in branch becomes
    # unreachable from the executable -- the arm always on, the control arm
    # (the eager tool-result tier) selectable by nobody. That is F7's pattern
    # inverted: not "declared and read by nobody" but "declared with a default
    # that hides its off-state", which this file's read-but-undeclared guard
    # cannot see.
    it "parses to nil when unset, so the reader can tell that no strategy was named" do
      expect(parse.key?(:compact_strategy)).to be(false)
      expect(parse[:compact_strategy]).to be_nil
    end

    # And separately: DEFAULT is what an explicit, empty RESOLUTION falls
    # through to. That is the resolver's own question and the constant is its
    # answer -- the flag never restates it.
    it "leaves DEFAULT as the resolver's fallback, not the executable's" do
      expect(Lain::CLI::CompactionStrategy.new(nil).send(:strategy_name))
        .to eq(Lain::CLI::CompactionStrategy::DEFAULT)
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

    # Same shape --isolation and --compact-strategy already have: pin the help
    # text to the AUTHORITY rather than to a sentence someone has to remember to
    # update.
    it "names every provider the summarizer tier accepts in its help text" do
      help = LainCLI.commands.fetch("chat").options.fetch(:summarizer_provider).description
      expect(help).to include(*Lain::CLI::Backend::PROVIDERS)
    end

    # `--summarizer-model`'s help had no such guard, and drifted into asserting
    # the OPPOSITE of the code ("never the chat's --model") with nothing failing
    # -- the help text is the only description of this rule most operators ever
    # read. There is no constant to pin a branch to, so the assertion is the
    # agreement itself: resolve BOTH branches from a real Backend, then require
    # the text to describe what they did and to not deny it.
    it "keeps the summarizer-model help text agreeing with what the code resolves" do
      help = LainCLI.commands.fetch("chat").options.fetch(:summarizer_model).description
      shared = Lain::CLI::Backend.new(parse("--provider", "ollama", "--model", "qwen3-coder:30b"))
      crossed = Lain::CLI::Backend.new(parse("--provider", "ollama", "--summarizer-provider", "anthropic"))

      expect(shared.summarizer_model).to eq(shared.context.model)
      expect(crossed.summarizer_model).to eq(Lain::Provider::Anthropic::DEFAULT_MODEL)
      expect(help).to include("chat's --model")
      expect(help).not_to include("never the chat's --model")
      expect(help).to include("summarizer provider's own default")
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

    # One GPU holds one resident model. An unpinned summarizer falls to the
    # local tier's own default and EVICTS the chat model on every compaction,
    # then the next turn reloads it: 84.0s against 7.5s, measured. Sharing the
    # provider is what makes the chat's model the cheap answer, so it is the
    # default when the two tiers name the same one.
    it "lets the chat's --model name the summarizer's when both tiers share a provider" do
      backend = Lain::CLI::Backend.new(parse("--provider", "ollama", "--model", "qwen3-coder:30b"))
      expect(backend.context.model).to eq("qwen3-coder:30b")
      expect(backend.summarizer_model).to eq("qwen3-coder:30b")
    end

    # The half of the old "never lets the chat's --model name the summarizer's"
    # that still holds, and the reason the rule is narrow: a model id is not
    # portable across providers, so inheriting one over a provider boundary
    # would name a model the summarizer's backend has never heard of.
    it "never lets the chat's --model name a summarizer on a different provider" do
      backend = Lain::CLI::Backend.new(parse("--provider", "ollama", "--model", "qwen3:8b",
                                             "--summarizer-provider", "anthropic"))
      expect(backend.context.model).to eq("qwen3:8b")
      expect(backend.summarizer_model).to eq(Lain::Provider::Anthropic::DEFAULT_MODEL)
    end

    it "keeps an explicit --summarizer-model above the inherited chat model" do
      backend = Lain::CLI::Backend.new(parse("--provider", "ollama", "--model", "qwen3-coder:30b",
                                             "--summarizer-model", "gemma3:12b"))
      expect(backend.context.model).to eq("qwen3-coder:30b")
      expect(backend.summarizer_model).to eq("gemma3:12b")
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

  # T11. The sampler set is read DYNAMICALLY (see DYNAMIC above), so this
  # file's read-implies-declared guard is blind to these two by construction --
  # it can only see literal keys. That blind spot is exactly why the wiring
  # needs an assertion of its own: without these declarations `--num-batch` is
  # a Thor parse error and no operator can reach the knob, while every unit
  # spec that hand-builds an option Hash stays green.
  describe "the throughput sampler flags" do
    it "declares --num-batch and --num-ctx on chat" do
      expect(declared).to include(:num_batch, :num_ctx)
    end

    # The property, which is about what the default RESOLVES TO and not about
    # whether one is declared: an unset flag must parse to nil.
    # {Backend#sampler_extra} keeps a key only when its value is non-nil, so nil
    # is what keeps `options` off a request nobody tuned. Both flags do declare
    # a `default:`, reading the environment through {Lain::CLI::EnvDefaults},
    # which answers nil for an unset variable -- exactly that absence. A LITERAL
    # default would materialize the key instead and put `options` on every
    # ollama request, the shape backend_spec pins as absent; this example is
    # what fails if one is ever added.
    it "parses to nil when unset, so an unset knob emits no option at all" do
      expect(parse[:num_batch]).to be_nil
      expect(parse[:num_ctx]).to be_nil
    end

    it "carries operator-set values through as numbers" do
      expect(parse("--num-batch", "2048")[:num_batch]).to eq(2048)
      expect(parse("--num-ctx", "8192")[:num_ctx]).to eq(8192)
    end
  end

  # S4. EVERY other spec in this repo builds Backend and Wiring from a plain
  # option Hash that simply omits the keys it does not care about -- including
  # the A8 shareability regression at `wiring_spec.rb:397-403`. That is the
  # exact blind spot this file's header describes from the other direction: a
  # hand-built Hash cannot reproduce what Thor MATERIALIZES, so a flag whose
  # declared default changes the run is invisible to all of them.
  #
  # These build the compaction wiring from the executable's OWN parsed options
  # and then take a real turn through it. Both of the defects this group was
  # written after would have failed here and nowhere else: a `default:` on
  # `--compact-strategy` (which made the control arm unselectable), and a
  # summarizer transport error escaping as a bare Faraday class (which killed
  # the turn rather than the span).
  describe "a turn taken through the executable's own parsed options" do
    let(:journal) { RecordingChannel.new }
    let(:session) { instance_double(Lain::Session, plan_step_completed?: false, pinned?: false) }

    let(:surface) { RecordingChannel.new }

    # The run's real sink shape: {Sink::IOAdapter} over a Channel, which is what
    # {CLI::CompactionMount} builds and the only route from `lib/` to a
    # frontend. Passing `Sink::Null` here would leave this group proving the
    # turn survives while proving nothing about the operator being told, which
    # is the whole of the sink's justification.
    def sink = Lain::Sink::IOAdapter.new(surface, tool_use_id: "lain:compaction", stream: :stderr)

    def source_from(*argv, **overrides)
      Lain::CLI::Backend.new(parse(*argv).merge(overrides))
                        .pipeline_source(cache_profile: Lain::CacheProfile::NO_CACHING, journal:, sink:)
    end

    def reported = surface.events.grep(Lain::Telemetry::ToolOutput)

    def collapse_policy(source)
      source.instance_variable_get(:@derived).instance_variable_get(:@strategy)
    end

    # A well-formed conversation, big enough to cross a lowered threshold.
    def history(size)
      (1..size).inject(Lain::Timeline.empty(store: Lain::Store.new)) do |line, index|
        line.commit(role: index.odd? && index > 1 ? "assistant" : "user",
                    content: [{ "type" => "text", "text" => "turn #{index}: #{"the quick brown fox. " * 40}" }])
      end
    end

    def decisions = journal.events.grep(Lain::Compaction::Source::CompactionDecision)

    it "leaves an un-flagged run on the eager tier, the arm every comparison is measured against" do
      expect(collapse_policy(source_from)).to be_nil
    end

    it "puts a flagged run on the strategy the flag names" do
      expect(collapse_policy(source_from("--compact-strategy", "elide")))
        .to be_a(Lain::Compaction::Strategy::Elide)
    end

    # B2, end to end and through the DEFAULT summarizer provider, which is the
    # one whose transport errors leaked. Nothing is listening on the ollama port
    # under WebMock, so the tier really is down -- and a down summarizer must
    # cost the SPAN, never the turn.
    #
    # THREE HALVES, and each of them lives somewhere else: the provider contains
    # the transport error (`ollama_spec`), the strategy declines the range and
    # reports it (`summarizing_spec:183`), the mount routes the report to a
    # channel (`compaction_mount_spec`). Nothing joined them, and each passes
    # while the next is broken. This is the join.
    it "renders the turn when the summarizer is unreachable, and TELLS the operator", :webmock do
      stub_request(:post, %r{/api/chat}).to_raise(Faraday::ConnectionFailed)
      source = source_from("--compact-strategy", "summarizing", compact_bytes: 100, compact_cap: 100,
                                                                compact_keep: 2)
      base = Lain::CLI::Backend.new(parse).context
      line = history(6)

      expect { source.context_for(base:, timeline: line, usage: nil, session:) }.not_to raise_error
      expect(decisions.last.compacted).to be(false)
      expect(reported.map(&:bytes).join).to include("Summarizing leaves", "uncollapsed")
      expect(reported.map(&:tool_use_id).uniq).to eq(["lain:compaction"])
    end
  end
end
