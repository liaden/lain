# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# How a bench agent is WIRED. Its own file because it is what BOTH
# agent-construction sites default to: the recorder-sharing, the guard stack and
# the write/read partition below are properties of the WIRING rather than of
# either caller, and a claim asserted inside one caller's spec is a claim the
# other one can quietly stop honouring.
RSpec.describe Lain::Bench::Harness do
  let(:journal) { Lain::Channel.new }
  let(:recorder) { Lain::Memory::Recorder.new }
  let(:worker_env) { Lain::WorkerEnv.default }

  describe "the capabilities" do
    it "builds the chat's own capability floor rather than a second list" do
      floor = Lain::Toolset.new(Lain::CLI::Wiring::BaseTools.build(Lain::Memory::Recorder.new))

      expect(described_class::TOOLS.call(recorder:, journal:).digest).to eq(floor.digest)
    end

    it "builds an empty toolset on the named empty arm" do
      expect(described_class::NO_TOOLS.call(recorder:, journal:).to_a).to be_empty
    end

    # The two arms of one duck must fail equally loudly on a keyword neither
    # knows. NO_TOOLS used to swallow a `**`, one screen from the seam this
    # chunk removed one from.
    it "refuses an unknown keyword on both arms, not just the one that reads them" do
      expect { described_class::TOOLS.call(memory: recorder) }.to raise_error(ArgumentError)
      expect { described_class::NO_TOOLS.call(memory: recorder) }.to raise_error(ArgumentError)
    end
  end

  describe "the bash exec" do
    let(:inner) { Lain::Exec::Local.new }

    def exec_of(toolset) = toolset.fetch("bash").instance_variable_get(:@exec)

    it "is the one the factory is handed" do
      expect(exec_of(described_class::TOOLS.call(recorder:, journal:, exec: inner))).to be(inner)
    end

    it "names its stages by the resolver the factory is handed" do
      resolver = instance_double(Lain::Shell::Executable::Resolver)
      bash = described_class::TOOLS.call(recorder:, journal:, resolver:).fetch("bash")

      expect(bash.instance_variable_get(:@resolver)).to be(resolver)
    end

    it "is accepted and ignored by the empty arm, as its sibling's keywords are" do
      expect(described_class::NO_TOOLS.call(recorder:, journal:, exec: inner).to_a).to be_empty
    end
  end

  # The partition is what makes a tool added to the floor a RED example rather
  # than a silent promotion to "safe", which is the whole worth of naming a
  # write set at all.
  describe "the write partition" do
    let(:floor) { described_class::TOOLS.call(recorder:, journal:).names }

    it "covers every tool on the floor" do
      expect((described_class::WRITERS + described_class::READERS).sort).to eq(floor.sort)
    end

    it "classifies no tool twice" do
      expect(described_class::WRITERS & described_class::READERS).to be_empty
    end

    it "says the floor can write" do
      expect(described_class.writes?(described_class::TOOLS.call(recorder:, journal:))).to be(true)
    end

    it "says the empty arm cannot" do
      expect(described_class.writes?(described_class::NO_TOOLS.call(recorder:, journal:))).to be(false)
    end
  end

  describe "the reporting" do
    subject(:wiring) { described_class::INSTRUMENTATION.call(journal:, recorder:, worker_env:) }

    # THE BLOCKER THIS FILE EXISTS FOR. CLAUDE.md: tier-1 read_file/grep/glob/
    # list_files do not check paths, "because the boundary is one place a reader
    # can find". A bench arm holds all four, so it gets the SAME place every
    # other run with no chat behind it gets -- asserted against that object's
    # own answer rather than against a list retyped here, which is the only
    # assertion a later tightening of `detached` cannot drift away from.
    it "guards a bench run exactly as an unchatted production run is guarded" do
      production = Lain::CLI::ToolGuard.detached(journal:).call(worker_env)

      expect(wiring.tool_middleware.to_a.map(&:class)).to eq(production.to_a.map(&:class))
    end

    it "holds all six guards and the gate, not the write refusal alone" do
      expect(wiring.tool_middleware.to_a.map(&:class)).to eq(
        [Lain::Middleware::ConfineToScope, Lain::Middleware::RefuseSecretWrites, Lain::Middleware::RedactSecretReads,
         Lain::Middleware::WithholdSecretPaths, Lain::Middleware::GuardTestLayout,
         Lain::Middleware::WithholdAutomaticOutput, Lain::Middleware::RememberedDenials,
         Lain::Middleware::Sensitivity, Lain::Middleware::Gate]
      )
    end

    # A release ledger shared across arms is the same cross-arm contamination
    # the per-spawn recorder exists to prevent, so the board is per agent where
    # Consolidation memoizes one for its whole run.
    it "builds a fresh board per agent" do
      other = described_class::INSTRUMENTATION.call(journal:, recorder:, worker_env:)
      ledger = ->(wired) { wired.tool_middleware.to_a.grep(Lain::Middleware::RedactSecretReads).first.ledger }

      expect(ledger.call(wiring)).not_to be(ledger.call(other))
    end

    # "Innermost" is now a claim about a PAIR, so the order is asserted rather
    # than membership: the request is recorded carrying the address, and the
    # attachment is resolved one hop from the provider. Without the second
    # member, an arm whose toolset makes a picture dies at the encoder with
    # {Lain::Attachment::Reference::Unresolved} -- and a bench arm is exactly
    # where a screenshot tool gets driven first.
    it "records every outbound request, then resolves its attachments innermost" do
      expect(wiring.model_middleware.to_a.map(&:class))
        .to eq([Lain::Middleware::JournalRequests, Lain::Middleware::ResolveAttachments])
    end

    # Keyed to the arm's OWN leased directory, for the reason the board above is
    # fresh per agent: one store across arms is the cross-arm contamination the
    # per-spawn recorder exists to prevent.
    #
    # Driven over TWO made directories rather than the default env, because
    # `WorkerEnv.default`'s cwd IS `Dir.pwd`: keying on the process directory
    # would satisfy a one-env assertion while being the very sharing this
    # example is named against.
    it "resolves against the arm's own directory, not one shared across arms" do
      keyed = Array.new(2) do
        Dir.mktmpdir do |made|
          env = Lain::WorkerEnv.new(cwd: made, env: {})
          resolved = described_class::INSTRUMENTATION.call(journal:, recorder:, worker_env: env)
                                                     .model_middleware.to_a.last.attachments.root
          [resolved, Lain::Attachment::Store.for(root: made).root]
        end
      end

      expect(keyed.map(&:first)).to eq(keyed.map(&:last))
      expect(keyed.first.first).not_to eq(keyed.last.first)
    end

    it "pairs each turn with the memory root in force when it rendered" do
      expect(wiring.journal).to be_a(Lain::Memory::JournalMemoryRoot)
    end

    # Reachable, and only by a caller that supplies its own source -- see the
    # constant's own comment for why nothing here can honestly default it.
    it "leaves the per-turn context source injectable and Null by default" do
      expect(wiring.pipeline_source).to be(Lain::Agent::PipelineSource::Null)
    end
  end

  # The guard stack over a REAL tier-1 read, so the claim is about what the
  # boundary does to a credential rather than about which classes are in a list.
  describe "a tier-one read through the guards", :seam do
    let(:api_key) { "sk-ant-api03-QZ9vK2mR7xT4wL8nB3jH6yD1sA5fG0pE" }

    around { |example| Dir.mktmpdir { |made| @dir = made and example.run } }

    def read(path)
      env = Lain::WorkerEnv.new(cwd: @dir, env: {})
      stack = described_class::INSTRUMENTATION.call(journal:, recorder:, worker_env: env).tool_middleware
      effect = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "read_file", input: { "path" => path })
      session = Lain::Session.new(worker_env: env)
      stack.call({ effect:, tool: Lain::Tools::ReadFile.new, context: session }) do |inner|
        invocation = Lain::Tool::Invocation.new(tool_use_id: "tu_1", context: inner.fetch(:context))
        inner.merge(result: Lain::Tools::ReadFile.new.call(inner.fetch(:effect).input, invocation))
      end
    end

    # THE BLOCKER, AS BEHAVIOUR. Before this, the harness wired
    # RefuseSecretWrites alone, so a bench arm holding all four tier-1 read
    # tools could read a credential straight into the model's context -- and
    # from there, through JournalRequests, into the recorded session file on
    # disk that `bench variance` loads and an operator shares. The mask is what
    # means those bytes never exist above the middleware at all.
    it "masks a credential out of a tier-one read before it can reach a Request" do
      path = File.join(@dir, ".env").tap { |file| File.write(file, "API_KEY=#{api_key}\n") }

      content = read(path).fetch(:result).content

      expect(content).not_to include(api_key)
      expect(content).to include("API_KEY=", "<redacted:1>")
    end

    it "records the masking, so the run can say what it withheld" do
      path = File.join(@dir, ".env").tap { |file| File.write(file, "API_KEY=#{api_key}\n") }
      read(path)

      expect(journal.drain.grep(Lain::Telemetry::ReadRedacted)).not_to be_empty
    end

    # The other half: guarding must not turn an ordinary read into a refusal,
    # or a bench arm would score zero for a reason nobody could see.
    it "leaves an ordinary read untouched" do
      path = File.join(@dir, "notes.txt").tap { |file| File.write(file, "ordinary\n") }

      expect(read(path).fetch(:result).content).to include("ordinary")
    end
  end

  # An arm leased a worktree runs with no human attached, so its gate cannot
  # park: what the lease holds runs unasked and what it does not is refused.
  describe "an arm leased a worktree", :seam do
    around do |example|
      Dir.mktmpdir do |made|
        @tmp = File.realpath(made)
        @lease = File.join(@tmp, "wt").tap { FileUtils.mkdir_p(File.join(_1, "lib")) }
        example.run
      end
    end

    def leased = Lain::WorkerEnv.new(cwd: @lease, env: {}, checkout: @lease)

    def acted(tool, input, through: described_class::INSTRUMENTATION)
      stack = through.call(journal:, recorder:, worker_env: leased).tool_middleware
      effect = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: tool.name, input:)
      stack.call({ effect:, tool:, context: Lain::Session.new(worker_env: leased) }) do |inner|
        invocation = Lain::Tool::Invocation.new(tool_use_id: "tu_1", context: inner.fetch(:context))
        inner.merge(result: tool.call(inner.fetch(:effect).input, invocation))
      end.fetch(:result)
    end

    def written(path) = acted(Lain::Tools::WriteFile.new, { "path" => path, "content" => "x = 1\n" })

    it "refuses a write outside the worktree in the lease's words" do
      outside = File.join(@tmp, "outside.rb")

      expect(written(outside)).to have_attributes(is_error: true, content: start_with("write_file refused")
                                                                           .and(include(@lease, "leased")))
      expect(File.exist?(outside)).to be(false)
    end

    it "refuses a bash cd out of the worktree, naming the lease" do
      refused = acted(Lain::Tools::Bash.new, { "command" => "cd #{@tmp} && touch x" })

      expect(refused).to have_attributes(is_error: true, content: start_with("bash refused").and(include(@lease)))
      expect(File.exist?(File.join(@tmp, "x"))).to be(false)
    end

    it "refuses a read outside the worktree, saying no human is attached" do
      refused = acted(Lain::Tools::ReadFile.new, { "path" => "/etc/hosts" })

      expect(refused).to have_attributes(is_error: true, content: include(@lease, "no human"))
    end

    # `--confine reader`'s guard, over a box whose probe answers without running anything.
    def reader
      project = Lain::Project.new(root: @lease, cwd: @lease, kind: :project, detected_by: :flag)
      paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(@tmp, "state"), "HOME" => File.join(@tmp, "home") })
      box = ->(argv) { [argv.include?("--status") ? '{"abi":3}' : "", true] }
      probe = ->(journal:, fence:) { Lain::Confine::Probe.new(fence:, journal:, runner: box, ptrace_scope: -> { "0" }) }
      described_class::Confinement.new(project:, paths:, journal: Lain::Channel.new, probe:).instrumentation
    end

    it "refuses an opaque loop under both confinements, and nothing outside the worktree changes" do
      outside = File.join(@tmp, "outside").tap { FileUtils.mkdir_p(_1) }
      File.write(File.join(outside, "a.rb"), "kept\n")
      File.write(File.join(outside, "t"), "moved\n")
      command = "cd #{outside} && for f in $(find . -name '*.rb'); do mv t \"$f\"; done"

      [described_class::INSTRUMENTATION, reader].each do |through|
        refused = acted(Lain::Tools::Bash.new, { "command" => command }, through:)

        # The lease is left out: RedactSecretReads can mask a long temporary path in a bash result.
        expect(refused).to have_attributes(is_error: true, content: include("leased to", "paths cannot be read"))
      end
      expect(File.read(File.join(outside, "a.rb"))).to eq("kept\n")
    end

    it "runs a write inside the worktree and a bash ls with no approval asked" do
      inside = File.join(@lease, "lib", "x.rb")

      expect(written(inside)).to have_attributes(is_error: false)
      expect(acted(Lain::Tools::Bash.new, { "command" => "ls" })).to have_attributes(is_error: false)
      expect(File.read(inside)).to eq("x = 1\n")
    end
  end
end
