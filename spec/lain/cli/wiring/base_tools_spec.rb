# frozen_string_literal: true

# The capability floor's own seam, and it earns a file for one thing the
# assemblers above it cannot show. This module is where the session's
# {Lain::Shell::Verdict} reaches {Lain::Tools::Bash}, and the keyword carrying
# it has a permissive default -- which is exactly how an unwired guard ships
# green forever. So what is asserted here is the IDENTITY of what arrives,
# alongside the default staying indistinguishable from the tool's own.
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
    let(:backend) { Lain::CLI::Backend.new({ provider: "ollama", model: nil, max_tokens: 64 }) }
    let(:chronicle) { Lain::CLI::Chronicle::Null.new }
    let(:journal) { RecordingChannel.new }
    let(:parent) { -> { Lain::Timeline.new } }
    let(:assembler) do
      Lain::CLI::Wiring::ToolsetBuild.new(backend:, provider: backend.provider(spool: chronicle.spool),
                                          chronicle:, options: {}, supervisor: Lain::Supervisor.new(journal:),
                                          parent:, journal:, library: backend.library,
                                          epic: Lain::CLI::EpicMount::NoEpic, root: Dir.pwd)
    end

    def live_bash = assembler.build(recorder, ask_human: Lain::Tools::AskHuman.new(parent:)).fetch("bash")

    it "lands the bash tool's arm record in that session's journal" do
      live_bash.call({ command: "ls -la" }, Lain::Tool::Invocation.new(tool_use_id: "tu_live", channel:))

      expect(journal.events.grep(Lain::Telemetry::ShellArm).map { |arm| [arm.tool_use_id, arm.verdict] })
        .to eq([["tu_live", :allow]])
    end
  end

  describe ".build" do
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
      no_shell = ->(*, **) { raise "a shell was spawned" }
      floor = described_class.build(recorder, exec: Lain::Exec::Local.new(shell_out_factory: no_shell))

      result = bash_in(floor).call({ command: "ls -la" }, Lain::Tool::Invocation.new(tool_use_id: "tu_1", channel:))

      expect(result).to be_ok
      expect(result.content).to include("exit status: 0")
    end
  end
end
