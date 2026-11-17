# frozen_string_literal: true

require "async"
require "json"
require "openssl"
require "rubygems/package"
require "stringio"
require "tmpdir"

# Stands in for the eager tier's local model (production wires an Ollama-backed
# {Lain::Oracle::Model}), answering the REAL {Lain::Oracle::Summarize}
# definition so the schema, the Promise, and `#summary` are the production ones
# -- only the network edge is stubbed, exactly as {Lain::Provider::Mock} stubs
# the chat provider.
class WiringSpecSummarizer
  def initialize(text)
    @definition = Lain::Oracle::Summarize.definition
    @text = text
  end

  def ask(_inputs = {}) = @definition.answer("summary" => @text)
end

# The launch block's stand-in for an adopted actor: it builds the child's
# Session from the LEASED WorkerEnv exactly as
# {Lain::Tools::Subagent::ChildBuilder#spawn_agent} does, so what a spec reads
# back is the object the real spawn path constructs.
#
# It answers the LIFECYCLE predicates as well as `#stop`, because that is what
# the actor duck is: {Lain::Supervisor::Registration#state} derives every row's
# state from `stopped?`/`dead?`, and {Lain::Supervisor#stop} reads it on the way
# out to tell a crashed row (surrendered) from a live one (released). A stand-in
# that answered only `#stop` kept passing while that contract widened under it,
# which is precisely how the widening went unnoticed -- so these are honest
# rather than hard-coded: this worker is alive until it is stopped, and never
# crashes.
class WiringSpecWorker
  attr_reader :session, :checkout

  # `checkout` is snapshotted HERE, inside the launch block, while the lease is
  # still live: {Lain::Supervisor#stop} releases it and a worktree release
  # removes the tree, so a spec that looked afterwards could only ever do string
  # math over `#cwd` -- which passes whether or not a checkout was ever created.
  def initialize(worker_env)
    @session = Lain::Session.new(worker_env:)
    @checkout = { exists: Dir.exist?(worker_env.cwd),
                  repo: File.exist?(worker_env.resolve(".git")),
                  seeded: File.exist?(worker_env.resolve("README")) }
    @stopped = false
  end

  def stop
    @stopped = true
    self
  end

  def stopped? = @stopped

  # No fiber to fail, so the only way this worker is dead is by being stopped --
  # {Lain::Tools::Subagent::Actor}'s own distinction, and it keeps every row here
  # out of the crashed branch.
  def dead? = @stopped
end

# An actor that CRASHED after committing in its leased checkout: dead from the
# moment it launched, stopped only when the supervisor farewells it. The commit
# is made inside the launch block, while the lease is live, because that is the
# work a reap has to save.
class WiringSpecCrashedWorker
  attr_reader :commit

  def initialize(worker_env)
    @worker_env = worker_env
    dir = worker_env.cwd
    File.write(File.join(dir, "crashed.txt"), "work a crash left behind\n")
    git(dir, "add", "-A")
    git(dir, "commit", "-q", "-m", "crashed work")
    @commit = git(dir, "rev-parse", "HEAD")
    @stopped = false
  end

  # Where it stands, which the supervisor checks against its lease.
  def session = Lain::Session.new(worker_env: @worker_env)

  def stop
    @stopped = true
    self
  end

  def stopped? = @stopped

  def dead? = true

  private

  def git(dir, *) = SeedRepo.git(dir, *).stdout.strip
end

# Counts the calls to `#start` and is otherwise the chronicle it wraps. The
# refusal group below needs an ORDERING claim -- that a config refusal lands
# before the session record is opened -- and `#start` is the moment that record
# exists: it builds the {Lain::SessionRecord::Scribe}, whose constructor writes
# the header. So "start was never called" is exactly "no orphan header on
# disk", asserted without parsing journal bytes.
class WiringSpecStartSpy < SimpleDelegator
  attr_reader :starts

  def initialize(inner)
    super
    @starts = 0
  end

  def start(**)
    @starts += 1
    super
  end
end

# The two members {Lain::CLI::Wiring#run_state} reads off a resume result. A
# Data rather than a double because what is asserted is identity -- the
# recorder that comes back IS the one resumed -- and a double answering a fresh
# object on each call could not show that.
WiringSpecResumed = Data.define(:recorder, :session)

# A tool middleware a config.rb could register: Base's pass-through.
class WiringSpecToolStamp < Lain::Middleware::Base; end

# A model middleware a config.rb could register; it keeps what came back.
class WiringSpecModelStamp < Lain::Middleware::Base
  SEEN = Queue.new

  def call(env, &)
    downstream(env, &).tap { |out| SEEN << out[:response] }
  end
end

# A model middleware that keeps which instance ran, to tell the chat's from a child's.
class WiringSpecInstanceStamp < Lain::Middleware::Base
  SEEN = Queue.new

  def call(env, &block)
    SEEN << self
    downstream(env, &block)
  end
end

# A turn middleware a config.rb could register: Base's pass-through settle.
class WiringSpecTurnStamp < Lain::Middleware::Base; end

# Records what the backend was asked for a provider WITH, because
# {Lain::CLI::Wiring}'s `#spooled_provider` has as its whole content the pair
# of keywords it passes -- the spool tee and the channel -- and the object that
# comes back is the same mock either way. Only the network edge is faked; the
# rest is the real {Lain::CLI::Backend} the exe builds.
class WiringAgentSpecBackend < Lain::CLI::Backend
  attr_reader :provider_calls

  def initialize(options, mock:, root: Dir.pwd)
    super(options, root:)
    @mock = mock
    @provider_calls = []
  end

  def provider(**kwargs)
    @provider_calls << kwargs
    @mock
  end

  # Wrapped IN PLACE OF {Lain::CLI::Backend}'s own memo, deliberately: `super`
  # fills `@context_window` with the real book, and this assignment then
  # replaces it with the counting wrapper -- so there is one object, and it is
  # the one the wiring hands the Agent. Counting on a second book built to
  # observe would answer a question nobody is asking.
  def context_window = @context_window ||= WiringAgentSpecWindow.new(super)
end

# Counts the re-resolutions the turn stack triggers and delegates the three
# reader messages, so "the trigger fired on the run's own book" is a property
# an example can see. A real {Lain::CLI::Backend::WindowBook::Live} answers the
# same duck and would count nothing.
class WiringAgentSpecWindow
  attr_reader :refreshes, :trail

  # `trail` is SHARED with the chronicle's turn member in the ordering example
  # below, because a list of classes says what the stack holds and not what ran
  # first -- and it is the running order three docstrings call load-bearing.
  def initialize(book, trail = [])
    @book = book
    @refreshes = 0
    @trail = trail
  end

  def reresolve
    @refreshes += 1
    @trail << :window
    @book.reresolve
  end

  def resolve(model) = @book.resolve(model)
  def window_tokens(model) = @book.window_tokens(model)
  def occupancy(used_tokens, model:) = @book.occupancy(used_tokens, model:)
end

# Captures the timeline handle the agent build hands the chronicle so an example
# can call it back AFTER the Agent exists. That is the only way to see whether
# the closure caught a live binding or a permanent nil -- the defect
# `wiring.rb` documents at its own `@agent = build_agent(...)` line.
class WiringAgentSpecChronicle < Lain::CLI::Chronicle::Null
  attr_reader :timeline_handle

  # The record journal a live chat writes its `capability_degraded` records to.
  # Defaulted to the Null's own /dev/null one, so every group that does not read
  # bytes back behaves exactly as it did before the keyword existed.
  def initialize(record_journal = nil)
    @record_journal = record_journal
    super()
  end

  def record_journal = @record_journal || super

  def turn_middleware(timeline)
    @timeline_handle = timeline
    super
  end

  # MEMOIZED where the Null answers a fresh spool per call, so "the provider
  # was teed into THE chronicle's spool" is an identity an example can assert
  # at all. Against the unmemoized one every comparison is between two distinct
  # Nulls and passes for the wrong reason -- or fails for it.
  def spool = @spool ||= super
end

# A chronicle whose turn phase is NOT empty.
#
# Written because the ordering assertions against the Null chronicle CANNOT
# FAIL: its `turn_middleware` is an empty Stack, so `[ResolveWindow, *[]]` and
# `[*[], ResolveWindow]` are the same list, and a mutant moving the refresh to
# the innermost position survived the entire suite. Benign today -- JournalTurns
# runs its work after `downstream` and reads no window -- but the ordering is
# stated as load-bearing in three docstrings, and a documented claim that
# nothing holds is the shape this chunk keeps producing.
class WiringAgentSpecJournallingChronicle < WiringAgentSpecChronicle
  # Named so the ordering reads as a list of classes, and RECORDING so the same
  # example can pin what actually ran first.
  class Member < Lain::Middleware::Base
    def initialize(trail)
      @trail = trail
      super()
    end

    def call(env, &app)
      @trail << :chronicle
      downstream(env, &app)
    end
  end

  def initialize(trail)
    @trail = trail
    super()
  end

  def turn_middleware(_timeline) = Lain::Middleware::Stack.new([Member.new(@trail)])
end

# The Switchboard's side of the seam, recorded. A stand-in rather than the real
# board because the point of the seam is that the agent build is HANDED one:
# what an example needs to see is which object the Agent was built over, and
# that {Lain::CLI::Wiring}'s `#agent_over` never went looking for one of its own.
class WiringAgentSpecBoard
  attr_reader :toolset, :grafted, :ledger, :approvals, :sensitivity, :snapshots, :policy_switch

  # A real board writes under `:shadow_git`; the stand-in
  # answers the write-set scope so building an Agent over it shells no git.
  def snapshot_scope = :write_set

  def secrets = Lain::Sensitivity::Secrets::Source::DEFAULT

  def bind_snapshots(slot)
    @snapshots = slot
  end

  # The session a flip into plan scope confines.
  attr_reader :session

  def bind_session(session)
    @session = session
    self
  end

  # The run's ONE region ledger, the approval queue an unattended board leaves
  # nil, and the path policy -- all real, because the three tool-phase guards
  # take them as required keywords with no default and a double answering nil
  # for any of them would test a construction production cannot reach.
  #
  # `sensitivity` joined that list when {CLI::ToolGuard} started
  # reading the listing filter off the board's policy instead of passing a
  # Null. It is the slot a real {CLI::Switchboard} has always had; this
  # stand-in simply had no reason to answer it until something asked.
  def initialize(toolset, approvals: nil)
    @toolset = toolset
    @grafted = []
    @policy_switch = Lain::Middleware::Gate::ApproveAll.new
    @ledger = Lain::Sensitivity::Ledger.new
    @approvals = approvals
    @sensitivity = Lain::Sensitivity::Policy.new(
      sensitivity: Lain::Sensitivity.new(home: "/home/tester", cwd: "/home/tester/project")
    )
  end

  # The one value the tool stack is built over, as a real board holds it: these
  # same slots, a test layout run declaring none, and a gate policy approving
  # every call, which an example can tell apart from any other by identity.
  def guard_inputs
    @guard_inputs ||= Lain::CLI::ToolGuard::Inputs.new(
      ledger:, approvals:, sensitivity:, test_layout: Lain::Middleware::GuardTestLayout::Run.undeclared,
      policy: policy_switch, policy_for: ->(_worker_env) { policy_switch }, denial: Lain::Middleware::Gate::DENIAL,
      bar: Lain::Middleware::WithholdAutomaticOutput::Bar.new
    )
  end

  def live_display = Lain::Sensitivity::Display::NULL

  def graft(context)
    @grafted << context
    context
  end
end

