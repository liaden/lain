# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"

# The Switchboard's side of this seam. Only the two slots {ToolGuard} reads --
# a real Ledger and a real Queue, never doubles, because every claim here is
# about IDENTITY: that the guard holds the BOARD's one ledger and the BOARD's
# one queue. A double answering plausible messages cannot tell the board's
# ledger from a freshly constructed second one, which is exactly the mistake
# this file exists to catch.
class ToolGuardSpecBoard
  attr_reader :ledger, :approvals, :sensitivity, :test_layout, :policy

  # `sensitivity` is a REAL {Lain::Sensitivity::Policy} over a REAL classifier
  # for this file's own reason, one slot over: the claim is that the listing
  # guard filters through the BOARD's policy rather than through a second
  # filter built beside it, and a double answering `filter` cannot tell those
  # apart. The default is the live one because that is what {CLI::Wiring} now
  # builds; a queueless board with no classifier passes the Null.
  # `policy` is the gate's, answering a fixed verdict and recording the context
  # it was asked in, so an example can see WHO a call was asked for.
  def initialize(approvals: nil, sensitivity: nil, test_layout: Lain::Middleware::GuardTestLayout::Run.undeclared,
                 policy: ToolGuardSpecPolicy.new)
    @ledger = Lain::Sensitivity::Ledger.new
    @approvals = approvals
    @test_layout = test_layout
    @policy = policy
    @sensitivity = sensitivity || Lain::Sensitivity::Policy.new(
      sensitivity: Lain::Sensitivity.new(home: "/home/tester", cwd: "/home/tester/project")
    )
  end

  # The one value a real {Lain::CLI::Switchboard} holds, over these same slots.
  def guard_inputs
    @guard_inputs ||= Lain::CLI::ToolGuard::Inputs.new(ledger:, approvals:, sensitivity:, test_layout:, policy:,
                                                       denial: "the spec board refuses %<name>s",
                                                       bar: Lain::Middleware::WithholdAutomaticOutput::Bar.new)
  end
end

# A gate policy answering one ruling, keeping every context it was asked in.
# It answers `#rule` as every production policy does, so the gate holds it
# as it is rather than through the adapter a bare callable gets.
class ToolGuardSpecPolicy
  attr_reader :contexts

  def initialize(verdict: false, ruling: nil)
    @ruling = ruling || fixed(verdict ? :allow : :deny)
    @contexts = []
  end

  def fixed(verdict) = Lain::Approval::Escalation::Ruling.public_send(verdict, rung: "spec", because: "a fixed answer")

  def rule(_effect, context)
    @contexts << context
    @ruling
  end

  def call(effect, context) = rule(effect, context).allow?
end

# A chronicle that is actually JOURNALING. `Chronicle::Null`'s
# `instrumentation.journal` IS `Channel::Null.instance`, so against it
# `journal: chronicle.instrumentation.journal` and `journal:
# Channel::Null.instance` are the same object -- every assertion passes under
# both, and the one line that carries the mask record to disk looks tested
# while nothing tests it. Only a real journal can tell them apart.
class ToolGuardSpecChronicle
  attr_reader :journal

  def initialize(journal)
    @journal = journal
  end

  def instrumentation = Lain::Agent::Instrumentation.new(journal: @journal)
end

# A queue that refuses every release, so the fail-open block below can carry a
# CONTROL arm. Without one, "the secret came through" is equally well explained
# by a region detector that never fired, and the example would pin nothing.
class ToolGuardSpecDecliningQueue
  module Verdict
    def self.approved? = false
  end

  # `outstanding:` is accepted and discarded, but cannot become the unused-
  # argument underscore: it is a KEYWORD, so the name is the duck.
  def adjudicate(_effect, _context, outstanding: nil) # rubocop:disable Lint/UnusedMethodArgument
    Verdict
  end
end

