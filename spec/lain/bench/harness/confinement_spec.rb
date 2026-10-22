# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Bench::Harness::Confinement do
  around do |example|
    Dir.mktmpdir("bench-confinement") do |dir|
      @base = File.realpath(dir)
      FileUtils.mkdir_p([File.join(@base, "repo"), File.join(@base, "home"), File.join(@base, "state")])
      File.write(File.join(@base, "repo", "README.md"), "one\ntwo\n")
      example.run
    end
  end

  let(:run_journal) { RecordingChannel.new }
  let(:agent_journal) { RecordingChannel.new }
  let(:recorder) { Lain::Memory::Recorder.new }
  let(:root) { File.join(@base, "repo") }
  let(:project) { Lain::Project.new(root:, cwd: root, kind: :project, detected_by: :flag) }
  let(:paths) do
    Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(@base, "state"), "HOME" => File.join(@base, "home") })
  end
  let(:box) { ->(argv) { [argv.include?("--status") ? '{"abi":3}' : "", true] } }
  let(:probes) { [] }
  let(:probe) do
    lambda { |journal:, fence:|
      probes << journal
      Lain::Confine::Probe.new(fence:, journal:, runner: box, ptrace_scope: -> { "0" })
    }
  end
  let(:confinement) { described_class.new(project:, paths:, journal: run_journal, probe:) }

  def exec_of(toolset) = toolset.fetch("bash").instance_variable_get(:@exec)

  def tools(journal: agent_journal) = confinement.tools(Lain::Bench::Harness::TOOLS).call(recorder:, journal:)

  describe "#tools" do
    it "builds each agent's bash over the sandbox, journalling to that agent's own journal" do
      exec = exec_of(tools)

      expect(exec).to be_a(Lain::Exec::Sandboxed)
      expect(exec.instance_variable_get(:@journal)).to be(agent_journal)
      expect(exec.instance_variable_get(:@inner)).to be_a(Lain::Exec::Local)
    end

    it "builds a sandbox per agent, but asks the box once for the whole run" do
      execs = Array.new(2) { exec_of(tools) }

      expect(execs.first).not_to be(execs.last)
      expect(probes).to eq([run_journal])
    end

    it "shares one mask list across the run's agents and primes none" do
      masks = Array.new(2) { exec_of(tools).instance_variable_get(:@profiles).instance_variable_get(:@masks) }

      expect(masks.first).to be(masks.last)
      expect(masks.first.instance_variable_get(:@priming)).to be_nil
    end

    context "when the box lacks the layers" do
      let(:box) { ->(_argv) { ["", false] } }

      it "builds the plain exec, and says once, in the run's journal, that the sandbox is unavailable" do
        execs = Array.new(2) { exec_of(tools) }
        noted = run_journal.events.grep(Lain::Telemetry::CapabilityDegraded)

        expect(execs).to all(be_a(Lain::Exec::Local))
        expect(noted.select { _1.capability == :sandbox }.size).to eq(1)
        expect(agent_journal.events.grep(Lain::Telemetry::CapabilityDegraded)).to be_empty
      end
    end
  end

  describe "#apply" do
    it "builds on the options it is given, replacing only the tools and the guard" do
      applied = confinement.apply(provider: :given)

      expect(applied).to include(provider: :given)
      expect(applied.keys).to include(:tools, :instrumentation)
    end

    it "refuses a guard of the caller's own rather than silently replacing it" do
      expect { confinement.apply(instrumentation: :mine) }.to raise_error(ArgumentError, /instrumentation/)
    end
  end

  describe "a sandbox it built" do
    it "can be primed, as a chat's can" do
      masks = confinement.instance_variable_get(:@masks)
      allow(masks).to receive(:prime).and_call_original
      sandbox = confinement.send(:sandbox, agent_journal)
      sandbox.wrap(Lain::Exec::Local.new, requirer: "Spec")

      expect(sandbox.prime).to be(sandbox)
      expect(masks).to have_received(:prime).once
    end
  end

  describe "#state" do
    it "names the arm when the box offers every layer" do
      expect(confinement.state).to eq("reader")
    end

    context "when the box lacks the layers" do
      let(:box) { ->(_argv) { ["", false] } }

      it "says the arm is degraded and what the box lacks" do
        expect(confinement.state).to eq("reader (degraded: the box lacks bwrap and landlock)")
      end
    end
  end

  # The gate of a bench arm approves everything, so before the read-only rung was put ahead of it
  # every call ran traced and none was ever confined.
  describe "a bash call through the arm's guard stack", :seam do
    let(:probe) { Lain::Bench::Harness::PROBE }
    let(:worker_env) { Lain::WorkerEnv.default.with(cwd: root) }
    let(:session) { Lain::Session.new(worker_env:) }
    let(:agent) { confinement.instrumentation.call(journal: agent_journal, recorder:, worker_env:) }

    def run_bash(command)
      toolset = tools
      dispatch_call("bash", { "command" => command }, toolset:, layers: agent.tool_middleware.to_a,
                                                      context: session, id: "tu_bench")
    end

    def sandbox_record = agent_journal.events.grep(Lain::Telemetry::Sandbox).find { _1.tool_use_id == "tu_bench" }

    it "runs a read-only command under the reader profile" do
      result = Sync { |task| task.with_timeout(20) { run_bash("cat README.md | wc -l") } }

      expect(result.content).to include("2")
      expect(sandbox_record.profile).to eq(:reader)
    end

    it "earns the reader profile for a read-only command in a leased arm too" do
      leased = worker_env.with(checkout: root)
      toolset = tools
      layers = confinement.instrumentation.call(journal: agent_journal, recorder:, worker_env: leased)
                          .tool_middleware.to_a
      Sync do |task|
        task.with_timeout(20) do
          dispatch_call("bash", { "command" => "cat README.md" }, toolset:, layers:,
                                                                  context: Lain::Session.new(worker_env: leased),
                                                                  id: "tu_bench")
        end
      end

      expect(sandbox_record.profile).to eq(:reader)
    end

    it "does not give the reader profile to a cat that shadows the system one" do
      planted = File.join(@base, "planted")
      FileUtils.mkdir_p(planted)
      File.write(File.join(planted, "cat"), "#!/bin/sh\nexec /usr/bin/cat \"$@\"\n")
      File.chmod(0o755, File.join(planted, "cat"))
      shadowed = worker_env.with(checkout: root, env: { "PATH" => "#{planted}:/usr/bin:/bin" })
      layers = confinement.instrumentation.call(journal: agent_journal, recorder:, worker_env: shadowed)
                          .tool_middleware.to_a
      Sync do |task|
        task.with_timeout(20) do
          dispatch_call("bash", { "command" => "cat README.md" }, toolset: tools, layers:,
                                                                  context: Lain::Session.new(worker_env: shadowed),
                                                                  id: "tu_bench")
        end
      end

      expect(sandbox_record.profile).not_to eq(:reader)
    end

    it "grants a user program from the home directory its exec under the reader profile" do
      bin = File.join(@base, "home", "bin")
      FileUtils.mkdir_p(bin)
      File.write(File.join(bin, "cat"), "#!/bin/sh\nexec /usr/bin/cat \"$@\"\n")
      File.chmod(0o755, File.join(bin, "cat"))
      homed = worker_env.with(checkout: root, env: { "PATH" => bin })
      layers = confinement.instrumentation.call(journal: agent_journal, recorder:, worker_env: homed)
                          .tool_middleware.to_a
      result = Sync do |task|
        task.with_timeout(20) do
          dispatch_call("bash", { "command" => "cat README.md" }, toolset: tools, layers:,
                                                                  context: Lain::Session.new(worker_env: homed),
                                                                  id: "tu_bench")
        end
      end

      expect(sandbox_record.profile).to eq(:reader)
      expect(result.content).to include("one")
    end

    it "still approves a command that may write, and traces it rather than confining it" do
      result = Sync { |task| task.with_timeout(20) { run_bash("touch made.txt") } }

      expect(result.error?).to be(false)
      expect(sandbox_record.profile).not_to eq(:reader)
    end

    context "with a real channel under the arm" do
      let(:agent_journal) { Lain::Channel.new }

      it "prices an arm whose guard stack escalated the call" do
        Sync { |task| task.with_timeout(20) { run_bash("touch made.txt") } }

        priced = nil
        expect { priced = Lain::Arm::Instrument.new.price(agent_journal) }.not_to raise_error
        expect(priced).to be_a(Lain::Ledger)
      end

      it "keeps the escalation record among the drained records" do
        Sync { |task| task.with_timeout(20) { run_bash("touch made.txt") } }

        expect(Lain::Arm::Instrument.records(agent_journal).map { _1["type"] }).to include("escalation")
      end
    end
  end
end