RSpec.describe Lain::CLI::Wiring do
  # Provider resolution, context, slots, and spawn policies stay the real
  # Backend's; only the network edge swaps for Provider::Mock, so the whole
  # chat assembly is exercised offline exactly as the exe wires it (the
  # extracted Repl is constructible without the exe).
  let(:offline_backend_class) do
    Class.new(Lain::CLI::Backend) do
      def initialize(options, mock:, root: Dir.pwd, **)
        super(options, root:, **)
        @mock = mock
      end

      def provider(**) = @mock
    end
  end

  # What the default Context asks of a provider, read off a Context rather than
  # a snapshot: the answer belongs to the pipeline in effect.
  let(:default_requires) { Lain::Context.new(model: "any", max_tokens: 1).requires }

  let(:mock_provider) do
    Lain::Provider::Mock.new(responses: [
                               Lain::Response.new(content: [{ "type" => "text", "text" => "settled" }],
                                                  stop_reason: :end_turn)
                             ])
  end
  let(:backend_root) { project_dir }
  let(:backend) do
    offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: mock_provider,
                                                                                  root: backend_root)
  end
  # A provider that answers BOTH questions the occupancy pin below needs of
  # one: what window it is serving (`Provider#context_window_tokens`, which the
  # base class answers nil for) and a turn whose usage gives `#occupancy` a
  # numerator.
  # 7,079 tokens is the POC's own figure -- 21.6% of a served 32,768 and 86.4%
  # of the conservative fallback, so the two candidate denominators cannot be
  # confused for one another.
  let(:serving_provider) do
    Class.new(Lain::Provider::Mock) do
      def context_window_tokens(_model) = 32_768
    end.new(responses: [
              Lain::Response.new(content: [{ "type" => "text", "text" => "settled" }], stop_reason: :end_turn,
                                 usage: Lain::Usage.new(input_tokens: 7_079, output_tokens: 1))
            ])
  end
  let(:channel) { Lain::Channel.new }
  let(:chronicle) { Lain::CLI::Chronicle::Null.new }
  # status_feed: is required, not defaulted (the Null placeholder is gone). The
  # direct-Wiring path threads it into the Command::Env's status reader -- and
  # #run hands it the run's Store, which is the ONE line that makes the HUD's
  # inbox_count able to retire anything. Stubbed rather than doubled away
  # so the #run group below can assert that call actually happened.
  let(:status_feed) { instance_double(Lain::StatusFeed, bind_store: nil) }
  let(:wiring) { new_wiring(options: { grace: 5 }, chronicle:, status_feed:) }
  # The default project is the checkout, and a wiring rooted there lists every tracked file to mask it.
  let(:project_dir) { File.realpath(Dir.mktmpdir("lain-wiring-project")) }

  after { FileUtils.rm_rf(project_dir) }

  def null_herdr(tty_factory) = described_class::HerdrBinding::Null.new(tty_factory:)

  def new_wiring(tty_factory: nil, **kwargs)
    herdr = tty_factory ? { herdr: null_herdr(tty_factory) } : {}
    described_class.new(project: throwaway_project(project_dir), **herdr, **kwargs)
  end

  def wire_agent
    recorder, session = wiring.run_state(nil)
    wiring.wire_agent(channel:, recorder:, session:, backend:)
  end

  # A second Wiring in one example needs its own Backend: a Backend's egress
  # literals bind once, to the first board's secrets source.
  def fresh_backend
    offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: mock_provider,
                                                                                  root: backend_root)
  end

  describe "the bench arms" do
    let(:arm_options) { { grace: 5, confine: "reader", judge_facts: "facts", tripwire: "observe" } }
    let(:armed) { new_wiring(options: arm_options, chronicle:, status_feed:) }

    it "answers the parsed flags" do
      expect([armed.arms.confine, armed.arms.judge_facts, armed.arms.tripwire]).to eq(%i[reader facts observe])
    end

    it "refuses a bad value when the wiring is built" do
      expect { new_wiring(options: { confine: "sideways" }, chronicle:, status_feed:) }
        .to raise_error(Lain::CLI::Arms::Unknown, /off, classes, reader/)
    end

    describe "the session header" do
      let(:journal_io) { StringIO.new }
      let(:state_dir) { Dir.mktmpdir("wiring-arms") }
      let(:chronicle) do
        Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io: journal_io),
                                 journal_path: File.join(state_dir, "session.ndjson"))
      end

      after { FileUtils.rm_rf(state_dir) }

      def header_of(wiring)
        recorder, session = wiring.run_state(nil)
        wiring.wire_agent(channel:, recorder:, session:, backend:)
        journal_records(journal_io).find { |r| r["type"] == "session" }
      end

      it "holds the arms that are on" do
        expect(header_of(armed)).to include("arms" => { "confine" => "reader", "judge_facts" => "facts",
                                                        "tripwire" => "observe", "round_budget" => "window",
                                                        "round_dedup" => "on" })
      end

      it "holds the 4 default-on arms when no arm flag is typed" do
        plain = new_wiring(options: { grace: 5 }, chronicle:, status_feed:)

        expect(header_of(plain))
          .to include("arms" => { "confine" => "workspace", "tripwire" => "observe", "round_budget" => "window",
                                  "round_dedup" => "on" })
      end

      describe "its provenance" do
        def provenance_of(wiring) = header_of(wiring).fetch("provenance")

        it "names what produced the run, and where" do
          expect(provenance_of(new_wiring(options: { grace: 5 }, chronicle:, status_feed:)))
            .to include("cwd" => project_dir, "root" => project_dir, "effort" => "unrecorded")
            .and(satisfy { |block| block.keys.sort == %w[cwd effort harness home policy root tool_surface] })
        end

        it "records the run's own toolset digest as its tool surface" do
          wiring = new_wiring(options: { grace: 5 }, chronicle:, status_feed:)
          recorder, session = wiring.run_state(nil)
          agent = wiring.wire_agent(channel:, recorder:, session:, backend:)
          header = journal_records(journal_io).find { |r| r["type"] == "session" }

          expect(header.dig("provenance", "tool_surface")).to eq(agent.toolset.digest)
        end

        def local_ollama_backend(models)
          model = backend.model
          transport = Class.new do
            define_method(:model_details) do |_|
              Struct.new(:body).new({ "details" => { "quantization_level" => "Q4_K_M" } })
            end
            define_method(:tags) { Struct.new(:body).new({ "models" => models.call(model) }) }
            define_method(:process_status) { Struct.new(:body).new({ "models" => [] }) }
          end.new
          offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 },
                                    mock: Lain::Provider::Ollama.new(transport:), root: backend_root)
        end

        def weights_of(models)
          wiring = new_wiring(options: { grace: 5 }, chronicle:, status_feed:)
          recorder, session = wiring.run_state(nil)
          wiring.wire_agent(channel:, recorder:, session:, backend: local_ollama_backend(models))
          journal_records(journal_io).find { |r| r["type"] == "session" }.dig("provenance", "weights")
        end

        it "records the weights of a local ollama run: the pulled digest and the quant" do
          expect(weights_of(->(model) { [{ "model" => model, "digest" => "sha256:abc" }] }))
            .to eq("digest" => "sha256:abc", "quant" => "Q4_K_M")
        end

        it "records a local model the server does not list as unrecorded" do
          expect(weights_of(->(_) { [] })).to eq("digest" => "unrecorded", "quant" => "Q4_K_M")
        end

        it "records no weights for a provider that states none" do
          expect(provenance_of(new_wiring(options: { grace: 5 }, chronicle:, status_feed:))).not_to have_key("weights")
        end

        it "records the running lain's harness" do
          expect(provenance_of(new_wiring(options: { grace: 5 }, chronicle:, status_feed:)).fetch("harness"))
            .to eq(Lain::SessionRecord::Provenance.running_harness)
        end

        it "records the effort the context was launched with" do
          effortful = offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64, effort: "low" },
                                                mock: mock_provider, root: backend_root)
          wiring = new_wiring(options: { grace: 5 }, chronicle:, status_feed:)
          recorder, session = wiring.run_state(nil)
          wiring.wire_agent(channel:, recorder:, session:, backend: effortful)

          expect(journal_records(journal_io).find { |r| r["type"] == "session" }.dig("provenance", "effort"))
            .to eq("low")
        end
      end

      describe "two chats in one project, the second after its config gained a line" do
        def chat_provenance
          io = StringIO.new
          recording = Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io:),
                                               journal_path: File.join(state_dir, "session.ndjson"))
          wiring = new_wiring(options: { grace: 5 }, chronicle: recording, status_feed:)
          recorder, session = wiring.run_state(nil)
          own_backend = offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 },
                                                  mock: mock_provider, root: backend_root)
          wiring.wire_agent(channel:, recorder:, session:, backend: own_backend)
          journal_records(io).find { |r| r["type"] == "session" }.fetch("provenance")
        end

        it "records different policies and the same tool surface" do
          write_config(project_dir, "approval do\nend\n")
          first = chat_provenance
          write_config(project_dir, "approval do\nend\n# a second chat's line\n")
          second = chat_provenance

          expect(second.fetch("policy")).not_to eq(first.fetch("policy"))
          expect(second.fetch("tool_surface")).to eq(first.fetch("tool_surface"))
        end
      end

      it "holds only round_dedup off when every arm is off" do
        off = new_wiring(options: { grace: 5, confine: "off", tripwire: "off", round_budget: "off",
                                    round_dedup: "off" },
                         chronicle:, status_feed:)

        expect(header_of(off)).to include("arms" => { "round_dedup" => "off" })
      end

      context "with configured middleware" do
        let(:backend) do
          middleware = Lain::Config::Middleware.new(tool: [Lain::Config::Middleware::Registration.new(
            factory: WiringSpecToolStamp, args: [], kwargs: {}, block: nil, at: "/spec/config.rb:1"
          )]).trusted_by("project", "d1")
          offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: mock_provider,
                                                                                        root: backend_root, middleware:)
        end

        it "holds whose trust admitted it" do
          plain = new_wiring(options: { grace: 5 }, chronicle:, status_feed:)

          expect(header_of(plain)).to include("middleware" => { "project" => "d1" })
        end
      end
    end

    it "hands the toolset build and the board build the same instance" do
      seen = []
      allow(Lain::CLI::Wiring::ToolsetBuild).to receive(:new).and_wrap_original do |original, **kwargs|
        seen << kwargs[:arms]
        original.call(**kwargs)
      end
      allow(Lain::CLI::Wiring::BoardBuild).to receive(:for).and_wrap_original do |original, **kwargs|
        seen << kwargs[:arms]
        original.call(**kwargs)
      end
      recorder, session = armed.run_state(nil)
      armed.wire_agent(channel:, recorder:, session:, backend:)

      expect(seen).to match([armed.arms, armed.arms]).and(satisfy { |pair| pair.first.equal?(pair.last) })
    end

    it "builds the board with the backend's model without building a Context for it" do
      contexts_built = nil
      allow(backend).to receive(:context).and_wrap_original do |original, **kwargs|
        contexts_built += 1 if contexts_built
        original.call(**kwargs)
      end
      allow(Lain::CLI::Wiring::JudgeSource).to receive(:for).and_wrap_original do |original, *args, **kwargs|
        contexts_built = 0
        original.call(*args, **kwargs)
      end
      seen = nil
      allow(Lain::CLI::Wiring::BoardBuild).to receive(:for).and_wrap_original do |original, **kwargs|
        seen = [contexts_built, kwargs[:model]]
        original.call(**kwargs)
      end

      wire_agent

      expect(seen).to eq([0, backend.model])
    end

    # The board reads what the Repl hears, so both must hold the one Heard, and a
    # --prompt seed must reach it through the run's own path.
    it "hands the board and the Repl one Heard, which hears the --prompt seed", :seam do
      requests = []
      heards = []
      allow(Lain::CLI::Wiring::BoardBuild).to receive(:for).and_wrap_original do |original, **kwargs|
        requests << kwargs[:request]
        original.call(**kwargs)
      end
      allow(Lain::CLI::Repl).to receive(:new).and_wrap_original do |original, **kwargs|
        heards << kwargs[:heard]
        original.call(**kwargs)
      end

      Dir.mktmpdir("wiring-heard") do |dir|
        options = { grace: 5, approval: "auto", judge_facts: "request", prompt: "summarize the README",
                    non_interactive: true }
        terminal = lambda do |channel:, **|
          Lain::Frontend::TTY.new(channel:, output: StringIO.new, history_path: File.join(dir, "history"))
        end
        wiring = new_wiring(options:, chronicle:, status_feed:, stdin: StringIO.new, tty_factory: terminal,
                            paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => dir, "HOME" => dir }))
        Timeout.timeout(20) { wiring.run(backend:, resumed: nil, nvim: nil) }
        wiring.conductor.close(reason: :exit)
      end

      expect(requests.sole).to equal(heards.sole)
      expect(requests.sole.call(Lain::Session.new)&.text).to eq("summarize the README")
    end

    # The mask list classifies against the board's policy, so a prime started before the board
    # exists would hand the first bash call a NoMethodError.
    it "primes the sandbox's mask list only once the board exists" do
      Dir.mktmpdir("lain-wiring-prime") do |dir|
        root = File.realpath(dir)
        env = { "XDG_STATE_HOME" => File.join(root, "s"), "HOME" => File.join(root, "h") }
        reader = described_class.new(options: { grace: 5, approval: "auto", confine: "reader" }, chronicle:,
                                     status_feed:, paths: Lain::Paths.new(env:), project: throwaway_project(root))
        board_existed = []
        allow(Lain::Confine::MaskList).to receive(:new).and_wrap_original do |original, **kwargs|
          original.call(**kwargs).tap do |list|
            allow(list).to receive(:prime) do
              board_existed << !reader.instance_variable_get(:@switchboard).nil?
              list
            end
          end
        end
        recorder, session = reader.run_state(nil)

        reader.wire_agent(channel:, recorder:, session:, backend:)

        expect(board_existed).to eq([true])
      end
    end

    it "reads trust and every project setting through its own Paths, never the environment's" do
      Dir.mktmpdir("lain-wiring-injected") do |dir|
        base = File.realpath(dir)
        root = File.join(base, "repo").tap { |path| FileUtils.mkdir_p(path) }
        elsewhere = File.join(base, "elsewhere").tap { |path| FileUtils.mkdir_p(path) }
        paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(base, "s"), "HOME" => File.join(base, "h"),
                                       "XDG_CONFIG_HOME" => File.join(base, "c") })
        write_config(root, "sensitivity denied: %w[*.secret]\nshell exclude: %w[curl]\napproval timeout: 900\n" \
                           "review model: \"claude-sonnet-5-5\"\nbudget iterations: { default: 7 }\n" \
                           "search include: [\"notes/**/*.md\"]\ntests preset: :rspec\n", paths:)
        wiring = described_class.new(options: { grace: 5, approval: "auto" }, chronicle:, status_feed:, paths:,
                                     project: throwaway_project(root))
        recorder, session = wiring.run_state(nil)

        with_env("HOME" => elsewhere, "XDG_STATE_HOME" => elsewhere, "XDG_CONFIG_HOME" => elsewhere) do
          wiring.wire_agent(channel:, recorder:, session:, backend:)
        end

        expect(Dir.children(elsewhere)).to eq([])
      end
    end

    # A root apart from HOME, since a root holding HOME confines nothing and
    # the rule would abstain for that reason instead.
    describe "under --confine classes" do
      let(:classed) do
        described_class.new(options: { grace: 5, approval: "auto", confine: "classes" }, chronicle:, status_feed:,
                            paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => @state, "HOME" => @home }),
                            project: throwaway_project(@root))
      end
      let(:backend_root) { @root }

      around do |example|
        Dir.mktmpdir("lain-wiring-classes") do |dir|
          base = File.realpath(dir)
          @root = File.join(base, "repo")
          @home = File.join(base, "home")
          @state = File.join(base, "state")
          FileUtils.mkdir_p([@root, @home, @state])
          File.write(File.join(@root, "README.md"), "# A project\n")
          example.run
        end
      end

      # The session env is a snapshot of ENV taken when the board is built.
      def board_on_path(path, wiring = classed)
        was = ENV.fetch("PATH")
        ENV["PATH"] = path
        recorder, session = wiring.run_state(nil)
        wiring.wire_agent(channel:, recorder:, session:, backend:)
        wiring.instance_variable_get(:@switchboard)
      ensure
        ENV["PATH"] = was
      end

      def bash_of(command)
        Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input: { "command" => command, "cwd" => @root })
      end

      it "allows a system cat, and the reason names the file that runs" do
        ruling = board_on_path("/usr/bin").policy_switch.rule(bash_of("cat README.md"), nil)

        expect(ruling).to have_attributes(verdict: :allow, rule: "composed_term")
        expect(ruling.reason).to include("/usr/bin/cat")
      end

      it "hands the ladder the resolver the bash tool holds" do
        board = board_on_path("/usr/bin")
        rule = board.ladder.to_a[1].instance_variable_get(:@rules).last
        from_ladder = rule.instance_variable_get(:@sensitivity).instance_variable_get(:@resolver)

        expect(board.toolset.fetch("bash").instance_variable_get(:@resolver)).to equal(from_ladder)
      end

      describe "the exec backend the launch builds once" do
        it "hands the bash tool the backend its ExecBackend built, and the ladder a resolver over the root" do
          board = board_on_path("/usr/bin")
          held = classed.send(:exec_backend)

          expect(board.toolset.fetch("bash").instance_variable_get(:@exec)).to equal(held.backend)
          expect(board.toolset.fetch("bash").instance_variable_get(:@resolver))
            .to be_a(Lain::Shell::Executable::Resolver)
        end

        it "hands the board's guard inputs the child env the backend holds" do
          board = board_on_path("/usr/bin")

          expect(board.guard_inputs.secrets.child_env).to equal(classed.send(:exec_backend).child_env)
        end

        it "memoizes the ExecBackend" do
          expect(classed.send(:exec_backend)).to equal(classed.send(:exec_backend))
        end

        it "passes the host's value of an env pass name to a bash child, end to end through the build" do
          stdout = with_env("HOME" => @home, "XDG_STATE_HOME" => @state, "LAIN_T1_PASSED" => "from-host") do
            write_config(@root, "env pass: %w[LAIN_T1_PASSED]\n")
            exec = board_on_path("/usr/bin").toolset.fetch("bash").instance_variable_get(:@exec)
            exec.call(command: "printenv LAIN_T1_PASSED", cwd: @root, env: ENV.to_h, timeout: 10).stdout
          end

          expect(stdout).to eq("from-host\n")
        end
      end

      context "with --exec docker" do
        let(:docked) do
          described_class.new(options: { grace: 5, approval: "auto", confine: "classes", exec: "docker" },
                              chronicle:, status_feed:, project: throwaway_project(@root),
                              paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => @state, "HOME" => @home }))
        end

        let(:image_id) { "d529dd0c6e5597ac7e4a3e2dea65c3fcc6173f4cae713c409265c1dd9914a11b" }

        def image_tar
          File.join(@home, "image.tar").tap do |tar|
            File.binwrite(tar, StringIO.new(+"", "w+b").tap do |io|
              Gem::Package::TarWriter.new(io) do |w|
                w.mkdir("bin/", 0o755)
                w.add_file_simple("bin/busybox", 0o755, 0) { nil }
                %w[cat uname].each { w.add_symlink("bin/#{_1}", "/bin/busybox", 0o777) }
              end
            end.string)
          end
        end

        # A stand-in client serving a small image, so the launch probe passes on a box with no docker.
        def client_dir
          File.join(@home, "client").tap do |dir|
            FileUtils.mkdir_p(dir)
            File.write(File.join(dir, "docker"), <<~SH)
              #!/bin/sh
              case "$1" in
                image) printf '%s\n["PATH=/bin"]\nnull\n' #{image_id} ;;
                export) cp #{image_tar} "$3" ;;
              esac
            SH
            File.chmod(0o755, File.join(dir, "docker"))
          end
        end

        def docked_on_path(wiring = docked)
          path = "#{client_dir}:/usr/bin"
          with_env("PATH" => path) { yield board_on_path(path, wiring) }
        end

        def stage_of(board, *argv)
          worker_env = Lain::WorkerEnv.new(cwd: @root, env: { "PATH" => "/usr/bin" })
          board.toolset.fetch("bash").instance_variable_get(:@resolver).for(worker_env)
               .call(Lain::Shell::Term.of(argv)).sole
        end

        it "resolves cat to the image's file, class system" do
          stage = docked_on_path { stage_of(_1, "cat", "README.md") }

          expect(stage.to_journal).to include("klass" => "system", "anomalies" => [], "resolved" => "/bin/cat")
        end

        it "resolves a project script on the host, class project" do
          FileUtils.mkdir_p(File.join(@root, "bin"))
          File.write(File.join(@root, "bin", "check"), "#!/bin/sh\n")
          File.chmod(0o755, File.join(@root, "bin", "check"))

          stage = docked_on_path { stage_of(_1, "bin/check") }

          expect(stage.to_journal).to include("klass" => "project", "resolved" => File.join(@root, "bin", "check"))
        end

        it "approves cat README.md in the rules rung, naming the image's file" do
          ruling = docked_on_path { _1.policy_switch.rule(bash_of("cat README.md"), nil) }

          expect(ruling).to have_attributes(verdict: :allow, rule: "composed_term")
          expect(ruling.reason).to include("/bin/cat")
        end

        it "applies a judge approve of an image program under --judge-facts facts, parking nothing" do
          approving = Lain::Provider::Mock.new(responses: [text_response("approve")])
          allow(Lain::CLI::Wiring::BoardBuild).to receive(:for).and_wrap_original do |original, **kwargs|
            original.call(**kwargs, judge: Lain::Approval::Judge.new(provider: approving, model: "m",
                                                                     slots: Lain::Prompt::Slots.new(fills: {})))
          end
          judged = described_class.new(options: { grace: 5, approval: "auto", confine: "off", exec: "docker",
                                                  judge_facts: "facts" },
                                       chronicle:, status_feed:, project: throwaway_project(@root),
                                       paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => @state, "HOME" => @home }))

          board, ruling, stage = docked_on_path(judged) do |built|
            ruled = Sync { |task| task.with_timeout(5) { built.policy_switch.rule(bash_of("uname -a"), nil) } }
            [built, ruled, stage_of(built, "uname", "-a")]
          end

          expect(stage.to_journal).to include("klass" => "system", "anomalies" => [], "resolved" => "/bin/uname")
          expect([ruling.verdict, ruling.rung]).to eq([:allow, "auto"])
          expect(board.approvals.to_a).to be_empty
        end

        it "keeps a git log from the judge, since the sandbox never wraps a container" do
          offering_every_layer

          judged = outside_a_git_hook do
            docked_on_path(workspace_wiring(exec: "docker")) { judge_asked_about_git_log(_1) }
          end

          expect(judged).to eq([])
        end
      end

      # Whether a judge-approved call runs under the workspace profile's masks is what the toolset
      # built, read by the board; the arm alone builds no sandbox. Read through the one call it changes:
      # a git log of the project's own history reaches the judge only under the masks.
      describe "the masks the board is told guard a judge-approved call" do
        it "lets a git log reach the judge when the sandbox wraps bash under --confine workspace", :seam do
          offering_every_layer

          expect(outside_a_git_hook { judge_asked_about_git_log(board_on_path("/usr/bin", workspace_wiring)) })
            .to eq(["bash"])
        end

        it "keeps a git log from the judge when the box cannot build the sandbox" do
          allow(Lain::Confine::Probe).to receive(:new).and_wrap_original do |original, **kwargs|
            original.call(**kwargs, runner: ->(_argv) { ["", false] })
          end

          expect(outside_a_git_hook { judge_asked_about_git_log(board_on_path("/usr/bin", workspace_wiring)) })
            .to eq([])
        end
      end

      # A commit's hooks run files the chat may have edited, so the rule approving one is built only where
      # the toolset built the sandbox that holds the call.
      describe "the lease commit rule" do
        # Under an attended ask, whose ladder holds the rules rung bare.
        def rule_names
          board = board_on_path("/usr/bin", workspace_wiring(approval: "ask", non_interactive: false))
          board.ladder.to_a[1].instance_variable_get(:@rules).map(&:name)
        end

        it "is built when the sandbox wraps bash under --confine workspace", :seam do
          offering_every_layer

          expect(rule_names).to include("lease_commit")
        end

        it "is not built when the box cannot build the sandbox" do
          allow(Lain::Confine::Probe).to receive(:new).and_wrap_original do |original, **kwargs|
            original.call(**kwargs, runner: ->(_argv) { ["", false] })
          end

          expect(rule_names).not_to include("lease_commit")
        end

        # Rooted at a real lease as a drained chore's chat is, with nothing built by hand.
        it "approves a commit in the lease the chat is rooted at", :seam do
          offering_every_layer
          upstream = File.join(File.dirname(@root), "upstream")
          FileUtils.cp_r("#{SeedRepo.at(SeedRepo::SEED)}/.", upstream.tap { FileUtils.mkdir_p(_1) })
          SeedRepo.git(upstream, "branch", "-M", "main")
          lease = Lain::CLI::IsolationBackend.resolve("worktree", root: upstream).acquire("wired")
          @root = lease.origin.path

          board = with_env("HOME" => @home, "XDG_CONFIG_HOME" => nil) do
            outside_a_git_hook { board_on_path("/usr/bin", workspace_wiring) }
          end
          ruling = Sync { |task| task.with_timeout(5) { board.policy_switch.rule(bash_of("git commit -m x"), nil) } }

          expect([ruling.allow?, ruling.rule]).to eq([true, "lease_commit"])
        ensure
          lease&.release(discard: true)
        end
      end

      def offering_every_layer
        allow(Lain::Confine::Probe).to receive(:new).and_wrap_original do |original, **kwargs|
          original.call(**kwargs, runner: ->(argv) { [argv.include?("--status") ? '{"abi":3,"reap":true}' : "", true] })
        end
      end

      # Unattended, so a call the judge never sees is refused at once rather than parked.
      def workspace_wiring(**over)
        allow(Lain::CLI::Wiring::BoardBuild).to receive(:for).and_wrap_original do |original, **kwargs|
          original.call(**kwargs, judge: ->(tool:, **) { asked.push(tool).then { :approve } })
        end
        options = { grace: 5, approval: "auto", confine: "workspace", non_interactive: true, **over }
        described_class.new(options:,
                            chronicle:, status_feed:, project: throwaway_project(@root),
                            paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => @state, "HOME" => @home }))
      end

      def asked = @asked ||= []

      # The chat's env is a snapshot of this process's, and the commit hook exports GIT_DIR and
      # GIT_INDEX_FILE; a git log under those reads another index, so it is rightly walked. Only the
      # config pair the specs set is kept.
      def outside_a_git_hook(&)
        with_env(ENV.keys.grep(/\AGIT_/).-(%w[GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM]).to_h { [_1, nil] }, &)
      end

      def judge_asked_about_git_log(board)
        FileUtils.mkdir_p(File.join(@root, ".git", "objects"))
        Sync { |task| task.with_timeout(5) { board.policy_switch.rule(bash_of("git log"), nil) } }
        asked
      end
    end

    describe "under --tripwire" do
      let(:journal_io) { StringIO.new }
      let(:state_dir) { Dir.mktmpdir("wiring-tripwire") }
      let(:chronicle) do
        Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io: journal_io),
                                 journal_path: File.join(state_dir, "session.ndjson"))
      end

      after { FileUtils.rm_rf(state_dir) }

      def remembered_deny_after_wiring(options)
        armed = new_wiring(options: { grace: 5, **options }, chronicle:, status_feed:)
        recorder, session = armed.run_state(nil)
        armed.wire_agent(channel:, recorder:, session:, backend:)
        chronicle.durable_journal << { "type" => "escalation", "tool" => "bash", "tool_use_id" => "tu_1",
                                       "requester" => "agent", "verdict" => "deny", "rung" => "remembered",
                                       "reason" => "", "final" => false }
        journal_records(journal_io).select { _1["type"] == "tripwire" }
      end

      it "folds the session's journal into a ledger under observe" do
        expect(remembered_deny_after_wiring(tripwire: "observe").sole)
          .to include("requester" => "agent", "signal" => "remembered_reask", "stop" => "none")
      end

      it "keeps no ledger when the arm is off" do
        expect(remembered_deny_after_wiring(tripwire: "off")).to be_empty
      end
    end

    describe "under --confine reader --tripwire observe, on this box", :seam do
      let(:base) { File.realpath(Dir.mktmpdir("wiring-tripwire-seam")) }
      let(:project_root) { File.join(base, "repo") }
      # Outside the project, since a project directory on PATH alone makes the ladder abstain.
      let(:planted) { File.join(base, "userbin", "cat") }
      let(:journal_io) { StringIO.new }
      let(:chronicle) do
        Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io: journal_io), journal_path: "seam.ndjson")
      end
      let(:tripped) do
        described_class.new(options: { grace: 5, approval: "auto", confine: "reader", tripwire: "observe" },
                            chronicle:, status_feed:, project: throwaway_project(project_root),
                            paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(base, "s"),
                                                          "HOME" => File.join(base, "h") }))
      end
      # A stray non-executable wc first on PATH: the shell tries it and the kernel refuses it on an honest call.
      let(:noise) { File.join(base, "noexec", "wc") }

      before do
        fence = Lain::Confine::Bwrap.fence_binary
        skip("bwrap or strace is not installed") unless %w[/usr/bin/bwrap /usr/bin/strace].all? { File.executable?(_1) }
        skip("lain-fence is not built at #{fence} -- run `bundle exec rake compile`") unless File.executable?(fence)
        FileUtils.mkdir_p([project_root, File.join(base, "s"), File.join(base, "h")])
        File.write(File.join(project_root, "README.md"), "the readme\n")
        FileUtils.mkdir_p(File.dirname(noise))
        File.write(noise, "not a program\n")
      end

      around do |example|
        was = ENV.fetch("PATH")
        ENV["PATH"] = "#{File.dirname(noise)}:#{File.dirname(planted)}:/usr/bin:/bin"
        example.run
      ensure
        ENV["PATH"] = was
        FileUtils.rm_rf(base)
      end

      # Planted once the call has resolved, so the ladder approved a system cat and only the kernel meets the plant.
      def plant_before_each_exec
        allow(Lain::Exec::Sandboxed).to receive(:new).and_wrap_original do |original, **kwargs|
          original.call(**kwargs).tap do |exec|
            allow(exec).to receive(:call).and_wrap_original do |call, **run|
              FileUtils.mkdir_p(File.dirname(planted))
              File.write(planted, "#!/bin/sh\necho planted\n")
              File.chmod(0o755, planted)
              call.call(**run)
            end
          end
        end
      end

      # @return [Array(Lain::Tool::Result, Array<Hash>)] the call's result and every record journalled
      # @yield once the lineage has started and before the call resolves
      def run_bash(command)
        recorder, session = tripped.run_state(nil)
        tripped.wire_agent(channel:, recorder:, session:, backend:)
        yield if block_given?
        board = tripped.instance_variable_get(:@switchboard)
        layers = Lain::CLI::ToolGuard.stack(chronicle, board).to_a
        result = Sync do |task|
          task.with_timeout(20) do
            dispatch_call("bash", { "command" => command }, id: "tu_seam", toolset: board.toolset, layers:,
                                                            context: session)
          end
        end
        [result, journal_records(journal_io)]
      end

      def exec_record_of(records) = records.find { _1["type"] == "exec_record" }

      def tripwires_of(records) = records.select { _1["type"] == "tripwire" }

      it "counts the kernel's refusal of a planted program as a strong signal for the call's requester" do
        plant_before_each_exec
        result, records = run_bash("cat README.md")

        expect(result.content).not_to include("planted")
        expect(exec_record_of(records)["refusals"]).to include({ "path" => planted, "errno" => "EACCES" })
        expect(tripwires_of(records))
          .to include(a_hash_including("requester" => "agent", "signal" => "refused_exec", "weight" => "strong"))
      end

      it "counts nothing for the refusal of a stray file the resolution skipped as not executable" do
        result, records = run_bash("wc -l README.md")

        expect(result.content).to include("1")
        expect(exec_record_of(records)["refusals"]).to include({ "path" => noise, "errno" => "EACCES" })
        expect(tripwires_of(records)).to be_empty
      end

      # The stray above was written before the lineage began; one written after cannot pass as noise.
      it "counts a non-executable candidate written this lineage and made executable before the exec" do
        game = File.join(File.dirname(noise), "head")
        allow(Lain::Exec::Sandboxed).to receive(:new).and_wrap_original do |original, **kwargs|
          original.call(**kwargs).tap do |exec|
            allow(exec).to receive(:call).and_wrap_original do |call, **run|
              File.chmod(0o755, game)
              call.call(**run)
            end
          end
        end

        _, records = run_bash("head -1 README.md") { File.write(game, "#!/bin/sh\necho planted\n") }

        expect(exec_record_of(records)["refusals"]).to include({ "path" => game, "errno" => "EACCES" })
        expect(tripwires_of(records)).to include(a_hash_including("signal" => "refused_exec", "weight" => "strong"))
      end

      it "starts every stage of a pipeline with the launcher, and counts nothing for an honest one" do
        _, records = run_bash("cat README.md | head -1")
        execs = exec_record_of(records)["execs"].select { _1["rc"].zero? }.map { _1["path"] }

        expect(execs).to eq([execs.first, "/usr/bin/cat", execs.first, "/usr/bin/head"])
        expect(File.basename(execs.first)).to eq("lain-fence")
        expect(tripwires_of(records)).to be_empty
      end
    end
  end

  # The record tee never reaches the transcript, so a write is told to the
  # human only through the channel the TTY drains.
  it "hands the main agent the transcript's channel as where written files are told" do
    displays = []
    allow(Lain::Agent).to receive(:new).and_wrap_original do |original, **kwargs|
      displays << kwargs[:display]
      original.call(**kwargs)
    end

    wire_agent

    expect(displays.first).to equal(channel)
  end

  # A chat started in a subdirectory still names its writes from the project
  # root, which is where the human reads paths from.
  it "names the chat's writes relative to the project root when its cwd is below it" do
    shown = Dir.mktmpdir do |dir|
      sub = File.join(dir, "lib", "sub").tap { |path| FileUtils.mkdir_p(path) }
      project = Lain::Project.new(root: dir, cwd: sub, kind: :project, detected_by: :flag)
      _, session = described_class.new(options: { grace: 5 }, chronicle:, status_feed:, project:).run_state(nil)
      written = File.join(dir, "lib", "other.rb")
      session.open_pre_images.record_pre_image(written) { nil }.record_write(written)
      session.round_writes
    end

    expect(shown).to eq(["lib/other.rb"])
  end

  # A child's own journal is the record, never the transcript, so its writes
  # reach the human only through the channel the Seam carries for them.
  it "hands every child the transcript's channel as where its written files are told" do
    displays = []
    allow(Lain::Tools::Subagent::Seam).to receive(:new).and_wrap_original do |original, **kwargs|
      displays << kwargs[:display_channel]
      original.call(**kwargs)
    end

    wire_agent

    expect(displays).to all(equal(channel)).and(be_any)
  end

  # The epic mount, the toolset's gate submitter, the board and the isolation
  # settings all read `.lain/config.rb` through one reader, so they cannot
  # read two different files.
  it "loads the project's config once per chat start" do
    allow(Lain::Config).to receive(:load).and_call_original

    wire_agent

    expect(Lain::Config).to have_received(:load).once
  end

  # The route `/meta` takes, from the chat's own session: an :inherit child
  # spawned after the chat committed a cut renders the cut, not the turns it
  # replaced.
  # --max-cost is run-wide: what the judge spends is paid into the very Shared
  # the chat agent's dollar ceiling reads.
  describe "a judged call's spend" do
    let(:priced) { Lain::Usage.new(input_tokens: 10_000) }

    def judged(responses, max_cost:)
      mock = Lain::Provider::Mock.new(responses:)
      options = { provider: "ollama", model: nil, max_tokens: 64, max_cost: }
      judging = offline_backend_class.new(options, mock:, root: project_dir)
      auto = new_wiring(options: { grace: 5, approval: "auto" }, chronicle:, status_feed:)
      recorder, session = auto.run_state(nil)
      [auto.wire_agent(channel:, recorder:, session:, backend: judging), judging, mock]
    end

    it "hands the agent the same Shared the tiers pay into" do
      agent, judging, = judged([text_response("hi")], max_cost: 1)

      expect(agent.spend).to be_a(Lain::Budget::Shared).and equal(judging.attachment.spend)
    end

    it "refuses the next chat step once a judged call cost more than --max-cost" do
      agent, judging, mock = judged([
                                      tool_response(["t1", "bash", { "command" => "curl -s http://t28.invalid/x" }],
                                                    model: "qwen3:4b"),
                                      text_response("DENY", model: "claude-opus-5-5", usage: priced),
                                      text_response("after", model: "qwen3:4b")
                                    ], max_cost: 0.01)

      begin
        agent.ask("go")
      rescue StandardError
        nil
      end

      expect([judging.attachment.spend.spent.dollars.amount, mock.requests.size]).to eq([BigDecimal("0.04"), 2])
    end
  end

  describe "the chat session an :inherit child reads its parent's cuts from" do
    let(:mock_provider) { Lain::Provider::Mock.new(responses: [text_response("settled"), text_response("done")]) }

    def handoff_at(head, first)
      Lain::Telemetry::CompactionCut.new(
        digest: head, head:, strategy: Lain::Telemetry::Compaction::EAGER_CONTROL_ARM, kind: "handoff", parent: nil,
        supersedes: [], plan_step_completions: 0,
        collapses: [{ "span" => [first, head], "content" => [{ "type" => "text", "text" => "STATE-DOCUMENT" }] }]
      )
    end

    it "renders the chat's held cut to a child spawned through the run's role-spawn seam" do
      recorder, session = wiring.run_state(nil)
      agent = wiring.wire_agent(channel:, recorder:, session:, backend:)
      agent.ask("REPLACED-TURN")
      session.record_compaction_cut(handoff_at(agent.timeline.head_digest, agent.timeline.to_a.first.digest))

      wiring.role_spawn.call(:researcher, :inherit, "go")

      sent = Lain::Canonical.dump(mock_provider.last_request.messages)
      expect(sent).to include("STATE-DOCUMENT")
      expect(sent).not_to include("REPLACED-TURN")
    end
  end

  # The 2026-08-05 defect, at the site it fired from -- and the surface it fired
  # from is now deleted. This call built a real dunstify adapter unconditionally,
  # so every spec, probe and experiment that reached #wire_agent notified the
  # human running the machine: nine notifications landed on a working human's
  # desktop, `appname: lain`, from agents' trees. The gate written for it was
  # consent BEFORE capability; removing the surface answers the same question by
  # construction.
  #
  # The `dunstify` put on PATH here RECORDS rather than merely exits, and that
  # is the point of it: a fake that only exits would be scenery, passing whether
  # or not anything tried to notify. This one writes its argv to a witness file,
  # so the first example fails if any line reached by a wired chat shells out to
  # the human's notification daemon -- capability restored to PATH, and nothing
  # taking it.
  describe "the desktop surface a chat no longer has" do
    let(:witness) { File.join(@dunstify_dir, "fired") }

    around do |example|
      Dir.mktmpdir do |dir|
        @dunstify_dir = dir
        fake = File.join(dir, "dunstify")
        File.write(fake, "#!/bin/sh\nprintf '%s\\n' \"$@\" >> #{File.join(dir, "fired")}\nexit 0\n")
        File.chmod(0o755, fake)
        with_env("PATH" => "#{dir}#{File::PATH_SEPARATOR}#{ENV.fetch("PATH")}") do
          example.run
        end
      end
    end

    it "assembles a chat that answers, and nothing in it reaches the notification daemon" do
      wiring = new_wiring(options: { grace: 5 }, chronicle:, status_feed:)
      recorder, session = wiring.run_state(nil)
      agent = wiring.wire_agent(channel:, recorder:, session:, backend:)

      expect(agent.ask("ping").text).to eq("settled")
      expect(wiring).not_to respond_to(:notifier)
      expect(File).not_to exist(witness)
    end

    # The structural half, and the one that makes the example above an
    # invariant rather than an observation: there is no adapter left to build,
    # so no consent and no capability can reintroduce one.
    it "offers no desktop notification surface at all, so consent has nothing left to turn on" do
      expect(Lain).not_to be_const_defined(:Notify)
    end
  end

  describe "#wire_agent" do
    # A child a closed or abandoned run left stopped is still the parent's to
    # resume, so the chat's subagent tool holds it under its label again.
    it "holds a resumed run's stopped children under their labels, for the chat's subagent to resume" do
      recorder, session = wiring.run_state(nil)
      store = Lain::Dag::Factory.store
      stop = Lain::Telemetry::ChildStopped.new(spawn: "blake3:spawn", label: "skeleton", role: "reviewer_code",
                                               head: "blake3:head", reason: :iterations, task: "review it")
      resumed = Lain::CLI::Resume::Result.new(file: "gone.ndjson", timeline: Lain::Dag::Factory.timeline(store:),
                                              session:, recorder:, open: false, notices: [], stops: [stop])

      agent = wiring.wire_agent(channel:, recorder:, session:, backend:, resumed:)
      subagent = agent.toolset.fetch("subagent")

      asked = { "role" => "reviewer_code", "resume" => "nobody" }

      expect { subagent.call(asked, Lain::Tool::Invocation.new(context: session)) }
        .to raise_error(Lain::Tool::InvalidInput, /these are: "skeleton"/)
    end

    describe "the iteration ceiling a chat starts under" do
      let(:table) { Lain::Budget::Table.new(rows: { "default" => 30 }) }

      before { allow(Lain::Config).to receive(:budget).and_return(table) }

      def resumed_with(allowance)
        recorder, session = wiring.run_state(nil)
        Lain::CLI::Resume::Result.new(file: "gone.ndjson", timeline: Lain::Dag::Factory.timeline(store: Lain::Dag::Factory.store),
                                      session:, recorder:, open: false, notices: [], allowance:)
      end

      def wired(resumed)
        wiring.wire_agent(channel:, recorder: resumed.recorder, session: resumed.session, backend:, resumed:)
      end

      it "is the configured default row on a fresh chat, before any skill" do
        expect(wire_agent.budget.iterations).to eq(30)
      end

      it "is the configured default row on a resume that holds no grant" do
        expect(wired(resumed_with(nil)).budget.iterations).to eq(30)
      end

      it "is the grant a resumed chain held, kept for the plain lines that follow" do
        agent = wired(resumed_with(Lain::Budget.ceilings(iterations: 103)))

        expect(agent.allowed).to eq(103)
      end
    end

    it "builds the Agent over the injected backend's provider, no exe involved" do
      agent = wire_agent
      expect(agent).to be_a(Lain::Agent)
      expect(agent.ask("ping").text).to eq("settled")
      expect(mock_provider.call_count).to eq(1)
    end

    it "warns the chat in its mailbox when its ask is 5 iterations from the ceiling it was given" do
      turns = nil
      probing = Class.new(Lain::Provider::Mock) do
        define_method(:complete) do |request, **|
          turns.call({ iteration: 20 }) { |env| env }
          super(request)
        end
      end.new(responses: [Lain::Response.new(content: [{ "type" => "text", "text" => "settled" }],
                                             stop_reason: :end_turn)])
      recorder, session = wiring.run_state(nil)
      agent = wiring.wire_agent(channel:, recorder:, session:, backend: offline_backend_class.new(
        { provider: "ollama", model: nil, max_tokens: 64 }, mock: probing, root: backend_root
      ))
      turns = agent.instance_variable_get(:@instrumentation).turn_middleware

      agent.ask("ping", iterations: 25)

      queued = wiring.send(:notes).mailbox.send(:first_queued)
      expect(queued).to include(from: "lain")
      expect(queued.fetch(:body).fetch("text")).to include("5 of 25 iterations remain")
    end

    it "warns at the point of a raised ceiling, not the default one, and again on the next ask" do
      turns = nil
      probing = Class.new(Lain::Provider::Mock) do
        define_method(:complete) do |request, **|
          [0, 10, 20].each { |iteration| turns.call({ iteration: }) { |env| env } }
          super(request)
        end
      end.new(responses: [Lain::Response.new(content: [{ "type" => "text", "text" => "settled" }],
                                             stop_reason: :end_turn)])
      recorder, session = wiring.run_state(nil)
      agent = wiring.wire_agent(channel:, recorder:, session:, backend: offline_backend_class.new(
        { provider: "ollama", model: nil, max_tokens: 64 }, mock: probing, root: backend_root
      ))
      turns = agent.instance_variable_get(:@instrumentation).turn_middleware
      posted = []
      mailbox = wiring.send(:notes).mailbox
      allow(mailbox).to receive(:post).and_wrap_original do |post, **note|
        posted << note.fetch(:text)
        post.call(**note)
      end

      agent.ask("one", iterations: 100)
      expect(posted).to be_empty
      agent.ask("two", iterations: 25)
      agent.ask("three", iterations: 25)

      expect(posted.size).to eq(2)
      expect(posted).to all(include("5 of 25 iterations remain"))
    end

    # The parent handle is ONE Proc, equal?-shared by AskHuman and
    # Subagent::Seam, and it is read at CALL time -- so nothing observes it until
    # the first question is asked or the first child is spawned, which is why it
    # was dead in production for as long as it was. Every other spec in the suite
    # builds its own working thunk instead of taking this one, so the seam that
    # ships had no coverage at all. Asserted through the tools' own resolution
    # (#parent_timeline, Seam#parent), not by reaching for the lambda: what
    # matters is that the objects Wiring hands out can find the Agent, not how.
    it "hands its tools a parent handle that resolves to the live Agent" do
      agent = wire_agent
      expect(wiring.ask_human.send(:parent_timeline)).to equal(agent.timeline)
      expect(agent.toolset.fetch("subagent").seam.parent.call).to equal(agent.timeline)
    end

    # `lain` names the harness, so the chat's own agent asks as `agent`, the
    # name its approvals carry: one actor, one name on every surface.
    it "names the main agent's questions agent, on the arrival line and in the record" do
      wire_agent
      shown = StringIO.new
      tty = Lain::Frontend::TTY.new(channel: Lain::Channel.new, output: shown, input: StringIO.new)

      Sync do
        wiring.ask_human.ask("which db?")
        item = wiring.questions.dequeue
        tty.render_arrival(item.question, from: item.from)
      end

      expect(shown.string).to include("? agent which db?")
      expect(wiring.ask_human.last_question.body).to include("asked_by" => "agent")
    end

    # ---- session_usage: the fix, at the seam that made the failure possible --

    # Asked what its own session had spent, the agent invented a metrics table
    # -- wrong model name, fabricated memory/CPU/RTT/network figures -- while
    # eight `turn_usage` records carrying the true answer sat in the journal it
    # had just written. Nothing in the shipped toolset could reach the run's own
    # accounting, so the model answered from nowhere.
    #
    # Asserted end to end through a real ask rather than by reaching for the
    # thunk, for the reason the parent-handle example above states: what matters
    # is that the tool Wiring hands the model finds the Agent Wiring built. A
    # spec that constructed its own thunk would pass while the shipped seam
    # stayed dead, which is exactly how the parent handle went unnoticed.
    it "hands the chat a session_usage tool reading the accounting of the Agent it built" do
      spending = Lain::Provider::Mock.new(
        responses: [Lain::Response.new(content: [{ "type" => "text", "text" => "settled" }], stop_reason: :end_turn,
                                       usage: Lain::Usage.new(input_tokens: 11, output_tokens: 4))]
      )
      recorder, session = wiring.run_state(nil)
      agent = wiring.wire_agent(channel:, recorder:, session:,
                                backend: offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 },
                                                                   mock: spending))
      agent.ask("ping")

      report = agent.toolset.fetch("session_usage").call({}, nil)

      expect(report).to be_ok
      expect(report.content).to include("input: 11", "output: 4", "total: 15")
    end

    # The reason it is appended by ToolsetBuild rather than added to BaseTools:
    # a child attenuates from the floor, and the floor is built ONCE and shared,
    # so a thunk over the chat's Agent placed there would make every subagent
    # report its PARENT's spend as its own -- the same wrong answer, one
    # level down. The positive half is not decoration: `not_to include` alone
    # passes for a child attenuated to nothing, and would also pass while the
    # tool was never wired at all.
    it "keeps session_usage off the set a child attenuates from, so no child reports its parent's spend" do
      agent = wire_agent

      expect(agent.toolset.names).to include("session_usage")
      expect(agent.toolset.fetch("subagent").attenuates_from.names).not_to include("session_usage")
    end

    # Scenario: the toolset does not change with the mode
    #
    # Through the Agent a real Wiring built, so the claim is about the set the
    # model is really shown: a flip moves the gate, never the tool block a
    # prompt cache keys on. It reaches for the board the way
    # `approve_everything` below does, and for the same reason: the board is
    # Wiring's private collaborator, and the flip has to happen after
    # #wire_agent built and memoized it.
    it "renders the same tool block before and after /mode bypass" do
      agent = wire_agent
      board = wiring.instance_variable_get(:@switchboard)
      before = [agent.toolset, agent.toolset.digest]

      board.mode_switch.switch(Lain::Mode.new(approval: :bypass), surface: "spec")

      expect([agent.toolset, agent.toolset.digest]).to eq(before)
      expect(agent.toolset.names).to include("session_usage", "bash", "edit_file")
    end

    # The provider-reported window again, at the third construction site -- the
    # one a human actually reads. `Agent#occupancy` is asked with NO KEYWORD by
    # Frontend::PromptComposer::RunState, so the book has to have arrived when
    # the Agent was BUILT -- and this is the only place that happens.
    #
    # It is pinned here rather than by handing the same book to two objects and
    # comparing their arithmetic: that proves the division agrees and nothing
    # about the wiring. Deleting `context_window:` from Wiring#backing left
    # the whole suite green while a running chat printed 86% at the prompt and
    # published 0.216 to state.json -- the two-surfaces-disagreeing state the
    # card calls worse than being uniformly wrong. No book is injected here; the
    # provider is asked, exactly as production asks it.
    it "hands the built Agent the run's own book, so #occupancy needs no keyword" do
      recorder, session = wiring.run_state(nil)
      backend = offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 },
                                          mock: serving_provider)

      agent = wiring.wire_agent(channel:, recorder:, session:, backend:)
      agent.ask("ping")

      expect(agent.occupancy).to eq(7_079.fdiv(32_768))
      expect(agent.occupancy).not_to eq(7_079.fdiv(Lain::ContextWindow::CONSERVATIVE_FALLBACK))
    end

    it "exposes the reply seam and fleet supervisor it wired, as its own accessors" do
      wire_agent
      expect(wiring.ask_human).to be_a(Lain::Tools::AskHuman)
      expect(wiring.questions).to be_a(Async::Queue)
      expect(wiring.supervisor).to be_a(Lain::Supervisor)
      expect(wiring.approvals).to be_a(Lain::Approval::Parked::Queue)
    end

    # The session Toolset is built ONCE (toolset_build.rb:61-64) and the
    # Agent holds it in an ivar for its whole life. This identity is what made a
    # #to_schema memo PLAUSIBLE -- Context#render (context.rb:162) calls
    # `toolset.to_schema` unconditionally every turn, against the same instance.
    # An earlier round declined that memo on a measurement (~225us per call,
    # orders of magnitude under a round trip) plus an objection: extra reachable
    # mutable state on a value object CLAUDE.md says must be deeply frozen.
    #
    # The memo shipped anyway, and both halves of that objection have since
    # been answered rather than overruled. Toolset now has value equality over
    # its canonical schema bytes, so it must hold a digest; the digest REQUIRES
    # the normalized schema, so keeping it is a reordering of work already done,
    # not an addition -- and it has to happen in #initialize, since the object
    # freezes itself there and a lazy memo would be a FrozenError. Nor is it
    # mutable state: what is stored is the same deeply-frozen structure
    # Canonical.normalize already returned, so the value stays deeply frozen.
    # Measured at review: ~844us once per session, ~461us saved every turn after
    # the first -- break-even at turn two. The invariant here -- one Toolset
    # survives the whole session -- is worth pinning on its own regardless
    # (Schneeman), and it is what makes the memo pay.
    it "renders every turn with the SAME Toolset instance across the session" do
      agent = wire_agent
      toolset_before = agent.toolset

      agent.ask("first turn")
      agent.ask("second turn")

      expect(agent.toolset).to equal(toolset_before)
    end

    # The chat's per-turn durability belt: {Lain::Middleware::JournalTurns} in
    # the turn phase, so every committed turn is on disk before the NEXT model
    # call. It reaches the Agent only through the run's one
    # {Lain::Agent::Instrumentation}, and a mutation run found that dropping
    # it there left this whole file green -- every other example builds over
    # Chronicle::Null, whose turn phase is empty either way, so "empty" proved
    # nothing. This one records.
    it "wires the chronicle's per-turn durability middleware, so each ask lands its turns on disk" do
      io = StringIO.new
      recording = Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io:), journal_path: "wiring-spec.ndjson")
      recording_wiring = new_wiring(options: { grace: 5 }, chronicle: recording, status_feed:)
      recorder, session = recording_wiring.run_state(nil)
      agent = recording_wiring.wire_agent(channel:, recorder:, session:, backend:)

      agent.ask("ping")

      turns = journal_records(io, "turn")
      # Two turns really landed (user + assistant), so the equality below is a
      # record agreeing with a conversation and not two empty lists agreeing.
      expect(turns.size).to eq(2)
      expect(turns.map { |record| record["digest"] }).to eq(agent.timeline.to_a.map(&:digest))
    end

    # The run negotiates its Context's `#requires` against the provider it
    # actually talks to, under `:degrade`, and journals what it lost. Before
    # this, `Capability::Policy.for` had ZERO call sites in lib/, exe/ and bin/
    # -- the record type, the emitter and the {Lain::Bench::Session::Loader}
    # fold all existed and nothing ever constructed the policy, so twelve POC
    # journals carried no `capability_degraded` line while
    # {Lain::Context::CacheBreakpoints} required `:prompt_caching` from a
    # provider that does not offer it.
    #
    # Recorded here as well as in spec/lain/seams/capability_degraded_spec.rb
    # because THIS file is where #wire_agent's own contract lives: the mock
    # below declares a capability set that is missing one the real
    # default Context requires, and the assertion reads the journal
    # bytes rather than a policy object nobody injected.
    it "journals what the run's provider cannot give its context, once, under :degrade" do
      io = StringIO.new
      recording = Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io:), journal_path: "wiring-spec.ndjson")
      lacking = Lain::Provider::Mock.new(responses: [Lain::Response.new(content: [], stop_reason: :end_turn)],
                                         capabilities: default_requires - %i[prompt_caching])
      recording_wiring = new_wiring(options: { grace: 5 }, chronicle: recording, status_feed:)
      recorder, session = recording_wiring.run_state(nil)
      recording_wiring.wire_agent(channel:, recorder:, session:,
                                  backend: offline_backend_class.new({ provider: "ollama", model: nil,
                                                                       max_tokens: 64 }, mock: lacking))

      degraded = journal_records(io)
                 .select { |record| record["type"] == "capability_degraded" }
      expect(default_requires).to include(:prompt_caching)
      expect(degraded.map { |record| record.values_at("capability", "provider") })
        .to eq([["prompt_caching", "Lain::Provider::Mock"]])
    end

    # The other arm, and the one that says the policy is resolving rather than
    # emitting unconditionally: the file's default mock declares the whole of
    # {Lain::Provider::CAPABILITIES}, so nothing its context requires is missing.
    it "journals no degradation when the provider supports everything the context requires" do
      io = StringIO.new
      recording = Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io:), journal_path: "wiring-spec.ndjson")
      recording_wiring = new_wiring(options: { grace: 5 }, chronicle: recording, status_feed:)
      recorder, session = recording_wiring.run_state(nil)
      recording_wiring.wire_agent(channel:, recorder:, session:, backend:)

      expect(default_requires.all? { |capability| mock_provider.supports?(capability) }).to be(true)
      expect(io.string).not_to include("capability_degraded")
    end

    # No --secret-oracle, no surface. Asserted at the CONSTRUCTION
    # site as well as at the fan-out, because "a flag that wires nothing" and
    # "a capability with no reachable construction" are the same defect read
    # from opposite ends, and this chunk produced both.
    it "wires no secret surface without --secret-oracle" do
      wire_agent
      expect(wiring.secret_surface(backend)).to be_nil
    end

    it "wires no secret surface under --secret-oracle off" do
      off = new_wiring(options: { grace: 5, secret_oracle: "off" }, chronicle:, status_feed:)
      recorder, session = off.run_state(nil)
      off.wire_agent(channel:, recorder:, session:, backend:)

      expect(off.secret_surface(backend)).to be_nil
    end

    it "refuses to start a chat under --secret-oracle cloud with no --gateway, naming it" do
      cloud = { grace: 5, secret_oracle: "cloud", secret_oracle_model: "glm-5.3:cloud" }

      expect { new_wiring(options: cloud, chronicle:, status_feed:) }.to raise_error(Lain::Error, /--gateway/)
    end

    # The surface turns any fault at ask time into a journaled no-op, so a
    # listener that is not the gateway has to be refused while the human is
    # still watching the launch.
    it "refuses at launch a --gateway that cannot prove it is a lain gateway" do
      token = "0123456789abcdef0123456789abcdef"
      stub_request(:get, %r{\Ahttp://127\.0\.0\.1:11434#{Lain::Gateway::IDENTITY_PATH}\?nonce=}o).to_return(status: 404)
      refusal = with_env("XDG_STATE_HOME" => File.join(project_dir, "state")) do
        Lain::Gateway::TokenFile.for(11_434).write(token)
        cloud = new_wiring(options: { grace: 5, secret_oracle: "cloud", secret_oracle_model: "glm-5.3:cloud",
                                      gateway: "http://127.0.0.1:11434" }, chronicle:, status_feed:)
        recorder, session = cloud.run_state(nil)
        cloud.wire_agent(channel:, recorder:, session:, backend:)
        cloud.secret_surface(backend)
      rescue Lain::Oracle::SecretRead::NotAGateway => e
        e
      end

      expect(refusal.message).to include("did not prove")
      expect(refusal.message).not_to include(token)
    end

    describe "--secret-oracle" do
      let(:wiring) { new_wiring(options: { grace: 5, secret_oracle: "local" }, chronicle:, status_feed:) }

      before do
        recorder, session = wiring.run_state(nil)
        wiring.wire_agent(channel:, recorder:, session:, backend:)
      end

      it "constructs the triage surface" do
        expect(wiring.secret_surface(backend)).to be_a(Lain::Approval::Parked::SecretSurface)
      end

      it "claims a call parked at the path gate, but not an ordinary one, through the session's own policy" do
        surface = wiring.secret_surface(backend)
        parked = lambda do |path|
          effect = Struct.new(:name, :input, :tool_use_id).new("read_file", { "path" => path }, "tu_1")
          Lain::Approval::Parked::Queue::Pending.new(effect:, identity: Lain::Requester.main, clock: -> { 0.0 })
        end

        expect([".env.local", "lib/lain.rb"].map { |path| surface.mine?(parked.call(path)) }).to eq([true, false])
      end

      it "audits 5 percent of confident approves with a real random source" do
        surface = wiring.secret_surface(backend)

        expect([surface.instance_variable_get(:@audit_rate), surface.instance_variable_get(:@random)])
          .to match([0.05, a_kind_of(Random)])
      end

      it "memoizes it, so the Repl and any later reader share one surface and one journal fd" do
        expect(wiring.secret_surface(backend)).to be(wiring.secret_surface(backend))
      end

      # The whole point of the rung: even a run whose every provider knob names
      # a remote arm judges its parked secrets locally. Captured off the tier
      # the surface actually holds, not off a `.new` count.
      it "builds it against the LOCAL ollama provider, whatever --provider and --summarizer-provider say" do
        remote = { grace: 5, secret_oracle: "local", provider: "anthropic", summarizer_provider: "anthropic" }
        built = new_wiring(options: remote, chronicle:, status_feed:)
        recorder, session = built.run_state(nil)
        other = fresh_backend
        built.wire_agent(channel:, recorder:, session:, backend: other)

        tier = built.secret_surface(other).instance_variable_get(:@oracle)
        # `.inner` peels {Lain::Provider::Journaled}, which wraps this provider
        # so the judge's own round trip reaches the Journal too. A
        # decorator cannot move the endpoint -- what it wraps is still the bare
        # local provider `SecretRead.tier` builds -- and this assertion is about
        # the endpoint.
        provider = tier.instance_variable_get(:@inner).instance_variable_get(:@provider).inner
        expect(provider).to be_a(Lain::Provider::Ollama)
      end

      # The judge's options come from the chat's Backend: a chat on the judge's
      # own local model shares its runner, so the batch size has to follow the
      # judge onto the wire or every judgement reloads the chat's model.
      it "hands the judge the chat's runner knobs when the chat runs the judge's own model" do
        tuned = offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64, num_batch: 2048 },
                                          mock: mock_provider)

        tier = wiring.secret_surface(tuned).instance_variable_get(:@oracle).instance_variable_get(:@inner)
        expect(tier.instance_variable_get(:@extra)).to eq("num_batch" => 2048)
      end
    end
  end

  describe "--secret-oracle cloud through a real gateway", :seam do
    let(:token) { "0123456789abcdef0123456789abcdef" }
    let(:shown) { [] }
    let(:console) do
      seen = shown
      Class.new { define_method(:approve?) { |request| (seen << request) && true } }.new
    end
    let(:server) do
      Lain::Gateway::Server.new(bind: "127.0.0.1", port: 0, upstream: Lain::Gateway::Upstream.for("https://ollama.com"),
                                inspection: Lain::Gateway::Inspection.new(literals: []), console:,
                                journal: Class.new { define_method(:record) { |_| nil } }.new, token:)
    end
    let(:wiring) do
      new_wiring(options: { grace: 5, secret_oracle: "cloud", secret_oracle_model: "glm-5.3:cloud",
                            gateway: server.url }, chronicle:, status_feed:)
    end
    let(:verdict) { '{"verdict":"deny","confidence":0.97,"reason":"a config file holding a token"}' }
    let(:secret) { "QZ9vK2mR7xT4wL8nB3jH6yD1sA5fG0pEu7Wq" }
    let(:outstanding) do
      Lain::Approval::Parked::Queue::Outstanding.new(path: "/repo/config/app.yml",
                                                     regions: Lain::Sensitivity::Regions.detect("see #{secret}\n"))
    end

    around do |example|
      with_env("OLLAMA_API_KEY" => "gateway-key", "XDG_STATE_HOME" => File.join(project_dir, "state")) do
        Lain::Gateway::TokenFile.for(server.port).write(token)
        serving = Thread.new { server.run }
        NetworkAccess.permit_loopback(server.port) { example.run }
      ensure
        server.stop
        serving&.join(5)
      end
    end

    it "sweeps a parked read across the gateway to the upstream and applies the verdict" do
      upstream = stub_request(:post, "https://ollama.com/api/chat").to_return(
        status: 200, headers: { "Content-Type" => "application/json" },
        body: JSON.generate("model" => "glm-5.3:cloud", "message" => { "role" => "assistant", "content" => verdict },
                            "done" => true, "done_reason" => "stop")
      )
      wire_agent
      surface = wiring.secret_surface(backend)
      read = Struct.new(:name, :input, :tool_use_id).new("read_file", { "path" => "/repo/config/app.yml" }, "tu_1")

      settled = Sync do |task|
        gated = task.async { wiring.approvals.adjudicate(read, nil, outstanding:) }
        pending = task.with_timeout(5) { wiring.approvals.dequeue }
        task.with_timeout(20) { surface.sweep(wiring.approvals) }
        task.with_timeout(5) { gated.wait }
        pending
      end

      expect([settled.approved?, settled.surface]).to eq([false, Lain::Approval::Parked::SecretSurface::SURFACE])
      expect(upstream).to have_been_requested.once
      expect(shown.size).to eq(1)
      body = JSON.parse(shown.first.body)
      expect(body["stream"]).to be(false)
      expect(body.dig("messages", 0, "content")).to include('"/repo/config/app.yml"', "tool: read_file", "1 sensitive")
      expect(body.dig("messages", 0, "content")).not_to include(secret)
    end
  end

  describe "the price tier hold the backend's anthropic clients ask" do
    def json_reply
      { status: 200, headers: { "Content-Type" => "application/json" },
        body: JSON.generate("id" => "m", "type" => "message", "role" => "assistant", "model" => "claude-haiku-5-5",
                            "content" => [{ "type" => "text", "text" => "ok" }], "stop_reason" => "end_turn",
                            "usage" => { "input_tokens" => 1, "output_tokens" => 1 }) }
    end

    def streamed_reply
      events = [
        { "type" => "message_start",
          "message" => { "id" => "m", "type" => "message", "role" => "assistant", "model" => "claude-haiku-5-5",
                         "content" => [], "usage" => { "input_tokens" => 1, "output_tokens" => 1 } } },
        { "type" => "content_block_start", "index" => 0, "content_block" => { "type" => "text", "text" => "" } },
        { "type" => "content_block_delta", "index" => 0, "delta" => { "type" => "text_delta", "text" => "ok" } },
        { "type" => "content_block_stop", "index" => 0 },
        { "type" => "message_delta", "delta" => { "stop_reason" => "end_turn" }, "usage" => { "output_tokens" => 1 } },
        { "type" => "message_stop" }
      ]
      { status: 200, headers: { "Content-Type" => "text/event-stream" },
        body: events.map { |event| "event: #{event["type"]}\ndata: #{JSON.generate(event)}\n\n" }.join }
    end

    let(:decision) do
      Lain::Approval::Parked::Queue::Decision.new(requester: Lain::Requester.main, kind: "price_tier",
                                                  summary: "claude-haiku-5-5 crosses its tier",
                                                  digest: "blake3:00")
    end

    it "parks a crossing on the attended approval queue and answers the human's verdict" do
      wire_agent

      verdict = Sync do |task|
        task.with_timeout(20) do
          asking = task.async { backend.price_tier_hold.decide(decision) }
          pending = wiring.approvals.dequeue
          expect(pending.kind).to eq("price_tier")
          pending.approve(surface: "spec", authority: :human)
          asking.wait
        end
      end

      expect(verdict).to eq(:approve)
    end

    it "sends a summarizer request past the tier only after the human approves it", :seam do
      stub_request(:post, "https://api.anthropic.com/v1/messages/count_tokens")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate("input_tokens" => 104_000))
      sent = stub_request(:post, "https://api.anthropic.com/v1/messages")
             .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                        body: JSON.generate("id" => "m", "type" => "message", "role" => "assistant",
                                            "model" => "claude-haiku-5-5", "content" => [],
                                            "stop_reason" => "end_turn",
                                            "usage" => { "input_tokens" => 1, "output_tokens" => 1 }))
      hosted_summarizer = Class.new(Lain::CLI::Backend) do
        def initialize(options, mock:, root:)
          super(options, root:)
          @mock = mock
        end

        def provider(name: provider_name, **) = name == "anthropic" ? super : @mock
      end
      hosted = hosted_summarizer.new({ provider: "ollama", model: nil, max_tokens: 64,
                                       summarizer_provider: "anthropic", summarizer_model: "claude-haiku-5-5" },
                                     mock: mock_provider, root: backend_root)
      summarizer = nil
      with_env("ANTHROPIC_API_KEY" => "sk-wiring-spec") do
        summarizer = hosted.summarizer_provider
        recorder, session = wiring.run_state(nil)
        wiring.wire_agent(channel:, recorder:, session:, backend: hosted)
      end
      request = Lain::Request.new(model: "claude-haiku-5-5", max_tokens: 64, stream: false,
                                  messages: [{ role: "user", content: "x" * 400_000 }])

      Sync do |task|
        task.with_timeout(20) do
          sending = task.async { summarizer.complete(request) }
          pending = wiring.approvals.dequeue
          expect(pending.ask_face).to include("104,000", "100,000")
          expect(sent).not_to have_been_requested
          pending.approve(surface: "spec", authority: :human)
          sending.wait
        end
      end

      expect(sent).to have_been_requested.once
      expect(wiring.approvals.to_a).to be_empty
    end

    it "carries an approval given on the chat to its subagents' provider, and shows it on the chat's channel", :seam do
      stub_request(:post, "https://api.anthropic.com/v1/messages/count_tokens")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: JSON.generate("input_tokens" => 104_000))
      stub_request(:post, "https://api.anthropic.com/v1/messages").to_return do |request|
        JSON.parse(request.body)["stream"] ? streamed_reply : json_reply
      end
      hosted = Lain::CLI::Backend.new({ provider: "anthropic", model: "claude-haiku-5-5", max_tokens: 64 },
                                      root: backend_root)
      agent = with_env("ANTHROPIC_API_KEY" => "sk-wiring-spec") do
        recorder, session = wiring.run_state(nil)
        wiring.wire_agent(channel:, recorder:, session:, backend: hosted)
      end
      subagents = agent.toolset.fetch("subagent").seam.provider
      later = Lain::Request.new(model: "claude-haiku-5-5", max_tokens: 64, stream: false,
                                messages: [{ role: "user", content: "y" * 400_000 }])

      Sync do |task|
        task.with_timeout(20) do
          asking = task.async { agent.ask("x" * 400_000) }
          wiring.approvals.dequeue.approve(surface: "spec", authority: :human)
          asking.wait
          task.with_timeout(5) { subagents.complete(later) }
        end
      end

      expect(wiring.approvals.to_a).to be_empty
      expect(channel.drain.grep(Lain::Telemetry::PriceTierCrossed).map(&:decision)).to eq([:carried])
    end

    it "refuses every crossing when no human is attached" do
      wiring = new_wiring(options: { grace: 5, non_interactive: true }, chronicle:, status_feed:)
      recorder, session = wiring.run_state(nil)
      wiring.wire_agent(channel:, recorder:, session:, backend:)

      expect(backend.price_tier_hold.decide(decision)).to eq(:refuse)
    end
  end

  # The literals are the board's own secrets source, bound by Backend#attach, so
  # the history the board primed is the history the guard reads.
  describe "the egress guard the backend's providers carry" do
    let(:journal) { RecordingChannel.new }
    let(:chronicle) { Lain::CLI::Chronicle.new(journal:, journal_path: "egress-guard-spec-fake-session.ndjson") }
    let(:messages_url) { "https://api.anthropic.com/v1/messages" }
    let(:hosted) do
      with_env("ANTHROPIC_API_KEY" => "sk-wiring-spec") do
        Lain::CLI::Backend.new({ provider: "anthropic", model: "claude-haiku-5-5", max_tokens: 64 },
                               root: backend_root)
      end
    end

    def ask(text)
      Lain::Request.new(model: "claude-haiku-5-5", max_tokens: 64, stream: false,
                        messages: [{ role: "user", content: text }])
    end

    def wire_hosted
      recorder, session = wiring.run_state(nil)
      with_env("ANTHROPIC_API_KEY" => "sk-wiring-spec") do
        wiring.wire_agent(channel:, recorder:, session:, backend: hosted)
      end
    end

    def chat_provider = with_env("ANTHROPIC_API_KEY" => "sk-wiring-spec") { hosted.provider }

    it "never sends a request carrying a host secret, and journals the host and a count", :seam do
      password = "db-password-24-bytes-xyz"
      sent = stub_request(:post, messages_url)

      with_env("ANTHROPIC_API_KEY" => "sk-wiring-spec", "DB_PASSWORD" => password) do
        wire_hosted
        expect { hosted.provider.complete(ask("connect with #{password}")) }
          .to raise_error(Lain::Provider::HTTP::EgressGuard::Refused, /known secret/)
      end

      expect(sent).not_to have_been_requested
      refused = journal.events.grep(Lain::Telemetry::EgressRefused)
      expect(refused.map(&:to_journal)).to eq([{ "type" => "egress_refused", "host" => "api.anthropic.com",
                                                 "count" => 1, "turn" => 1 }])
    end

    it "sends a clean request with the API key in its headers", :seam do
      sent = stub_request(:post, messages_url)
             .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                        body: JSON.generate("id" => "m", "type" => "message", "role" => "assistant",
                                            "model" => "claude-haiku-5-5",
                                            "content" => [{ "type" => "text", "text" => "ok" }],
                                            "stop_reason" => "end_turn",
                                            "usage" => { "input_tokens" => 1, "output_tokens" => 1 }))

      with_env("ANTHROPIC_API_KEY" => "sk-wiring-spec") do
        wire_hosted
        hosted.provider.complete(ask("what is 2 + 2?"))
      end

      expect(sent).to have_been_requested.once
    end

    it "refuses a value only the repository's history holds, enumerating that history once for the chat",
       :seam do
      leaked = "history-only-secret-value-31"
      SeedRepo.git(project_dir, "init", "-q")
      SeedRepo.git(project_dir, "config", "user.email", "test@example.com")
      SeedRepo.git(project_dir, "config", "user.name", "Test")
      File.write(File.join(project_dir, ".env"), "SERVICE_TOKEN=#{leaked}\n")
      SeedRepo.git(project_dir, "add", ".env")
      SeedRepo.git(project_dir, "commit", "-q", "-m", "leak")
      SeedRepo.git(project_dir, "rm", "-q", ".env")
      SeedRepo.git(project_dir, "commit", "-q", "-m", "unleak")
      enumerations = []
      allow(Lain::Shell::Out).to receive(:new).and_wrap_original do |original, *argv, **opts|
        enumerations << argv if argv.include?("rev-list")
        original.call(*argv, **opts)
      end
      sent = stub_request(:post, messages_url)

      wire_hosted
      provider = chat_provider
      2.times do
        expect { provider.complete(ask("the old token was #{leaked}")) }
          .to raise_error(Lain::Provider::HTTP::EgressGuard::Refused, /known secret/)
      end

      expect(sent).not_to have_been_requested
      expect(enumerations.size).to eq(1)
    end

    it "binds the backend's literals to the board's own history" do
      wire_hosted

      board = wiring.instance_variable_get(:@switchboard)
      source = hosted.egress_literals.instance_variable_get(:@source)
      expect(source.history).to be(board.guard_inputs.secrets.history)
      expect(source.child_env).to be(board.guard_inputs.secrets.child_env)
    end

    it "attaches the backend to the board it builds, so a second board is refused" do
      wire_hosted

      board = wiring.instance_variable_get(:@switchboard)
      other = Struct.new(:guard_inputs, :approvals).new(board.guard_inputs, board.approvals)
      expect { hosted.attach(other, channel) }.to raise_error(Lain::CLI::Backend::Rebound)
      expect { hosted.attach(board, channel, spend: hosted.attachment.spend) }.not_to raise_error
    end

    it "parks no egress decision when supervision was not asked for", :seam do
      sent = stub_request(:post, messages_url).to_return(status: 200, headers: { "Content-Type" => "application/json" },
                                                         body: JSON.generate(reply))

      with_env("ANTHROPIC_API_KEY" => "sk-wiring-spec") do
        wire_hosted
        hosted.provider.complete(ask("what is 2 + 2?"))
      end

      expect(sent).to have_been_requested.once
      expect(journal.events.grep(Lain::Telemetry::AwaitingHuman)).to be_empty
    end

    it "sends a secret once a human releases it through the board's read path", :seam do
      secret = "kJ8fQ2mZ4vX7pL0aB3nR6yT9uW1cE5dG8hK2jM4qS7vY0zA3"
      SeedRepo.git(project_dir, "init", "-q")
      path = File.join(project_dir, ".env").tap { File.write(_1, "API_KEY=#{secret}\n") }
      sent = stub_request(:post, messages_url).to_return(status: 200, headers: { "Content-Type" => "application/json" },
                                                         body: JSON.generate(reply))
      wire_hosted
      board = wiring.instance_variable_get(:@switchboard)
      before = sending(secret)

      read = Sync do |task|
        answerer = task.async { loop { board.approvals.dequeue.approve(surface: "spec", authority: :human) } }
        session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: project_dir, env: {}))
        dispatch_call("read_file", { "path" => path }, toolset: board.toolset,
                                                       layers: Lain::CLI::ToolGuard.stack(chronicle, board).to_a,
                                                       context: session).tap { answerer.stop }
      end
      after = sending("the key is #{secret}")

      expect([before, read.content.include?(secret), after]).to eq([:refused, true, :sent])
      expect(sent).to have_been_requested.once
      expect(journal.events.filter_map { _1.to_journal["type"] if _1.respond_to?(:to_journal) })
        .to include("egress_refused", "read_released")
    end

    def sending(text)
      chat_provider.complete(ask(text))
      :sent
    rescue Lain::Provider::HTTP::EgressGuard::Refused
      :refused
    end

    def reply
      { "id" => "m", "type" => "message", "role" => "assistant", "model" => "claude-haiku-5-5",
        "content" => [{ "type" => "text", "text" => "ok" }], "stop_reason" => "end_turn",
        "usage" => { "input_tokens" => 1, "output_tokens" => 1 } }
    end

    describe "the secret oracle's provider", :seam do
      let(:wiring) { new_wiring(options: { grace: 5, secret_oracle: "local" }, chronicle:, status_feed:) }
      let(:token) { "0123456789abcdef0123456789abcdef" }

      it "refuses a lent value in the cloud tier's question before it reaches the gateway" do
        lent = "db-password-24-bytes-xyz"
        stub_request(:get,
                     %r{\Ahttp://127\.0\.0\.1:4000#{Lain::Gateway::IDENTITY_PATH}\?nonce=}o).to_return do |request|
          nonce = URI.decode_www_form(URI(request.uri.to_s).query).assoc("nonce").last
          { status: 200, body: JSON.generate("proof" => OpenSSL::HMAC.hexdigest("SHA256", token, nonce),
                                             "paths" => ["/api/chat"]) }
        end
        asked = stub_request(:post, "http://127.0.0.1:4000/api/chat")
        with_env("DB_PASSWORD" => lent, "XDG_STATE_HOME" => File.join(project_dir, "state")) do
          Lain::Gateway::TokenFile.for(4000).write(token)
          cloud = new_wiring(options: { grace: 5, secret_oracle: "cloud", secret_oracle_model: "glm-5.3:cloud",
                                        gateway: "http://127.0.0.1:4000" }, chronicle:, status_feed:)
          recorder, session = cloud.run_state(nil)
          cloud.wire_agent(channel:, recorder:, session:, backend:)
          oracle = cloud.secret_surface(backend).instance_variable_get(:@oracle)

          expect { oracle.ask(path: "\"/home/user/#{lent}\"", tool: "read_file", region_count: "0") }
            .to raise_error(Lain::Provider::HTTP::EgressGuard::Refused, /known secret/)
        end
        expect(asked).not_to have_been_requested
      end
    end

    %w[oracle all].each do |scope|
      describe "under --supervise-egress #{scope}", :seam do
        let(:wiring) { new_wiring(options: { grace: 5, secret_oracle: "local" }, chronicle:, status_feed:) }
        let(:hosted) do
          with_env("ANTHROPIC_API_KEY" => "sk-wiring-spec") do
            Lain::CLI::Backend.new({ provider: "anthropic", model: "claude-haiku-5-5", max_tokens: 64,
                                     supervise_egress: scope }, root: backend_root)
          end
        end

        def egress_pendings = journal.events.grep(Lain::Telemetry::AwaitingHuman).select { _1.tool == "egress" }

        it "parks the secret oracle's request for the human, and sends nothing it denies" do
          judged = stub_request(:post, "http://localhost:11434/api/chat")
          wire_hosted
          oracle = wiring.secret_surface(hosted).instance_variable_get(:@oracle)

          Sync do |task|
            task.with_timeout(20) do
              asking = task.async do
                oracle.ask(path: '"/repo/.env"', tool: "read_file", region_count: "1")
              rescue Lain::Provider::HTTP::EgressGuard::Refused => e
                e
              end
              parked = wiring.approvals.dequeue
              expect(parked.ask_face).to include("secret_oracle sends")
              parked.deny(surface: "spec", authority: :human)
              expect(asking.wait.message).to include("egress denied")
            end
          end

          expect(egress_pendings.map(&:requester)).to eq(["secret_oracle"])
          expect(judged).not_to have_been_requested
        end

        # Under all the chat's request parks too, which the examples below pin.
        if scope == "oracle"
          it "sends the chat's own request without asking" do
            sent = stub_request(:post, messages_url)
                   .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                              body: JSON.generate(reply))

            wire_hosted
            chat_provider.complete(ask("what is 2 + 2?"))

            expect(sent).to have_been_requested.once
            expect(egress_pendings).to be_empty
          end
        end
      end
    end

    describe "under --supervise-egress all", :seam do
      let(:hosted) do
        with_env("ANTHROPIC_API_KEY" => "sk-wiring-spec") do
          Lain::CLI::Backend.new({ provider: "anthropic", model: "claude-haiku-5-5", max_tokens: 64,
                                   supervise_egress: "all" }, root: backend_root)
        end
      end

      def egress_pendings = journal.events.grep(Lain::Telemetry::AwaitingHuman).select { _1.tool == "egress" }

      it "journals the egress decision before any request, and sends exactly one once the human approves" do
        sent = stub_request(:post, messages_url)
               .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: JSON.generate(reply))
        wire_hosted
        provider = chat_provider

        Sync do |task|
          task.with_timeout(20) do
            sending = task.async { provider.complete(ask("what is 2 + 2?")) }
            pending = wiring.approvals.dequeue
            expect(egress_pendings.size).to eq(1)
            expect(sent).not_to have_been_requested
            pending.approve(surface: "spec", authority: :human)
            sending.wait
          end
        end

        expect(sent).to have_been_requested.once
      end

      it "sends nothing the human denies, and the call fails naming the denial" do
        sent = stub_request(:post, messages_url)
        wire_hosted
        provider = chat_provider

        Sync do |task|
          task.with_timeout(20) do
            sending = task.async do
              provider.complete(ask("what is 2 + 2?"))
            rescue Lain::Provider::HTTP::EgressGuard::Refused => e
              e
            end
            wiring.approvals.dequeue.deny(surface: "spec", authority: :human)
            expect(sending.wait.message).to include("egress denied")
          end
        end

        expect(sent).not_to have_been_requested
      end

      it "refuses without waiting when no human is attached, naming the flag" do
        sent = stub_request(:post, messages_url)
        headless = new_wiring(options: { grace: 5, non_interactive: true }, chronicle:, status_feed:)
        recorder, session = headless.run_state(nil)
        with_env("ANTHROPIC_API_KEY" => "sk-wiring-spec") do
          headless.wire_agent(channel:, recorder:, session:, backend: hosted)
        end

        expect { chat_provider.complete(ask("what is 2 + 2?")) }
          .to raise_error(Lain::Provider::HTTP::EgressGuard::Refused, /--supervise-egress/)
        expect(sent).not_to have_been_requested
      end
    end
  end

  # The flip a real Wiring's board journals, onto the run's own record.
  describe "a mode flip's journaled record" do
    let(:journal) { RecordingChannel.new }
    # See the note on wiring_spec's other recording examples: Chronicle#spool
    # derives the WAL path by pure string manipulation, and a Provider::Mock
    # run never writes a frame.
    let(:chronicle) { Lain::CLI::Chronicle.new(journal:, journal_path: "t1-modeswitch-spec-fake-session.ndjson") }

    def mode_switches = journal.events.grep(Lain::Telemetry::ModeSwitch)

    it "carries both axes on each side, and a gate flip beside it naming the ladder applied" do
      wire_agent
      board = wiring.instance_variable_get(:@switchboard)

      board.mode_switch.switch(Lain::Mode.new(approval: :bypass), surface: "spec")

      flip = mode_switches.last
      expect(flip.to_h.slice(:from_scope, :from_approval, :to_scope, :to_approval))
        .to eq(from_scope: "checkout", from_approval: "ask", to_scope: "checkout", to_approval: "bypass")
      expect(journal.events.grep(Lain::Telemetry::PolicySwitch).map(&:to)).to eq(["bypass"])
    end
  end

  # The tool-phase guard was constructed bare (`RefuseSecretWrites.new`
  # with no `journal:`), so a live credential-shaped refusal journaled to
  # `Channel::Null` and left no record while every other mount of this
  # middleware (consolidation.rb, improve.rb, run_recorder.rb) passes one.
  describe "the secret-write guard's journal wiring", :seam do
    # A tool turn primes the shadow snapshot store, which
    # lives under the state home -- so this chat gets a throwaway one.
    around do |example|
      Dir.mktmpdir("lain-wiring-state") do |state|
        @state = state
        example.run
      end
    end

    def credential_tool_use
      { "type" => "tool_use", "id" => "tu_1", "name" => "memory_write",
        "input" => { "id" => "creds", "description" => "oops", "body" => "sk-#{"a" * 20}" } }
    end

    let(:wiring) do
      described_class.new(options: { grace: 5 }, chronicle:, status_feed:,
                          paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => @state, "HOME" => @state }),
                          project: throwaway_project(@state))
    end
    let(:backend_root) { @state }
    let(:credential_provider) do
      Lain::Provider::Mock.new(responses: [
                                 Lain::Response.new(content: [credential_tool_use], stop_reason: :tool_use),
                                 Lain::Response.new(content: [{ "type" => "text", "text" => "settled" }],
                                                    stop_reason: :end_turn)
                               ])
    end
    let(:backend) do
      offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: credential_provider)
    end

    def build_agent_and_recorder
      recorder, session = wiring.run_state(nil)
      [wiring.wire_agent(channel:, recorder:, session:, backend:), recorder]
    end

    context "when the wired chat journal is capturing" do
      let(:journal) { RecordingChannel.new }
      # journal_path: a bogus-but-harmless NDJSON name -- Chronicle#spool
      # derives the WAL path from it via pure string manipulation
      # (Paths.wal_for) and ResponseWal opens its file lazily on the first
      # frame, which a Provider::Mock-backed run never writes.
      let(:chronicle) { Lain::CLI::Chronicle.new(journal:, journal_path: "b1-spec-fake-session.ndjson") }

      it "records a WriteRefused naming the matched pattern when a credential-shaped memory_write is refused" do
        agent, = build_agent_and_recorder
        agent.ask("please remember this credential")

        refusal = journal.events.find { |event| event.is_a?(Lain::Telemetry::WriteRefused) }
        expect(refusal).not_to be_nil
        expect(refusal.pattern).to eq("openai-style api key")
      end
    end

    context "when the chat started with --no-journal" do
      let(:chronicle) { Lain::CLI::Chronicle::Null.new }

      it "still refuses a credential-shaped memory_write, and nothing raises" do
        agent, recorder = build_agent_and_recorder

        expect { agent.ask("please remember this credential") }.not_to raise_error
        expect { recorder.fetch("creds") }.to raise_error(Lain::Memory::Index::UnknownId)
      end
    end
  end

  # The guard's `oracle:` seam sat on its NullOracle in the live chat, so
  # the memory-save gate judged nothing there. Wiring it in composes the two
  # distinct findings: a credential is a PATTERN hit, a contentless save is
  # the oracle's DECLINE, and they must stay distinguishable in the journal.
  describe "the secret-write guard's oracle wiring", :seam do
    # The same throwaway state home, for the same shadow snapshot store.
    around do |example|
      Dir.mktmpdir("lain-wiring-state") do |state|
        @state = state
        example.run
      end
    end

    let(:wiring) do
      described_class.new(options: { grace: 5 }, chronicle:, status_feed:,
                          paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => @state, "HOME" => @state }),
                          project: throwaway_project(@state))
    end
    let(:backend_root) { @state }
    let(:journal) { RecordingChannel.new }
    # See the note above on journal_path: pure string manipulation derives the
    # WAL path, and a Provider::Mock run never writes a frame.
    let(:chronicle) { Lain::CLI::Chronicle.new(journal:, journal_path: "b4-spec-fake-session.ndjson") }
    let(:backend) do
      offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: dispatching_provider)
    end
    let(:dispatching_provider) do
      Lain::Provider::Mock.new(responses: [
                                 Lain::Response.new(content: [tool_use], stop_reason: :tool_use),
                                 Lain::Response.new(content: [{ "type" => "text", "text" => "settled" }],
                                                    stop_reason: :end_turn)
                               ])
    end

    def dispatch
      recorder, session = wiring.run_state(nil)
      agent = wiring.wire_agent(channel:, recorder:, session:, backend:)
      agent.ask("do the thing")
      [agent, recorder]
    end

    def refusals = journal.events.grep(Lain::Telemetry::WriteRefused)

    # The dispatched tool's own answer, read back off the committed timeline --
    # the only place a middleware-withheld call and a downstream one can be told
    # apart without reaching inside the stack.
    def tool_results(agent)
      agent.timeline.to_a.map(&:content).grep(Array).flatten.grep(Hash)
           .select { |block| block["type"] == "tool_result" }.map { |block| block["content"] }.join("\n")
    end

    context "with a memory_write whose body is a git commit SHA" do
      let(:sha) { "9a1b2c3d4e5f60718293a4b5c6d7e8f901234567" }
      let(:tool_use) do
        { "type" => "tool_use", "id" => "tu_1", "name" => "memory_write",
          "input" => { "id" => "head-sha", "description" => "the commit under test", "body" => sha } }
      end

      it "is not refused, and the item lands in the recorder" do
        _agent, recorder = dispatch

        expect(refusals).to be_empty
        expect(recorder.fetch("head-sha").body).to eq(sha)
      end
    end

    context "with a memory_write carrying an API-key-shaped body" do
      let(:tool_use) do
        { "type" => "tool_use", "id" => "tu_1", "name" => "memory_write",
          "input" => { "id" => "creds", "description" => "oops", "body" => "sk-#{"a" * 20}" } }
      end

      it "is refused under the pattern's name, never as the oracle's decline" do
        _agent, recorder = dispatch

        expect(refusals.map(&:pattern)).to eq(["openai-style api key"])
        expect(Lain::Middleware::RefuseSecretWrites.decline?(refusals.first.pattern)).to be(false)
        expect { recorder.fetch("creds") }.to raise_error(Lain::Memory::Index::UnknownId)
      end
    end

    context "with a memory_write whose body is blank" do
      let(:tool_use) do
        { "type" => "tool_use", "id" => "tu_1", "name" => "memory_write",
          "input" => { "id" => "nothing", "description" => "empty", "body" => "  \n\t " } }
      end

      it "is refused as the oracle's decline, under no pattern name" do
        agent, recorder = dispatch

        expect(refusals.map(&:pattern)).to eq([Lain::Middleware::RefuseSecretWrites::ORACLE_DECLINE])
        expect(Lain::Middleware::RefuseSecretWrites.decline?(refusals.first.pattern)).to be(true)
        expect(Lain::Middleware::RefuseSecretWrites::PATTERNS).not_to have_key(refusals.first.pattern)
        expect { recorder.fetch("nothing") }.to raise_error(Lain::Memory::Index::UnknownId)
        # The model-facing half: a decline must make no credential claim.
        expect(tool_results(agent)).to include("not worth writing")
        expect(tool_results(agent)).not_to include("pattern")
      end
    end

    # GUARDED_TOOLS holds improvement_write too, and its input is
    # {note, kind, evidence_digests} -- no `body`. The gate abstains there
    # (MemorySave::Gate::JUDGED_FIELD), and if it ever stops abstaining this
    # wiring refuses EVERY improvement note. The chat toolset does not carry the
    # tool, so reaching Handler::Live's unknown-tool answer is the proof the
    # guard let it through rather than withholding it.
    context "with an improvement_write, which carries no body for the gate to judge" do
      let(:tool_use) do
        { "type" => "tool_use", "id" => "tu_1", "name" => "improvement_write",
          "input" => { "note" => "the guard should not judge this", "kind" => "insight",
                       "evidence_digests" => [] } }
      end

      it "reaches downstream rather than being declined" do
        agent, = dispatch

        expect(refusals).to be_empty
        expect(tool_results(agent)).to include('no tool named "improvement_write"')
      end
    end
  end

  # A streamed tool's bytes are a VIEW, not a record. Wiring hands
  # Handler::Live a fan-out over the run's TTY Channel AND the editor's, so
  # nvim's lain://journal sees what the terminal sees -- while the durable
  # NDJSON keeps only the turn's tool_result (Tools::Bash.render_output),
  # which is where those same bytes already are.
  describe "streamed tool output on the live views", :seam do
    let(:bash_use) do
      { "type" => "tool_use", "id" => "tu_bash", "name" => "bash", "input" => { "command" => "printf hello" } }
    end
    let(:streaming_provider) do
      Lain::Provider::Mock.new(responses: [
                                 Lain::Response.new(content: [bash_use], stop_reason: :tool_use),
                                 Lain::Response.new(content: [{ "type" => "text", "text" => "settled" }],
                                                    stop_reason: :end_turn)
                               ])
    end
    let(:backend) do
      offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: streaming_provider)
    end
    # The TTY leg, recorded rather than a real SizedQueue: nothing drains it here.
    let(:channel) { RecordingChannel.new }
    let(:view_channel) { Lain::Channel::DropOldest.new }
    let(:journal) { RecordingChannel.new }
    # See the note above on journal_path: Chronicle#spool derives the WAL path by
    # pure string manipulation, and a Provider::Mock run never writes a frame.
    let(:chronicle) { Lain::CLI::Chronicle.new(journal:, journal_path: "t1-spec-fake-session.ndjson") }
    let(:views) { { channel: view_channel, socket_path: "/tmp/lain-t1-spec.sock", journal: } }
    # A throwaway state home: the bash turn primes the shadow
    # snapshot store, which lives there.
    let(:wiring) do
      described_class.new(options: { grace: 5 }, chronicle:, status_feed:,
                          paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => @state, "HOME" => @state }),
                          project: throwaway_project(@state))
    end
    let(:backend_root) { @state }

    # A bypass-approved call runs in the workspace profile, which refuses a TMPDIR holding home, as the
    # spec's TMPDIR holds this chat's.
    around do |example|
      Dir.mktmpdir("lain-wiring-state") do |state|
        @state = state
        Dir.mktmpdir("lain-wiring-tmp") { |tmp| with_env("TMPDIR" => tmp) { example.run } }
      end
    end

    # Bash is tier 3 and would otherwise park on the approval gate forever;
    # this block is about where the bytes go, not who let them run. The
    # deleted `--yolo` flag used to buy that at construction, and `auto` is the
    # approval it resolved to -- so the board is flipped there instead. It has to happen HERE, after
    # #wire_agent, because that is where Wiring builds and memoizes the board,
    # and it reaches in for it because the board is Wiring's private
    # collaborator rather than part of its surface.
    def approve_everything
      wiring.instance_variable_get(:@switchboard)
            .mode_switch.switch(Lain::Mode.new(approval: :bypass), surface: "spec")
    end

    def dispatch(attached)
      recorder, session = wiring.run_state(nil)
      agent = wiring.wire_agent(channel:, recorder:, session:, backend:, views: attached)
      approve_everything
      agent.ask("run it")
      agent
    end

    def streamed(events) = events.grep(Lain::Telemetry::ToolOutput)

    # The tool's own answer off the committed timeline -- proof the call
    # completed rather than dying inside the fan-out.
    def tool_results(agent)
      agent.timeline.to_a.map(&:content).grep(Array).flatten.grep(Hash)
           .select { |block| block["type"] == "tool_result" }.map { |block| block["content"] }.join("\n")
    end

    it "fans a bash tool's stdout onto the editor's Channel as well as the TTY's" do
      dispatch(views)

      expect(streamed(channel.events).map(&:bytes).join).to include("hello")
      expect(streamed(view_channel.drain).map { |event| [event.tool_use_id, event.stream, event.bytes] })
        .to eq([["tu_bash", :stdout, "hello"]])
    end

    it "keeps the streamed bytes off the durable record, which already carries them in the tool_result" do
      agent = dispatch(views)

      expect(streamed(journal.events)).to be_empty
      expect(tool_results(agent)).to include("hello")
    end

    it "completes the tool, and still renders to the TTY, when the editor quit and closed its Channel" do
      view_channel.close
      agent = dispatch(views)

      expect(streamed(channel.events).map(&:bytes).join).to include("hello")
      expect(tool_results(agent)).to include("hello")
    end

    it "renders to the TTY and raises nothing when no editor is attached" do
      agent = dispatch(nil)

      expect(streamed(channel.events).map(&:bytes).join).to include("hello")
      expect(tool_results(agent)).to include("hello")
    end

    describe "a command that prints a session secret" do
      let(:secret) { "hunterhunterhunter" }
      let(:bash_use) do
        { "type" => "tool_use", "id" => "tu_bash", "name" => "bash",
          "input" => { "command" => "echo #{secret}" } }
      end

      around do |example|
        ENV["LAIN_WIRING_SPEC_TOKEN"] = secret
        example.run
      ensure
        ENV.delete("LAIN_WIRING_SPEC_TOKEN")
      end

      it "masks the same bytes on the live channel as in the model's copy" do
        agent = dispatch(nil)
        shown = streamed(channel.events).map(&:bytes).join

        expect([shown, tool_results(agent)]).to all(include("<redacted:1>"))
        expect([shown, tool_results(agent)]).to all(satisfy { |text| !text.include?(secret) })
      end
    end
  end

  # Where the records a chat's collaborators write end up. The display Channel
  # renders three record types and skips the rest, so a record handed to it is
  # a record lost; these read the session record back instead.
  describe "the records a chat's collaborators write", :seam do
    let(:session_io) { StringIO.new }
    let(:session_file) { Lain::Journal.new(io: session_io) }
    let(:chronicle) { Lain::CLI::Chronicle.new(journal: session_file, journal_path: "collaborator-records-session.ndjson") }
    let(:channel) { RecordingChannel.new }
    let(:mock_provider) do
      Lain::Provider::Mock.new(responses: [tool_response(["tu_bash", "bash", { "command" => "printf hello" }]),
                                           text_response("settled")])
    end
    let(:wiring) do
      described_class.new(options: { grace: 5 }, chronicle:, status_feed:,
                          paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => @state, "HOME" => @state }),
                          project: throwaway_project(@state))
    end
    let(:backend_root) { @state }

    around do |example|
      Dir.mktmpdir("lain-wiring-records") do |state|
        @state = state
        example.run
      end
    end

    def records = journal_records(session_io)

    def of_type(type) = journal_records(session_io, type)

    # Bash is tier 3 and would park on the approval gate; the board is flipped
    # to `auto` after #wire_agent memoizes it, as the live-views group does.
    def converse(prompt)
      recorder, session = wiring.run_state(nil)
      agent = wiring.wire_agent(channel:, recorder:, session:, backend:)
      wiring.instance_variable_get(:@switchboard)
            .mode_switch.switch(Lain::Mode.new(approval: :bypass), surface: "spec")
      agent.ask(prompt)
    end

    it "lands the bash tool's arm record for that call in the session record" do
      converse("run it")

      expect(of_type("shell_arm").map { |arm| arm["tool_use_id"] }).to eq(["tu_bash"])
    end

    # A chat launched without --nvim still tees onto the status feed whenever it
    # journals. The arm record is nothing that feed folds, so it must go round
    # the tee rather than through it.
    it "lands the arm record in the file and not on the status feed a plain chat tees" do
      feed = RecordingChannel.new
      Lain::CLI::LiveViews.new(options: { journal: true }, chronicle:, status_feed: feed,
                               agent_states: Lain::AgentStates::Tracker.new(clock: Lain::RunClock.new))

      converse("run it")

      expect(of_type("shell_arm").size).to eq(1)
      expect(feed.events.grep(Lain::Telemetry::ShellArm)).to be_empty
    end

    context "when the model spawns a one-shot subagent" do
      let(:mock_provider) do
        spawn_call = ["s1", "subagent", { "prompt" => "look around", "role" => "researcher" }]
        Lain::Provider::Mock.new(responses: [tool_response(spawn_call),
                                             text_response("child done"), text_response("parent done")])
      end

      def child_digests = of_type("child_turn").map { |turn| turn["digest"] }

      # The chat spawns on its first iteration of 25, and its researcher still
      # gets the 60 its role asks.
      context "when the chat's child asks for more iterations than the chat has left" do
        let(:mock_provider) do
          reads = Array.new(60) { |i| tool_response(["c#{i}", "read_file", { "path" => "missing-#{i}.txt" }]) }
          spawn_call = ["s1", "subagent", { "prompt" => "look around", "role" => "researcher" }]
          Lain::Provider::Mock.new(responses: [tool_response(spawn_call),
                                               *reads, text_response("parent done")])
        end

        it "holds the chat's child to its role's own iterations" do
          recorder, session = wiring.run_state(nil)
          agent = wiring.wire_agent(channel:, recorder:, session:, backend:)
          wiring.instance_variable_get(:@switchboard)
                .mode_switch.switch(Lain::Mode.new(approval: :bypass), surface: "spec")
          agent.ask("look around")
          spawned = agent.timeline.to_a.flat_map { |event| Array(event.content) }
                         .find { |block| block["type"] == "tool_result" && block["tool_use_id"] == "s1" }

          expect(spawned["content"]).to start_with("loop ran 60 iterations, ceiling is 60")
        end
      end

      context "when the parent and its child both pay" do
        let(:mock_provider) do
          spawn_call = ["s1", "subagent", { "prompt" => "look around", "role" => "researcher" }]
          Lain::Provider::Mock.new(responses: [
                                     tool_response(spawn_call,
                                                   usage: Lain::Usage.new(input_tokens: 20)),
                                     text_response("child done", usage: Lain::Usage.new(input_tokens: 700)),
                                     text_response("parent done", usage: Lain::Usage.new(input_tokens: 5))
                                   ])
        end

        it "reports the child's spend through the chat's own session_usage tool" do
          recorder, session = wiring.run_state(nil)
          agent = wiring.wire_agent(channel:, recorder:, session:, backend:)
          wiring.instance_variable_get(:@switchboard)
                .mode_switch.switch(Lain::Mode.new(approval: :bypass), surface: "spec")
          agent.ask("look around")

          expect(agent.toolset.fetch("session_usage").call({}, nil).content).to include("  total: 725")
        end

        it "shows a live run: equal to the run: rebuilt from the session file, the child's spend included" do
          feed = Lain::StatusFeed.new(path: File.join(@state, "status.json"))
          Lain::CLI::LiveViews.new(options: { journal: true }, chronicle:, status_feed: feed,
                                   agent_states: Lain::AgentStates::Tracker.new(clock: Lain::RunClock.new))

          converse("look around")
          rebuilt = of_type("turn_usage").sum do |usage|
            Lain::StatusFeed::JournaledUsage.new(usage["usage"]).total_tokens
          end

          expect([rebuilt, feed.observed["run_tokens"]]).to eq([725, 725])
        end
      end

      # A child's payment names its spawn, so salvage and cache waste pair
      # only the parent's own with the parent's requests, while the ledger can
      # still price the child's turns from the one file.
      it "writes a child's turn_usage naming its spawn beside the parent's own" do
        converse("look around")
        own, childs = of_type("turn_usage").partition { |usage| usage["spawn"].nil? }

        expect([child_digests, own, childs]).to all(be_present)
        expect(own.map { |usage| usage["digest"] })
          .to match_array(of_type("turn").select { |turn| turn["role"] == "assistant" }.map { |turn| turn["digest"] })
        expect(child_digests).to include(*childs.map { |usage| usage["digest"] })
        expect(childs.map { |usage| usage["spawn"] }.uniq).to contain_exactly(a_string_starting_with("blake3:"))
        expect(of_type("request_sent").size).to eq(own.size)
      end
    end
  end

  describe "which files a chat counts as fresh", :seam do
    let(:session_io) { StringIO.new }
    let(:chronicle) do
      Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io: session_io), journal_path: "fresh-session.ndjson")
    end
    let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => @state, "HOME" => @state }) }
    let(:wiring) do
      described_class.new(options: { grace: 5 }, chronicle:, status_feed:, paths:, project: throwaway_project(@state))
    end
    let(:backend_root) { @state }
    let(:cat) { File.join(@state, "bin", "cat") }
    let(:mock_provider) do
      write = ["tu_write", "write_file", { "path" => cat, "content" => "x" }]
      bash = ["tu_bash", "bash", { "command" => "printf hi" }]
      Lain::Provider::Mock.new(responses: [tool_response(write), tool_response(bash), text_response("settled")])
    end

    around do |example|
      Dir.mktmpdir("lain-wiring-fresh") do |state|
        @state = File.realpath(state)
        FileUtils.mkdir_p(File.join(@state, "bin"))
        example.run
      end
    end

    def fresh = wiring.instance_variable_get(:@observers).fresh

    def converse(prompt, resumed: nil)
      recorder, session = wiring.run_state(resumed)
      agent = wiring.wire_agent(channel:, recorder:, session:, backend:, resumed:)
      wiring.instance_variable_get(:@switchboard)
            .mode_switch.switch(Lain::Mode.new(approval: :bypass), surface: "spec")
      agent.ask(prompt)
    end

    # The lineage starts after every file here, so only a write record can
    # make one fresh.
    context "when the chat resumes a lineage of 2 session files" do
      let(:old) { File.join(@state, "old.sh").tap { |path| File.write(path, "") } }
      let(:untouched) { File.join(@state, "untouched.sh").tap { |path| File.write(path, "") } }

      def session_file(name, *records, resumed_from: nil)
        header = { "ts" => "2099-01-01T00:00:00.000000Z", "type" => "session", "resumed_from" => resumed_from }
        File.write(File.join(paths.filing_dir(root: @state), name),
                   [header.compact, *records].map { |record| "#{JSON.generate(record)}\n" }.join)
      end

      # The same basename under the process's own working directory, with a
      # chain that cannot be walked: a lineage read from there answers every
      # path fresh.
      def decoy(name)
        File.write(File.join(paths.sessions_dir, name),
                   "#{JSON.generate("ts" => "2099-01-01T00:00:00.000000Z", "type" => "session",
                                    "resumed_from" => { "file" => "missing.ndjson" })}\n")
      end

      def resumed
        written = Lain::Telemetry::FileWritten.from_stat(File.stat(old), path: old, tool_use_id: "tu_0")
        session_file("first.ndjson", written.to_journal)
        session_file("second.ndjson", resumed_from: { "file" => "first.ndjson" })
        Lain::CLI::Resume::Result.new(file: "second.ndjson",
                                      timeline: Lain::Dag::Factory.timeline(head_digest: nil, store: Lain::Dag::Factory.store),
                                      session: Lain::Session.new, open: false, notices: [],
                                      recorder: Lain::Memory::Recorder.new(index: Lain::Memory::Index.empty))
      end

      it "reads the lineage from the project's directory, not the process's" do
        decoy("second.ndjson")
        converse("plant it", resumed:)

        expect([old, untouched, cat].map { |path| fresh.fresh?(path) }).to eq([true, false, true])
      end

      it "remembers the first file's write, and folds this session's own" do
        converse("plant it", resumed:)

        expect([old, untouched, cat].map { |path| fresh.fresh?(path) }).to eq([true, false, true])
      end

      context "when the chat started with --no-journal" do
        let(:chronicle) { Lain::CLI::Chronicle::Null.new }

        it "still folds this session's own write" do
          converse("plant it", resumed:)

          expect([untouched, cat].map { |path| fresh.fresh?(path) }).to eq([false, true])
        end
      end
    end
  end

  # The model phase's translator for a prompt the provider refused whole is
  # composed HERE, beside the turn phase's window refresh, and not inside the
  # chronicle's instrumentation: under --no-journal the chronicle has no model
  # stack at all, and a refused prompt is no less refused for going unrecorded.
  describe "the request budget a chat's model phase opens with" do
    # Ollama's own refusal, raised the way the provider raises it, for any
    # prompt carrying the marker.
    let(:refusing_provider) do
      Class.new(Lain::Provider::Mock) do
        def context_window_tokens(_model) = 32_768

        def complete(request, **)
          if JSON.generate(request.messages).include?("DOES-NOT-FIT")
            @requests << request
            raise Lain::Provider::Ollama::WindowExceededError.new(
              "request (80000 tokens) exceeds the available context size (32768 tokens)",
              prompt_tokens: 80_000, window_tokens: 32_768, source: "ollama", status: 400
            )
          end

          super
        end
      end.new(responses: [Lain::Response.new(content: [{ "type" => "text", "text" => "settled" }],
                                             stop_reason: :end_turn)])
    end

    let(:served_backend) do
      offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: refusing_provider)
    end

    def asker(over: chronicle)
      wired = new_wiring(options: { grace: 5 }, chronicle: over, status_feed:)
      recorder, session = wired.run_state(nil)
      agent = wired.wire_agent(channel:, recorder:, session:, backend: served_backend)
      Lain::CLI::Repl::Ask.new(agent:, tty: nil, chronicle: over)
    end

    context "when the chat started with --no-journal" do
      it "ends the ask with the refusal naming the provider's numbers, and answers the next prompt" do
        ask = asker

        outcome = ask.attempt("DOES-NOT-FIT")

        expect(outcome).to be_a(Lain::Middleware::RequestBudget::OverWindow)
        expect(outcome.message).to include("80000", "32768", "/rewind")
        expect(ask.attempt("ping").text).to eq("settled")
        expect(refusing_provider.call_count).to eq(2)
      end
    end

    context "when the chat is journaling" do
      let(:journal_io) { StringIO.new }
      let(:recording) do
        Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io: journal_io), journal_path: "budget-spec.ndjson")
      end

      def journaled(type)
        journal_records(journal_io, type)
      end

      it "records the refusal in the session record with the provider's exact figures" do
        asker(over: recording).attempt("DOES-NOT-FIT")

        expect(journaled("window_pressure"))
          .to contain_exactly(include("kind" => "over_window", "source" => "ollama", "prompt_tokens" => 80_000,
                                      "window_tokens" => 32_768))
      end
    end
  end

  describe "the prefix chain a journaling chat records" do
    let(:chatty_provider) do
      Lain::Provider::Mock.new(responses: Array.new(11) do |i|
        Lain::Response.new(content: [{ "type" => "text", "text" => "reply #{i}" }], stop_reason: :end_turn)
      end)
    end
    let(:chatty_backend) do
      offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: chatty_provider,
                                                                                    root: backend_root)
    end
    let(:recording) do
      Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io: StringIO.new), journal_path: "prefix-chain-spec.ndjson")
    end

    it "digests only the messages a later turn added" do
      wired = new_wiring(options: { grace: 5 }, chronicle: recording, status_feed:)
      recorder, session = wired.run_state(nil)
      agent = wired.wire_agent(channel:, recorder:, session:, backend: chatty_backend)
      10.times { |i| agent.ask("turn #{i}") }

      spent = digests_during { agent.ask("turn 10") }
      added = chatty_provider.requests[10].messages.size - chatty_provider.requests[9].messages.size
      expect(spent).to be <= added + 4
    end
  end

  # The assembly, and the point the whole chunk converges on. A plain `lain
  # chat` compacts, which means the Agent gets three things Wiring never passed
  # before: the run's per-turn Context source, the eager-summary observer its
  # ToolRunner fires through, and a journal that TEES turn_usage to that source
  # -- `context_for`'s `usage:` is a plain Integer, while {Lain::Compaction::Cold}
  # needs a {Lain::Telemetry::TurnUsage}'s cache-read count and the render seam
  # has no route to it.
  describe "the compaction mount" do
    require "tmpdir"

    let(:summary_text) { "EAGER-SUMMARY-OF-THE-BIG-RESULT" }
    let(:big_file) { File.join(@dir, "big.txt") }

    # Only the two network edges are doubled: the chat provider and the eager
    # tier. The Eager itself, the observer, the snapshot, the scheduler and the
    # render are the real wiring under test.
    let(:summarizing_backend_class) do
      Class.new(Lain::CLI::Backend) do
        def initialize(options, mock:, oracle:, root: Dir.pwd)
          super(options, root:)
          @mock = mock
          @oracle = oracle
        end

        def provider(**) = @mock

        def eager = @eager ||= Lain::Oracle::Eager.new(oracle: @oracle)
      end
    end

    let(:reading_provider) do
      Lain::Provider::Mock.new(responses: [
                                 Lain::Response.new(content: [read_use], stop_reason: :tool_use),
                                 Lain::Response.new(content: [{ "type" => "text", "text" => "settled" }],
                                                    stop_reason: :end_turn)
                               ])
    end

    let(:read_use) do
      { "type" => "tool_use", "id" => "tu_1", "name" => "read_file", "input" => { "path" => big_file } }
    end

    # compact_keep 1 + compact_bytes 1 puts every turn past the byte threshold,
    # so what decides is TIMING -- and Provider::Mock's NO_CACHING profile makes
    # the first turn_usage confirm the cache cold, which is only true if the
    # source is actually on the journal's sink list.
    let(:compaction_options) { { provider: "ollama", model: nil, max_tokens: 64, compact_keep: 1, compact_bytes: 1 } }

    let(:backend) do
      summarizing_backend_class.new(compaction_options, mock: reading_provider,
                                                        oracle: WiringSpecSummarizer.new(summary_text),
                                                        root: backend_root)
    end

    let(:journal) { RecordingChannel.new }
    let(:chronicle) { Lain::CLI::Chronicle.new(journal:, journal_path: "a8-spec-fake-session.ndjson") }
    # The read turn primes the shadow snapshot store, which lives
    # under the state home -- this example's own tmpdir, not the developer's.
    let(:wiring) do
      described_class.new(options: { grace: 5 }, chronicle:, status_feed:,
                          paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => @dir, "HOME" => @dir }),
                          project: throwaway_project(@dir))
    end
    let(:backend_root) { @dir }

    around do |example|
      Dir.mktmpdir do |dir|
        @dir = dir
        File.write(File.join(dir, "big.txt"), "the quick brown fox jumped over the lazy dog. " * 140)
        example.run
      end
    end

    # A bounded spin, never a synchronization: the fire resolves on its own
    # fiber and the timeout turns "it never did" into a report instead of a hang.
    def settle(task, eager, digest)
      task.with_timeout(1) { task.sleep(0.001) while eager.held(digest).nil? }
    end

    # Read off the Agent rather than re-asked of the Backend: `#pipeline_source`
    # binds its journal on the FIRST call and now refuses a differing second
    # one, so a spec that re-asked with different arguments would be exercising
    # a wiring the run never performs. Through the Agent's one
    # {Lain::Agent::Instrumentation} -- `fetch`, not `dig`, so a
    # renamed ivar is a KeyError here and never a silent nil.
    def source_of(agent) = instrumentation_of(agent).pipeline_source

    def instrumentation_of(agent)
      agent.instance_variables.include?(:@instrumentation) or
        raise KeyError, "the Agent no longer carries @instrumentation: this seam needs updating"

      agent.instance_variable_get(:@instrumentation)
    end

    def decisions = journal.events.grep(Lain::Compaction::Source::CompactionDecision)

    # Two asks, because the head a compaction can profitably drop only exists
    # once the first turn's big tool_result is behind the trailing window: the
    # opening exchange alone is small enough that Source#shrinks? refuses the
    # rewrite. The settle between them is what makes the eager fire observable.
    def converse(agent, eager_fires: true)
      Sync do |task|
        agent.ask("read it")
        settle(task, backend.eager, Lain::Canonical.digest(File.read(big_file))) if eager_fires
        agent.ask("now summarize what you saw")
      end
    end

    # ONE Eager, reached from both ends: the observer fires into it and the
    # source snapshots it. Two instances would mean every fire landed somewhere
    # no render reads, with `hits` reporting an honest, useless zero.
    it "hands the Agent the run's ONE source and its ONE summary observer" do
      agent = wire_agent

      expect(source_of(agent)).to be_a(Lain::Compaction::Source)
      expect(agent.send(:tool_runner).instance_variable_get(:@observer)).to be(backend.tool_observer)
      expect(backend.tool_observer.eager).to be(backend.eager)
      expect(source_of(agent).eager).to be(backend.eager)
    end

    # Without the tee `Cold` is never fed, the `:cold` decision path is dead on
    # the live path, and every compaction journals `cache_state: forced` -- a
    # bench arm that measures nothing.
    it "tees turn_usage to the source, so a zero cache-read confirms the cache cold", :seam do
      agent = wire_agent
      cold = source_of(agent).instance_variable_get(:@cold)
      expect(cold).not_to be_cold

      Sync { agent.ask("read it") }

      expect(cold).to be_cold
      # Provider::Mock carries NO_CACHING, so there is no TTL for an idle mark
      # to compare against and each zero cache-read confirms on its own -- one
      # per model round trip, and a tool-use turn makes two.
      confirmations = journal.events.grep(Lain::Compaction::Cold::CacheColdConfirmed)
      expect(confirmations.map(&:reason).uniq).to eq([:signal_only])
    end

    # The live chat Context is deliberately NOT Ractor-shareable -- /model's
    # slot is mutable by design (model_switch.rb:20-22) -- so the composed
    # per-turn pipeline has to be built from a flattened twin. Without that,
    # EVERY compacting turn of every real chat raises Ractor::IsolationError out
    # of Scheduler::COMPOSE, and no spec holding a plain Context can see it.
    it "compacts a Context carrying the live /model slot, which is not shareable", :seam do
      agent = wire_agent
      expect(agent.context).not_to be_deeply_frozen

      expect { converse(agent) }.not_to raise_error

      expect(decisions.map(&:compacted)).to include(true)
    end

    # End to end: a tool result is offered to the summarizer, the
    # post-dispatch observer fires a summary into the run's Eager, and the next
    # render -- which compacts, because the cache is cold -- carries the FIRED
    # TEXT where an unwired run would carry an elision line.
    it "renders the summary a tool dispatch fired, not an elision line", :seam do
      converse(wire_agent)

      rendered = Lain::Canonical.dump(reading_provider.last_request.messages)

      expect(rendered).to include(summary_text)
      # The dropped bytes are really gone -- the summary replaced them rather
      # than riding alongside. (The turn's other blocks -- a plain text turn, a
      # tool_use -- still carry ELIDED lines: nothing is summarizable there, and
      # attesting them is the invariant, not a miss.)
      expect(rendered).not_to include("the quick brown fox jumped over the lazy dog. " * 5)
      expect(decisions.map(&:compacted)).to include(true)
      expect(decisions.map(&:summary_hits).max).to be >= 1
    end

    # The live half of the review's cost-honesty fix. This run's model is
    # Ollama's local default, which Backend::COMPACTION_PRICES prices at zero
    # -- so the accounting reads "$0.0", and WITHOUT the model beside it that
    # is indistinguishable on the record from a compaction that genuinely cost
    # nothing. It is also what a reader needs to spot a `/model` switch: this
    # names the tier the estimate was priced against, TurnUsage names the tier
    # that answered, and after a switch they differ.
    it "journals the model its zero cost figures are quoted in", :seam do
      converse(wire_agent)

      accounting = journal.events.grep(Lain::Telemetry::Compaction)
      expect(accounting).not_to be_empty
      expect(accounting.map(&:model).uniq).to eq([Lain::Provider::Ollama::DEFAULT_MODEL])
      expect(accounting.map(&:cost_saved).uniq).to eq(["0.0"])
    end

    # The control arm, on the SAME live path the flagged run below takes. The
    # flagged example alone would leave the default run's record free to carry
    # nil -- and nil is the one value {Lain::Telemetry::Compaction} reserves for
    # a journal written before this field existed, so a bench reading it would
    # drop the control arm's rows rather than compare against them. This
    # describe's own `compaction_options` set no `--compact-strategy`, which is
    # what makes this an unflagged launch and not a contrived one.
    it "journals the eager control arm on a run that named no strategy at all", :seam do
      converse(wire_agent)

      accounting = journal.events.grep(Lain::Telemetry::Compaction)
      expect(accounting).not_to be_empty
      expect(accounting.map(&:collapse_strategy).uniq).to eq([Lain::Telemetry::Compaction::EAGER_CONTROL_ARM])
    end

    # End to end, and the only place the whole thread is real: the flag is
    # parsed here, {Lain::CLI::Backend::SpanSummarizer} resolves it, the Source
    # carries the operator's word, and the Scheduler -- handed a pipeline, able
    # to name no policy behind it -- journals that word on every compaction. It
    # is what lets a bench group `bytes_before - bytes_after` by arm with no
    # launch command to hand.
    context "with --compact-strategy", :seam do
      let(:compaction_options) { super().merge(compact_strategy: "elide-tools") }

      it "journals the arm the operator named on every compaction it performs" do
        converse(wire_agent, eager_fires: false)

        accounting = journal.events.grep(Lain::Telemetry::Compaction)
        expect(accounting).not_to be_empty
        expect(accounting.map(&:collapse_strategy).uniq).to eq(["elide-tools"])
      end
    end

    context "with --no-compact", :seam do
      let(:compaction_options) { super().merge(compact: false) }

      it "leaves the Agent on the Null source, rendering exactly as an unwired chat would" do
        agent = wire_agent

        Sync { agent.ask("read it") }

        expect(source_of(agent)).to be(Lain::Agent::PipelineSource::Null)
        expect(Lain::Canonical.dump(reading_provider.last_request.messages)).not_to include(summary_text)
        expect(decisions).to be_empty
      end
    end
  end

  # `--isolation`, wired at the ONE seam the fleet leases through. The main
  # chat is deliberately NOT leased -- #run_state builds its Session on
  # {Lain::WorkerEnv.default}, because the user's own edits belong in the user's
  # own tree -- so what a leased environment reaches is an ACTOR-mode subagent,
  # adopted through this Supervisor.
  describe "the fleet's isolation backend" do
    require "fileutils"
    require "tmpdir"

    # The lease and handback records land in the session record, read back here
    # off a recording journal. The display Channel is recorded too, only so
    # nothing blocks on a SizedQueue nobody drains.
    let(:channel) { RecordingChannel.new }
    let(:record) { RecordingChannel.new }
    let(:chronicle) { Lain::CLI::Chronicle.new(journal: record, journal_path: "fleet-isolation-session.ndjson") }

    def wiring_with(isolation)
      described_class.new(options: { grace: 5, isolation: }, chronicle:, status_feed:)
    end

    # Adoption is what leases: the Supervisor acquires the worker's environment
    # and hands it to the launch block, exactly as {Lain::Tools::Subagent}'s
    # `mode: :actor` dispatch does. The supervisor's own reactor task is what an
    # actor outlives, so the adoption runs under a Sync the spec holds.
    def adopt_worker(wiring)
      recorder, session = wiring.run_state(nil)
      wiring.wire_agent(channel:, recorder:, session:, backend:)
      Sync do |task|
        wiring.supervisor.run(task)
        wiring.supervisor.adopt(role: "researcher") { |worker_env| WiringSpecWorker.new(worker_env) }
      ensure
        wiring.supervisor.stop
      end
    end

    def leases = record.events.grep(Lain::Telemetry::IsolationLease)

    # A chat started somewhere OTHER than the repo this suite runs in, so "the
    # lease names the chat's own cwd" is an assertion and not a coincidence --
    # and so no `.lain/services.rb` of the host project can decorate the backend.
    def in_throwaway_chat_dir(&block)
      Dir.mktmpdir("lain-d2-chat") { |dir| Dir.chdir(File.realpath(dir), &block) }
    end

    # ONE backend per run, and the run's two consumers share it. The fleet a
    # {Lain::Supervisor} adopts actors onto and the children a model dispatches
    # both key resources on a worker id, and both allocate from per-INSTANCE
    # state -- {Lain::Isolation::Worktree}'s `@leased` Set and Monitor serialize
    # one instance, so two backends cannot refuse each other's paths, and a
    # per-{Lain::Isolation::DbIndex} pool hands the same index out twice. The
    # declaration file is read once for the same reason
    # {Lain::CLI::IsolationBackend}'s own `#services` gives.
    #
    # Resolution count is the whole assertion available without a reader: with
    # exactly one resolved, the example below (the supervisor leasing a real
    # Worktree) and the model-dispatch example (the child leasing a real
    # Worktree) cannot be naming two different objects.
    it "resolves ONE isolation backend for the whole run, not one per consumer" do
      allow(Lain::CLI::IsolationBackend).to receive(:resolve).and_call_original

      in_throwaway_chat_dir do
        wiring = wiring_with(nil)
        recorder, session = wiring.run_state(nil)
        wiring.wire_agent(channel:, recorder:, session:, backend:)
      end

      expect(Lain::CLI::IsolationBackend).to have_received(:resolve).once
    end

    context "without an isolation option" do
      it "leases the chat's own process environment -- the shared-process default" do
        chat_cwd = nil
        worker = in_throwaway_chat_dir do |dir|
          chat_cwd = dir
          adopt_worker(wiring_with(nil))
        end

        expect(worker.session.worker_env.cwd).to eq(chat_cwd)
        expect(worker.session.worker_env.env).to eq(ENV.to_h)
      end

      # The resolver decorates BY NEED, so a run whose journal records anything
      # never holds a bare Null -- what a spec can see is the concrete backend
      # NAMED on the lease record the Journal decorator emits.
      it "resolves the shared-process backend, journalled, so the lease is on the record" do
        in_throwaway_chat_dir { adopt_worker(wiring_with(nil)) }

        expect(leases.map { |lease| [lease.kind, lease.backend] })
          .to eq([[:acquired, "Lain::Isolation::Null"], [:released, "Lain::Isolation::Null"]])
      end

      # No checkout was cut, so there is nothing to hand back -- and a handback
      # run over the chat's OWN tree would read the human's work as a worker's.
      it "runs no handback when the fleet cuts no checkout to hand back from" do
        in_throwaway_chat_dir do
          wiring = wiring_with(nil)
          recorder, session = wiring.run_state(nil)
          wiring.wire_agent(channel:, recorder:, session:, backend:)
          Sync { wiring.role_spawn.call(:dev, :fresh, "work") }
        end

        expect(record.events.grep(Lain::Telemetry::Handback)).to be_empty
      end
    end

    context "with the worktree isolation option", :seam do
      def run_git(dir, *args) = SeedRepo.git(dir, *args)

      # Copied, not rebuilt: five git subprocesses per example for a directory that
      # is identical every time (see {SeedRepo}). A method, not a constant --
      # a constant inside a top-level `RSpec.describe do ... end` lands on Object,
      # where a second spec file spelling the same name silently clobbers it.
      def seed_repo(dir) = FileUtils.cp_r("#{SeedRepo.at(seed_files)}/.", dir)

      def seed_files = { "README" => "seed\n" }

      # A throwaway repo AND a throwaway XDG_RUNTIME_DIR: the leased checkouts
      # land under the tmpdir, never the machine's real runtime dir and never the
      # lain repo this suite runs in.
      def in_throwaway_repo
        Dir.mktmpdir("lain-d2-project") do |project|
          Dir.mktmpdir("lain-d2-runtime") do |runtime|
            repo = File.realpath(project)
            seed_repo(repo)
            Dir.mktmpdir("lain-d2-state") do |state|
              xdg = { "XDG_RUNTIME_DIR" => File.realpath(runtime), "XDG_STATE_HOME" => File.realpath(state) }
              Dir.chdir(repo) { with_env(xdg) { yield repo, xdg["XDG_STATE_HOME"] } }
            end
          end
        end
      end

      it "hands the supervisor the resolved worktree backend" do
        in_throwaway_repo { adopt_worker(wiring_with("worktree")) }

        expect(leases.map(&:backend).uniq).to eq(["Lain::Isolation::Clone"])
      end

      # THROUGH THE TOOL: nothing here is doubled. The backend is the one
      # `--isolation worktree` really resolves, the tool is the one this run's
      # own ToolsetBuild built, and the spawn is a tool_use the model
      # dispatched through the parent's loop.
      #
      # A child's cwd is unobservable from outside a spawn that hands back a
      # Timeline and never an Agent, so the child asks for a RELATIVE path that
      # does not exist and `list_files` names the absolute path it resolved to.
      context "when the MODEL dispatches a subagent" do
        let(:mock_provider) do
          Lain::Provider::Mock.new(responses: [
                                     tool_response(["s1", "subagent",
                                                    { "prompt" => "look around", "role" => "researcher" }]),
                                     tool_response(["l1", "list_files", { "path" => "no-such-dir" }]),
                                     text_response("child done"),
                                     text_response("parent done")
                                   ])
        end

        def spawn_through_the_tool(wiring)
          recorder, session = wiring.run_state(nil)
          agent = wiring.wire_agent(channel:, recorder:, session:, backend:)
          Sync { agent.ask("look around") }
        end

        # The one tool_result whose content is a refusal naming an absolute
        # path: the child's `list_files` at a relative path that is nowhere.
        def child_resolved_path
          refusal = mock_provider.requests.flat_map(&:messages)
                                 .flat_map { |message| message["content"] }
                                 .grep(Hash)
                                 .find { |block| block["type"] == "tool_result" }
          refusal.fetch("content").to_s.delete_prefix("no such directory: ")
        end

        # The isolation flag places epic workers' checkouts; the chat's
        # researcher always works in a kept scratch directory of its own.
        it "leases the researcher its own scratch directory rather than the resolved worktree" do
          chat_cwd = nil
          state_dir = nil
          in_throwaway_repo do |repo, state|
            chat_cwd = repo
            state_dir = state
            spawn_through_the_tool(wiring_with("worktree"))
          end

          expect(leases.map { |lease| [lease.kind, lease.backend] })
            .to eq([[:acquired, "Lain::Isolation::Scratch"], [:kept, "Lain::Isolation::Scratch"]])
          expect(child_resolved_path).to start_with(File.join(state_dir, "lain", "research", ""))
          expect(File.basename(File.dirname(child_resolved_path))).to start_with("research-")
          expect(child_resolved_path).not_to include("/worktrees/")
          expect(child_resolved_path).not_to start_with(chat_cwd)
        end
      end

      it "runs the adopted actor's session against the leased checkout, not the chat's cwd" do
        chat_cwd = nil
        worker = in_throwaway_repo do |repo|
          chat_cwd = repo
          adopt_worker(wiring_with("worktree"))
        end
        leased = worker.session.worker_env.cwd

        expect(leased).not_to eq(chat_cwd)
        # A REAL checkout, not a path the lease merely named: it exists, git
        # knows it (`.git` is a file inside a linked worktree), and it carries
        # the repo's seeded content -- so the cwd below is somewhere a child's
        # tools can actually work, which `#resolve`'s string math cannot show.
        expect(worker.checkout).to eq({ exists: true, repo: true, seeded: true })
        expect(worker.session.worker_env.resolve("notes.md")).to eq(File.join(leased, "notes.md"))
      end

      # The chat path's handback: a one-shot child's lease ends in the run's
      # handoff, queued for the branch the chat launched on -- and the
      # Supervisor holds the same handoff, so a crashed actor's commits are
      # anchored rather than kept by nothing.
      describe "the handback a worker's work comes home through" do
        def git_out(dir, *args) = SeedRepo.git(dir, *args).stdout.strip

        def on_feat(repo, config: nil)
          git_out(repo, "switch", "-q", "-c", "feat")
          return if config.nil?

          write_config(repo, config)
        end

        def spawn_dev(wiring, notice: ->(_line) {}, backend: self.backend)
          recorder, session = wiring.run_state(nil)
          wiring.wire_agent(channel:, recorder:, session:, backend:, notice:)
          Sync { wiring.role_spawn.call(:dev, :fresh, "work") }
        end

        def handbacks = record.events.grep(Lain::Telemetry::Handback)

        def recording_spawner
          Class.new do
            attr_reader :calls

            def initialize
              @calls = []
              @started = true
            end

            def drain(branch:, root:, **)
              @calls << [branch, root]
              @started
            end
          end.new
        end

        it "queues a one-shot child's commit for the chat's branch, asks for a drainer, and merges nothing" do
          spawner = recording_spawner
          allow(Lain::Isolation::MergeCoordinator::Spawner).to receive(:new).and_return(spawner)
          root, result, tip, pending = in_throwaway_repo do |repo|
            on_feat(repo)
            answer = spawn_dev(wiring_with("worktree"),
                               backend: offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 },
                                                                  mock: committing_provider, root: repo))
            home = Lain::Isolation::MergeCoordinator::Home.for(repo_root: repo, branch: "feat")
            [repo, answer, git_out(repo, "rev-parse", "feat"),
             Lain::Isolation::MergeCoordinator::Spool.new(home).pending]
          end

          expect(tip).to eq(@moved)
          expect(pending.map { |entry| entry.worker.ref }).to eq([handbacks.first.ref])
          expect(spawner.calls).to eq([["feat", root]])
          id = pending.first.id
          expect(result.content).to include("queued as #{id}").and include("lain land wait #{id}")
        end

        it "syncs each child with the rebase retries the project's config names" do
          in_throwaway_repo do |repo|
            on_feat(repo, config: %(isolation rebase_retries: 0\n))
            spawn_dev(wiring_with("worktree"))
          end

          expect(handbacks.map(&:sync)).to eq([:disabled])
        end

        it "anchors a crashed actor's commits when the supervisor stops, instead of keeping nothing" do
          anchored = nil
          worker = in_throwaway_repo do |repo|
            on_feat(repo)
            wiring = wiring_with("worktree")
            recorder, session = wiring.run_state(nil)
            wiring.wire_agent(channel:, recorder:, session:, backend:)
            crashed = Sync do |task|
              wiring.supervisor.run(task)
              wiring.supervisor.adopt(role: "dev") { |worker_env| WiringSpecCrashedWorker.new(worker_env) }
            ensure
              wiring.supervisor.stop
            end
            anchored = git_out(repo, "for-each-ref", "--format=%(objectname)", "refs/lain/worker/")
            crashed
          end

          expect(anchored).to eq(worker.commit)
        end

        it "builds one RoleSpawn for the run" do
          allow(Lain::Skill::RoleSpawn).to receive(:new).and_call_original

          in_throwaway_repo do |repo|
            on_feat(repo)
            wiring = wiring_with("worktree")
            recorder, session = wiring.run_state(nil)
            wiring.wire_agent(channel:, recorder:, session:, backend:)
          end

          expect(Lain::Skill::RoleSpawn).to have_received(:new).once
        end

        # The child commits while the branch moves under it, so a lint that
        # ran after the rebase would have logged a different HEAD.
        def committing_provider
          Class.new(Lain::Provider::Mock) do
            def complete(request, on_stream_started: nil)
              step = super
              step.respond_to?(:call) ? step.call(request) : step
            end
          end.new(responses: [->(_request) { commit_and_move }])
        end

        def commit_in(dir, file)
          File.write(File.join(dir, file), "#{file}\n")
          git_out(dir, "add", file)
          git_out(dir, "commit", "-q", "-m", file)
          git_out(dir, "rev-parse", "HEAD")
        end

        def commit_and_move
          @worktree = record.events.grep(Lain::Telemetry::IsolationLease).find { |lease| lease.kind == :acquired }.path
          @committed = commit_in(@worktree, "work.txt")
          @moved = commit_in(Dir.pwd, "moved.txt")
          Lain::Response.new(content: [{ "type" => "text", "text" => "done" }], stop_reason: :end_turn)
        end

        it "runs the configured lint in the child's checkout before its rebase, and journals the checks" do
          logged = in_throwaway_repo do |repo, state|
            log = File.join(state, "lint.log")
            on_feat(repo, config: %(isolation lint: ["sh", "-c", "pwd > #{log}; git rev-parse HEAD >> #{log}"]\n))
            spawn_dev(wiring_with("worktree"),
                      backend: offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 },
                                                         mock: committing_provider, root: repo))
            File.readlines(log, chomp: true)
          end

          expect(logged).to eq([@worktree, @committed])
          expect(handbacks.map(&:sync)).to eq([:synced])
          expect(handbacks.first.checks).to include("outcome" => "passed")
        end
      end
    end

    # The sibling of the block below, at the seam a COMMAND becomes a process
    # rather than the one a WORKER leases an environment from, and it keeps the
    # same ordering rule: resolved before the header is pinned.
    context "with an unrecognized exec option" do
      it "raises a Lain::Error before the toolset exists" do
        wiring = new_wiring(options: { grace: 5, exec: "podman" }, chronicle:, status_feed:)
        recorder, session = wiring.run_state(nil)

        expect { wiring.wire_agent(channel:, recorder:, session:, backend:) }
          .to raise_error(Lain::Error, /unknown exec backend "podman".*local.*docker/m)
      end
    end

    # Resolved BEFORE {Lain::CLI::Chronicle#start} pins the header, so the
    # refusal lands while the session record is still empty -- the same
    # refusal-before-journal ordering --resume and --fork already keep.
    context "with an unrecognized isolation option" do
      it "raises a Lain::Error and leaves no session record behind" do
        Dir.mktmpdir("lain-d2-state") do |state|
          paths = Lain::Paths.new(env: { "HOME" => "/home/nobody", "XDG_STATE_HOME" => state })
          journaled = Lain::CLI::Chronicle.for(enabled: true, paths:, root: Dir.pwd)
          wiring = new_wiring(options: { grace: 5, isolation: "docker" }, chronicle: journaled, status_feed:)
          recorder, session = wiring.run_state(nil)

          expect { wiring.wire_agent(channel:, recorder:, session:, backend:) }
            .to raise_error(Lain::Error, /unknown isolation backend "docker".*none.*worktree/m)

          journaled.close(reason: :exit)
          # "No session record behind" is now literal. A journal that
          # closes with nothing ever recorded into it removes its own file, so
          # the zero-byte artifact never reaches the readers that pick the
          # newest session (--resume, --fork, watch, sessions).
          expect(File).not_to exist(journaled.journal_path)
        end
      end
    end
  end

  describe "#run" do
    require "stringio"
    require "tmpdir"

    # The injection seams: a spec assembles and runs the whole conversation
    # through #run's own path -- no send(:build_repl), no instance_variable_set
    # -- by handing in a StringIO-backed TTY factory and a recording conductor
    # opener instead of the real-terminal defaults.
    let(:opened) { [] }
    let(:conductor_opener) { ->(**kwargs) { Lain::CLI::Conductor.open(**kwargs).tap { |c| opened << c } } }

    # Wiring hands the factory a `prompt_renderer:` too. It is swallowed rather
    # than forwarded: what this spec is about is the object WIRING composes and
    # passes on, not what the TTY then does with it (that is tty_spec's).
    def tty_factory(dir)
      lambda do |channel:, **|
        Lain::Frontend::TTY.new(channel:, output: StringIO.new, history_path: File.join(dir, "history"))
      end
    end

    def run_wiring(input: "quit\n", options: { grace: 5 }, backend: self.backend)
      Dir.mktmpdir do |dir|
        wiring = new_wiring(options:, chronicle:, status_feed:, stdin: StringIO.new(input),
                            tty_factory: tty_factory(dir), conductor_opener:)
        wiring.run(backend:, resumed: nil, nvim: nil)
        wiring.conductor.close(reason: :exit)
        wiring
      end
    end

    # Two identical results are the smallest round every real budget changes,
    # and the record it writes names the policy; no budget writes none.
    def round_budget_basis(options:)
      budgets = []
      allow(Lain::Agent).to receive(:new).and_wrap_original do |original, *args, **kwargs, &block|
        budgets << kwargs[:round_budget]
        original.call(*args, **kwargs, &block)
      end
      run_wiring(options: { grace: 5 }.merge(options))
      basis_of_two_equal_results(budgets.first)
    end

    def basis_of_two_equal_results(budget)
      room = Lain::Tool::Room.new(window: 32_768, usage: Lain::Usage.new(input_tokens: 100, output_tokens: 10),
                                  ceiling: 16_384)
      tool = Struct.new(:name) { def rerunnable? = true }.new("read_file")
      calls = %w[a b].map { |id| Lain::Tool::RoundBudget::Call.new(id:, tool:) }
      blocks = calls.map { |call| { "type" => "tool_result", "tool_use_id" => call.id, "content" => "x" * 400 } }
      [].tap { |bases| budget.for(head: "h") { room }.call(blocks, calls) { |record| bases << record.basis } }
    end

    it "gives a plain chat's main agent the window round budget", :seam do
      expect(round_budget_basis(options: {})).to eq(["window"])
    end

    it "gives the main agent the static round budget when asked", :seam do
      expect(round_budget_basis(options: { round_budget: "static" })).to eq(["static"])
    end

    it "gives the main agent only deduplication when the budget is off", :seam do
      expect(round_budget_basis(options: { round_budget: "off" })).to eq(["dedup"])
    end

    it "gives the main agent no round budget when both arms are off", :seam do
      expect(round_budget_basis(options: { round_budget: "off", round_dedup: "off" })).to eq([])
    end

    # The quit is the last thing that could give a plan-scope spike back: one
    # left behind holds a branch, and a locked worktree, nothing else removes.
    describe "a quit in plan scope", :seam do
      let(:screen) { StringIO.new }

      def quit_in_plan(state)
        terminal = lambda do |channel:, **|
          Lain::Frontend::TTY.new(channel:, output: screen, history_path: File.join(state, "history"))
        end
        wiring = new_wiring(options: { grace: 5 }, chronicle:, status_feed:, stdin: StringIO.new("/mode plan\nquit\n"),
                            tty_factory: terminal, conductor_opener:,
                            paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => state, "HOME" => state }))
        wiring.run(backend:, resumed: nil, nvim: nil)
        wiring.conductor.close(reason: :exit)
      end

      def git(*args) = SeedRepo.git(project_dir, *args).stdout

      def locked_worktrees = git("worktree", "list", "--porcelain").lines.grep(/\Alocked/)

      it "leaves no plan branch and no locked worktree in a git project" do
        FileUtils.cp_r("#{SeedRepo.at({ "a.rb" => "one\n" })}/.", project_dir)

        Dir.mktmpdir("lain-wiring-quit") { |state| quit_in_plan(File.realpath(state)) }

        expect([git("for-each-ref", "refs/heads/lain/plan/"), locked_worktrees]).to eq(["", []])
        expect(opened.sole).to be_closed
      end

      # Outside git there are no commits to keep, and what plan scope wrote
      # there may be a secret.
      it "discards the scratch directory in a project git does not hold, and says so" do
        scratches = []
        allow(Lain::Isolation::Scratch).to receive(:new).and_wrap_original do |original, **kwargs|
          original.call(**kwargs).tap do |scratch|
            allow(scratch).to(receive(:acquire).and_wrap_original { |acquire| acquire.call.tap { scratches << _1 } })
          end
        end

        Dir.mktmpdir("lain-wiring-quit") { |state| quit_in_plan(File.realpath(state)) }

        dir = scratches.sole.worker_env.cwd
        expect([File.exist?(dir), opened.sole]).to match([false, be_closed])
        expect(screen.string).to include(dir, "discarded")
      end
    end

    # The epic driver's supervisor, retirement and landing queue all journal
    # into what these seams carry, and a chat can only reach that driver through
    # a slash command, so nothing else here would notice a display Channel there.
    it "hands the epic driver's seams the session record, never the display channel", :seam do
      allow(Lain::CLI::EpicDriver::Seams).to receive(:new).and_call_original

      run_wiring

      expect(Lain::CLI::EpicDriver::Seams).to have_received(:new)
        .with(hash_including(journal: be(chronicle.durable_journal)))
    end

    # The REAL Backend, never the offline double: what these two are about is
    # the endpoint the chat's own provider resolves, and a stand-in answering
    # one would be answering the question under test. Nothing dials out --
    # `quit` ends the chat before a turn is taken.
    def backend_on(provider) = Lain::CLI::Backend.new({ provider:, model: nil, max_tokens: 64 }, root: Dir.pwd)

    # The seams wiring really built, caught as they are handed to the surface.
    def epic_seams_over(backend)
      built = []
      allow(Lain::CLI::EpicDriver::Seams).to receive(:new).and_wrap_original do |original, **kwargs|
        original.call(**kwargs).tap { |seams| built << seams }
      end
      run_wiring(backend:)
      built.fetch(0)
    end

    # How many issues the driver those seams build carries when the human typed
    # no width and the project declared none. Production's own join, asked of
    # the endpoint wiring handed over rather than of one an example made up.
    def carried_width(seams) = Lain::CLI::EpicDriver::Run.width_for(endpoint: seams.endpoint)

    # The stall the derived width exists to stop the driver manufacturing: one
    # local server serves one request at a time, so a second issue either waits
    # or makes the server swap models and throw away the prefix cache.
    it "carries one issue at a time when the chat's provider dials a local server", :seam do
      expect(carried_width(epic_seams_over(backend_on("ollama")))).to eq(1)
    end

    # The other direction, and nowhere but here can catch it: `Backend` answers
    # localhost as the default base for anthropic too, so a wiring that asked
    # IT would halve every hosted run for a reason nothing in the output names.
    it "carries the hosted default when the chat's provider dials anthropic", :seam do
      width = with_env("ANTHROPIC_API_KEY" => "sk-wiring-spec") do
        carried_width(epic_seams_over(backend_on("anthropic")))
      end

      expect(width).to eq(2)
    end

    # `--input socket:<name>` puts the human in another pane. The chat then has
    # no reader for its own stdin at all, which is the point: a `lain up` chat
    # pane is a scrolling transcript nobody types into.
    it "reads the human from an input socket, never this terminal, when --input names one", :seam do
      Dir.mktmpdir do |dir|
        paths = Lain::Paths.new(env: { "XDG_RUNTIME_DIR" => dir })
        path = Lain::CLI::InputSocket.path(name: "wiring", paths:, cwd: project_dir)
        stdin = StringIO.new("never read\n")
        allow(status_feed).to receive(:state).and_return(PublishedFeedState.build)
        wiring = new_wiring(options: { grace: 5, input: "socket:wiring" }, chronicle:, status_feed:,
                            paths:, stdin:, tty_factory: tty_factory(dir), conductor_opener:)
        pane = Thread.new { end_the_chat_from_a_pane(path) }

        wiring.run(backend:, resumed: nil, nvim: nil)
        wiring.conductor.close(reason: :exit)

        expect([pane.value, stdin.pos]).to eq([path, 0])
      end
    end

    # A stopped child keeps its checkout live for a resume, so the run's close
    # is what gives back the leases the chat's spawns hold.
    it "hands the conductor the chat's spawn leases, which its close gives back", :seam do
      closed = []
      allow(Lain::Isolation::Leases).to receive(:new).and_wrap_original do |original, **kwargs|
        original.call(**kwargs).tap do |leases|
          leases.define_singleton_method(:close) { (closed << self) && super() }
        end
      end

      run_wiring

      expect(closed.size).to eq(1)
      expect(closed.first.lane).to eq(Lain::Isolation::Leases::Lane::UNNAMED)
    end

    # History is a line editor's, and a chat reading a pipe has none: what a
    # script feeds it is not what a human would reach for at `you>`.
    it "keeps no history for a chat reading a stream that is not a terminal", :seam do
      kept = Dir.mktmpdir do |dir|
        wiring = new_wiring(options: { grace: 5 }, chronicle:, status_feed:, stdin: StringIO.new("quit\n"),
                            tty_factory: tty_factory(dir), conductor_opener:)
        wiring.run(backend:, resumed: nil, nvim: nil)
        wiring.conductor.close(reason: :exit)
        File.exist?(File.join(dir, "history"))
      end

      expect(kept).to be(false)
    end

    # The pane is a line editor in another process, and its lines reach the
    # chat's Intake over the socket -- which is where they are kept, so a
    # cockpit's history is the chat's and not the pane's.
    it "keeps the line a pane sent over the input socket in the chat's history", :seam do
      Dir.mktmpdir do |dir|
        paths = Lain::Paths.new(env: { "XDG_RUNTIME_DIR" => dir })
        path = Lain::CLI::InputSocket.path(name: "wiring-history", paths:, cwd: project_dir)
        allow(status_feed).to receive(:state).and_return(PublishedFeedState.build)
        wiring = new_wiring(options: { grace: 5, input: "socket:wiring-history" }, chronicle:, status_feed:,
                            paths:, stdin: StringIO.new, tty_factory: tty_factory(dir), conductor_opener:)
        pane = Thread.new { type_at_you_from_a_pane(path, "quit") }

        wiring.run(backend:, resumed: nil, nvim: nil)
        wiring.conductor.close(reason: :exit)
        pane.join

        expect(File.read(File.join(dir, "history"))).to eq("quit\n")
      end
    end

    # A cockpit's prompt is typed in another pane, so the transcript is the only
    # place the chat pane can show it; a plain chat's terminal already shows it.
    it "echoes a line typed in the input pane into the transcript, and not a line typed here", :seam do
      transcripts = Dir.mktmpdir do |dir|
        paths = Lain::Paths.new(env: { "XDG_RUNTIME_DIR" => dir })
        path = Lain::CLI::InputSocket.path(name: "wiring-echo", paths:, cwd: project_dir)
        allow(status_feed).to receive(:state).and_return(PublishedFeedState.build)
        outputs = []
        factory = lambda do |channel:, **|
          Lain::Frontend::TTY.new(channel:, output: StringIO.new.tap { |io| outputs << io },
                                  history_path: File.join(dir, "history"))
        end
        cockpit = new_wiring(options: { grace: 5, input: "socket:wiring-echo" }, chronicle:, status_feed:,
                             paths:, stdin: StringIO.new, tty_factory: factory, conductor_opener:)
        pane = Thread.new { type_at_you_from_a_pane(path, "quit") }
        cockpit.run(backend:, resumed: nil, nvim: nil)
        cockpit.conductor.close(reason: :exit)
        pane.join
        plain = new_wiring(options: { grace: 5 }, chronicle:, status_feed:, stdin: StringIO.new("quit\n"),
                           tty_factory: factory, conductor_opener:)
        plain.run(backend: fresh_backend, resumed: nil, nvim: nil)
        plain.conductor.close(reason: :exit)
        outputs.map { |io| io.string.include?("you> quit") }
      end

      expect(transcripts).to eq([true, false])
    end

    # `lain queue open` holds a review when no chat runs in its checkout; the
    # next cockpit there is the one that offers it.
    describe "a review held for this checkout", :seam do
      let(:state) { File.realpath(Dir.mktmpdir("lain-wiring-pending")) }
      # Apart from the state, since a socket's path has a short limit.
      let(:run_dir) { Dir.mktmpdir }
      let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => state, "XDG_RUNTIME_DIR" => run_dir, "HOME" => state }) }
      let(:pending) { Lain::Review::Queue::Pending.new(paths:, env: {}) }
      let(:fields) { { "kind" => "range", "base" => "a" * 40, "head" => "b" * 40, "repo_root" => project_dir } }

      before do
        SeedRepo.git(project_dir, "init", "-q")
        checkouts = Lain::Review::Queue::Checkouts.new(roots: [])
        pending.hold(Lain::Review::Queue::Request.load(fields, checkouts:),
                     Lain::Review::Queue::Mark.new(id: "commit:#{project_dir}", head_sha: "b" * 40))
        allow(status_feed).to receive(:state).and_return(PublishedFeedState.build)
      end

      after { FileUtils.rm_rf([state, run_dir]) }

      def held = Dir.glob(File.join(paths.state_home, "queue", "pending", "*"))

      def answer_from_a_pane(path)
        client = Enumerator.produce { connect_to(path) }.lazy.grep(UNIXSocket).first
        frames = Enumerator.produce { JSON.parse(client.gets) }
        offer = frames.find { |frame| frame["kind"] == "human" }
        typed(client, "x", offer)
        typed(client, "quit", frames.find { |frame| frame["kind"] == "you" })
        client.read
        offer["text"]
      ensure
        client&.close
      end

      def typed(client, text, prompt)
        client.write("#{JSON.generate({ "v" => "line", "text" => text, "generation" => prompt["generation"] })}\n")
        client.flush
      end

      def chat(options, stdin: StringIO.new)
        new_wiring(options: { grace: 5 }.merge(options), chronicle:, status_feed:, paths:, stdin:,
                   tty_factory: tty_factory(state), conductor_opener:)
      end

      it "is offered for 1 keypress when an attended chat with an editor starts, and is then gone" do
        path = Lain::CLI::InputSocket.path(name: "wiring-pending", paths:, cwd: project_dir)
        wiring = chat({ input: "socket:wiring-pending", nvim: File.join(state, "nvim.sock") })
        pane = Thread.new { answer_from_a_pane(path) }

        Timeout.timeout(20) { wiring.run(backend:, resumed: nil, nvim: nil) }
        wiring.conductor.close(reason: :exit)

        expect([pane.value, held])
          .to eq(["lain queue: /review #{"b" * 40} --base #{"a" * 40}  (Enter opens, x drops)", []])
      end

      it "stays held when the input socket cannot bind" do
        path = Lain::CLI::InputSocket.path(name: "wiring-pending", paths:, cwd: project_dir)
        FileUtils.mkdir_p(File.dirname(path))
        other = UNIXServer.new(path)
        wiring = chat({ input: "socket:wiring-pending", nvim: File.join(state, "nvim.sock") })

        expect { Timeout.timeout(20) { wiring.run(backend:, resumed: nil, nvim: nil) } }
          .to raise_error(Lain::CLI::InputSocket::InUse)
        expect(held.size).to eq(1)
      ensure
        other&.close
      end

      it "is held again when the chat ends before the human answers" do
        path = Lain::CLI::InputSocket.path(name: "wiring-pending", paths:, cwd: project_dir)
        wiring = chat({ input: "socket:wiring-pending", nvim: File.join(state, "nvim.sock") })
        pane = Thread.new { stop_at_the_offer(path) }

        Timeout.timeout(20) { wiring.run(backend:, resumed: nil, nvim: nil) }
        wiring.conductor.close(reason: :exit)
        pane.join

        expect(held.size).to eq(1)
      end

      def stop_at_the_offer(path)
        client = Enumerator.produce { connect_to(path) }.lazy.grep(UNIXSocket).first
        Enumerator.produce { JSON.parse(client.gets) }.find { |frame| frame["kind"] == "human" }
        client.write("#{JSON.generate({ "v" => "signal", "name" => "sigterm" })}\n")
        client.flush
        client.read
      ensure
        client&.close
      end

      it "stays held when a chat with no editor starts, however long it sits at you>" do
        path = Lain::CLI::InputSocket.path(name: "wiring-pending", paths:, cwd: project_dir)
        wiring = chat({ input: "socket:wiring-pending" })
        pane = Thread.new { quit_after_a_while(path) }

        Timeout.timeout(20) { wiring.run(backend:, resumed: nil, nvim: nil) }
        wiring.conductor.close(reason: :exit)
        pane.join

        expect(held.size).to eq(1)
      end

      def quit_after_a_while(path)
        client = Enumerator.produce { connect_to(path) }.lazy.grep(UNIXSocket).first
        you = Enumerator.produce { JSON.parse(client.gets) }.find { |frame| frame["kind"] == "you" }
        sleep(0.3)
        typed(client, "quit", you)
        client.read
      ensure
        client&.close
      end

      it "stays held when a chat nobody attends starts, even with an editor" do
        wiring = chat({ non_interactive: true, prompt: "hello", nvim: File.join(state, "nvim.sock") })

        Timeout.timeout(20) { wiring.run(backend:, resumed: nil, nvim: nil) }
        wiring.conductor.close(reason: :exit)

        expect(held.size).to eq(1)
      end
    end

    describe "the terminal's completion sources", :seam do
      def offered_after(typed, backend: self.backend)
        sources = nil
        factory = lambda do |channel:, completion_sources:, **|
          sources = completion_sources
          Lain::Frontend::TTY.new(channel:, output: StringIO.new, history_path: File::NULL)
        end
        wiring = new_wiring(options: { grace: 5 }, chronicle:, status_feed:, stdin: StringIO.new("quit\n"),
                            tty_factory: factory, conductor_opener:)
        wiring.run(backend:, resumed: nil, nvim: nil)
        wiring.conductor.close(reason: :exit)
        sources.for("/").match(typed).map { |match| match["candidate"] }
      end

      it "offers a built-in command" do
        expect(offered_after("inb")).to include("inbox")
      end

      it "offers a shipped skill" do
        expect(offered_after("crit")).to include("critique")
      end

      it "lists skills with the commands it tells an input pane" do
        wiring = run_wiring

        expect(wiring.send(:command_names)).to include("inbox", "critique")
      end

      it "offers a project skill" do
        Dir.mktmpdir("lain-skill-root") do |root|
          FileUtils.mkdir_p(File.join(root, ".lain", "skills", "deploy"))
          File.write(File.join(root, ".lain", "skills", "deploy", "skill.md"), "# Deploy\nShip it.\n")
          project_backend = Lain::CLI::Backend.new({ provider: "ollama", model: nil, max_tokens: 64 }, root:)

          expect(offered_after("depl", backend: project_backend)).to include("deploy")
        end
      end
    end

    it "hands the chat's Intake the approval key, which flips the board", :seam do
      built = Hash.new { |hash, key| hash[key] = [] }
      [Lain::Frontend::Intake, Lain::CLI::Switchboard].each do |klass|
        allow(klass).to receive(:new).and_wrap_original do |original, *args, **kwargs, &block|
          original.call(*args, **kwargs, &block).tap { |made| built[klass] << made }
        end
      end

      flipped = Dir.mktmpdir do |dir|
        wiring = new_wiring(options: { grace: 5 }, chronicle:, status_feed:, stdin: StringIO.new("quit\n"),
                            tty_factory: tty_factory(dir), conductor_opener:)
        wiring.run(backend:, resumed: nil, nvim: nil)
        board = built[Lain::CLI::Switchboard].last
        before = board.mode_switch.approval.name
        built[Lain::Frontend::Intake].sole.cycle
        wiring.conductor.close(reason: :exit)
        [before, board.mode_switch.approval.name]
      end

      expect(flipped).to eq(%i[ask auto])
    end

    # A line typed mid-run is one note however it arrives, so the Agent that
    # folds it and every reader that can take it must hold the same queue.
    it "hands a built chat's Agent, Intake, StdinPump and Repl one HumanNotes", :seam do
      seen = Hash.new { |hash, key| hash[key] = [] }
      { Lain::Agent => :mailbox, Lain::Frontend::Intake => :notes, Lain::Frontend::StdinPump => :notes,
        Lain::CLI::Repl => :notes }.each do |klass, key|
        allow(klass).to receive(:new).and_wrap_original do |original, *args, **kwargs, &block|
          seen[klass] << kwargs[key]
          original.call(*args, **kwargs, &block)
        end
      end

      Dir.mktmpdir do |dir|
        wiring = new_wiring(options: { grace: 5 }, chronicle:, status_feed:, stdin: StringIO.new("quit\n"),
                            tty_factory: tty_factory(dir), conductor_opener:)
        wiring.run(backend:, resumed: nil, nvim: nil)
        wiring.conductor.close(reason: :exit)
      end

      notes = seen[Lain::CLI::Repl].sole
      expect(notes).to be_a(Lain::CLI::HumanNotes)
      expect([seen[Lain::Frontend::Intake].sole, seen[Lain::Frontend::StdinPump].sole, seen[Lain::Agent].first])
        .to eq([notes, notes, notes.mailbox])
    end

    # The schedule decides whether a tick exists at all, so the surface a
    # built Repl is handed is read back off the constructor it really got.
    describe "the phone's surface", :seam do
      def remote_handed
        seen = []
        allow(Lain::CLI::Repl).to receive(:new).and_wrap_original do |original, **kwargs|
          seen << kwargs.fetch(:remote)
          original.call(**kwargs)
        end
        run_wiring
        seen.sole
      end

      def write_user_config(body)
        user = Lain::Paths.new
        FileUtils.mkdir_p(File.dirname(user.user_config))
        File.write(user.user_config, body)
        Lain::Project::Trust.for_user(paths: user).grant!
      end

      after { FileUtils.rm_f(Lain::Paths.new.user_config) }

      it "hands the Repl a remote surface when the user's config sets remote relay" do
        write_user_config("remote relay: \"127.0.0.1:7820\"\n")

        expect(remote_handed).to be_a(Lain::Approval::RemoteSurface)
      end

      it "hands the Repl a surface that announces on the configured ntfy topic" do
        write_user_config("remote relay: \"127.0.0.1:7820\", ntfy: \"http://127.0.0.1:8090/lain-x7\"\n")

        expect(remote_handed.ntfy).to be_an_instance_of(Lain::Remote::Ntfy)
      end

      it "hands the Repl none when remote relay is unset" do
        expect(remote_handed).to be_nil
      end
    end

    describe "the idle compaction surface", :seam do
      def idle_handed(schedule)
        seen = []
        allow(backend).to receive(:compaction_schedule).and_return(schedule)
        allow(Lain::CLI::Repl).to receive(:new).and_wrap_original do |original, **kwargs|
          seen << kwargs[:idle]
          original.call(**kwargs)
        end
        run_wiring
        seen.sole
      end

      it "hands the Repl a ticking surface when the run is on the idle schedule" do
        expect(idle_handed("idle")).to be_a(Lain::CLI::Repl::IdleCompaction)
      end

      it "ticks the chat's own agent and reports a fault on the display channel" do
        built = {}
        allow(Lain::Agent).to receive(:new).and_wrap_original do |original, **kwargs|
          original.call(**kwargs).tap { |agent| built.merge!(agent:, channel: kwargs[:display]) }
        end
        idle = idle_handed("idle")
        allow(built[:agent]).to receive(:prepare_idle).and_raise(RuntimeError, "summarizer down")
        pushed = []
        allow(built[:channel]).to receive(:push) { |event| pushed << event }

        idle.tick

        expect(pushed).to include(
          an_object_having_attributes(class: Lain::Telemetry::ToolOutput, tool_use_id: "lain:idle-compaction",
                                      stream: :stderr, bytes: a_string_matching(/RuntimeError.*summarizer down/))
        )
      end

      it "hands the Repl the Never surface when the run is on the turn schedule" do
        expect(idle_handed("turn")).to be(Lain::CLI::Repl::IdleCompaction::Never)
      end
    end

    it "hands the Repl the daemon registration the launch built, which the conversation opens", :seam do
      registration = instance_spy(Lain::Daemon::Registration)
      seen = []
      allow(Lain::CLI::Repl).to receive(:new).and_wrap_original do |original, **kwargs|
        seen << kwargs[:registration]
        original.call(**kwargs)
      end

      Dir.mktmpdir do |dir|
        wiring = new_wiring(options: { grace: 5 }, chronicle:, status_feed:, stdin: StringIO.new("quit\n"),
                            tty_factory: tty_factory(dir), conductor_opener:, registration:)
        wiring.run(backend:, resumed: nil, nvim: nil)
        wiring.conductor.close(reason: :exit)
      end

      expect(seen).to eq([registration])
      expect(registration).to have_received(:open)
    end

    it "hands the chat's StdinPump the approval key the user's config names", :seam do
      allow(Lain::Config).to receive(:keys)
        .and_return(Lain::Config::Keys.from({ "approval_cycle" => "s-tab" }, path: nil))
      keys = []
      allow(Lain::Frontend::StdinPump).to receive(:new).and_wrap_original do |original, *args, **kwargs, &block|
        keys << kwargs[:cycle_key]
        original.call(*args, **kwargs, &block)
      end

      Dir.mktmpdir do |dir|
        wiring = new_wiring(options: { grace: 5 }, chronicle:, status_feed:, stdin: StringIO.new("quit\n"),
                            tty_factory: tty_factory(dir), conductor_opener:)
        wiring.run(backend:, resumed: nil, nvim: nil)
        wiring.conductor.close(reason: :exit)
      end

      expect(keys).to eq(["s-tab"])
    end

    it "hands the chat's terminal the theme the user's config declares, with the pastel it paints through", :seam do
      handed = []
      theme = Lain::Frontend::Theme.new(pastel: Pastel.new(enabled: false))
      allow(Lain::Frontend::Theme).to receive(:on_stdout) { theme }

      Dir.mktmpdir do |dir|
        factory = lambda do |channel:, theme:, pastel:, **|
          handed << [theme, pastel]
          Lain::Frontend::TTY.new(channel:, theme:, pastel:, output: StringIO.new,
                                  history_path: File.join(dir, "history"))
        end
        wiring = new_wiring(options: { grace: 5 }, chronicle:, status_feed:, stdin: StringIO.new("quit\n"),
                            tty_factory: factory, conductor_opener:)
        wiring.run(backend:, resumed: nil, nvim: nil)
        wiring.conductor.close(reason: :exit)
      end

      expect(handed).to eq([[theme, theme.pastel]])
      expect(Lain::Frontend::Theme).to have_received(:on_stdout).with(paths: an_instance_of(Lain::Paths))
    end

    # A registered command runs outside every ask, so prose typed meanwhile
    # waits as the next prompt rather than going to an agent that is not running.
    it "holds prose typed while a registered command runs, rather than noting it", :seam do
      rails = []
      allow(Lain::Frontend::Intake).to receive(:new).and_wrap_original do |original, **kwargs|
        original.call(**kwargs).tap { |rail| rails << rail }
      end
      allow(Lain::CLI::Repl).to receive(:new).and_wrap_original do |original, **kwargs|
        registry = kwargs.fetch(:commands)
        typing = Object.new
        typing.define_singleton_method(:dispatch) do |text, &turn|
          rails.last << Lain::Frontend::Intake::Line.new(text: "prefer Syncthing", generation: 0) if text == "/help"
          registry.dispatch(text, &turn)
        end
        typing.define_singleton_method(:serves_replies?) { |text| registry.serves_replies?(text) }
        original.call(**kwargs, commands: typing)
      end
      output = StringIO.new

      Dir.mktmpdir do |dir|
        factory = lambda do |channel:, **|
          Lain::Frontend::TTY.new(channel:, output:, history_path: File.join(dir, "history"))
        end
        wiring = new_wiring(options: { grace: 5 }, chronicle:, status_feed:, stdin: StringIO.new("/help\n"),
                            tty_factory: factory, conductor_opener:)
        wiring.run(backend:, resumed: nil, nvim: nil)
        wiring.conductor.close(reason: :exit)
      end

      expect(output.string).to include("held as your next prompt: prefer Syncthing")
      expect(output.string).not_to include("note for the agent")
    end

    # The run is not working once its final reply commits, so a prompt typed
    # while it tears down is the next prompt, not a note for no request.
    context "with a model that answers twice", :seam do
      let(:mock_provider) { Lain::Provider::Mock.new(responses: [text_response("first"), text_response("second")]) }

      it "holds prose typed after the final reply commits as the next prompt, rather than noting it" do
        rails = []
        allow(Lain::Frontend::Intake).to receive(:new).and_wrap_original do |original, **kwargs|
          original.call(**kwargs).tap { |rail| rails << rail }
        end
        typed = [false]
        typing = Class.new(Lain::Middleware::Base) do
          define_method(:call) do |env, &downstream|
            downstream.call(env).tap do |settled|
              if settled.fetch(:settled) && !typed.first
                typed[0] = true
                rails.last << Lain::Frontend::Intake::Line.new(text: "Second prompt please.", generation: 0)
              end
            end
          end
        end.new
        typing_chronicle = Class.new(Lain::CLI::Chronicle::Null) do
          define_method(:turn_middleware) { |_timeline| Lain::Middleware::Stack.new([typing]) }
        end.new
        output = StringIO.new

        Dir.mktmpdir do |dir|
          factory = lambda do |channel:, **|
            Lain::Frontend::TTY.new(channel:, output:, history_path: File.join(dir, "history"))
          end
          wiring = new_wiring(options: { grace: 5 }, chronicle: typing_chronicle, status_feed:,
                              stdin: StringIO.new("tell me\n"), tty_factory: factory, conductor_opener:)
          wiring.run(backend:, resumed: nil, nvim: nil)
          wiring.conductor.close(reason: :exit)
        end

        expect(output.string).to include("held as your next prompt: Second prompt please.")
        expect(output.string).not_to include("note for the agent")
        expect(mock_provider.requests.size).to eq(2)
      end
    end

    # Answers the first `you>` a pane is shown with `text`, as a human typing
    # there would, then goes away.
    def type_at_you_from_a_pane(path, text)
      client = Enumerator.produce { connect_to(path) }.lazy.grep(UNIXSocket).first
      prompt = Enumerator.produce { JSON.parse(client.gets) }.find { |frame| frame["kind"] == "you" }
      client.write("#{JSON.generate({ "v" => "line", "text" => text, "generation" => prompt["generation"] })}\n")
      client.flush
      client.read
    ensure
      client&.close
    end

    # Connects as a `lain input` pane would, waits for a frame, and ends the
    # stream. Answers the path it reached, so the assertion names the socket
    # that was there rather than a bare true.
    def end_the_chat_from_a_pane(path)
      client = Enumerator.produce { connect_to(path) }.lazy.grep(UNIXSocket).first
      client.gets
      client.write(%({"v":"eof"}\n))
      client.flush
      path
    end

    def connect_to(path)
      UNIXSocket.new(path)
    rescue SystemCallError
      sleep(0.01)
      nil
    end

    it "threads the injected tty/conductor seams -- the conductor the opener built is the one exposed", :seam do
      wiring = run_wiring

      expect(opened).to eq([wiring.conductor])
    end

    # What replaced the desktop notifier as `request_review`'s way of telling a
    # human a file is waiting on them -- and with no editor wired in production
    # ({CLI::EpicMount#request_review} says why), the only way. Asserted through
    # the object rather than through a keyword: the seam is a thunk read at CALL
    # time, so the question is what it reaches once a frontend exists.
    describe "the run's one line to the human" do
      it "says nothing before a frontend exists, which is the window the toolset is built in" do
        wiring = new_wiring(options: { grace: 5 }, chronicle:, status_feed:)

        expect { wiring.told.call("a file is waiting") }.not_to raise_error
      end

      it "reaches the terminal once #run has built one", :seam do
        rendered = StringIO.new
        Dir.mktmpdir do |dir|
          factory = lambda do |channel:, **|
            Lain::Frontend::TTY.new(channel:, output: rendered, history_path: File.join(dir, "history"))
          end
          wiring = new_wiring(options: { grace: 5 }, chronicle:, status_feed:, stdin: StringIO.new("quit\n"),
                              tty_factory: factory, conductor_opener:)
          wiring.run(backend:, resumed: nil, nvim: nil)
          wiring.conductor.close(reason: :exit)
          wiring.told.call("epic.md is open for review")
        end

        expect(rendered.string).to include("epic.md is open for review")
      end
    end

    # The ONE production line the fix rests on. {Lain::StatusFeed} is built
    # a layer above this class ({Lain::CLI::ChatLaunch}, which must have it
    # in the live-view tee's sink list before Wiring exists), so it holds no
    # Store at construction and its inbox_count can retire nothing until this
    # class hands it one. Nothing else observes that hand-over: deleting it left
    # every example in this file green while the HUD went back to counting up
    # forever, which is the defect class this card exists to remove. So the call
    # is EXPECTED here, and against the run's own Store -- an `instance_of`
    # would still pass for a second, empty one, which retires exactly nothing.
    it "hands the herdr binding's reporter to the commands' env" do
      reporter = Lain::Herdr::Reporter::Null.new
      wiring = Dir.mktmpdir do |dir|
        focus = Lain::Frontend::Focus.tmux(env: {})
        herdr = Struct.new(:tty_factory, :focus, :reporter, :window_surface, :notes)
                      .new(tty_factory(dir), focus, reporter, Lain::CLI::TmuxSurface.new, Lain::Sink::Null.new)
        new_wiring(options: { grace: 5 }, chronicle:, status_feed:, stdin: StringIO.new("quit\n"), herdr:,
                   conductor_opener:).tap do |built|
          built.run(backend:, resumed: nil, nvim: nil)
          built.conductor.close(reason: :exit)
        end
      end

      expect(wiring.command_env.reporter).to be(reporter)
    end

    # One account per process, read by the command surface, whose notes go to the chat's own line.
    it "builds the GitHub account once, over herdr's notes, and hands it to the command surface", :seam do
      account = instance_double(Lain::Forge::Gh::Account)
      notes = Lain::Herdr::HeldNotes.new
      allow(Lain::Forge::Gh::Account).to receive(:configured).and_return(account)
      allow(Lain::CLI::Command::Surface).to receive(:new).and_call_original

      Dir.mktmpdir do |dir|
        herdr = Struct.new(:tty_factory, :focus, :reporter, :window_surface, :notes)
                      .new(tty_factory(dir), Lain::Frontend::Focus.tmux(env: {}), Lain::Herdr::Reporter::Null.new,
                           Lain::CLI::TmuxSurface.new, notes)
        built = new_wiring(options: { grace: 5 }, chronicle:, status_feed:, stdin: StringIO.new("quit\n"), herdr:,
                           conductor_opener:)
        built.run(backend:, resumed: nil, nvim: nil)
        built.conductor.close(reason: :exit)
      end

      expect(Lain::Forge::Gh::Account).to have_received(:configured).once.with(hash_including(notes:))
      expect(Lain::CLI::Command::Surface).to have_received(:new).with(hash_including(gh_account: account))
    end

    it "lends the bash backend the same GitHub account the command surface gets", :seam do
      account = instance_double(Lain::Forge::Gh::Account)
      allow(Lain::Forge::Gh::Account).to receive(:configured).and_return(account)
      allow(Lain::CLI::ExecBackend).to receive(:launch).and_call_original

      run_wiring

      expect(Lain::CLI::ExecBackend).to have_received(:launch).once.with(anything, hash_including(lend: account))
    end

    it "hands the StatusFeed the run's own Store, the only thing that lets inbox_count retire", :seam do
      wiring = run_wiring

      expect(status_feed).to have_received(:bind_store).with(wiring.command_surface.env.agent.timeline.store)
    end

    # The Conductor is the ONE place a user prompt is answered, so it is
    # where RunClock#record_input is called -- and the clock it records on has
    # to be the one the StatusFeed publishes, or the published idle never
    # resets. ChatLaunch builds it; this class only has to pass it on.
    it "passes the run's RunClock on to the conductor it opens", :seam do
      run_clock = Lain::RunClock.new
      seen = []
      opener = ->(**kwargs) { Lain::CLI::Conductor.open(**kwargs).tap { seen << kwargs[:run_clock] } }

      Dir.mktmpdir do |dir|
        wiring = new_wiring(options: { grace: 5 }, chronicle:, status_feed:, run_clock:,
                            tty_factory: tty_factory(dir), stdin: StringIO.new("quit\n"),
                            conductor_opener: opener)
        wiring.run(backend:, resumed: nil, nvim: nil)
        wiring.conductor.close(reason: :exit)
      end

      expect(seen).to eq([run_clock])
    end

    # The tracker is the real one and the notices are the ones Wiring built: a done main chat, 31 seconds
    # old, reaches the terminal as one sequence and the feed as one entry, and the ring itself stayed in the pane.
    context "with an agent-state tracker", :seam do
      let(:fed) { [] }
      let(:screen) { StringIO.new }
      let(:tracker) { Lain::AgentStates::Tracker.new(clock: Lain::RunClock.new) }
      let(:done) do
        telemetry = Lain::Telemetry
        [telemetry::RequestSent.new(digest: "blake3:#{"e" * 64}", payload: {}, stream: true, extra: {},
                                    prefix_digests: nil, prefix_chain_version: nil, requester: nil),
         telemetry::AskSettled.new(head: "blake3:#{"f" * 64}", stop_reason: "end_turn", turns: 1, seconds: 1.0)]
      end

      def capture_notices(into)
        allow(Lain::Notices).to receive(:for).and_return(->(*args) { fed << args })
        allow(Lain::CLI::Repl).to receive(:new).and_wrap_original do |original, **kwargs|
          into << kwargs[:notices]
          original.call(**kwargs)
        end
      end

      def screen_factory(dir)
        lambda do |channel:, tmux:, **|
          @rung = tmux
          Lain::Frontend::TTY.new(channel:, output: screen, history_path: File.join(dir, "history"), tmux:)
        end
      end

      def run_with(agent_states)
        captured = []
        capture_notices(captured)
        Dir.mktmpdir do |dir|
          wiring = new_wiring(options: { grace: 5 }, chronicle:, status_feed:, stdin: StringIO.new("quit\n"),
                              tty_factory: screen_factory(dir), conductor_opener:, agent_states:)
          wiring.run(backend:, resumed: nil, nvim: nil)
          wiring.conductor.close(reason: :exit)
        end
        captured.first
      end

      it "sends a finished agent's notice after the delay, through the terminal and the feed" do
        allow(Lain::Config).to receive(:attention).and_return(Lain::Config::Attention.new(delay: 0))
        notices = run_with(tracker)
        done.each { tracker << _1 }
        notices.tick

        expect(fed).to match([["lain", String, "done: main"]])
        expect(screen.string).to include("\e]777;notify;").and include("done: main")
      end

      it "asks the herdr binding's focus when a notice falls due" do
        allow(Lain::Config).to receive(:attention).and_return(Lain::Config::Attention.new(delay: 0))
        window = Struct.new(:asked) { def focused? = (self.asked = true) && false }.new
        herdr = Struct.new(:tty_factory, :focus, :reporter, :window_surface, :notes)
                      .new(nil, window, Lain::Herdr::Reporter::Null.new, Lain::CLI::TmuxSurface.new, Lain::Sink::Null.new)
        notices = nil
        Dir.mktmpdir do |dir|
          herdr.tty_factory = screen_factory(dir)
          captured = []
          capture_notices(captured)
          wiring = new_wiring(options: { grace: 5 }, chronicle:, status_feed:, stdin: StringIO.new("quit\n"),
                              herdr:, conductor_opener:, agent_states: tracker)
          wiring.run(backend:, resumed: nil, nvim: nil)
          wiring.conductor.close(reason: :exit)
          notices = captured.first
        end
        done.each { tracker << _1 }
        notices.tick

        expect(window.asked).to be(true)
      end

      it "keeps today's immediate notices when no tracker was passed" do
        expect(run_with(nil)).to be(Lain::AgentStates::Notices::Never)
        expect(@rung.call("hello")).to be_nil
        expect(fed).to match([["lain", String, "hello"]])
      end
    end

    # {Lain::CLI::Wiring#goal_journal} (wiring.rb:334) resolves the standing-goal
    # driver's destination through {Lain::CLI::Chronicle#record_journal}. Nothing
    # asserted it: replacing the resolution with a fresh /dev/null Journal left
    # the ENTIRE suite green (a mutant that survived), because every other
    # example here runs over Chronicle::Null, whose record_journal IS a discard
    # -- so a discard substituted for a discard changed nothing observable
    # anywhere. This one records, and drives the real driver the run wired.
    context "with a recording chronicle" do
      let(:journal_io) { StringIO.new }
      let(:chronicle) do
        Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io: journal_io),
                                 journal_path: "wiring-spec-goal.ndjson")
      end

      def settled_with(text)
        CoreGraph.timeline.commit(role: :user, content: [{ "type" => "text", "text" => "go" }])
                 .commit(role: :assistant, content: [{ "type" => "text", "text" => text }])
      end

      # `run_wiring` inlined for one reason: it closes the conductor, and
      # {Lain::CLI::Conductor#close} closes the session record. The driver has to
      # write while the record is still open, so the close moves BELOW the drive.
      it "wires the standing-goal driver over the run's own journal, not a discard", :seam do
        Dir.mktmpdir do |dir|
          wiring = new_wiring(options: { grace: 5 }, chronicle:, status_feed:,
                              tty_factory: tty_factory(dir), stdin: StringIO.new("quit\n"), conductor_opener:)
          wiring.run(backend:, resumed: nil, nvim: nil)

          driver = wiring.command_surface.goal_driver
          driver.start("ship it")
          driver.poll(settled_with("working on it"))
          wiring.conductor.close(reason: :exit)
        end

        records = journal_records(journal_io)
        # The run really opened a record, so the selection below is a search
        # through a populated file rather than two empty lists agreeing.
        expect(records.map { |record| record["type"] }).to include("session")
        expect(records.select { |record| record["type"] == "goal_iteration" }.map { |record| record["goal"] })
          .to eq(["ship it"])
      end

      # Readers of a session file take its first record as the header, and a
      # launch under the default auto approval journals a flip from ask.
      it "writes the session header before the launch's mode switch", :seam do
        Dir.mktmpdir do |dir|
          wiring = new_wiring(options: { grace: 5, approval: "auto" }, chronicle:, status_feed:,
                              tty_factory: tty_factory(dir), stdin: StringIO.new("quit\n"), conductor_opener:)
          wiring.run(backend:, resumed: nil, nvim: nil)
          wiring.conductor.close(reason: :exit)
        end

        records = journal_records(journal_io)
        expect(records.first["type"]).to eq(Lain::SessionRecord::HEADER_TYPE)
        expect(records.select { |record| record["type"] == "mode_switch" })
          .to contain_exactly(a_hash_including("from_approval" => "auto", "to_approval" => "auto",
                                               "surface" => Lain::CLI::Switchboard::LAUNCH_SURFACE))
      end

      it "writes the session header ahead of what a box with no sandbox journals" do
        allow(Lain::Confine::Probe).to receive(:new).and_wrap_original do |original, **kwargs|
          original.call(**kwargs, runner: ->(_argv) { ["", false] })
        end
        Dir.mktmpdir do |dir|
          wiring = new_wiring(options: { grace: 5 }, chronicle:, status_feed:, tty_factory: tty_factory(dir),
                              stdin: StringIO.new("quit\n"), conductor_opener:)
          wiring.run(backend:, resumed: nil, nvim: nil)
          wiring.conductor.close(reason: :exit)
        end

        types = journal_records(journal_io).map { |record| record["type"] }
        expect(types.first).to eq(Lain::SessionRecord::HEADER_TYPE)
        expect(types).to include("capability_degraded")
      end
    end

    # `--no-journal --nvim`: no session record, and every journal-role
    # collaborator is handed the tee onto nvim's own journal. A flip there must
    # apply whole -- gate policy and all -- and a goal must drive, where a tee
    # that answered only `<<` killed the chat on the first `record`.
    context "with a --no-journal chronicle teed onto an editor's journal", :seam do
      let(:tee_io) { StringIO.new }
      let(:chronicle) do
        Class.new(Lain::CLI::Chronicle::Null) do
          def initialize(tee)
            super()
            @tee = tee
          end
        end.new(Lain::CLI::JournalTee.new(Lain::Journal.new(io: tee_io), Lain::Channel::DropOldest.new))
      end

      def settled_with(text)
        CoreGraph.timeline.commit(role: :user, content: [{ "type" => "text", "text" => "go" }])
                 .commit(role: :assistant, content: [{ "type" => "text", "text" => text }])
      end

      # Scenario: a switch applies wholly under --no-journal --nvim
      it "applies /mode bypass to the gate and drives /goal, with no NoMethodError" do
        Dir.mktmpdir do |dir|
          wiring = new_wiring(options: { grace: 5 }, chronicle:, status_feed:,
                              tty_factory: tty_factory(dir), stdin: StringIO.new("quit\n"), conductor_opener:)
          wiring.run(backend:, resumed: nil, nvim: nil)
          commands = wiring.command_surface.commands

          commands.dispatch("/mode bypass") { raise "unmatched" }
          commands.dispatch("/goal ship it") { raise "unmatched" }
          prompt = wiring.command_surface.goal_driver.poll(settled_with("working on it"))
          wiring.conductor.close(reason: :exit)

          expect(wiring.instance_variable_get(:@switchboard).policy_switch.current.map(&:name))
            .to eq(%w[triage rules bypass])
          expect(prompt).to include("ship it")
        end

        types = tee_io.string.each_line.map { |line| JSON.parse(line)["type"] }
        expect(types).to include("mode_switch", "goal_iteration")
      end
    end

    it "hands commands the live run's project and typed model flags, so a fork reopens this project", :seam do
      env = run_wiring.command_env
      argv = env.child_argv.chat("--fork", "s.ndjson@abc")

      expect(argv).to eq(["chat", "--root", project_dir, "--cwd", project_dir, "--provider", "ollama",
                          "--fork", "s.ndjson@abc"])
      expect(Lain::CLI::ChildArgv.printable(argv)).to start_with("lain chat --root #{project_dir} --cwd #{project_dir}")
    end

    it "assembles the frozen Command::Env once, nil-free, from the collaborators it wired", :seam do
      wiring = run_wiring
      env = wiring.command_env

      expect(env).to be_frozen
      expect(env.sessions).to be_a(Lain::CLI::Sessions)
      expect(env.tmux_surface).to be_a(Lain::CLI::TmuxSurface)
      expect(env.approvals).to be(wiring.approvals)
      expect(env.supervisor).to be(wiring.supervisor)
      expect(env.replies).to be_a(Lain::CLI::HumanReplies)
      expect(env.agent).to be_a(Lain::Agent)
      expect(env.status).to be(status_feed)
      expect(env.fork_point).to be_a(Lain::CLI::ForkPoint)
      expect(env.chronicle).to be(chronicle)
    end

    # The load-bearing identity behind it (a review panel's probe): a dropped
    # surface_kwargs would leave this reader on its Null and silently
    # disconnect /model from the Agent's Context.
    it "hands the Env the SAME model switch the Agent's context holds", :seam do
      wiring = run_wiring
      env = wiring.command_env

      expect(env.model_switch).to be_a(Lain::Context::ModelSwitch)
      expect(env.agent.context.model).to eq(env.model_switch.current)
      env.model_switch.switch("probe-model-x", surface: "probe")
      expect(env.agent.context.model).to eq("probe-model-x")
    end

    # The session's ONE queue, pinned on the {Lain::CLI::Switchboard} because
    # that is what owns the policy switch: the gate policy is DERIVED from a
    # mode flip (#apply writes it as the consequence of the flip /mode reaches
    # through `mode_switch`), so no command reads it and Command::Env no longer
    # carries it. What the Gate holds is the LADDER, and the identity that
    # matters is one rung down -- its asking rung must park on the same object
    # /approve drains, or a rewiring gives the run two queues and the drain
    # empties the wrong one.
    #
    # Reached for privately, on the same terms as `board_for` below: the board
    # IS this run's authority and nothing in lib/ asks Wiring for it, so a
    # public reader would exist only for this example.
    it "parks the ladder's asking rung on the SAME queue /approve drains", :seam do
      wiring = run_wiring
      board = wiring.instance_variable_get(:@switchboard)

      expect(board.policy_switch).to be_a(Lain::Approval::Parked::PolicySwitch)
      expect(board.policy_switch.current).to be_a(Lain::Approval::Escalation)
      expect(board.policy_switch.current.find { |rung| rung.name == "surfaces" }.queue).to be(wiring.approvals)
      # The queue /approve actually drains, reached the way the command does.
      expect(wiring.command_env.approvals).to be(wiring.approvals)
    end

    # BEFORE the threading below, a wired session read the project tree FIVE
    # times -- two Skill::Catalog loads (the command Surface's, and the one
    # ReplMiddleware.renderer did for Tools::RunSkill) and three Prompt::Slots
    # loads (Backend's memoized one, the repl stack's, and RunSkill's). Same
    # tree, so the drift never showed in a test; it would show the moment a
    # `.lain/` file changed mid-session, and it defeats the "session-fixed
    # snapshot" claim both objects are documented with. One load each, threaded.
    describe "the session's ONE catalog and ONE slots", :seam do
      def help_catalog(surface)
        surface.commands.registry.find { |command| command.name == "help" }.instance_variable_get(:@catalog)
      end

      def run_skill_renderer(wiring)
        wiring.command_env.agent.toolset.fetch("run_skill").instance_variable_get(:@renderer)
      end

      def stack_renderer(surface)
        surface.middleware.to_a.first.instance_variable_get(:@renderer)
      end

      it "hands /help, the repl stack, and Tools::RunSkill the SAME Skill::Catalog" do
        wiring = run_wiring
        surface = wiring.command_surface
        catalog = help_catalog(surface)

        expect(catalog).to be_a(Lain::Skill::Catalog)
        expect(stack_renderer(surface).instance_variable_get(:@catalog)).to be(catalog)
        expect(run_skill_renderer(wiring).instance_variable_get(:@catalog)).to be(catalog)
      end

      it "hands Backend#context, RoleSpawn, and Tools::RunSkill the SAME Prompt::Slots" do
        wiring = run_wiring
        slots = backend.slots

        expect(slots).to be_a(Lain::Prompt::Slots)
        expect(wiring.role_spawn.instance_variable_get(:@slots)).to be(slots)
        expect(run_skill_renderer(wiring).instance_variable_get(:@slots)).to be(slots)
        expect(stack_renderer(wiring.command_surface).instance_variable_get(:@slots)).to be(slots)
      end

      # The pair had TWO owners -- Wiring loaded the catalog, Backend the
      # slots -- and travelled onward as two keywords, which is the state of an
      # object nobody had named. It is one {Skill::Library} now, owned by the
      # Backend (the lowest point above every reader, since #context renders the
      # slots into the system prompt). Both halves of the run therefore come out
      # of the SAME library instance, not merely out of equal snapshots.
      it "reads both halves out of the Backend's ONE library" do
        wiring = run_wiring
        library = backend.library

        expect(help_catalog(wiring.command_surface)).to be(library.catalog)
        expect(wiring.role_spawn.instance_variable_get(:@slots)).to be(library.slots)
        expect(run_skill_renderer(wiring).instance_variable_get(:@catalog)).to be(library.catalog)
      end

      # What the threading BUYS, stated as a count rather than as identity: five
      # reads of the project tree originally, two after the threading (one per
      # owner), and one apiece now. Identity alone would still pass if some
      # reader loaded a snapshot it then threw away, so the count is its own
      # assertion.
      it "loads the catalog exactly once and the slots exactly once for the whole session" do
        allow(Lain::Skill::Catalog).to receive(:load).and_call_original
        allow(Lain::Prompt::Slots).to receive(:load).and_call_original

        run_wiring

        expect(Lain::Skill::Catalog).to have_received(:load).once
        expect(Lain::Prompt::Slots).to have_received(:load).once
      end
    end

    it "wires the queue-shaped NoApprovals under --non-interactive, so the env reader stays nil-free", :seam do
      wiring = run_wiring(options: { grace: 5, non_interactive: true })

      expect(wiring.command_env.approvals).to be(Lain::CLI::Command::Env::NoApprovals)
    end

    # This class is the only object holding the Agent, the RunClock and
    # the StatusFeed at once, so composing the prompt's state reader is its
    # job -- and the TTY factory is where it hands it over.
    describe "the prompt renderer" do
      require "fileutils"

      let(:plain_theme) { Lain::Frontend::Theme.new(pastel: Pastel.new(enabled: false)) }

      # The fleet reading the renderer takes off the feed. Stubbed here and
      # nowhere else, because this is the only block that actually composes a
      # prompt -- every other #run spec leaves the renderer unused.
      before { allow(status_feed).to receive(:state).and_return(PublishedFeedState.build("fleet" => [])) }

      # Records what #run passed, and still builds a working TTY so the rest
      # of the run proceeds exactly as the specs above drive it.
      def recording_factory(dir, seen)
        lambda do |channel:, **kwargs|
          seen << kwargs[:prompt_renderer]
          tty_factory(dir).call(channel:)
        end
      end

      def run_recording(options: { grace: 5 }, &notice)
        seen = []
        Dir.mktmpdir do |dir|
          wiring = new_wiring(options:, chronicle:, status_feed:,
                              tty_factory: recording_factory(dir, seen), conductor_opener:,
                              stdin: StringIO.new("quit\n"))
          wiring.run(backend:, resumed: nil, nvim: nil, &notice)
          wiring.conductor.close(reason: :exit)
        end
        seen
      end

      it "hands the TTY factory a renderer composed from the run's own state", :seam do
        expect(run_recording.first).to be_a(Lain::Frontend::PromptComposer::Formatted)
      end

      # Through the wiring rather than in isolation: the renderer this
      # class built reads the LIVE agent, so the model it names is the one the
      # run is actually talking to.
      it "builds it over the live model slot, the run clock and the status feed", :seam do
        composed = run_recording.first.call(text: "> ", theme: plain_theme)

        expect(composed).to include(Lain::Provider::Ollama::DEFAULT_MODEL)
        expect(composed.lines.last).to eq("> ")
      end

      # The modes chunk wired the live switch and the shipped format's $mode
      # segment both; what never happened is THIS class handing the RunState the
      # switch to read. `checkout ask` is where a session starts and its lighters
      # are the empty String on purpose (default.toml's own note), so a chat that
      # never flips renders exactly as it did before this card -- the honest
      # reading is "nothing to say", not a literal word on the line. A flip is
      # where the wiring becomes observable: the SAME renderer, called again,
      # reads the switchboard's live slot and the chrome changes with it.
      it "wires the run's live mode switch into the prompt, so a mode flip shows at the next render" do
        agent = wire_agent
        board = wiring.instance_variable_get(:@switchboard)
        renderer = wiring.send(:prompt_renderer, agent, nil)

        before_flip = renderer.call(text: "> ", theme: plain_theme)
        expect(before_flip).not_to include("BYPASS")

        board.mode_switch.switch(Lain::Mode.new(approval: :bypass), surface: "spec")
        after_flip = renderer.call(text: "> ", theme: plain_theme)

        expect(after_flip).to include("BYPASS")
      end

      # The object identity behind the render above: the state the renderer was
      # BUILT with already names the switchboard's own mode_switch, not a copy
      # taken at construction time -- reached directly so this example fails for
      # the wiring reason rather than for a rendering or elision one.
      it "hands the RunState the switchboard's own mode_switch object" do
        agent = wire_agent
        board = wiring.instance_variable_get(:@switchboard)
        renderer = wiring.send(:prompt_renderer, agent, nil)
        state = renderer.instance_variable_get(:@state)

        expect(state.instance_variable_get(:@mode)).to be(board.mode_switch)
        expect(state.instance_variable_get(:@mode).current).to eq(Lain::Mode.new)
      end

      def startup_notices_for(provider)
        notices = []
        Lain::Provider::Admission.reset!
        with_env("OLLAMA_API_KEY" => "sk-ollama-test", "LAIN_PROVIDER_CONCURRENCY" => nil) do
          cloud_backend = offline_backend_class.new({ provider:, model: nil, max_tokens: 64 },
                                                    mock: mock_provider, root: backend_root)
          seen = []
          Dir.mktmpdir do |dir|
            wiring = new_wiring(options: { grace: 5 }, chronicle:, status_feed:,
                                tty_factory: recording_factory(dir, seen), conductor_opener:,
                                stdin: StringIO.new("quit\n"))
            wiring.run(backend: cloud_backend, resumed: nil, nvim: nil) { |notice| notices << notice }
            wiring.conductor.close(reason: :exit)
          end
        end
        notices
      end

      it "tells a cloud chat its width at startup", :seam do
        expect(startup_notices_for("ollama-cloud").join).to include("cloud requests at once")
      end

      it "says nothing about cloud width to a local chat", :seam do
        expect(startup_notices_for("ollama").join).not_to include("cloud requests")
      end

      # A project config that does not parse is reported through the same
      # startup-notice seam a resumed chat's notices use, and the chat is still
      # usable -- today's prompt, not a crash.
      def with_project_config(bytes)
        notices = []
        renderer = Dir.mktmpdir do |project|
          FileUtils.mkdir_p(File.join(project, ".lain"))
          File.binwrite(File.join(project, ".lain", "prompt.toml"), bytes)
          Dir.chdir(project) { run_recording { |notice| notices << notice }.first }
        end
        [notices, renderer]
      end

      it "reports a malformed project config as a startup notice, and keeps the chat usable", :seam do
        notices, renderer = with_project_config(%(format = "[unclosed"\n))

        expect(notices.join).to include("prompt.toml")
        expect(renderer).to be_a(Lain::Frontend::PromptComposer::Null)
      end

      # `Wiring#run` has no rescue around the renderer and `exe/lain` catches
      # only Lain::Error, so an EncodingError escaping `.renderer` aborts the
      # chat with a backtrace before a prompt ever exists. A single Latin-1
      # byte in a project config is enough to do it.
      it "survives a project config that is not valid UTF-8, rather than aborting the chat", :seam do
        notices = renderer = nil

        expect { notices, renderer = with_project_config(%(format = "\xBB "\n).b) }.not_to raise_error
        expect(notices.join).to include("prompt.toml")
        expect(renderer).to be_a(Lain::Frontend::PromptComposer::Null)
      end
    end

    describe "the write-record notice", :seam do
      def quiet_tty(dir)
        lambda do |channel:, alternate_screen: true, **|
          Lain::Frontend::TTY.new(channel:, output: StringIO.new, history_path: File.join(dir, "history"),
                                  alternate_screen:)
        end
      end

      def resumed_from(file)
        Lain::CLI::Resume::Result.new(
          file:, timeline: Lain::Dag::Factory.timeline(head_digest: nil, store: Lain::Dag::Factory.store), session: Lain::Session.new,
          open: false, notices: [], recorder: Lain::Memory::Recorder.new(index: Lain::Memory::Index.empty)
        )
      end

      def said_resuming(file, state)
        said = []
        Dir.mktmpdir do |dir|
          wiring = new_wiring(options: { grace: 5 }, chronicle:, status_feed:, conductor_opener:,
                              paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => state, "HOME" => state }),
                              tty_factory: quiet_tty(dir), stdin: StringIO.new("quit\n"))
          wiring.run(backend:, resumed: resumed_from(file), nvim: nil) { |line| said << line }
          wiring.conductor.close(reason: :exit)
        end
        said
      end

      it "is said at startup when the resumed lineage's write records cannot be read" do
        Dir.mktmpdir do |state|
          expect(said_resuming("missing.ndjson", state).grep(/write records could not be read/).size).to eq(1)
        end
      end

      it "is not said for a lineage that reads cleanly" do
        Dir.mktmpdir do |state|
          store = Lain::Paths.new(env: { "XDG_STATE_HOME" => state, "HOME" => state })
          sessions = store.filing_dir(root: File.realpath(project_dir))
          header = JSON.generate("ts" => "2099-01-01T00:00:00.000000Z", "type" => "session")
          File.write(File.join(sessions, "ok.ndjson"), "#{header}\n")

          expect(said_resuming("ok.ndjson", state).grep(/write records/)).to be_empty
        end
      end
    end

    # The alternate screen wipes whatever was printed before it opened, so a
    # notice said only at launch is gone before the human sees the chat.
    describe "resume notices on the chat screen", :seam do
      let(:mismatch) { "recorded with --compact-keep 4; continuing with 8 (the current flags win)" }

      def resumed_with_notice
        timeline = Lain::Dag::Factory.timeline(head_digest: nil, store: Lain::Dag::Factory.store)
        Lain::CLI::Resume::Result.new(file: "prior.ndjson", timeline:, session: Lain::Session.new, open: false,
                                      recorder: Lain::Memory::Recorder.new(index: Lain::Memory::Index.empty),
                                      notices: [mismatch])
      end

      def run_resumed(stdin:, options: { grace: 5 })
        said = []
        screen = StringIO.new
        Dir.mktmpdir do |dir|
          factory = lambda do |channel:, alternate_screen: true, **|
            Lain::Frontend::TTY.new(channel:, output: screen, history_path: File.join(dir, "history"),
                                    alternate_screen:)
          end
          wiring = new_wiring(options:, chronicle:, status_feed:, stdin:,
                              tty_factory: factory, conductor_opener:)
          wiring.run(backend:, resumed: resumed_with_notice, nvim: nil) { |line| said << line }
          wiring.conductor.close(reason: :exit)
        end
        [said, screen.string]
      end

      it "draws a notice after the alternate screen opens, where the human can still see it" do
        stdin = StringIO.new
        allow(stdin).to receive(:tty?).and_return(true)
        allow(Reline).to receive(:readmultiline).and_return("quit")

        _said, screen = run_resumed(stdin:, options: { grace: 5 })

        expect(screen.index(mismatch)).to be > screen.index(Lain::Frontend::TTY::ALTERNATE_SCREEN_ON)
      end

      def pane_output
        @pane_output ||= Class.new(StringIO) do
          def tty? = true
          def winsize = [24, 60]
        end.new
      end

      def pane_wiring(dir, paths)
        stdin = StringIO.new
        allow(stdin).to receive(:tty?).and_return(true)
        allow(status_feed).to receive(:state).and_return({})
        factory = lambda do |channel:, alternate_screen: true, **|
          Lain::Frontend::TTY.new(channel:, output: pane_output, history_path: File.join(dir, "history"),
                                  alternate_screen:)
        end
        new_wiring(options: { grace: 5, input: "socket:wiring-scrollback" }, chronicle:,
                   status_feed:, paths:, stdin:, tty_factory: factory, conductor_opener:)
      end

      def run_in_pane(notice)
        said = []
        Dir.mktmpdir do |dir|
          paths = Lain::Paths.new(env: { "XDG_RUNTIME_DIR" => dir })
          path = Lain::CLI::InputSocket.path(name: "wiring-scrollback", paths:, cwd: project_dir)
          wiring = pane_wiring(dir, paths)
          pane = Thread.new { end_the_chat_from_a_pane(path) }
          wiring.run(backend:, resumed: resumed_with(notice), nvim: nil) { |line| said << line }
          wiring.conductor.close(reason: :exit)
          pane.join
        end
        said
      end

      def resumed_with(notice)
        timeline = Lain::Dag::Factory.timeline(head_digest: nil, store: Lain::Dag::Factory.store)
        Lain::CLI::Resume::Result.new(file: "prior.ndjson", timeline:, session: Lain::Session.new, open: false,
                                      recorder: Lain::Memory::Recorder.new(index: Lain::Memory::Index.empty),
                                      notices: [notice])
      end

      # A cockpit chat's notices stay in scrollback, drawn by the terminal so they wrap to the pane.
      it "stays on normal scrollback and draws a notice once when a pane reads the human" do
        said = run_in_pane("short notice")

        expect(pane_output.string).not_to include("\e[?1049h")
        expect(pane_output.string.scan("short notice").size).to eq(1)
        expect(said).not_to include("short notice")
      end

      it "wraps a long notice to the width of the pane it is drawn in" do
        long = Array.new(20) { |i| "word#{i}" }.join(" ")
        run_in_pane(long)

        lines = pane_output.string.gsub(/\e\[[\d;?]*[A-Za-z]/, "").lines.map(&:chomp).grep(/word/)
        expect(lines.size).to be > 1
        expect(lines.map(&:length).max).to be <= 60
        expect(lines.join(" ").scan(/word\d+/)).to eq(Array.new(20) { |i| "word#{i}" })
      end

      it "draws no alternate screen under --non-interactive, and says a notice once" do
        stdin = StringIO.new("quit\n")
        allow(stdin).to receive(:tty?).and_return(true)

        said, screen = run_resumed(stdin:, options: { grace: 5, non_interactive: true })

        expect(screen).not_to include(Lain::Frontend::TTY::ALTERNATE_SCREEN_ON)
        expect(said.count(mismatch)).to eq(1)
        expect(screen).not_to include(mismatch)
      end

      it "says a notice once to the notice block when there is no terminal" do
        said, screen = run_resumed(stdin: StringIO.new("quit\n"))

        expect(said.count(mismatch)).to eq(1)
        expect(screen).not_to include(mismatch)
      end
    end

    # The `vi` and `notify` layers are the terminal's to act on, so what this
    # class owes the TTY factory is the session's layer set as it is NOW --
    # read through the live switch `/mode` writes, never a copy taken at launch.
    describe "the mode layers the terminal reads", :seam do
      def layered_factory(rendered, dir, seen)
        lambda do |channel:, layers:, **|
          seen << layers
          Lain::Frontend::TTY.new(channel:, output: rendered, layers:, history_path: File.join(dir, "history"),
                                  tmux: ->(_note) {})
        end
      end

      def run_layered(rendered = StringIO.new, seen = [])
        Dir.mktmpdir do |dir|
          wiring = new_wiring(options: { grace: 5 }, chronicle:, status_feed:,
                              tty_factory: layered_factory(rendered, dir, seen), conductor_opener:,
                              stdin: StringIO.new("quit\n"))
          wiring.run(backend:, resumed: nil, nvim: nil)
          yield wiring
          wiring.conductor.close(reason: :exit)
        end
        seen
      end

      def type_mode(wiring, args) = Lain::CLI::Command::Mode.new.call(args, wiring.command_env)

      it "hands the factory a reading of the layers that follows /mode" do
        seen = run_layered do |wiring|
          type_mode(wiring, "+vi")
        end

        expect(seen.size).to eq(1)
        expect(seen.first.call).to include(:vi)
      end

      it "hands it a reading that shows a layer lowered again" do
        seen = run_layered do |wiring|
          type_mode(wiring, "+vi +notify")
          type_mode(wiring, "-vi")
        end

        expect(seen.size).to eq(1)
        expect(seen.first.call.names).to eq([:notify])
      end

      it "hands the factory a Notifier built from the process environment as the tmux duck" do
        ducks = []
        Dir.mktmpdir do |dir|
          factory = lambda do |channel:, tmux:, **|
            ducks << tmux
            Lain::Frontend::TTY.new(channel:, output: StringIO.new, history_path: File.join(dir, "history"))
          end
          wiring = new_wiring(options: { grace: 5 }, chronicle:, status_feed:, tty_factory: factory,
                              conductor_opener:, stdin: StringIO.new("quit\n"),
                              paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => dir, "HOME" => dir }))
          wiring.run(backend:, resumed: nil, nvim: nil)
          wiring.conductor.close(reason: :exit)
        end

        expect(ducks.sole).to be_a(Lain::Frontend::TTY::Notifier)
      end

      it "rings a kitty terminal through the TTY's own output, masked, and feeds the same masked note" do
        rendered = StringIO.new
        fed = []
        allow(Lain::Notices).to receive(:for).and_return(->(*args) { fed << args })
        stub_const("ENV", ENV.to_h.merge("KITTY_WINDOW_ID" => "3").except("TMUX", "TERM_PROGRAM"))
        factory = lambda do |channel:, layers:, tmux:, **|
          Lain::Frontend::TTY.new(channel:, output: rendered, layers:, tmux:,
                                  history_path: File.join(Dir.tmpdir, "wiring-notify-#{Process.pid}"))
        end

        Dir.mktmpdir do |dir|
          wiring = new_wiring(options: { grace: 5 }, chronicle:, status_feed:, tty_factory: factory,
                              conductor_opener:, stdin: StringIO.new("quit\n"),
                              paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => dir, "HOME" => dir }))
          wiring.run(backend:, resumed: nil, nvim: nil)
          type_mode(wiring, "+notify")
          wiring.told.call("key AKIAIOSFODNN7EXAMPLE is open")
          wiring.conductor.close(reason: :exit)
        end

        expect(rendered.string).to include("\e]99;;key <redacted:1> is open\e\\")
        expect(fed.sole.last).to eq("key <redacted:1> is open")
      end

      # `request_review`'s line to the human is a wait on them, so it rings
      # unless the human typed /mode +quiet.
      it "rings the terminal with the run's line to the human with no layer set" do
        rendered = StringIO.new

        run_layered(rendered) { |wiring| wiring.told.call("epic.md is open for review") }

        expect(rendered.string.count("\a")).to eq(1)
        expect(rendered.string.index("\a")).to be > rendered.string.index("epic.md is open for review")
      end

      it "rings nothing for the run's line to the human once /mode +quiet is typed" do
        rendered = StringIO.new

        run_layered(rendered) do |wiring|
          type_mode(wiring, "+quiet")
          wiring.told.call("epic.md is open for review")
        end

        expect(rendered.string).to include("epic.md is open for review")
        expect(rendered.string).not_to include("\a")
      end
    end

    # request_review is a capability, so it is the toolset build's to
    # append -- but WHICH epic a chat is in is a question the chat tier never
    # had to answer before, and the answer decides whether the tool exists at
    # all. {EpicMount} owns both; what these examples pin is the wiring.
    #
    # Isolation is total and deliberate: a repo-mode epics home under the
    # tmpdir, plus an XDG state home inside it, so neither this developer's
    # real epics nor their real session journals can decide an example.
    describe "the epic tier's request_review tool" do
      require "fileutils"

      def with_state_home(path)
        was = ENV.fetch("XDG_STATE_HOME", nil)
        ENV["XDG_STATE_HOME"] = path
        yield
      ensure
        ENV["XDG_STATE_HOME"] = was
      end

      # Written straight to the repo-mode layout rather than through
      # {Epic::Home}: an epic exists once its document is on disk, and this
      # spec is about the wiring above that, not about path arithmetic.
      def create_epic(dir, slug)
        graph = Lain::Epic::Graph.new(issues: [Lain::Epic::Issue.new(id: "a1", title: "the a1 issue")])
        path = File.join(dir, ".lain", "epics", slug, "epic.md")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, Lain::Epic::Document.to_markdown(graph))
      end

      def in_project(*slugs)
        Dir.mktmpdir do |dir|
          slugs.each { |slug| create_epic(dir, slug) }
          with_state_home(File.join(dir, "state")) do
            write_config(dir, "epics home: :repo\n")
            Dir.chdir(dir) { yield(dir) }
          end
        end
      end

      def toolset_named(options: { grace: 5 })
        mounted = described_class.new(options:, chronicle:, status_feed:)
        recorder, session = mounted.run_state(nil)
        mounted.wire_agent(channel:, recorder:, session:, backend:).toolset.names
      end

      def run_in(dir, options: { grace: 5 }, &notice)
        wiring = described_class.new(options:, chronicle:, status_feed:,
                                     herdr: null_herdr(tty_factory(dir)),
                                     stdin: StringIO.new("quit\n"), conductor_opener:)
        wiring.run(backend: fresh_backend, resumed: nil, nvim: nil, &notice)
        wiring.conductor.close(reason: :exit)
        wiring
      end

      it "wires the tool when the project's sole epic resolves" do
        in_project("alpha") { expect(toolset_named).to include("request_review") }
      end

      it "wires the tool for the epic --epic names" do
        in_project("alpha", "beta") do
          expect(toolset_named(options: { grace: 5, epic: "beta" })).to include("request_review")
        end
      end

      # A chat must never fail to start over this, and a tool that cannot act
      # must not be offered to the model.
      it "leaves the tool out, and says why, when the home holds several epics and none was named", :seam do
        in_project("alpha", "beta") do |dir|
          said = []

          expect(toolset_named).not_to include("request_review")
          run_in(dir) { |notice| said << notice }
          expect(said.join).to include("--epic")
        end
      end

      # The ordinary chat: no epic anywhere, no tool, and nothing said.
      it "starts a chat with no epic home at all, silently", :seam do
        Dir.mktmpdir do |dir|
          with_state_home(File.join(dir, "state")) do
            Dir.chdir(dir) do
              said = []

              expect(toolset_named).not_to include("request_review")
              expect { run_in(dir) { |notice| said << notice } }.not_to raise_error
              expect(said).to be_empty
            end
          end
        end
      end

      it "sends a mounted chat's agent the epic's slug, home path and tools in its workspace", :seam do
        in_project("alpha") do |dir|
          reminders = run_in(dir).command_env.agent.workspace.reminders.join("\n")

          expect(reminders).to include("alpha", File.join(dir, ".lain", "epics", "alpha"), "epic_graph", "epic_show",
                                       "epic_status")
        end
      end

      describe "the session header", :seam do
        let(:journal_io) { StringIO.new }
        let(:chronicle) do
          Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io: journal_io),
                                   journal_path: File.join(Dir.tmpdir, "epic-header-#{Process.pid}.ndjson"))
        end

        def header_reminders = journal_records(journal_io).find { |r| r["type"] == "session" }["reminders"]

        it "records the epic line of a mounted chat, so a replay renders what the model was sent" do
          in_project("alpha") do |dir|
            run_in(dir)

            expect(header_reminders.join).to include("alpha", File.join(dir, ".lain", "epics", "alpha"))
          end
        end

        it "records no reminder for a chat in no epic" do
          in_project do |dir|
            run_in(dir)

            expect(header_reminders).to be_empty
          end
        end
      end

      it "sends a chat in no epic an empty workspace", :seam do
        in_project do |dir|
          expect(run_in(dir).command_env.agent.workspace.reminders).to be_empty
        end
      end

      # {HumanReplies} is built in #build_repl, strictly AFTER the toolset --
      # so the tool holds a thunk, and what it must read at CALL time is the
      # run's ONE live replies object, the same one the Env hands the commands.
      it "late-binds the tool to the live HumanReplies the run built", :seam do
        in_project("alpha") do |dir|
          wiring = run_in(dir)
          tool = wiring.command_env.agent.toolset.fetch("request_review")

          expect(tool.send(:bindings)).to equal(wiring.command_env.replies)
        end
      end

      # `/implement-epic` drives the SAME mount the tool and the editor read.
      # The seat resolves it once, and the driver is built from that one mount:
      # a second EpicMount.for would hand this chat a second Epic::Review over
      # one journal, which stops guarding silently.
      it "builds the command surface's epic driver from the seat's one mount", :seam do
        in_project("alpha") do |dir|
          driver = run_in(dir).command_env.epic_driver

          expect(driver).to be_mounted
          expect(driver.slug).to eq("alpha")
        end
      end

      # No epic resolved costs the chat its driver exactly as it costs it the
      # tool -- and what it gets instead is the refusing Null, never nil.
      it "hands it the refusing Null when no epic resolves, so the command still answers", :seam do
        in_project("alpha", "beta") do |dir|
          expect(run_in(dir).command_env.epic_driver).not_to be_mounted
        end
      end

      # THE REASON THIS GROUP NEEDED MORE THAN IT HAD. This wiring
      # mounted the epic with `notify:` and `bindings:` only, so `changesets:`
      # and `surface:` stayed nil, `Implementation#hold` answered
      # `Refusals.no_changeset` on every call in every real process, and the
      # surface resolved to the Null. NOTHING AMONG 10865 EXAMPLES COULD SEE IT:
      # every existing example of the changeset half passes those seams in by
      # hand. These two drive the PRODUCTION mount instead -- real git, the real
      # thunks -- and answer the review on the rail an editor answers it on.
      describe "the changeset half of that tool, over the wiring the exe uses", :seam do
        # The frontend, reduced to the three messages {HumanReplies} asks of one
        # ({Frontend::Neovim} answers exactly these). The surface is the REAL
        # text one and the view the REAL sidebar view: what is under test is
        # whether the tool reaches THESE rather than its nulls, and a double
        # answering the port would be indistinguishable from `Surface::Null`.
        def review_editor(sink)
          view = Lain::Frontend::Neovim::ReviewView.new
          surface = Lain::Review::Surface::Text.new(sink:)
          Object.new.tap do |editor|
            editor.define_singleton_method(:review_surface) { surface }
            editor.define_singleton_method(:review_view) { view }
            editor.define_singleton_method(:bound) { @bound }
            editor.define_singleton_method(:bind_changeset_review) { |review| @bound = review }
          end
        end

        # A project that is BOTH an epic home and a git repository with
        # something to review, because {Wiring#epic_mount} builds its changeset
        # source over the resolved project's ROOT ({CLI::ReviewSeams.for}'s
        # `root:`): the two have to be one directory. It read `Dir.pwd` when
        # this was written, and named a `#review_seams` that never existed.
        # The epic's own files are written AFTER the commit, so they stay
        # untracked and the changeset under review is the one file this example
        # is about. Committed first, the epic document is in the diff too --
        # which is not wrong, but it makes the review two files wide for no
        # reason and every hunk of it has to be marked before a verdict is
        # admissible.
        def in_repo(slug: "alpha")
          Dir.mktmpdir do |dir|
            FileUtils.cp_r(File.join(SeedRepo.at("README" => "seed\n"), "."), dir)
            commit(dir)
            create_epic(dir, slug)
            with_state_home(File.join(dir, "state")) do
              write_config(dir, "epics home: :repo\n")
              Dir.chdir(dir) { yield(dir) }
            end
          end
        end

        # The second commit, so `HEAD~1..HEAD` is a real one-file changeset.
        def commit(dir)
          File.write(File.join(dir, "README"), "seed\nthe line under review\n")
          [%w[add -A], ["commit", "-q", "-m", "the work under review"]].each do |argv|
            SeedRepo.git(dir, *argv)
          end
        end

        def invocation = Lain::Tool::Invocation.new(context: Lain::Session::Null.instance)

        # The hand-over whole, as a human doing it would: the tool parks, the
        # editor's own rail is handed a review, the human answers it there.
        # `pumped_until` and not a bare `task.yield`: the call shells out to git
        # before it binds anything, so the moment the rail is handed a review is
        # several reactor turns away and a fixed number of yields would be a
        # guess. Bounded, so a review that never binds is a failing example
        # naming the condition rather than a hang.
        def reviewed(wiring, editor)
          tool = wiring.command_env.agent.toolset.fetch("request_review")
          result = nil
          Sync do |task|
            call = task.async { result = tool.call({ "stage" => "implementation", "base" => "HEAD~1" }, invocation) }
            pumped_until(task, reason: "the editor's rail was handed a review") { editor.bound }
            yield
            call.wait
          end
          result
        end

        # The human's whole side of it, on the objects the wiring supplied: read
        # the sidebar the editor's OWN view drew, mark the row, answer.
        #
        # The mark is not decoration. This wiring passes no `policy:`, so the
        # tool takes {Verdict::Policy.default} -- `EveryHunk`, which refuses an
        # approve over hunks nobody read -- and a verdict refused leaves the call
        # parked. So `be_ok` below holds only if the mark reached the session
        # THROUGH the view the wiring injected, which is what makes one
        # assertion cover all three seams.
        def marked_and_approved(editor)
          handover = editor.bound
          rendering = editor.review_view.render(handover.session.marked, scope: :cumulative)
          row = rendering.lines.index { |line| line.include?("README") } + 1
          handover.mark(row, "reviewed", generation: rendering.generation)
          handover.wrote_verdict("approve")
        end

        it "supplies a changeset source, a view and a rail, so the stage opens and a verdict settles it" do
          in_repo do |dir|
            wiring = run_in(dir)
            editor = review_editor(StringIO.new)
            wiring.command_env.replies.bind_review_editor(editor)

            result = reviewed(wiring, editor) { marked_and_approved(editor) }

            expect(result).to be_ok
            expect(result.content).to include("approve").and include("review-changeset-v1:")
          end
        end

        it "supplies the editor's own surface and view, and not the nulls that stood in for them" do
          in_repo do |dir|
            wiring = run_in(dir)
            sink = StringIO.new
            editor = review_editor(sink)
            wiring.command_env.replies.bind_review_editor(editor)
            gesture = nil

            reviewed(wiring, editor) do
              # The VIEW, told apart from {Handover::Detached} by whose sentence
              # comes back: a live view says nothing has been rendered into IT
              # yet, and the null says there is no editor at all. Two facts, and
              # a tool holding the null would answer the wrong one.
              gesture = editor.bound.open(1, generation: nil)
              marked_and_approved(editor)
            end

            expect(sink.string).to include("README")
            expect(gesture.report).to include("lain://review")
          end
        end
      end
    end
  end

  # The run's {Lain::Project}, threaded. Five collaborators used to reach
  # `Dir.pwd` for themselves, which made "where is this project" a question
  # five objects answered independently -- and answered WRONG from a
  # subdirectory, where the root is up the tree and the cwd is not it.
  #
  # NOTHING HERE CHDIRS, and that is the whole design of the block: the process
  # working directory stays the repository this suite runs in, so every
  # assertion below distinguishes the injected project from `Dir.pwd` rather
  # than watching the two agree by construction.
  describe "the resolved project" do
    require "fileutils"
    require "tmpdir"

    # A root with a real subdirectory to sit in, so root and cwd are DIFFERENT
    # directories and an assertion can say which one a collaborator got.
    # Realpath'd because {Lain::Project} resolves, and a tmpdir is a symlink on
    # more boxes than not.
    #
    # The XDG state home moves under the tree for {Lain::CLI::EpicMount}'s
    # sake -- the group one describe up does the same -- so this developer's
    # real epics can never decide an example.
    def in_project_tree
      Dir.mktmpdir("lain-t5-project") do |dir|
        root = File.realpath(dir)
        cwd = File.join(root, "services", "ingest")
        FileUtils.mkdir_p(cwd)
        with_env("XDG_STATE_HOME" => File.join(root, "state")) { yield(root, cwd) }
      end
    end

    def project_at(root, cwd) = Lain::Project.new(root:, cwd:, kind: :project, detected_by: :flag)

    def wiring_for(project, options: { grace: 5 })
      described_class.new(options:, chronicle:, status_feed:, project:)
    end

    # The whole run, so {Lain::CLI::Command::Surface} exists: it is built in
    # #build_repl, which only #run reaches. The conductor opener is the real
    # default -- what is under test is the project, not the seams the #run
    # group above already drives.
    def run_project(project, options: { grace: 5 })
      Dir.mktmpdir("lain-t5-tty") do |dir|
        wiring = described_class.new(options:, chronicle:, status_feed:, project:,
                                     herdr: null_herdr(project_tty_factory(dir)),
                                     stdin: StringIO.new("quit\n"))
        wiring.run(backend:, resumed: nil, nvim: nil)
        wiring.conductor.close(reason: :exit)
        wiring
      end
    end

    def project_tty_factory(dir)
      lambda do |channel:, **|
        Lain::Frontend::TTY.new(channel:, output: StringIO.new, history_path: File.join(dir, "history"))
      end
    end

    it "runs the chat's Session in the project's CWD, which is not its root" do
      in_project_tree do |root, cwd|
        _, session = wiring_for(project_at(root, cwd)).run_state(nil)

        expect(session.worker_env.cwd).to eq(cwd)
      end
    end

    it "hands every Config reader the Paths it holds, from the isolation handback to the command surface" do
      Dir.mktmpdir("lain-wiring-readers") do |dir|
        base = File.realpath(dir)
        root = File.join(base, "repo")
        FileUtils.cp_r("#{SeedRepo.at({ "README.md" => "seed\n" })}/.", root)
        paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(base, "s"), "HOME" => File.join(base, "h") })
        write_config(root, "approval timeout: 900\ntests preset: :rspec, source_roots: %w[app]\n", paths:)
        seen = []
        %i[load sensitivity shell_exclusions test_layout budget approval_timeout search].each do |reader|
          allow(Lain::Config).to receive(reader).and_wrap_original do |original, **kwargs|
            seen << [reader, kwargs.fetch(:paths)]
            original.call(**kwargs)
          end
        end
        wiring = described_class.new(options: { grace: 5, isolation: "worktree" }, chronicle:, status_feed:, paths:,
                                     project: throwaway_project(root), herdr: null_herdr(project_tty_factory(base)),
                                     stdin: StringIO.new("quit\n"))

        with_env("HOME" => base, "XDG_STATE_HOME" => base, "XDG_CONFIG_HOME" => base) do
          owned = offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: mock_provider,
                                                                                                root:, paths:)
          wiring.run(backend: owned, resumed: nil, nvim: nil)
          wiring.conductor.close(reason: :exit)
        end

        expect(seen.map(&:first).tally).to include(test_layout: 2, budget: 2)
        expect(seen.reject { |_, used| used.equal?(paths) }).to be_empty
      end
    end

    # The env half of the WorkerEnv is untouched: this card moves the working
    # directory a chat's tools resolve against, and nothing else about the
    # host-side execution context.
    it "leaves the chat's environment snapshot exactly as WorkerEnv.default takes it" do
      in_project_tree do |root, cwd|
        _, session = wiring_for(project_at(root, cwd)).run_state(nil)

        expect(session.worker_env.env).to eq(Lain::WorkerEnv.default.env)
      end
    end

    # Spies rather than effect-reading, for one reason: three of the four
    # consume the root into a path they then only use on the way to git or to
    # disk, so what a spec could see afterwards is a derived artifact and not
    # the root. What is under test is the THREADING, and the argument IS the
    # threading. The two that leave a readable trace get it asserted below as
    # well.
    it "hands the isolation and exec backends, epic mount, review seams and command surface the ROOT", :seam do
      allow(Lain::CLI::IsolationBackend).to receive(:resolve).and_call_original
      allow(Lain::CLI::ExecBackend).to receive(:new).and_call_original
      allow(Lain::CLI::EpicMount).to receive(:for).and_call_original
      allow(Lain::CLI::ReviewSeams).to receive(:for).and_call_original
      allow(Lain::CLI::Command::Surface).to receive(:new).and_call_original

      in_project_tree do |root, cwd|
        run_project(project_at(root, cwd))

        expect(Lain::CLI::IsolationBackend).to have_received(:resolve).with(anything, hash_including(root:))
        expect(Lain::CLI::ExecBackend).to have_received(:new).with(anything, hash_including(root:))
        expect(Lain::CLI::EpicMount).to have_received(:for).with(hash_including(root:))
        expect(Lain::CLI::ReviewSeams).to have_received(:for).with(anything, root:)
        expect(Lain::CLI::Command::Surface).to have_received(:new).with(hash_including(root:))
      end
    end

    # The rail the chat built is the one that asks the registry and the one /held lists, so
    # a bare Intake in its place, or a surface built without it, reads here.
    it "refuses /approve with nothing pending and lists what was held, through the chat's own rail", :seam do
      in_project_tree do |root, cwd|
        output = StringIO.new
        Dir.mktmpdir("lain-held-tty") do |dir|
          factory = lambda do |channel:, **|
            Lain::Frontend::TTY.new(channel:, output:, history_path: File.join(dir, "history"))
          end
          wiring = described_class.new(options: { grace: 5 }, chronicle:, status_feed:, project: project_at(root, cwd),
                                       herdr: null_herdr(factory), stdin: StringIO.new("quit\n"))
          wiring.run(backend:, resumed: nil, nvim: nil)
          wiring.conductor.hold("/approve")
          wiring.conductor.hold("do this later")
          listing = wiring.command_surface.commands.dispatch("/held") { raise "unmatched" }
          wiring.conductor.close(reason: :exit)

          expect([output.string.scan("no pending approvals").size, listing])
            .to eq([1, "held for you>:\n  1. do this later"])
        end
      end
    end

    # The surface's own trace, so the spy above is not the only witness: `/meta`,
    # `/review` and `/review-submit` are each constructed with this root.
    it "leaves that root where /meta and the two review commands read it", :seam do
      in_project_tree do |root, cwd|
        surface = run_project(project_at(root, cwd)).command_surface

        expect(surface.instance_variable_get(:@root)).to eq(root)
      end
    end

    # A run whose cwd is a subdirectory still journals against the project, and
    # the two are asserted TOGETHER because the pair is the point: the tools
    # work where the user is, the project-scoped collaborators work where the
    # project is.
    it "sends the cwd to the Session and the root to the collaborators, from one Project", :seam do
      in_project_tree do |root, cwd|
        wiring = run_project(project_at(root, cwd))

        expect(wiring.command_env.agent.session.worker_env.cwd).to eq(cwd)
        expect(wiring.command_surface.instance_variable_get(:@root)).to eq(root)
      end
    end

    # With nothing injected the default resolves the process's own
    # project, and a chat started in a directory that IS its own root gets the
    # WorkerEnv it got before this card existed -- byte for byte.
    describe "the default" do
      it "is byte-identical to WorkerEnv.default when the cwd is its own root" do
        Dir.mktmpdir("lain-t5-default") do |dir|
          Dir.chdir(File.realpath(dir)) do
            _, session = described_class.new(options: { grace: 5 }, chronicle:, status_feed:).run_state(nil)

            expect(session.worker_env).to eq(Lain::WorkerEnv.default)
          end
        end
      end

      it "resolves the working directory's own project" do
        Dir.mktmpdir("lain-t5-default") do |dir|
          Dir.chdir(File.realpath(dir)) do
            project = described_class.new(options: { grace: 5 }, chronicle:, status_feed:).project

            expect([project.root, project.cwd]).to eq([File.realpath(dir), File.realpath(dir)])
          end
        end
      end

      # THE EXAMPLE THAT MAKES THE TWO ABOVE MEAN SOMETHING. Both of them chdir
      # into a bare tmpdir that is its own root, so `root == cwd` holds by
      # construction and `Dir.pwd` would satisfy them exactly as the resolver
      # does -- the review demonstrated it: replacing #default_project's body
      # with `Project.new(root: Dir.pwd, cwd: Dir.pwd, ...)` reverted the whole
      # change at its one production entry point and left every delivered example
      # green. This one WALKS: `.lain/` is two directories up, so the two fields
      # must differ, and only a resolution can tell them apart.
      #
      # `HOME` is injected at the tmpdir base so the walk's stop rule is the
      # fixture's and not this developer's, exactly as {Project::Resolver}
      # requires its home to be given rather than guessed.
      it "walks for the root, so a chat started in a subdirectory gets root != cwd" do
        Dir.mktmpdir("lain-t5-walk") do |dir|
          base = File.realpath(dir)
          root = File.join(base, "repo")
          cwd = File.join(root, "services", "ingest")
          FileUtils.mkdir_p(File.join(root, ".lain"))
          FileUtils.mkdir_p(cwd)

          with_env("HOME" => base) do
            Dir.chdir(cwd) do
              project = Lain::Project::Resolver.default_project

              expect(project.root).to eq(root)
              expect(project.cwd).to eq(cwd)
              expect(project.root).not_to eq(project.cwd)
            end
          end
        end
      end

      # And what that resolution BUYS at the wiring, since #default_project
      # answering correctly is worth nothing if the instance then ignores it:
      # the Session's cwd comes from the project the instance resolved for
      # ITSELF, with nothing injected. The root half below is the attr_reader
      # read back, not a threading -- what the collaborators do with the root is
      # the injected-project group above, which can tell root from cwd.
      it "threads its own resolution into the Session's working directory" do
        Dir.mktmpdir("lain-t5-walk-wired") do |dir|
          base = File.realpath(dir)
          root = File.join(base, "repo")
          cwd = File.join(root, "services", "ingest")
          FileUtils.mkdir_p(File.join(root, ".lain"))
          FileUtils.mkdir_p(cwd)

          with_env("HOME" => base, "XDG_STATE_HOME" => File.join(base, "state")) do
            Dir.chdir(cwd) do
              wiring = described_class.new(options: { grace: 5 }, chronicle:, status_feed:)
              _, session = wiring.run_state(nil)

              expect(session.worker_env.cwd).to eq(cwd)
              expect(wiring.project.root).to eq(root)
            end
          end
        end
      end
    end
  end

  # Every OTHER spec of this boundary passes by handing a classifier in,
  # and production handed one in nowhere -- `Switchboard.for` never passed
  # `sensitivity:`, so the constructor's Null default stood and `gates?`
  # answered false for every path in every real chat. So nothing here injects a
  # classifier or a policy: each example builds a chat the way #run does,
  # through #wire_agent, and reads the board that assembly memoized. An example
  # that passed a Sensitivity in would prove exactly what the last twenty-two
  # cards' specs proved, which is nothing.
  describe "the path boundary a real chat builds" do
    def board_for(root:, cwd: root)
      wiring = wired(root:, cwd:)
      # The memo #build_agent assigned -- arguments ignored, since `||=` has
      # already answered. Reaching for it privately rather than adding a public
      # reader: the board IS this run's authority, and nothing in lib/ asks
      # Wiring for it.
      wiring.send(:switchboard, backend, nil)
    end

    def wired(root:, cwd: root, chronicle: self.chronicle)
      wiring = described_class.new(options: { grace: 5 }, chronicle:, status_feed:,
                                   project: Lain::Project.new(root:, cwd:, kind: :project, detected_by: :flag))
      recorder, session = wiring.run_state(nil)
      wiring.wire_agent(channel:, recorder:, session:, backend:)
      wiring
    end

    def read_of(path) = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "read_file", input: { "path" => path })

    # The reason the board's own classifier gave, asked through the surface
    # that reports one. `gates?` answers a Boolean, and the GATED half of the
    # table carries its verdict out through exactly one production reader --
    # the listing filter's withheld rows, which is what prints `2 paths
    # withheld (credential)`. So this is the board's real answer, not a second
    # classifier built to the same recipe, and it needs no reach past the Policy.
    def verdict_for(board, path) = board.sensitivity.filter.sift([path]) { |row| [row] }.withheld.first

    # `HOME` is injected at the tmpdir base for the reason the project-walk group
    # above injects it: the home-ANCHORED half of the classifier's denied table
    # is built from it, so a fixture reading this developer's real home would
    # assert against a directory nobody controls. {Lain::Paths} is where the
    # boundary reads it, and it reads the environment it is given.
    def in_tree(config: nil)
      Dir.mktmpdir("lain-t23") do |dir|
        base = File.realpath(dir)
        root = File.join(base, "repo")
        home = File.join(base, "home")
        FileUtils.mkdir_p(File.join(root, ".lain"))
        with_env("HOME" => home, "XDG_STATE_HOME" => File.join(base, "state")) do
          write_config(root, config) if config
          yield(root, home)
        end
      end
    end

    # The backend carries what the launch read from config.rb, and the board
    # the chat builds hands its tool members to the agent's stack, outermost.
    it "starts the agent's tool stack with the configured tool middleware" do
      in_tree do |root|
        middleware = Lain::Config::Middleware.new(tool: [Lain::Config::Middleware::Registration.new(
          factory: WiringSpecToolStamp, args: [], kwargs: {}, block: nil, at: "/spec/config.rb:1"
        )])
        configured = offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 },
                                               mock: mock_provider, root:, middleware:)
        wiring = described_class.new(options: { grace: 5 }, chronicle:, status_feed:,
                                     project: Lain::Project.new(root:, cwd: root, kind: :project, detected_by: :flag))
        recorder, session = wiring.run_state(nil)
        runner = wiring.wire_agent(channel:, recorder:, session:, backend: configured).send(:tool_runner)

        expect(runner.middleware.to_a.map(&:class))
          .to eq([WiringSpecToolStamp, Lain::Middleware::ParsedCommand, Lain::Middleware::ConfineToScope, Lain::Middleware::RefuseSecretWrites,
                  Lain::Middleware::RedactSecretReads, Lain::Middleware::WithholdSecretPaths,
                  Lain::Middleware::GuardTestLayout, Lain::Middleware::WithholdAutomaticOutput,
                  Lain::Middleware::TripwireStop, Lain::Middleware::RememberedDenials,
                  Lain::Middleware::Sensitivity, Lain::Middleware::Gate])
      end
    end

    def configured_middleware(**areas)
      Lain::Config::Middleware.new(**areas.transform_values do |factory|
        [Lain::Config::Middleware::Registration.new(factory:, args: [], kwargs: {}, block: nil,
                                                    at: "/spec/config.rb:1")]
      end)
    end

    def configured_backend(root, **areas)
      middleware = configured_middleware(**areas)
      offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 },
                                mock: mock_provider, root:, middleware:)
    end

    def configured_wiring(root)
      described_class.new(options: { grace: 5 }, chronicle:, status_feed:,
                          project: Lain::Project.new(root:, cwd: root, kind: :project, detected_by: :flag))
    end

    def configured_agent(root, **areas)
      wiring = configured_wiring(root)
      recorder, session = wiring.run_state(nil)
      wiring.wire_agent(channel:, recorder:, session:, backend: configured_backend(root, **areas))
    end

    def configured_instrumentation(root, wiring, backend, board: board_for(root:))
      wiring.send(:backing, backend, channel, -> {}, board:)[:instrumentation]
    end

    it "starts the agent's model stack with the configured model middleware" do
      in_tree do |root|
        classes = configured_agent(root, model: WiringSpecModelStamp).send(:model_caller).middleware.to_a.map(&:class)

        expect(classes.first(2)).to eq([WiringSpecModelStamp, Lain::Middleware::RequestBudget])
        expect(classes.last).to be(Lain::Middleware::ResolveAttachments)
      end
    end

    it "lets a configured model middleware see the response the agent committed" do
      in_tree do |root|
        WiringSpecModelStamp::SEEN.clear
        agent = configured_agent(root, model: WiringSpecModelStamp)
        agent.ask("hello")

        seen = Array.new(WiringSpecModelStamp::SEEN.size) { WiringSpecModelStamp::SEEN.pop }
        expect(seen.map(&:content)).to eq([[{ "type" => "text", "text" => "settled" }]])
        expect(agent.timeline.to_a.last.content).to eq([{ "type" => "text", "text" => "settled" }])
      end
    end

    it "gives a spawned child its own instance of the configured model middleware", :seam do
      in_tree do |root|
        WiringSpecInstanceStamp::SEEN.clear
        spawn_call = ["s1", "subagent", { "prompt" => "look", "role" => "researcher" }]
        spawning = Lain::Provider::Mock.new(responses: [tool_response(spawn_call),
                                                        text_response("child done"), text_response("parent done")])
        middleware = configured_middleware(model: WiringSpecInstanceStamp)
        backend = offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 },
                                            mock: spawning, root:, middleware:)
        wiring = configured_wiring(root)
        recorder, session = wiring.run_state(nil)
        wiring.wire_agent(channel:, recorder:, session:, backend:).ask("spawn one")

        seen = Array.new(WiringSpecInstanceStamp::SEEN.size) { WiringSpecInstanceStamp::SEEN.pop }
        parent, child = seen.first(2)
        expect([seen.size, parent.equal?(child), parent.class, child.class])
          .to eq([3, false, WiringSpecInstanceStamp, WiringSpecInstanceStamp])
      end
    end

    it "starts the agent's turn stack with the configured turn middleware" do
      in_tree do |root|
        backend = configured_backend(root, turn: WiringSpecTurnStamp)
        classes = configured_instrumentation(root, configured_wiring(root), backend).turn_middleware.to_a.map(&:class)

        expect(classes.first(2)).to eq([WiringSpecTurnStamp, Lain::Middleware::ResolveWindow])
      end
    end

    it "runs a configured repl middleware over a typed line before the agent sees it", :seam do
      in_tree do |root|
        upcase = proc { |env, &downstream| downstream.call(env.merge(text: env.fetch(:text).upcase)) }
        registration = Lain::Config::Middleware::Registration.new(factory: nil, args: [], kwargs: {}, block: upcase,
                                                                  at: "/spec/config.rb:1")
        middleware = Lain::Config::Middleware.new(repl: [registration])
        backend = offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 },
                                            mock: mock_provider, root:, middleware:)
        Dir.mktmpdir do |dir|
          wiring = described_class.new(options: { grace: 5 }, chronicle:, status_feed:,
                                       stdin: StringIO.new("hi\nquit\n"),
                                       herdr: null_herdr(lambda { |channel:, **|
                                         Lain::Frontend::TTY.new(channel:, output: StringIO.new,
                                                                 history_path: File.join(dir, "history"))
                                       }),
                                       project: Lain::Project.new(root:, cwd: root, kind: :project, detected_by: :flag))
          wiring.run(backend:, resumed: nil, nvim: nil)
          wiring.conductor.close(reason: :exit)
        end

        expect(mock_provider.last_request.messages.last.to_s).to include("HI")
      end
    end

    it "builds a fresh model and turn member for every stack" do
      in_tree do |root|
        wiring = configured_wiring(root)
        backend = configured_backend(root, model: WiringSpecModelStamp, turn: WiringSpecTurnStamp)
        board = board_for(root:)
        first, second = Array.new(2) { configured_instrumentation(root, wiring, backend, board:) }

        expect(first.model_middleware.to_a.first).not_to eql(second.model_middleware.to_a.first)
        expect(first.turn_middleware.to_a.first).not_to eql(second.turn_middleware.to_a.first)
      end
    end

    it "gates a credential-shaped path under the project root" do
      in_tree do |root|
        board = board_for(root:)

        expect(board.sensitivity.gates?(read_of(File.join(root, ".env")), cwd: root)).to be(true)
      end
    end

    it "names a credential as the reason it gated one" do
      in_tree do |root|
        verdict = verdict_for(board_for(root:), File.join(root, ".env"))

        expect([verdict&.level, verdict&.reason]).to eq(%i[gated credential])
      end
    end

    it "leaves an ordinary path ungated" do
      in_tree do |root|
        board = board_for(root:)

        expect(board.sensitivity.gates?(read_of(File.join(root, "README.md")), cwd: root)).to be(false)
      end
    end

    # No config at all: the built-in tables are what a project gets, and the
    # unambiguous half of the denied table matches wherever it sits.
    it "denies a private key with no config to say so" do
      in_tree do |root, home|
        denial = board_for(root:).sensitivity.denial(read_of(File.join(home, ".ssh", "id_rsa")), cwd: root)

        expect([denial&.path, denial&.reason]).to eq([File.join(home, ".ssh", "id_rsa"), :protected])
      end
    end

    # The home-ANCHORED half of the same table, which is the half that can only
    # work if the injected home actually reached the classifier: `.kube/config`
    # is denied under this run's home and ordinary anywhere else.
    it "anchors the home-relative rules at the home it was given" do
      in_tree do |root, home|
        board = board_for(root:)

        expect(board.sensitivity.denial(read_of(File.join(home, ".kube", "config")),
                                        cwd: root)&.reason).to eq(:protected)
        expect(board.sensitivity.denial(read_of(File.join(root, ".kube", "config")), cwd: root)).to be_nil
      end
    end

    it "denies what the project's own [sensitivity] table denies, in the project's own words" do
      in_tree(config: "sensitivity denied: %w[*.secret]\n") do |root|
        denial = board_for(root:).sensitivity.denial(read_of(File.join(root, "prod.secret")), cwd: root)

        expect(denial&.reason).to eq(:configured)
        expect(denial&.verdict&.explanation).to eq("named by this project's sensitivity config")
      end
    end

    it "builds the auto judge with the timeout the project's approval table sets" do
      in_tree(config: "approval judge_timeout: 90\n") do |root|
        built = Struct.new(:timeout).new
        allow(Lain::Approval::Judge).to receive(:new) { |**kw| built.timeout = kw[:timeout] and instance_double(Lain::Approval::Judge, call: :approve) }
        allow(Lain::CLI::Wiring::BoardBuild).to receive(:for).and_wrap_original do |original, **kwargs|
          kwargs[:judge].call(tool: "bash", input: {}, place: nil)
          original.call(**kwargs)
        end

        board_for(root:)

        expect(built.timeout).to eq(90)
      end
    end

    it "gates what the project's [sensitivity] table merely gates" do
      in_tree(config: "sensitivity gated: %w[*.private]\n") do |root|
        board = board_for(root:)

        expect(board.sensitivity.gates?(read_of(File.join(root, "notes.private")), cwd: root)).to be(true)
        expect(board.sensitivity.denial(read_of(File.join(root, "notes.private")), cwd: root)).to be_nil
      end
    end

    # LOUD: this table restricts, so a session that ran with it silently
    # un-parsed would be running with the project's denials off.
    it "refuses a malformed [sensitivity] table at construction, naming the file" do
      in_tree(config: "sensitivity denied: \"*.secret\"\n") do |root|
        expect { wired(root:) }
          .to raise_error(Lain::Config::Refusal, /#{Regexp.escape(config_path(root))}.*list of patterns/)
      end
    end

    # BEFORE the session header is pinned, which is {Wiring#fleet_isolation}'s
    # stated ordering one method away: a refusal after `chronicle.start` leaves
    # a session record on disk for a chat that never ran. `#start` is what
    # builds the Scribe, and the Scribe writes the header in its constructor, so
    # "start was never called" IS "no orphan record".
    it "refuses before the session record is opened, leaving no orphan header" do
      in_tree(config: "sensitivity denied: \"*.secret\"\n") do |root|
        spy = WiringSpecStartSpy.new(Lain::CLI::Chronicle::Null.new)

        expect { wired(root:, chronicle: spy) }
          .to raise_error(Lain::Config::Refusal, /`sensitivity` denied is a list/)
        expect(spy.starts).to eq(0)
      end
    end

    # And the converse, so the ordering above is not satisfied by never starting
    # at all: an ordinary chat still pins its header.
    it "still opens the session record when the config is fine" do
      in_tree do |root|
        spy = WiringSpecStartSpy.new(Lain::CLI::Chronicle::Null.new)
        wired(root:, chronicle: spy)

        expect(spy.starts).to eq(1)
      end
    end

    # Trusting the file is the one decision: an allow entry it carries is
    # honoured with no second consent asked of anyone.
    it "pre-approves a call the trusted config allows" do
      in_tree(config: %(approval do\n  allow "bash", command: "bundle exec rspec"\nend\n)) do |root|
        board = board_for(root:)
        call = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash",
                                          input: { "command" => "bundle exec rspec" })

        expect(Sync { |task| task.with_timeout(2) { board.policy_switch.call(call, nil) } }).to be(true)
      end
    end

    # The child's half of the same wiring: the seam's tool stack is built over
    # the board, so a subagent's gate asks THIS classifier. It answered the
    # Null's false until the board held a real one.
    it "hands the same classifier to the subagent seam" do
      in_tree do |root|
        child_gate = wired(root:).send(:toolset_build).send(:seam).tool_middleware
                                 .call(Lain::WorkerEnv.default).to_a.last

        expect(child_gate.instance_variable_get(:@sensitivity).gates?(read_of(File.join(root, ".env")),
                                                                      cwd: root)).to be(true)
      end
    end

    # The other object a real chat's board is built from, and the only one it
    # SHARES with the toolset: {Wiring#verdict} is memoized, so #build_toolset
    # and #switchboard read one slot and the bash tool and the ladder's triage
    # rung end up holding one {Lain::Shell::Verdict}. That is what makes "the
    # journalled verdict is the verdict the tool acted on" true by
    # construction -- nothing is carried between the gate and the tool, so
    # nothing can be forged in transit either.
    describe "the shell verdict a real chat builds" do
      def verdict_of_rung(board) = board.ladder.first.instance_variable_get(:@verdict)

      def verdict_of_tool(board) = board.toolset.fetch("bash").instance_variable_get(:@verdict)

      # `equal?` and never `eq`, because identity is the CLAIM: one object at
      # two seams, so nothing has to be carried between the gate and the tool.
      # `eq` would assert something weaker and different -- that two verdicts
      # agree -- which is exactly what the regression this guards against
      # produces ({ToolsetBuild} and {BoardBuild} each calling
      # `Shell::Verdict.new`, restoring the double parse with a green suite).
      #
      # `eq` happens to catch it TODAY, and only by coincidence of two
      # unrelated classes inheriting `Object#==`. Measured:
      # `Verdict.new == Verdict.new` and `Parse.new == Parse.new` are both
      # false, while `Exclusions` is a `Data` and already compares equal. The
      # coincidence rests on nothing anyone declared and nothing any spec pins:
      # {Shell::Parse} is a STATELESS frozen object (`def initialize = freeze`,
      # no ivars), which is the shape that becomes a value. Measured with a
      # `Data.define(:parse, :capability_set)` stand-in: two verdicts over two
      # fresh Parses are not `eq`, two over a SHARED Parse are. So the guard
      # fails open the moment either half turns value-like. Do not simplify it.
      it "gives the triage rung and the bash tool the same instance, not two equal ones" do
        in_tree(config: %(shell exclude: %w[curl]\n)) do |root|
          board = board_for(root:)

          expect(verdict_of_rung(board)).to equal(verdict_of_tool(board))
        end
      end

      # And the shared instance is the PROJECT's, not a shared permissive
      # default -- without this, the example above would still pass over two
      # branches that agreed on restricting nothing.
      it "carries the project's own exclusion table to both of them" do
        in_tree(config: %(shell exclude: %w[curl]\n)) do |root|
          board = board_for(root:)

          expect(verdict_of_rung(board).call("curl http://example.com")).to be_deny
          expect(verdict_of_tool(board).call("curl http://example.com")).to be_deny
        end
      end

      it "expands a word-leading tilde to the HOME the chat's bash children are lent" do
        in_tree do |root|
          wiring = wired(root:)
          home = wiring.send(:chat_env).env.fetch("HOME")

          expect(wiring.send(:verdict).call("cat ~/x").term).to eq(Lain::Shell::Term.of(["cat", "#{home}/x"]))
        end
      end
    end

    # The TOOL phase, from the production board. Two independent things had to
    # be true for this axis to fire, and asserting only one is how the card
    # half-lands and looks done: the stack has to CARRY the listing guard, and
    # that guard's filter has to be a live one rather than the Null. Both here,
    # in one example, over the board a real chat built.
    describe "the tool phase over that board" do
      def listing_guard(board)
        Lain::CLI::ToolGuard.stack(chronicle, board).to_a.grep(Lain::Middleware::WithholdSecretPaths).first
      end

      it "carries the listing guard, filtering through the board's own classifier" do
        in_tree do |root|
          board = board_for(root:)

          expect(Lain::CLI::ToolGuard.stack(chronicle, board).to_a.map(&:class))
            .to eq([Lain::Middleware::ParsedCommand, Lain::Middleware::ConfineToScope, Lain::Middleware::RefuseSecretWrites,
                    Lain::Middleware::RedactSecretReads,
                    Lain::Middleware::WithholdSecretPaths, Lain::Middleware::GuardTestLayout,
                    Lain::Middleware::WithholdAutomaticOutput, Lain::Middleware::TripwireStop, Lain::Middleware::RememberedDenials,
                    Lain::Middleware::Sensitivity,
                    Lain::Middleware::Gate])
          expect(listing_guard(board).filter).to be(board.sensitivity.filter)
          expect(listing_guard(board).filter).not_to be(Lain::Sensitivity::Filter::Null.instance)
        end
      end

      # And what that buys, end to end: a listing that names a credential-shaped
      # path has that row dropped, with the count and the reason reported --
      # never silently, because a truncated listing reads as "that is
      # everything" and the agent acts on it.
      it "withholds a credential-shaped row from a listing, and says so" do
        in_tree do |root|
          sifted = listing_guard(board_for(root:))
                   .filter.sift([File.join(root, "README.md"), File.join(root, ".env")]) { |row| [row] }

          expect(sifted.kept).to eq([File.join(root, "README.md")])
          expect([sifted.count, sifted.reasons]).to eq([1, [:credential]])
        end
      end
    end
  end

  # The fold's acceptance criteria. Six single-caller collaborators came back
  # into this class, so what used to be asserted against a module function is
  # asserted here against the object that does the work: the run's state, the
  # epic it is seated in, and -- already pinned above, at the shell verdict --
  # the ONE object two seams share.
  describe "the collaborators this class absorbed" do
    # The resumed halves arrive from the resume result rather than being
    # built fresh, and BOTH are decorated by the chronicle: decorating one and
    # not the other is a run whose usage records name a memory root its reads
    # never wrote.
    describe "a resumed run's state" do
      def recorded(item)
        Lain::Memory::Recorder.new(index: Lain::Memory::Index.empty.write(item))
      end

      let(:remembered) do
        Lain::Memory::Item.new(id: "db-conventions", description: "how this project names tables", body: "snake")
      end

      # The recorded VIEW is restored, re-opened on the project's store: the
      # same items, so the manifest is what was recorded, and a write from here
      # lands durably where the next fresh chat will see it.
      it "restores the resumed view's items rather than opening on the store head" do
        restored, = wiring.run_state(WiringSpecResumed.new(recorder: recorded(remembered),
                                                           session: Lain::Session.new))

        expect(restored.index.to_h.keys).to eq(["db-conventions"])
        expect(restored.loaded.items.map(&:id)).to eq(["db-conventions"])
      end

      # The resumed Session already holds the read-set, pin-set and todo list
      # replay restored, so it is POINTED at the re-opened view rather than
      # rebuilt -- and its manifest has to follow, or it renders a snapshot the
      # memory tools no longer write into.
      it "points the resumed session's manifest at the re-opened view" do
        session = Lain::Session.new(memory: recorded(remembered))

        restored, restored_session = wiring.run_state(WiringSpecResumed.new(recorder: recorded(remembered),
                                                                            session:))
        restored.write(Lain::Memory::Item.new(id: "later", description: "written after the resume", body: "x"))

        expect(restored_session).to be(session)
        expect(restored_session.reminders.join).to include("later")
      end

      # A resume keeps its own view on purpose, so what other chats added since
      # is reported rather than silently absent. Its own state home, because the
      # store is a FILE and the suite's is shared by every example in the process.
      it "says how many newer entries the store holds, and says nothing when it holds none" do
        Dir.mktmpdir do |state|
          isolated = new_wiring(options: { grace: 5 }, chronicle:, status_feed:,
                                paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => state,
                                                              "HOME" => state }))
          resumed = WiringSpecResumed.new(recorder: recorded(remembered), session: Lain::Session.new)
          restored, = isolated.run_state(resumed)

          expect(isolated.memory_notices(restored, resumed)).to eq([])
          Lain::Memory::ProjectStore.new(
            project_dir: Lain::ProjectDir.new(root: isolated.project.root,
                                              paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => state,
                                                                            "HOME" => state }))
          ).view.write(Lain::Memory::Item.new(id: "elsewhere", description: "d", body: "b"))
          expect(isolated.memory_notices(restored, resumed).join).to include("1 entry newer")
        end
      end

      it "tells a fresh chat nothing, because its view already holds them" do
        recorder, = wiring.run_state(nil)

        expect(wiring.memory_notices(recorder, nil)).to eq([])
      end

      # The fresh half, and the one thing about it that is this class's own
      # answer rather than a constructor default: a fresh Session runs at the
      # PROJECT's cwd, never at whatever `Dir.pwd` the process happens to hold.
      it "builds a fresh pair, seated at the project's own cwd" do
        recorder, session = wiring.run_state(nil)

        expect(recorder).to be_a(Lain::Memory::Recorder)
        expect(session.worker_env.cwd).to eq(wiring.chat_env.cwd)
      end
    end

    # The mount is resolved ONCE and read twice -- the toolset takes its
    # tools, an attached editor's lain://status takes its slug -- because
    # {CLI::EpicMount} builds the one {Epic::Review} per slug and a second
    # mount would be a second guard over one journal.
    describe "the epic a chat is seated in" do
      around do |example|
        Dir.mktmpdir("lain-wiring-epic") do |dir|
          @tmp = File.realpath(dir)
          FileUtils.mkdir_p(epic_root)
          with_env("XDG_STATE_HOME" => File.join(@tmp, "state")) { example.run }
        end
      end

      def epic_root = File.join(@tmp, "project")

      def seated(options = {})
        described_class.new(options: { grace: 5, **options }, chronicle:, status_feed:,
                            herdr: null_herdr(lambda { |channel:, **|
                              Lain::Frontend::TTY.new(channel:, output: StringIO.new,
                                                      history_path: File.join(@tmp, "history"))
                            }), stdin: StringIO.new("quit\n"),
                            project: Lain::Project.new(root: epic_root, cwd: epic_root, kind: :project,
                                                       detected_by: :flag))
      end

      # What the editor is HANDED, taken off the `#run` path rather than from a
      # reader: {Wiring#editor_seams} is the one place a mount becomes a view,
      # and the Repl is where that view lands. The Repl's own `#run` is stubbed
      # because the conversation is not the claim -- what the example reads is
      # the seam hash a real assembly composed on its way to one.
      def seams_handed_to_editor(chat)
        seen = {}
        allow(Lain::CLI::Repl).to receive(:new).and_wrap_original do |original, **kwargs|
          original.call(**kwargs).tap { |repl| allow(repl).to receive(:run) { |**seams| seen.replace(seams) } }
        end
        chat.run(backend:, resumed: nil, nvim: nil)
        chat.conductor.close(reason: :exit)
        seen
      end

      def epic_handed_to_editor(chat) = seams_handed_to_editor(chat).fetch(:epic)

      def write_demo
        graph = Lain::Epic::Graph.new(issues: [Lain::Epic::Issue.new(id: "a", title: "the a issue")])
        config = Lain::Config.new(epics: Lain::Config::Epics.new(home: :xdg))
        Lain::Epic::Home.resolve(config:, paths: Lain::Paths.new, root: epic_root, slug: "demo").write_epic(graph)
      end

      it "mounts the declared epic once, so the toolset and the editor read the same mount" do
        write_demo
        chat = seated

        expect(chat.send(:epic_mount)).to be_a(Lain::CLI::EpicMount).and(equal(chat.send(:epic_mount)))
        expect(chat.send(:epic_mount).slug).to eq("demo")
      end

      it "tells the notice why a mount was abandoned, on the first call only" do
        heard = []
        chat = seated(epic: "nope")

        2.times { chat.send(:epic_mount, ->(message) { heard << message }) }

        expect(heard.size).to eq(1)
        expect(heard.first).to include("request_review is not wired")
      end

      describe "the slug a recorded answer carries" do
        let(:journal) { [] }

        def answered_slug(chat)
          allow(chronicle).to receive(:record_journal).and_return(journal)
          timeline = Lain::Dag::Factory.timeline(store: Lain::Dag::Factory.store)
                                       .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
          asker = chat.send(:wire_askers, -> { timeline })
          Sync { asker.tap { |a| a.ask("which?") }.reply("this one", asker.last_question.digest) }
          journal.grep(Lain::Telemetry::QuestionAnswered).fetch(0).epic_slug
        end

        it "is the mounted epic's" do
          write_demo

          expect(answered_slug(seated)).to eq("demo")
        end

        it "is absent when the chat is in no epic" do
          expect(answered_slug(seated)).to be_nil
        end
      end

      it "hands the editor the mounted epic, folded from the root the mount resolved", :seam do
        write_demo

        expect(epic_handed_to_editor(seated).lines)
          .to include("# epic `demo`", a_string_including("`a` the a issue"))
      end

      it "hands the editor the unmounted null when the chat is in no epic", :seam do
        expect(epic_handed_to_editor(seated)).to equal(Lain::Frontend::Neovim::StatusView::Unmounted)
      end

      # An epic_write in a chat seated in no epic still writes a document the
      # human should be able to read where it was made.
      it "hands the editor an epic documents reader when the chat is in no epic", :seam do
        expect(seams_handed_to_editor(seated).fetch(:epic_docs)).to be_a(Lain::CLI::EpicMount::Homes)
      end

      context "with the chat's journal filed in the project's session directory", :seam do
        let(:project) { Lain::Project.new(root: epic_root, cwd: epic_root, kind: :project, detected_by: :flag) }
        let(:session_dir) { Lain::Paths.new.filing_dir(root: project.root) }
        let(:chronicle) do
          Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io: StringIO.new),
                                   journal_path: File.join(session_dir, "chat.ndjson"))
        end

        it "hands the editor a scan that finds the files resumed from this chat's journal" do
          FileUtils.mkdir_p(session_dir)
          header = { "type" => Lain::SessionRecord::HEADER_TYPE,
                     "resumed_from" => { "file" => "chat.ndjson", "head" => "blake3:d1" } }
          File.write(File.join(session_dir, "child.ndjson"), "#{JSON.generate(header)}\n")

          expect(seams_handed_to_editor(seated).fetch(:forks).call).to eq("blake3:d1" => ["child.ndjson"])
        end
      end
    end
  end

  # An image a turn REFERS to rather than carries: the address rides the
  # Timeline and the journal, and the bytes are put back on the last hop out.
  # The route in is {Lain::Agent::RequestOverride}, the same one-shot slot a
  # frontend resend uses, because it is the only production seam that gets a
  # hand-built Request onto the wire without a tool to make one.
  describe "an image carried as an address" do
    let(:png) { (+"\x89PNG\r\n\x1a\n\x00\xff\x80pixels").force_encoding(Encoding::BINARY) }

    def dispatch(over: chronicle)
      wired = new_wiring(options: { grace: 5 }, chronicle: over, status_feed:)
      recorder, session = wired.run_state(nil)
      agent = wired.wire_agent(channel:, recorder:, session:, backend:)
      reference = Lain::Attachment::Reference.new(digest: wired.send(:toolset_build).attachments.put(png),
                                                  media_type: "image/png")
      agent.request_override.queue(
        Lain::Request.new(model: "qwen3:4b", max_tokens: 64,
                          messages: [{ "role" => "user",
                                       "content" => [{ "type" => "text", "text" => "what is on it" },
                                                     reference.block] }])
      )
      agent.ask("what is on it")
      [wired, agent, reference]
    end

    def sent_data = mock_provider.last_request.messages.dig(0, "content", 1, "source", "data")

    # --no-journal: the model stack is composed in #model_phase and not in the
    # chronicle's instrumentation, which has no model stack at all here, so a
    # chat that records nothing still sends its pictures.
    it "sends the bytes on a chat started with no journal" do
      dispatch

      expect(sent_data.unpack1("m0")).to eq(png)
    end

    # `be`, never `eq` on `.root`: {Lain::Attachment::Store} has no `==`, so an
    # equality read would compare object identity anyway while LOOKING like it
    # compared directories -- and two stores that merely compute the same path
    # is exactly what one store exists to make unrepresentable.
    it "hands a spawned child the same store, so a subagent writes into no second directory" do
      wired, agent, = dispatch

      expect(agent.toolset.fetch("subagent").seam.attachments).to be(wired.send(:attachments))
      expect(wired.role_spawn.seam.attachments).to be(wired.send(:attachments))
    end

    it "resolves against the run's ONE store, the same object the toolset's tools write into" do
      wired, agent, = dispatch

      resolver = agent.send(:model_caller).middleware.to_a.last
      expect(resolver).to be_a(Lain::Middleware::ResolveAttachments)
      expect(resolver.attachments).to be(wired.send(:toolset_build).attachments)
    end

    context "when the chat is journaling" do
      let(:journal_io) { StringIO.new }
      let(:recording) do
        Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io: journal_io), journal_path: "image-spec.ndjson")
      end

      it "records the address and sends the bytes" do
        _, _, reference = dispatch(over: recording)

        sent = journal_records(journal_io)
               .find { |record| record["type"] == "request_sent" }
        expect(sent["payload"]["messages"].dig(0, "content", 1, "source"))
          .to include("type" => "attachment", "digest" => reference.digest)
        expect(journal_io.string).not_to include([png].pack("m0"))
        expect(sent_data.unpack1("m0")).to eq(png)
      end
    end
  end

  # `auto` asks a judge built over the run's role-spawn seam, once, at the
  # first judged call; a judge that cannot be built hands the call to a human.
  describe "the judge auto approval asks" do
    around do |example|
      Dir.mktmpdir("lain-wiring-judge") do |state|
        @state = File.realpath(state)
        example.run
      end
    end

    let(:journal_io) { StringIO.new }
    let(:chronicle) do
      Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io: journal_io), journal_path: "judge-spec.ndjson")
    end
    let(:mock_provider) { Lain::Provider::Mock.new(responses: [text_response("APPROVE"), text_response("APPROVE")]) }
    let(:backend_root) { @state }
    let(:wiring) do
      described_class.new(options: { grace: 5, approval: "auto" }, chronicle:, status_feed:,
                          paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => @state, "HOME" => @state }),
                          project: throwaway_project(@state))
    end

    def board
      wire_agent
      wiring.instance_variable_get(:@switchboard)
    end

    def removal = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input: { "command" => "rm -rf build" })

    it "builds the judge once across two judged calls" do
      allow(Lain::Approval::Judge).to receive(:new).and_call_original
      gate = board.policy_switch

      expect(Array.new(2) { gate.call(removal, nil) }).to eq([true, true])
      expect(Lain::Approval::Judge).to have_received(:new).once
    end

    it "hands the call to a human when the judge cannot be built" do
      allow(Lain::Approval::Judge).to receive(:new).and_raise(IOError, "no spawn seam")
      live = board
      pending = Sync do |task|
        call = task.async { live.policy_switch.call(removal, nil) }
        task.with_timeout(1) { live.approvals.dequeue }
      ensure
        call&.stop
      end

      expect(pending).to be_a(Lain::Approval::Parked::Queue::Pending)
      expect(journal_records(journal_io, "escalation"))
        .to include(a_hash_including("rung" => "auto", "reason" => "fault", "error" => "IOError: no spawn seam"))
    end
  end