# The tool phase's guards, and the wiring line each rests on. The stack itself
# is one expression, which is why it went untested: it looks like plumbing. It
# is not -- `board.approvals || Unqueued.instance` decides whether a run asks a
# human before sending a secret, and `board.ledger` decides whether the run has
# one release ledger or two.
RSpec.describe Lain::CLI::ToolGuard do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  # Journaling, never the Null chronicle -- see {ToolGuardSpecChronicle}.
  let(:chronicle) { ToolGuardSpecChronicle.new(journal) }
  let(:queue) { Lain::Approval::Queue.new(journal:) }

  def guards(board) = described_class.stack(chronicle, board).to_a

  def read_guard(board) = guards(board).grep(Lain::Middleware::RedactSecretReads).first

  def read_call(path) = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "read_file", input: { "path" => path })

  describe "the stack it builds" do
    it "puts the write, read, listing, test layout and automatic output guards first, then the path refusal and " \
       "the gate" do
      expect(guards(ToolGuardSpecBoard.new).map(&:class))
        .to eq([Lain::Middleware::RefuseSecretWrites, Lain::Middleware::RedactSecretReads,
                Lain::Middleware::WithholdSecretPaths, Lain::Middleware::GuardTestLayout,
                Lain::Middleware::WithholdAutomaticOutput, Lain::Middleware::Sensitivity, Lain::Middleware::Gate])
    end

    # Everything the guards are built over is ONE value on the board, so a
    # board answering nothing else is enough to build the stack from.
    it "reads every input off the board's one value" do
      inputs = Lain::CLI::ToolGuard::Inputs.new(ledger: Lain::Sensitivity::Ledger.new, approvals: queue,
                                                sensitivity: Lain::Sensitivity::Policy::Null.instance,
                                                test_layout: Lain::Middleware::GuardTestLayout::Run.undeclared,
                                                policy: ToolGuardSpecPolicy.new, denial: "no %<name>s",
                                                bar: Lain::Middleware::WithholdAutomaticOutput::Bar.new)
      bare = Data.define(:guard_inputs).new(guard_inputs: inputs)

      read = described_class.stack(chronicle, bare).to_a.grep(Lain::Middleware::RedactSecretReads).first

      expect(read.ledger).to be(inputs.ledger)
      expect(read.queue).to be(queue)
    end

    # The board's ONE run, for the ledger's reason: a second would keep a
    # second constant index and say the absence of a layout a second time.
    it "judges writes through the board's own layout run, at the project root alone" do
      board = ToolGuardSpecBoard.new
      layout = guards(board).grep(Lain::Middleware::GuardTestLayout).first

      expect(layout.run).to be(board.test_layout)
      expect(layout.roots).to eq([board.test_layout.root])
    end

    # This example was the Null pin -- "wires the listing guard with the Null
    # filter, because no classifier is constructed yet" -- and it existed so
    # the swap away from it could not happen silently. It has happened, so the
    # pin is INVERTED rather than deleted: a stack entry is still only half of
    # what makes a guard live, and this is the other half.
    #
    # Identity against `board.sensitivity.filter`, never `be_a(Filter)`: a
    # filter built HERE from a freshly constructed classifier would be a real
    # Filter, would answer every message, and would judge a DIFFERENT set of
    # paths than the gate -- the run enumerating a path its own gate refuses to
    # read. Only sameness can see that, and the shape makes it structural: the
    # Policy exposes no classifier, so this is the only filter reachable.
    it "wires the listing guard with the board's own filter, over the classifier the gate reads" do
      board = ToolGuardSpecBoard.new
      guard = guards(board).grep(Lain::Middleware::WithholdSecretPaths).first

      expect(guard.filter).to be(board.sensitivity.filter)
      expect(guard.filter).not_to be(Lain::Sensitivity::Filter::Null.instance)
    end

    # The consequence a reader can check, and it fails against any second
    # filter whatever its construction: the row the gate would gate is the row
    # this guard drops.
    it "so a path the gate gates is a path the listing guard withholds" do
      board = ToolGuardSpecBoard.new
      guard = guards(board).grep(Lain::Middleware::WithholdSecretPaths).first
      gated = "/home/tester/project/.env"

      expect(board.sensitivity.gates?(read_call(gated))).to be(true)
      expect(guard.filter.sift([gated]) { |row| [row] }.withheld.map(&:reason)).to eq([:credential])
    end

    # The other half of the Null story: a board that resolved no classifier
    # produces byte-identical listings, with no `if filter` anywhere.
    it "passes the Null filter through when the board wired no classifier" do
      board = ToolGuardSpecBoard.new(sensitivity: Lain::Sensitivity::Policy::Null.instance)
      guard = guards(board).grep(Lain::Middleware::WithholdSecretPaths).first

      expect(guard.filter).to be(Lain::Sensitivity::Filter::Null.instance)
    end
  end

  # The left branch of `board.approvals || Unqueued.instance`, which no example
  # reached before: every board in the suite carried a nil queue, so a wiring
  # that ALWAYS substituted the always-approve stand-in -- silently approving
  # and releasing every region of every read, in every run, with no human
  # anywhere -- passed the whole suite.
  # {Lain::Agent::Instrumentation} is a collaborator of the Agent's, not a shard
  # of it: two of its three callers are outside `Agent`, and this is one. So it
  # stayed its own object when the collaborator RESOLVER folded back in, and
  # this example is where that asymmetry is pinned rather than remembered.
  # The gate is a guard like the other four, built over the same one value, so
  # a chat's stack and every child's come out of this one module. Its place is
  # the posture: the gate judges the tool the runner resolved and approves the
  # input it was shown, so nothing may sit between it and the interpreter.
  describe "the gate every stack ends in" do
    def gate_of(stack) = stack.to_a.last

    def dispatched(stack, name = "bash", context: :the_session)
      env = stack.call({ effect: Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name:, input: {}),
                         tool: Lain::Tools::Bash.new, context: }) do |passed|
        passed.merge(result: Lain::Tool::Result.ok("the interpreter ran"))
      end
      env.fetch(:result)
    end

    it "ends the chat's stack, a child's and a run's with no chat alike in the gate" do
      board = ToolGuardSpecBoard.new
      built = [described_class.stack(chronicle, board),
               described_class.child_stack(chronicle, board, Lain::WorkerEnv.default, requester: "researcher"),
               described_class.detached(journal:).call(Lain::WorkerEnv.default)]

      expect(built.map { |stack| stack.to_a.last(2).map(&:class) })
        .to all(eq([Lain::Middleware::Sensitivity, Lain::Middleware::Gate]))
    end

    it "judges both axes over the board's one path policy and asks the board's one gate policy" do
      board = ToolGuardSpecBoard.new
      layers = guards(board).last(2)

      expect(layers.map { |layer| layer.instance_variable_get(:@sensitivity) }).to all(be(board.sensitivity))
      expect(gate_of(guards(board)).instance_variable_get(:@policy)).to be(board.policy)
    end

    it "reports a refused call in the board's own words" do
      expect(dispatched(described_class.stack(chronicle, ToolGuardSpecBoard.new)))
        .to eq(Lain::Tool::Result.error(%(the spec board refuses "bash")))
    end

    it "records a refused path into the chronicle's journal, where the read guard records a mask" do
      refused = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "read_file",
                                           input: { "path" => "/home/tester/.ssh/id_rsa" })

      described_class.stack(chronicle, ToolGuardSpecBoard.new)
                     .call({ effect: refused, tool: Lain::Tools::ReadFile.new, context: nil }) { |passed| passed }

      expect(Lain::Journal.records(journal_io.string.lines, type: "read_refused").to_a.size).to eq(1)
    end

    # The child's half of the same record: a refused path lands where its
    # parent's does, never on a channel nothing renders.
    it "records a child's refused path into the chronicle's journal too" do
      refused = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "read_file",
                                           input: { "path" => "/home/tester/.ssh/id_rsa" })

      described_class.child_stack(chronicle, ToolGuardSpecBoard.new, Lain::WorkerEnv.default, requester: "researcher")
                     .call({ effect: refused, tool: Lain::Tools::ReadFile.new, context: nil }) { |passed| passed }

      expect(Lain::Journal.records(journal_io.string.lines, type: "read_refused").to_a.size).to eq(1)
    end

    # The check a child's stack is held to, on every stack built here: the
    # parent's, a chat child's and a run's with no chat alike.
    it "holds every stack it builds to the gate closing it" do
      allow(Lain::Middleware::Gate).to receive(:closes!).and_call_original
      board = ToolGuardSpecBoard.new

      described_class.stack(chronicle, board)
      described_class.child_stack(chronicle, board, Lain::WorkerEnv.default, requester: "researcher")
      described_class.detached(journal:).call(Lain::WorkerEnv.default)

      expect(Lain::Middleware::Gate).to have_received(:closes!).exactly(3).times
    end

    # The parent asks as itself: a context nobody wrapped names nobody, which
    # the approval queue reads as the session's own agent.
    it "asks the parent's policy in the session's own context" do
      board = ToolGuardSpecBoard.new

      dispatched(described_class.stack(chronicle, board))

      expect(board.policy.contexts).to eq([:the_session])
    end

    # A child asks the SAME policy, through a context naming the child, so a
    # park says which of a fleet is asking while the verdict stays the board's.
    # A `bash` call is judged over the automatic output guard's context, so the
    # session sits one delegator further down.
    it "asks a child's policy through a context naming the child" do
      board = ToolGuardSpecBoard.new

      dispatched(described_class.child_stack(chronicle, board, Lain::WorkerEnv.default, requester: "researcher"))

      expect(board.policy.contexts.map(&:requester)).to eq(%w[researcher])
      expect(board.policy.contexts.first.__getobj__).to be_a(Lain::Middleware::WithholdAutomaticOutput::Carried)
      expect(board.policy.contexts.first.__getobj__.__getobj__).to be(:the_session)
    end

    # Production never reaches the gate's adapter for a bare callable, whose
    # rulings carry no reason: the parent's gate holds the board's policy, a
    # child's holds the ruling-answering wrapper naming it, and a run with no
    # chat holds its own fixed policy.
    it "holds a policy that answers a ruling itself on every stack it builds" do
      board = ToolGuardSpecBoard.new
      held = [described_class.stack(chronicle, board),
              described_class.child_stack(chronicle, board, Lain::WorkerEnv.default, requester: "researcher"),
              described_class.detached(journal:).call(Lain::WorkerEnv.default)]
             .map { |stack| gate_of(stack).instance_variable_get(:@policy) }

      expect(held.map(&:class))
        .to eq([ToolGuardSpecPolicy, described_class::Asking, Lain::Middleware::Gate::ApproveAll])
    end

    it "forwards a child's ruling from the board's policy, asked in a context naming the child" do
      denied = Lain::Approval::Escalation::Ruling.deny(rung: "triage", because: "excluded", final: true)
      board = ToolGuardSpecBoard.new(policy: ToolGuardSpecPolicy.new(ruling: denied))
      asking = described_class::Asking.new(policy: board.policy, requester: "researcher")

      expect(asking.rule(:effect, :the_session)).to be(denied)
      expect(board.policy.contexts.map(&:requester)).to eq(%w[researcher])
    end

    it "rules for a child through a bare callable it wraps, rather than raising out of the turn" do
      asked = []
      refusing = lambda do |_effect, context|
        asked << context.requester
        false
      end
      asking = described_class::Asking.new(policy: refusing, requester: "researcher")

      expect(asking.rule(:effect, :the_session)).to be_deny
      expect(asking.call(:effect, :the_session)).to be(false)
      expect(asked).to eq(%w[researcher researcher])
    end

    it "tells a child why a refusal no approval lifts was made, as it tells the parent" do
      denied = Lain::Approval::Escalation::Ruling.deny(rung: "triage", because: "the argv names a key", final: true)
      board = ToolGuardSpecBoard.new(policy: ToolGuardSpecPolicy.new(ruling: denied))

      told = [described_class.stack(chronicle, board),
              described_class.child_stack(chronicle, board, Lain::WorkerEnv.default, requester: "researcher")]
             .map { |stack| dispatched(stack).content }

      expect(told).to all(include("the argv names a key", "no approval will lift this"))
    end
  end

  # What a chat's spawn seam carries: the builder over a board that does not
  # exist yet when the seam does, and the name its children are asked for.
  describe Lain::CLI::ToolGuard::Spawned do
    subject(:spawned) { described_class.new(chronicle:, board: -> { board }, requester: "subagent") }

    let(:board) { ToolGuardSpecBoard.new }

    it "builds a child's stack over the board the thunk answers when a child is built" do
      stack = spawned.call(Lain::WorkerEnv.default)

      expect(stack.to_a.grep(Lain::Middleware::RedactSecretReads).first.ledger).to be(board.ledger)
      expect(stack.to_a.last.instance_variable_get(:@policy).requester).to eq("subagent")
    end

    # Rebinding who is asking is a copy differing in that one member, so the
    # run's one seam is never relabelled in place.
    it "names a different child in a copy, leaving itself as it was" do
      renamed = spawned.with(requester: "researcher")

      expect(renamed.call(Lain::WorkerEnv.default).to_a.last.instance_variable_get(:@policy).requester)
        .to eq("researcher")
      expect(spawned.requester).to eq("subagent")
    end

    it "builds a fresh stack per child, so a layer one child's builder inserts reaches no other" do
      expect(spawned.call(Lain::WorkerEnv.default)).not_to be(spawned.call(Lain::WorkerEnv.default))
    end

    # A board still nil when a child is built is a spawn that beat the chat's
    # assembly: refused loudly, never a child built over nothing.
    it "refuses to build a child over a board that does not exist yet" do
      unbuilt = described_class.new(chronicle:, board: -> {}, requester: "subagent")

      expect { unbuilt.call(Lain::WorkerEnv.default) }.to raise_error(NoMethodError, /guard_inputs/)
    end
  end

  describe Lain::CLI::ToolGuard::Journaled do
    it "builds the instrumentation a journal-only run hands to Agent.new" do
      journal = RecordingChannel.new

      instrumentation = described_class.new(journal:).instrumentation

      expect(instrumentation).to be_a(Lain::Agent::Instrumentation)
      expect(instrumentation.journal).to be(journal)
    end
  end

  describe "which queue the read guard parks on" do
    it "parks on the board's own queue when the run wired one" do
      board = ToolGuardSpecBoard.new(approvals: queue)

      expect(read_guard(board).queue).to be(queue)
    end

    it "is not the always-approve stand-in when a real queue exists" do
      board = ToolGuardSpecBoard.new(approvals: queue)

      expect(read_guard(board).queue).not_to be_a(Lain::Middleware::RedactSecretReads::Unqueued)
    end

    # An unattended run is the only run with no queue, and the substitution has
    # to happen HERE: the middleware refuses a nil queue outright, so without it
    # a `--non-interactive` chat raises at construction.
    it "substitutes the unqueued stand-in only when the board wired none" do
      expect(read_guard(ToolGuardSpecBoard.new).queue)
        .to be(Lain::Middleware::RedactSecretReads::Unqueued.instance)
    end
  end

  # `Telemetry::ReadRedacted` is now the ONLY record that a path was masked --
  # `SessionRecord::Replay` folds it and nothing else rebuilds the masked set --
  # so this keyword became security-bearing the moment the resume path landed.
  # Send it to `Channel::Null` instead and the live session still refuses while
  # every resumed one PERMITS the write, and the secret on disk is replaced by
  # its own placeholder.
  describe "which journal the read guard records a mask into" do
    it "records into the chronicle's journal, not a discard" do
      expect(read_guard(ToolGuardSpecBoard.new).journal).to be(journal)
    end

    it "is not the Null channel, which would drop the only record of the mask" do
      expect(read_guard(ToolGuardSpecBoard.new).journal).not_to be(Lain::Channel::Null.instance)
    end

    # The consequence, checked rather than inferred: a record written through
    # the guard's journal is one a replay can find.
    it "so a mask it records is one a resume can read back" do
      read_guard(ToolGuardSpecBoard.new).journal <<
        Lain::Telemetry::ReadRedacted.new(tool_use_id: "tu_1", path: "/repo/.env", regions: 1, released: 0)

      expect(Lain::SessionRecord::Replay.new(journal_io.string.each_line).session.masked_read?("/repo/.env"))
        .to be(true)
    end
  end

  # A fresh `Sensitivity::Ledger.new` here would answer every message the
  # board's does and hold none of its releases -- the second ledger that class's
  # own no-default rule exists to prevent. Only identity can see it.
  describe "which ledger the read guard releases into" do
    it "holds the board's ledger itself, never a second one" do
      board = ToolGuardSpecBoard.new

      expect(read_guard(board).ledger).to be(board.ledger)
    end

    # The identity assertion above is the mechanical statement; this is the
    # consequence a reader can check, and it fails against any second ledger
    # whatever its construction.
    it "so a release the guard makes is one the board can see" do
      board = ToolGuardSpecBoard.new
      regions = Lain::Sensitivity::Regions.detect("API_KEY=sk-ant-api03-QZ9vK2mR7xT4wL8nB3jH6yD1sA5fG0pE\n")

      read_guard(board).ledger.release("/repo/.env", regions)

      expect(board.ledger.released?("/repo/.env", regions.first.digest)).to be(true)
    end
  end

  # A child's stack is the parent's, guard for guard, over the same board --
  # except that a child leased into a checkout of its own writes THERE, so its
  # layout guard also holds that checkout's root. The layout is repo-relative,
  # so the checkout maps onto the project path for path.
  describe ".child_stack" do
    def layout_of(stack) = stack.to_a.grep(Lain::Middleware::GuardTestLayout).first

    def env_at(cwd, checkout: nil) = Lain::WorkerEnv.default.with(cwd:, checkout:)

    around do |example|
      Dir.mktmpdir do |dir|
        @project = File.join(dir, "project")
        @checkout = File.join(dir, "checkout")
        FileUtils.mkdir_p([File.join(@project, "lib"), @checkout])
        File.write(File.join(@checkout, ".git"), "gitdir: #{File.join(@project, ".git")}\n")
        example.run
      end
    end

    let(:run) { Lain::Middleware::GuardTestLayout::Run.new(layout: Lain::TestLayout::None, root: @project) }
    let(:board) { ToolGuardSpecBoard.new(test_layout: run) }

    def child_stack(worker_env) = described_class.child_stack(chronicle, board, worker_env, requester: "subagent")

    it "is the parent's stack, guard for guard" do
      expect(child_stack(env_at(@checkout, checkout: @checkout)).to_a.map(&:class)).to eq(guards(board).map(&:class))
    end

    it "judges a leased child's writes at its own checkout too, through the board's one run" do
      layout = layout_of(child_stack(env_at(@checkout, checkout: @checkout)))

      expect(layout.run).to be(board.test_layout)
      expect(layout.roots).to eq([@project, @checkout])
    end

    it "judges an unleased child standing in another repository at the project root alone" do
      expect(layout_of(child_stack(env_at(@checkout))).roots).to eq([@project])
    end

    it "judges an unleased child standing in the project at the project root alone" do
      expect(layout_of(child_stack(env_at(File.join(@project, "lib")))).roots).to eq([@project])
    end
  end

  # Out of chat there is no board to borrow: the run builds its own, once, and
  # every child it spawns reads behind a stack over that one board.
  describe ".detached" do
    let(:secret) { "AKIAIOSFODNN7EXAMPLE" }

    def detached_read(stack, path)
      Sync do
        stack.call({ effect: read_call(path), tool: Lain::Tools::ReadFile.new, context: Lain::Session.new }) do |inner|
          invocation = Lain::Tool::Invocation.new(tool_use_id: inner.fetch(:effect).tool_use_id,
                                                  context: inner.fetch(:context))
          inner.merge(result: Lain::Tools::ReadFile.new.call(inner.fetch(:effect).input, invocation))
        end
      end.fetch(:result).content
    end

    def detached_guards(thunk) = thunk.call(Lain::WorkerEnv.default).to_a

    it "answers a thunk building the chat's layers, in the chat's order" do
      expect(detached_guards(described_class.detached(journal:)).map(&:class))
        .to eq(guards(ToolGuardSpecBoard.new).map(&:class))
    end

    # A run with no chat has no surface for a question to reach, so its gate
    # APPROVES, deliberately against the gate's own fail-closed default: the
    # roles such a run spawns hold no gated tool, and a gate that parked would
    # park forever. Over the Null path policy, for the listing's reason below.
    it "approves every gated call, over no path policy" do
      stack = described_class.detached(journal:).call(Lain::WorkerEnv.default)
      bash = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input: { "command" => "ls" })

      env = stack.call({ effect: bash, tool: Lain::Tools::Bash.new, context: nil }) do |passed|
        passed.merge(result: Lain::Tool::Result.ok("the interpreter ran"))
      end

      expect(env.fetch(:result)).to eq(Lain::Tool::Result.ok("the interpreter ran"))
      expect(stack.to_a.last.instance_variable_get(:@sensitivity)).to be(Lain::Sensitivity::Policy::Null.instance)
    end

    # The thunk is called once per child, and every child must release into the
    # same ledger or a region one of them released stays masked for the next.
    it "builds every stack over ONE ledger, however many children ask" do
      thunk = described_class.detached(journal:)
      first, second = Array.new(2) { detached_guards(thunk).grep(Lain::Middleware::RedactSecretReads).first }

      expect(first).not_to be(second)
      expect(first.ledger).to be(second.ledger)
    end

    it "records into the journal it was handed" do
      read = detached_guards(described_class.detached(journal:)).grep(Lain::Middleware::RedactSecretReads).first

      expect(read.journal).to be(journal)
    end

    # Nobody is at an out-of-chat run's surface to release a region, and the
    # chat's unattended stand-in APPROVES. This one must not.
    it "masks a credential region, because nobody out of chat can release it" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "creds.txt")
        File.write(path, "harmless line\naws_access_key_id = #{secret}\ntail\n")

        content = detached_read(described_class.detached(journal:).call(Lain::WorkerEnv.default), path)

        expect(content).to include("<redacted:1>").and include("harmless line")
        expect(content).not_to include(secret)
      end
    end
  end

  # The production stack over a real board, a real ladder, a real queue and a
  # real `bash`: a command a rule approves automatically prints a key, and
  # nothing but the refusal reaches the model.
  describe "an automatically approved command's credential-shaped output", :seam do
    let(:key) do
      "-----BEGIN OPENSSH PRIVATE KEY-----\n" \
        "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\n" \
        "QyNTUxOQAAACBkSFTHQQ+dpqPdxkFGgYj9bzDbArQV711eUcx0p2x/BAAAAJiFPjsMhT47\n" \
        "-----END OPENSSH PRIVATE KEY-----\n"
    end
    let(:toolset) { Lain::Toolset.new([Lain::Tools::Bash.new]) }

    around do |example|
      Dir.mktmpdir do |dir|
        @dir = dir
        File.write(File.join(dir, "notes.txt"), key)
        example.run
      end
    end

    def automatic(command) = { "tool" => "bash", "input" => { "command" => command, "cwd" => @dir } }

    def board_approving(*commands)
      Lain::CLI::Switchboard.new(journal:, model: "claude-opus-4-8", toolset:,
                                 rules: [Lain::Approval::Remembered.new(allow: commands.map { automatic(_1) })])
    end

    def run_bash(board, command, id: "tu_1")
      layers = described_class.stack(chronicle, board).to_a
      dispatch_call("bash", { "command" => command, "cwd" => @dir }, id:, toolset:, layers:, context: Lain::Session.new)
    end

    # The call parks, so a sibling fiber stands where a human's surface does.
    def answered_by_human(board, command, approve:)
      Sync do |task|
        ran = task.async { run_bash(board, command, id: "tu_2") }
        pending = task.with_timeout(5) { board.approvals.dequeue }
        pending.decide(approve, surface: Lain::Frontend::ApprovalPolicy::SURFACE)
        [pending, task.with_timeout(30) { ran.wait }]
      end
    end

    it "composes the withholding guard on the parent's, a child's and a detached run's stack" do
      board = ToolGuardSpecBoard.new
      built = [described_class.stack(chronicle, board),
               described_class.child_stack(chronicle, board, Lain::WorkerEnv.default, requester: "researcher"),
               described_class.detached(journal:).call(Lain::WorkerEnv.default)]

      expect(built.map { |stack| stack.to_a.grep(Lain::Middleware::WithholdAutomaticOutput).size }).to all(eq(1))
    end

    it "bars a command for the parent and its children alike, through the board's one bar" do
      board = ToolGuardSpecBoard.new
      parent, child = [described_class.stack(chronicle, board),
                       described_class.child_stack(chronicle, board, Lain::WorkerEnv.default, requester: "researcher")]
                      .map { |stack| stack.to_a.grep(Lain::Middleware::WithholdAutomaticOutput).first }

      expect(parent.bar).to be(child.bar)
      expect(parent.bar).to be(board.guard_inputs.bar)
    end

    # Scenario: an automatically approved key print is withheld
    it "answers a withheld refusal naming 1 region" do
      told = Sync { run_bash(board_approving("cat notes.txt"), "cat notes.txt") }

      expect(told).to have_attributes(is_error: true)
      expect(told.content).to include("1 credential-shaped region", "now needs a human's approval")
      expect(told.content).not_to include("PRIVATE KEY")
      expect(Lain::Journal.records(journal_io.string.lines, type: "automatic_output_withheld").to_a)
        .to contain_exactly(include("tool_use_id" => "tu_1", "regions" => 1))
    end

    # Scenario: the retry goes to a human
    it "parks the same command for a human when the model calls it again" do
      board = board_approving("cat notes.txt")
      Sync { run_bash(board, "cat notes.txt") }

      pending, told = answered_by_human(board, "cat notes.txt", approve: false)

      expect(pending).to have_attributes(tool: "bash", tool_use_id: "tu_2")
      expect(told).to have_attributes(is_error: true)
    end

    # Under `auto` there is no queue to park on, so the retry is refused, and
    # the refusal names the way to a human rather than promising one.
    it "refuses the same command under auto approval, naming /mode ask as the way to a human" do
      board = board_approving("cat notes.txt")
      board.mode_switch.switch(Lain::Mode.new(approval: :auto), surface: "tty")
      Sync { run_bash(board, "cat notes.txt") }

      told = Sync { run_bash(board, "cat notes.txt", id: "tu_2") }

      expect(told).to have_attributes(is_error: true)
      expect(told.content).to include("a human must switch to /mode ask to approve it", "no approval will lift this")
      expect(told.content).not_to include("PRIVATE KEY")
      expect(board.approvals.each.count).to eq(0)
    end

    # With the auto_approve layer on, the model judge watches the same queue.
    # A barred retry is a human's alone, so the judge is never asked about it
    # and the call still waits for a person.
    it "keeps the parked retry from an automatic surface, so a human still decides it" do
      board = board_approving("cat notes.txt")
      judge = Lain::Approval::AutoSurface.new(role_spawn: ->(*) { Lain::Tool::Result.ok("APPROVE") },
                                              enabled: -> { true })
      Sync { run_bash(board, "cat notes.txt") }

      pending, told = Sync do |task|
        ran = task.async { run_bash(board, "cat notes.txt", id: "tu_2") }
        parked = task.with_timeout(5) { board.approvals.dequeue }
        judge.sweep(board.approvals)
        expect(parked).not_to be_decided
        parked.approve(surface: Lain::Frontend::ApprovalPolicy::SURFACE)
        [parked, task.with_timeout(30) { ran.wait }]
      end

      expect(pending.surface).to eq(Lain::Frontend::ApprovalPolicy::SURFACE)
      expect(told.content).to include(key)
    end

    # The stated limit: the scan sees credential SHAPES as printed. It catches an
    # accidental print, not a command written to reshape output past the
    # detector, which is why the approval predicates, not this layer, keep such a
    # command in front of a human.
    ["fold -w 16 notes.txt", "sed 's/./& /g' notes.txt", "xxd notes.txt"].each do |reshaping|
      it "does not see a key reshaped past the detector by `#{reshaping}`" do
        board = board_approving
        board.mode_switch.switch(Lain::Mode.new(approval: :auto), surface: "tty")

        told = Sync { run_bash(board, reshaping) }

        expect(told).to have_attributes(is_error: false)
        expect(told.content).not_to include("withheld")
      end
    end

    it "runs bash for a caller that threads no session" do
      board = board_approving("ls")
      layers = described_class.stack(chronicle, board).to_a

      told = Sync { dispatch_call("bash", { "command" => "ls", "cwd" => @dir }, toolset:, layers:, context: nil) }

      expect(told.content).to include("notes.txt")
    end

    # Scenario: a human-approved print is untouched
    it "hands a human-approved print the file's bytes" do
      _, told = answered_by_human(board_approving, "cat notes.txt", approve: true)

      expect(told).to have_attributes(is_error: false)
      expect(told.content).to include(key)
    end

    # Scenario: ordinary output passes
    it "passes an automatically approved ls unchanged" do
      told = Sync { run_bash(board_approving("ls"), "ls") }

      expect(told).to have_attributes(is_error: false)
      expect(told.content).to include("notes.txt").and include("exit status: 0")
    end
  end

  # {Lain::Middleware::RedactSecretReads::Unqueued}'s docstring is the
  # load-bearing account of this run's ONE fail-open, and until this block
  # nothing executable joined its two halves: `switchboard_spec` pins the deny,
  # `redact_secret_reads_spec` pins the approve over a HAND-BUILT Unqueued, and
  # no board ever reached both. Either half could move and the docstring would
  # go stale in silence -- the exact failure this card exists to remove.
  #
  # So: ONE unattended board, both halves, off the real Switchboard. This cannot
  # go red today, and that is the point -- round 11's deferred flip to deny
  # lands here as a red example on purpose, instead of quietly leaving a lying
  # comment behind.
  describe "the fail-open an unattended run ships with", :seam do
    let(:base) { Lain::Toolset.new([Lain::Tools::Bash.new, Lain::Tools::ReadFile.new]) }
    let(:board) do
      Lain::CLI::Switchboard.new(journal:, model: "claude-opus-4-8", toolset: base, attended: false)
    end
    let(:secret) { "AKIAIOSFODNN7EXAMPLE" }
    let(:body) { "harmless line\naws_access_key_id = #{secret}\ntail\n" }

    # The real read, driven through a real guard stack over a real file --
    # a seam, not a double: what is under test is what the BYTES do.
    def bytes_read_through(stack, path)
      Sync do
        stack.call({ effect: read_call(path), tool: Lain::Tools::ReadFile.new, context: Lain::Session.new }) do |inner|
          invocation = Lain::Tool::Invocation.new(tool_use_id: inner.fetch(:effect).tool_use_id,
                                                  context: inner.fetch(:context))
          inner.merge(result: Lain::Tools::ReadFile.new.call(inner.fetch(:effect).input, invocation))
        end
      end.fetch(:result).content
    end

    def with_secret_file
      Dir.mktmpdir do |dir|
        path = File.join(dir, "creds.txt")
        File.write(path, body)
        yield path
      end
    end

    # The single condition both halves read. Asserted first because if this ever
    # stops being nil, neither example below is testing what it says.
    it "wires no approval queue at all" do
      expect(board.approvals).to be_nil
    end

    it "DENIES every gated call, because nobody is there to ask" do
      told = dispatch_call("bash", { "command" => "ls" }, id: "tu_gate", toolset: board.toolset,
                                                          layers: described_class.stack(chronicle, board).to_a,
                                                          context: Lain::Session.new)

      expect(told.is_error).to be(true)
      expect(told.content).to include("no approval is possible")
    end

    # The other direction, off the SAME board: the secret is released whole.
    it "and APPROVES every sensitive region, releasing the bytes verbatim" do
      with_secret_file do |path|
        content = bytes_read_through(described_class.stack(chronicle, board), path)

        expect(content).to include(secret)
        expect(content).not_to include("<redacted")
      end
    end

    # The control: identical bytes, identical guard, a queue that says no. It
    # masks -- so the release above is a real decision, not a detector asleep.
    it "is a real release -- the same read masks when a queue declines" do
      with_secret_file do |path|
        guard = Lain::Middleware::RedactSecretReads.new(ledger: board.ledger,
                                                        queue: ToolGuardSpecDecliningQueue.new,
                                                        journal: chronicle.instrumentation.journal)

        content = bytes_read_through(Lain::Middleware::Stack.new([guard]), path)

        expect(content).not_to include(secret)
        expect(content).to include("<redacted")
      end
    end
  end
end