end

# What the Agent is built FROM, driven at the seam that takes the board as an
# argument rather than resolving one: the provider the run talks to, the
# compaction wiring hung off it, the instrumentation stack, and the executor
# the board's gate closes over.
RSpec.describe Lain::CLI::Wiring, "the Agent build" do
  let(:mock_provider) do
    Lain::Provider::Mock.new(responses: [
                               Lain::Response.new(content: [{ "type" => "text", "text" => "settled" }],
                                                  stop_reason: :end_turn)
                             ])
  end
  let(:backend) { WiringAgentSpecBackend.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: mock_provider) }
  let(:chronicle) { WiringAgentSpecChronicle.new }
  let(:channel) { Lain::Channel.new }
  let(:board) { WiringAgentSpecBoard.new(Lain::Toolset.new) }
  let(:status_feed) { instance_double(Lain::StatusFeed, bind_store: nil) }
  let(:wiring) do
    described_class.new(options: { grace: 5 }, chronicle:, status_feed:,
                        project: Lain::Project.new(root: @root, cwd: @root, kind: :project, detected_by: :flag))
  end

  # The root every snapshot is rooted at reaches the build off the wiring's own
  # {Lain::Project} rather than as a keyword, which is what the snapshot example
  # below reads back. A REAL directory, because {Lain::Project} resolves its
  # root through `File.realpath` and refuses one that is not there.
  around do |example|
    Dir.mktmpdir("lain-agent-build-root") { |dir| @root = File.realpath(dir) and example.run }
  end

  def build(**overrides)
    wiring.send(:agent_over, board:, channel:, backend:, session: Lain::Session.new, **overrides)
  end

  # Both branches of the `channel:` default are reached through #wire_agent,
  # the public seam, because a run makes exactly these two provider calls and
  # in this order: the toolset build takes the Null default, and the agent
  # build takes the run's live Channel. Asking the private method directly
  # would prove the method's own arithmetic and say nothing about which caller
  # gets which, which is the whole of what this group is about.
  describe "the provider the run talks to" do
    # The SPOOLED calls a real assembly made, in the order it made them. A run
    # asks the backend for a provider on other errands too -- the library's, and
    # the summarizer arm's -- and those are not round trips this class tees, so
    # the set is the calls that named a spool at all. Its SIZE is asserted
    # because `all` over an empty list is a pass, which is exactly what a
    # regression that stopped spooling would produce.
    def spooled_calls
      recorder, session = wiring.run_state(nil)
      wiring.wire_agent(channel:, recorder:, session:, backend:)
      backend.provider_calls.select { |call| call.key?(:spool) }
    end

    it "tees every round trip into the chronicle's response spool" do
      calls = spooled_calls

      expect(calls.size).to eq(2)
      expect(calls).to all(include(spool: chronicle.spool))
    end

    # A subagent leaves the default: its stream is not rendered, so only the
    # spool tee matters there. Handing it the main chat's live Channel instead
    # would put a child's tokens on the human's screen.
    it "defaults the channel to the Null one, so an unrendered stream stays unrendered" do
      expect(spooled_calls.first[:channel]).to be(Lain::Channel::Null.instance)
    end

    it "passes the run's live channel through when one is handed in" do
      expect(spooled_calls.last[:channel]).to be(channel)
    end
  end

  # The written/not-written pair is driven through the ASSEMBLY rather than at
  # the method, over a provider that really lacks a capability the Context
  # really requires: what a flag would change is the policy, but what shipped
  # broken for twelve POC journals was the wiring -- a policy with a record
  # type, an emitter, a reader and no caller. Reaching the method directly
  # could not have caught that. The journal read back is the CHRONICLE's own
  # record journal, which is the file a live chat writes these to.
  describe "the capability degradations a run records" do
    let(:io) { StringIO.new }
    let(:chronicle) { WiringAgentSpecChronicle.new(Lain::Journal.new(io:)) }
    let(:context) { Lain::Context.new(model: "qwen3:4b", max_tokens: 64) }

    def degraded_lines
      io.string.each_line.filter_map { |line| Lain::Journal.parse(line) }
        .select { |record| record["type"] == "capability_degraded" }
    end

    # The real ollama declaration -- `%i[streaming thinking structured_output]`,
    # no `:prompt_caching` -- against what the real default Context requires. A
    # double answering `supports?` would be asserting on the double.
    def wire_over(capabilities)
      lacking = Lain::Provider::Mock.new(capabilities:)
      recorder, session = wiring.run_state(nil)
      wiring.wire_agent(channel:, recorder:, session:,
                        backend: WiringAgentSpecBackend.new({ provider: "ollama", model: nil, max_tokens: 64 },
                                                            mock: lacking))
    end

    it "writes one record per capability the provider cannot give the context" do
      wire_over(context.requires - %i[prompt_caching])

      expect(context.requires).to include(:prompt_caching)
      expect(degraded_lines.map { |record| record.values_at("capability", "requirer", "provider") })
        .to eq([%w[prompt_caching Lain::Context Lain::Provider::Mock]])
    end

    it "writes no degradation when the provider supports everything the context requires" do
      wire_over(context.requires)

      expect(io.string).not_to be_empty
      expect(degraded_lines).to be_empty
    end

    # The wired policy is `:degrade` and may never be `:strict`:
    # `Policy::Strict#handle_missing` reuses {Lain::Provider#require!}, so the
    # missing capability above would raise {Lain::Provider::Unsupported} at turn
    # one of every ollama chat. Stated as behaviour rather than as a constant
    # comparison, so it survives the constant being renamed.
    # The one of the three that stays at the method, because it is about the
    # POLICY and not about the wiring: `:strict` would raise HERE, inside the
    # call the two examples above reach through an assembly that would then
    # never return. `journal:` is what makes driving it directly cheap -- the
    # method needs one message, so a StringIO-backed {Lain::Journal} is the
    # whole fixture.
    it "degrades rather than raising, which is the whole of why :strict is not wired" do
      lacking = Lain::Provider::Mock.new(capabilities: context.requires - %i[prompt_caching])

      expect { wiring.send(:journal_degradation, context, lacking, journal: Lain::Journal.new(io:)) }
        .not_to raise_error
      expect(described_class::DEGRADE).to eq(:degrade)
    end
  end

  describe "the provider and instrumentation the Agent is backed by" do
    subject(:backing) { wiring.send(:backing, backend, channel, -> {}, board:) }

    it "hands back the provider it spooled and the instrumentation over it" do
      expect(backing[:provider]).to be(mock_provider)
      expect(backing[:instrumentation]).to be_a(Lain::Agent::Instrumentation)
    end

    # The same class list `spec/lain/cli_spec.rb` pins through the Wiring seam,
    # asserted here against the module that now builds it: a credential-shaped
    # memory_write is withheld in the TOOL phase, before it reaches the recorder,
    # an unreleased region is masked out of a read in the same phase, before its
    # bytes can reach an Event or the prompt-cache prefix, and a sensitive path
    # is dropped out of a listing before the enumeration is believed.
    # ...and then the board's two gating layers, innermost, so a secret write
    # is refused before a human is ever asked about it.
    it "puts all three secret guards, then the test layout guard, then the board's gate, in the tool phase" do
      expect(backing[:instrumentation].tool_middleware.to_a.map(&:class))
        .to eq([Lain::Middleware::ParsedCommand, Lain::Middleware::ConfineToScope, Lain::Middleware::RefuseSecretWrites,
                Lain::Middleware::RedactSecretReads,
                Lain::Middleware::WithholdSecretPaths, Lain::Middleware::GuardTestLayout,
                Lain::Middleware::WithholdAutomaticOutput, Lain::Middleware::TripwireStop, Lain::Middleware::RememberedDenials,
                Lain::Middleware::Sensitivity, Lain::Middleware::Gate])
    end

    # An unattended run leaves {Lain::CLI::Switchboard#approvals} nil, and the
    # read guard takes its queue as a required keyword -- so the stand-in has to
    # be substituted HERE, at the wiring, or the run raises on construction.
    # Selected by CLASS, not by position: this example is about the read guard
    # being constructible without a queue, and indexing at the end of the stack
    # tied it to being the last entry, which a third guard then made false.
    it "substitutes the unqueued stand-in when the board wired no approval queue" do
      expect { backing }.not_to raise_error
      expect(backing[:instrumentation].tool_middleware.to_a.grep(Lain::Middleware::RedactSecretReads))
        .not_to be_empty
    end

    # The run's own member sits ahead of the chronicle's, so the Null
    # chronicle's empty phase is no longer an empty stack -- it is the window
    # refresh alone.
    it "takes the turn phase from the chronicle, ahead of which it puts the window refresh" do
      expect(backing[:instrumentation].turn_middleware.to_a.map(&:class))
        .to eq([Lain::Middleware::ResolveWindow, Lain::Middleware::WrapUp])
    end

    # The OWNER of the re-resolution trigger, named here because the book
    # cannot own it: {CLI::Backend::WindowBook::Live} has no clock and no turn
    # count, and re-resolving per READ would let one turn's three readers see
    # three windows. It must refresh the run's ONE book -- the same instance
    # handed to the Agent as `context_window:` -- or the reader that self-
    # corrects is not the reader anything divides by.
    # The ordering, against a turn stack that HAS another member -- the only
    # arrangement in which the wrong order is distinguishable. Both halves are
    # asserted: what the stack holds, and what ran first.
    it "puts the window refresh outermost, ahead of the chronicle's own members" do
      trail = backend.context_window.trail
      journalling = described_class.new(
        options: { grace: 5 }, chronicle: WiringAgentSpecJournallingChronicle.new(trail), status_feed:,
        project: Lain::Project.new(root: @root, cwd: @root, kind: :project, detected_by: :flag)
      )
      stack = journalling.send(:backing, backend, channel, -> {}, board:)[:instrumentation].turn_middleware

      stack.call({ iteration: 0 }) { |env| env }

      expect(stack.to_a.map(&:class))
        .to eq([Lain::Middleware::ResolveWindow, Lain::Middleware::WrapUp, WiringAgentSpecJournallingChronicle::Member])
      expect(trail).to eq(%i[window chronicle])
    end

    it "refreshes the very book the Agent is handed, once per turn" do
      backing[:instrumentation].turn_middleware.call({ iteration: 0 }) { |env| env }

      expect(backing[:context_window]).to be(backend.context_window)
      expect(backend.context_window.refreshes).to eq(1)
    end

    it "builds its provider over the live channel, not the Null default" do
      backing

      expect(backend.provider_calls.first[:channel]).to be(channel)
    end
  end

  describe "the Agent itself" do
    # The seam's constraint, stated as an assertion: the board ARRIVES. Were
    # this method to memoize one of its own, `Wiring#approvals`, the command
    # surface and every subagent's gate policy would each read a different
    # switchboard -- or nil.
    # `backend.context` answers a FRESH value at every call by design, so what
    # is asserted is the routing, not an identity the subject never promised:
    # the board grafted exactly once, and the Agent holds what that graft
    # returned.
    it "builds over the board it was handed, never one it resolved itself" do
      agent = build

      expect(agent.toolset).to be(board.toolset)
      expect(board.grafted.one?).to be(true)
      expect(agent.context).to be(board.grafted.first)
    end

    # The stack's order is inspectable end to end: the four guards, the path
    # refusal, the approval gate, and the interpreter last -- a bare Live,
    # because everything that may refuse a call is a layer in front of it.
    it "runs the guards, then the gate over the board's own policy, then a bare Live interpreter" do
      runner = build.send(:tool_runner)

      expect([*runner.middleware.to_a.map(&:class), runner.handler.class])
        .to eq([Lain::Middleware::ParsedCommand, Lain::Middleware::ConfineToScope, Lain::Middleware::RefuseSecretWrites,
                Lain::Middleware::RedactSecretReads,
                Lain::Middleware::WithholdSecretPaths, Lain::Middleware::GuardTestLayout,
                Lain::Middleware::WithholdAutomaticOutput, Lain::Middleware::TripwireStop, Lain::Middleware::RememberedDenials,
                Lain::Middleware::Sensitivity, Lain::Middleware::Gate,
                Lain::Effect::Handler::Live])
      expect(gate_asks?(board.policy_switch, runner.middleware,
                        toolset: Lain::Toolset.new([Lain::Tools::Bash.new]))).to be(true)
    end

    it "seeds the Agent with a resumed Timeline when one is passed" do
      resumed = Lain::Dag::Factory.timeline(head_digest: nil, store: Lain::Dag::Factory.store)

      expect(build(timeline: resumed).timeline).to eq(resumed)
    end

    it "gives the Agent a RequestOverride, so the resend bridge has its slot" do
      expect(build.request_override).to be_a(Lain::Agent::RequestOverride)
    end

    # The nil-capture guard. The handle is built BEFORE the Agent it reads, so
    # it can only be a thunk over a binding assigned afterwards; a plain return
    # value would leave it nil forever and every turn-middleware read would
    # raise NoMethodError on the first turn.
    it "hands the chronicle a timeline handle that resolves to the built Agent" do
      agent = build

      expect(chronicle.timeline_handle.call).to be(agent.timeline)
    end

    # A flip into plan scope confines the session the Agent runs its tools in,
    # so the board must hold that one and no other.
    it "binds the board to the session the Agent is built over" do
      agent = build

      expect(board.session).to be(agent.session)
    end

    # The slot is born here and handed to the board, which hands it to `/undo`.
    it "hands the board a snapshot slot rooted at the project, under the board's scope" do
      build

      expect(board.snapshots).to be_a(Lain::Agent::SnapshotSlot)
      expect(board.snapshots.root).to eq(@root)
      expect(board.snapshots.label).to eq("write_set")
    end
  end

  # The shadow scope every mode writes under, from the first turn, in a chat
  # Wiring built from a project SUBDIRECTORY, with a real bash call writing a
  # file no lain tool records. Bash is tier 3 and would park on the approval
  # queue, so the board is flipped to auto first, which leaves the slot alone.
  describe "a chat Wiring launched from a subdirectory", :seam do
    around do |example|
      Dir.mktmpdir("lain-agent-build-project") do |project|
        Dir.mktmpdir("lain-agent-build-state") do |state|
          @project = File.realpath(project)
          @state = state
          FileUtils.mkdir_p(File.join(@project, "sub"))
          # The workspace profile refuses a TMPDIR holding home, as the spec's TMPDIR holds this chat's.
          Dir.mktmpdir("lain-agent-build-tmp") { |tmp| with_env("TMPDIR" => tmp) { example.run } }
        end
      end
    end

    let(:shell_write) { "printf unrecorded > #{File.join(@project, "made-by-bash.txt")}" }
    let(:provider) do
      Lain::Provider::Mock.new(responses: [
                                 tool_response(["tu_1", "bash", { "command" => shell_write }]),
                                 Lain::Response.new(content: [{ "type" => "text", "text" => "done" }],
                                                    stop_reason: :end_turn)
                               ])
    end

    def wired_chat
      wiring = described_class.new(
        options: { grace: 5 }, chronicle:, status_feed: instance_double(Lain::StatusFeed),
        project: Lain::Project.new(root: @project, cwd: File.join(@project, "sub"), kind: :project,
                                   detected_by: :flag),
        paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => @state, "HOME" => @state })
      )
      recorder, session = wiring.run_state(nil)
      [wiring, wiring.wire_agent(channel:, recorder:, session:, backend: WiringAgentSpecBackend.new(
        { provider: "ollama", model: nil, max_tokens: 64 }, mock: provider
      ))]
    end

    it "records a file no lain tool wrote in the next snapshot, rooted at the project root" do
      wiring, agent = wired_chat
      board = wiring.role_spawn.seam.tool_middleware.board.call
      board.mode_switch.switch(Lain::Mode.new(approval: :bypass), surface: "spec")

      agent.ask("make it")

      entry = board.snapshots.log.to_a.last
      body = agent.timeline.store.fetch(entry.snapshot).body
      expect(entry.files.keys).to eq(["made-by-bash.txt"])
      expect(body.fetch("root")).to eq(@project)
      expect(body.fetch("snapshot_scope")).to eq(Lain::Workspace::Snapshot::Scope::ShadowGit::NOTE)
    end
  end

  describe "the switchboard memo Wiring keeps" do
    let(:status_feed) { instance_double(Lain::StatusFeed) }
    let(:wired_backend) do
      Class.new(Lain::CLI::Backend) do
        def initialize(options, mock:, root: Dir.pwd)
          super(options, root:)
          @mock = mock
        end

        def provider(**) = @mock
      end.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: mock_provider)
    end

    def wire
      recorder, session = wiring.run_state(nil)
      wiring.wire_agent(channel:, recorder:, session:, backend: wired_backend)
    end

    it "hands the bash tool a resolver over the Fresh the observers registered, not a fallback" do
      agent = wire

      resolver = agent.toolset.fetch("bash").instance_variable_get(:@resolver)

      expect(resolver.instance_variable_get(:@fresh)).to be(wiring.instance_variable_get(:@observers).fresh)
    end

    it "hands the toolset build the Fresh the observers registered, which a sandbox's port grant reads" do
      wire

      expect(wiring.instance_variable_get(:@toolset_build).instance_variable_get(:@fresh))
        .to be(wiring.instance_variable_get(:@observers).fresh)
    end

    # Assigned as a SIDE EFFECT of building the agent: #switchboard is memoized
    # at its one call site, and three readers depend on that having happened.
    # Moving the memo into this module is the failure the card is written to
    # avoid, so the readers are what pin it.
    it "is assigned by the time the parked-approval queue is read" do
      wire

      expect(wiring.approvals).to be_a(Lain::Approval::Parked::Queue)
    end

    # Reaching {Command::Env}'s own refusal AT ALL is the assertion:
    # `@switchboard.surface_kwargs` runs first and would raise NoMethodError on
    # nil before any Env existed. What the refusal then names is the pair
    # #build_repl owns and this call deliberately withholds -- never
    # `approvals`, which is nil exactly when the memo is.
    it "is assigned by the time the command surface is assembled" do
      wire

      expect do
        wiring.send(:assemble_surface, agent: nil, library: nil, window: nil, endpoint: nil,
                                       middleware: Lain::Config::Middleware.empty,
                                       profile: Lain::CLI::RunProfile.from_options({}))
      end.to raise_error(ArgumentError, /\[:replies, :agent\]/)
    end

    # A subagent's tool stack is built by {CLI::ToolGuard::Spawned} over the
    # thunk `-> { @switchboard }`, read at SPAWN time -- turns after the Agent
    # was built, which is what lets it be late. Reached here through public
    # readers only ({Wiring#role_spawn}, {Skill::RoleSpawn#seam},
    # {Tools::Subagent::Seam#tool_middleware}), because the point is the seam a
    # child really travels over and not an ivar.
    def child_guard = wiring.role_spawn.seam.tool_middleware

    def child_gate = child_guard.call(Lain::WorkerEnv.default).to_a.last

    # Driving `.board.call` IS driving the thunk: that is the call the builder
    # makes as each child is built.
    it "is what a subagent's tool stack thunk resolves" do
      wire

      expect(child_guard.board.call).to be_a(Lain::CLI::Switchboard)
    end

    # The privilege-inversion guard, stated as the thing a child's dispatch
    # actually consults: the gate a child is built behind asks the board's
    # ONE policy switch, and calls whatever that slot currently holds.
    #
    # The queue assertion is the one that is not a tautology, and the direction
    # is the whole of why: the left side travels the CHILD's thunk out to a
    # board and back, where the right side is {Wiring}'s own reader over the
    # memo. Two paths, one object.
    #
    # What then adjudicates is the run's escalation ladder. Against an ungated
    # board it would be an unconditional approver: a child could do what its
    # parent must ask to do, which is a privilege inversion and not a wiring
    # omission.
    it "gates a child through the run's own queue, the one its parent is gated by", :seam do
      wire
      resolved = child_guard.board.call

      expect(gate_asks?(resolved.policy_switch, child_guard.call(Lain::WorkerEnv.default), toolset: resolved.toolset))
        .to be(true)
      expect(resolved.approvals).to be(wiring.approvals)
      expect(resolved.policy_switch.current).to be_a(Lain::Approval::Escalation)
      expect(resolved.policy_switch.current).not_to be_a(Lain::Middleware::Gate::ApproveAll)
    end

    # The identity that makes the privilege inversion unrepresentable: ONE
    # board, so one {Sensitivity::Policy}, so the paths a child's gate refuses
    # are the paths its parent's gate refuses -- by construction rather than by
    # two wirings agreeing. A second thunk here would satisfy every behavioural
    # check in this suite and still point at a different session.
    #
    # `#sensitivity` is read off the resolved board rather than off Wiring,
    # which keeps no public reader for it: the board IS the parent gate's
    # source, so reading its slot is reading what the parent consults.
    it "resolves a child's sensitivity from the same board its gate policy resolves" do
      wire

      expect(child_gate.instance_variable_get(:@sensitivity).policy).to be(child_guard.board.call.sensitivity)
    end

    # The late half, which the two above cannot see: the thunk closes over an
    # IVAR, so it must answer the board that is there WHEN IT IS CALLED, not
    # one captured while the toolset was being built -- at which point the memo
    # is still nil. Building the toolset alone and reading the thunk before the
    # agent exists is the only place that distinction is visible.
    it "reads nil until the agent build assigns it, which is what makes the thunk late" do
      recorder, = wiring.run_state(nil)
      wiring.send(:build_toolset, recorder, backend: wired_backend, parent: -> {},
                                            ask_human: Lain::Tools::AskHuman.new(parent: -> {}))

      expect(wiring.role_spawn.seam.tool_middleware.board.call).to be_nil
    end
  end
end

# The capability floor's own seam, and it earns a group of its own for one
# thing the assemblers above it cannot show. This module is where the session's
# {Lain::Shell::Verdict} reaches {Lain::Tools::Bash}, and the keyword carrying
# it has a permissive default -- which is exactly how an unwired guard ships
# green forever. So what is asserted here is the IDENTITY of what arrives,
# alongside the default staying indistinguishable from the tool's own.
RSpec.describe Lain::CLI::Wiring::ScreenNotices do
  # The alternate screen wipes whatever was said before it opened, so a warning
  # given then -- a key the line editor would not give up -- is said once it is up.
  it "says a warning given before the screen opened once it is up, after the startup notices" do
    said = []
    screen = Object.new
    screen.define_singleton_method(:render_warning) { |line| said << line }
    screen.define_singleton_method(:run) do |&conversation|
      said << :opened
      conversation.call(self)
    end
    notices = described_class.new(screen, ["startup"])

    notices.render_warning("the approval key is off")
    notices.run { notices.render_warning("later") }

    expect(said).to eq([:opened, "startup", "the approval key is off", "later"])
  end
end

RSpec.describe Lain::CLI::Wiring::BaseTools do
  let(:recorder) { Lain::Memory::Recorder.new }
  let(:channel) { RecordingChannel.new }

  # `@verdict` is read through the ivar for `toolset_build_spec`'s reason:
  # {Lain::Tools::Bash} exposes no reader, and adding one to widen a spec's
  # reach would be the spec shaping the subject.
  def bash_in(floor) = floor.find { |tool| tool.name == "bash" }

  def verdict_of(floor) = bash_in(floor).instance_variable_get(:@verdict)

  def excluding(*programs)
    Lain::Shell::Verdict.new(capability_set: Lain::Shell::Exclusions.new(patterns: programs))
  end

  # The keyword carrying the session's journal has a Null default too, and a
  # permissive default is exactly how a wired-looking guard ships doing nothing.
  # So this is driven through {Lain::CLI::Wiring::ToolsetBuild} -- the object
  # that assembles this floor for every chat -- with the real bash tool running
  # a real command and NO double anywhere below the assembler. What is asserted
  # is that the record lands in the journal that session was built with.
  describe "the journal a live session's assembler hands the floor" do
    let(:backend) { Lain::CLI::Backend.new({ provider: "ollama", model: nil, max_tokens: 64 }, root: Dir.pwd) }
    let(:chronicle) { Lain::CLI::Chronicle::Null.new }
    let(:journal) { RecordingChannel.new }
    let(:parent) { -> { Lain::Dag::Factory.timeline(store: Lain::Dag::Factory.store) } }
    let(:assembler) do
      Lain::CLI::Wiring::ToolsetBuild.new(backend:, provider: backend.provider(spool: chronicle.spool),
                                          chronicle:, options: {}, supervisor: Lain::Supervisor.new(journal:),
                                          parent:, journal:, library: backend.library,
                                          epic: SpecNulls.unmounted_epic, root: Dir.pwd,
                                          switchboard: -> { SpecNulls::NoSwitchboard },
                                          askers: SpecNulls::UnwiredAskers.build,
                                          **SpecNulls.unloaded_project)
    end

    def live_bash = assembler.build(recorder, ask_human: Lain::Tools::AskHuman.new(parent:)).fetch("bash")

    it "lands the bash tool's arm record in that session's journal" do
      live_bash.call({ command: "ls -la" }, Lain::Tool::Invocation.new(tool_use_id: "tu_live", channel:))

      expect(journal.events.grep(Lain::Telemetry::ShellArm).map { |arm| [arm.tool_use_id, arm.verdict] })
        .to eq([["tu_live", :allow]])
    end
  end

  describe "the floor itself" do
    it "hands the bash tool the verdict it was built with, by identity" do
      chosen = excluding("curl")

      expect(verdict_of(described_class.build(recorder, verdict: chosen))).to be(chosen)
    end

    # The behavioural half of the same claim: the floor's bash really answers
    # through the session's table, so a program the project ruled out is a
    # refusal at the tool's own arm choice too.
    it "gives the floor a verdict that refuses the program the session excluded" do
      floor = described_class.build(recorder, verdict: excluding("curl"))

      expect(verdict_of(floor).call("curl http://example.com")).to be_deny
    end

    # The exec tools are named in one place production reads
    # ({Lain::Approval::Escalation::Triage::COMMAND_TOOLS}) and built in one
    # place a chat reaches (this floor). A name on that list the floor never
    # builds is a tool nothing can reach while the approval vocabulary still
    # vouches for it -- which is how a second exec tool sat there unoffered.
    # So the two halves are asserted against each other rather than separately.
    it "offers bash, and names no command tool the floor does not build" do
      names = described_class.build(recorder).map(&:name)

      expect(names).to include("bash")
      expect(Lain::Approval::Escalation::Triage::COMMAND_TOOLS - names).to be_empty
    end

    # The floor is what a subagent role attenuates FROM, so the ONE bash the
    # floor holds is the one a child inherits -- there is no second tool to
    # wire, and no way for a child's verdict to differ from its parent's.
    it "builds exactly one bash, so a child cannot inherit a different verdict" do
      floor = described_class.build(recorder, verdict: excluding("curl"))

      expect(floor.count { |tool| tool.name == "bash" }).to eq(1)
    end

    # The default is what an unwired build gets, and it must restrict nothing:
    # a floor built with no session behaves byte-for-byte as it did before the
    # keyword existed.
    it "defaults to a verdict that restricts no program" do
      expect(verdict_of(described_class.build(recorder)).call("curl http://example.com")).to be_allow
    end

    # A bash built with no verdict at all still runs the term arm, which is the
    # property the default exists to protect: `Tools::Subagent` runs an ungated
    # handler and `bash_spec` constructs the tool alone, so sharing the
    # session's instance has to stay an INJECTION rather than a dependency.
    it "still runs the term arm with no verdict wired, and spawns no shell" do
      seen = []
      real = Lain::Shell::Pipeline.new
      pipeline = lambda do |term, **options|
        seen << term
        real.call(term, **options)
      end
      floor = described_class.build(recorder, exec: Lain::Exec::Local.new(pipeline:))

      result = bash_in(floor).call({ command: "ls -la" }, Lain::Tool::Invocation.new(tool_use_id: "tu_1", channel:))

      expect(seen).to eq([Lain::Shell::Term.of(%w[ls -la])])
      expect(result).to be_ok
      expect(result.content).to include("exit status: 0")
    end

    # {Lain::Tool::FileTarget} is a MIXIN, so nothing constructs it and no spec
    # of its own can prove the floor's tools really carry it. This drives the
    # read_file the floor built -- no double anywhere below the assembler --
    # against a session whose cwd is not the process's, which is the one
    # observable difference between resolving through the seam and resolving
    # against Dir.pwd the way these tools each used to.
    it "gives the floor's file tools the session's cwd to resolve against" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "a.txt"), "inside the session cwd\n")
        session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: dir, env: ENV.to_h))
        read_file = described_class.build(recorder).find { |tool| tool.name == "read_file" }

        result = read_file.call({ path: "a.txt" },
                                Lain::Tool::Invocation.new(tool_use_id: "tu_1", context: session))

        expect(result).to be_ok
        expect(result.content).to include("inside the session cwd")
      end
    end
  end
end

# How the chat handoff finds the repository a worker's work is anchored in.
# It used to derive that separately from the {Lain::Isolation::Worktree}
# backend that actually cut the worker checkouts -- a second, git-shelled
# `rev-parse --show-toplevel` that can disagree with the backend's own answer
# under GIT_CEILING_DIRECTORIES (see the divergence example below). Reading
# the backend's own #repo_root instead makes the two answers unrepresentable
# as different directories.
RSpec.describe Lain::CLI::Wiring, "the handback a worker's work comes home on", :seam do
  around do |example|
    Dir.mktmpdir("lain-handback-repo") do |dir|
      @repo = File.realpath(dir)
      init_repo(@repo)
      @root = File.join(@repo, "sub")
      FileUtils.mkdir_p(@root)
      example.run
    end
  end

  def init_repo(dir) = FileUtils.cp_r("#{SeedRepo.at("README" => "seed\n")}/.", dir)

  # The fleet backend a `--isolation worktree` chat resolves, reached through
  # the wiring rather than built beside it: what is under test is the handback
  # the run's OWN isolation produces, and a second backend built here could
  # answer a different repository than the one the run cut checkouts from.
  def handback_of_chat
    described_class.new(options: { grace: 5, isolation: "worktree" },
                        chronicle: Lain::CLI::Chronicle::Null.new,
                        status_feed: instance_double(Lain::StatusFeed),
                        project: Lain::Project.new(root: @root, cwd: @root, kind: :project, detected_by: :flag))
                   .send(:handback)
  end

  it "refuses, naming the file and line, when the project's config will not load" do
    write_config(@root, "\nisolation retain_days: 0\n")

    expect { handback_of_chat }.to raise_error(Lain::Config::Refusal, /config\.rb:2/)
  end

  it "wires the handoff with the working branch's repository" do
    expect(handback_of_chat.handoff).not_to equal(Lain::Isolation::WorkerHandoff::Null)
  end

  # THE DIVERGENCE. `--isolation worktree` launched from a SUBDIRECTORY of the
  # repository, under GIT_CEILING_DIRECTORIES pointed at the repository root
  # itself: git's own discovery walk stops BEFORE reaching that root when it
  # starts below it (verified against a real `git rev-parse --show-toplevel`),
  # so a handoff that re-derives its root by shelling out raises where the
  # backend -- whose own repository search is a plain directory walk, not a
  # git subprocess -- resolved and cut worktrees just fine.
  it "answers from the backend's own repository rather than raising under GIT_CEILING_DIRECTORIES" do
    with_env("GIT_CEILING_DIRECTORIES" => @repo) do
      handback = nil
      expect { handback = handback_of_chat }.not_to raise_error

      expect(handback.handoff.repo_root).to eq(@repo)
    end
  end
end
