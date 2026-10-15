# frozen_string_literal: true

require "async"
require "fileutils"
require "stringio"
require "tmpdir"

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module JudgedSpecSupport
  # A {Skill::RoleSpawn} stand-in: counts every spawn and answers each through
  # the injected block.
  class ScriptedRoleSpawn
    attr_reader :calls

    def initialize(calls = [], &answer)
      @answer = answer
      @calls = calls
    end

    def never_parking = self.class.new(@calls, &@answer)

    def call(role, context_mode, prompt)
      @calls << { role:, context_mode:, prompt: }
      @answer.call(prompt)
    end
  end

  # A context the way {Middleware::WithholdAutomaticOutput} hands one over: a
  # worker environment, a requester, and the bar on automatic approval.
  Context = Data.define(:worker_env, :requester, :automatic_approval_barred) do
    def automatic_approval_barred? = automatic_approval_barred
  end
end

RSpec.describe Lain::Approval::Judged do
  let(:home) { "/home/tester" }
  let(:root) { "/home/tester/project" }
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:queue) { Lain::Approval::Queue.new(journal:, timeout: 5) }
  let(:policy) do
    Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: root, root:), home:, root:)
  end
  let(:context) do
    JudgedSpecSupport::Context.new(worker_env: Lain::WorkerEnv.new(cwd: root, env: {}), requester: "main",
                                   automatic_approval_barred: false)
  end

  def spawn_answering(text = nil, &answer)
    JudgedSpecSupport::ScriptedRoleSpawn.new(&answer || ->(_) { Lain::Tool::Result.ok(text) })
  end

  def rung(spawn, asking: Lain::Approval::Escalation::Surfaces.new(queue), timeout: 30)
    described_class.new(judge: Lain::Approval::Judge.new(role_spawn: spawn, timeout:), policy:, asking:, journal:)
  end

  def call(name, input) = Lain::Effect::ToolCall.new(tool_use_id: "tu_#{name}", name:, input:)

  def bash(command = "make test", **rest) = call("bash", { "command" => command, **rest })

  def escalations = Lain::Journal.records(journal_io.string.lines, type: "escalation").to_a

  # Runs the rung in a reactor; a parked call is answered by the human the
  # block plays, and an unparked one finishes on its own.
  def ruled(subject, effect, within: context, &human)
    Sync do |task|
      ruling = task.async { subject.call(effect, within) }
      human&.call(task.with_timeout(1) { queue.dequeue })
      ruling.wait
    end
  end

  it "names itself auto" do
    expect(rung(spawn_answering("approve")).name).to eq("auto")
  end

  it "applies a clear approve with automatic authority and parks nothing" do
    ruling = ruled(rung(spawn_answering("approve")), bash)

    expect([ruling.verdict, ruling.authority, ruling.rung]).to eq([:allow, :automatic, "auto"])
    expect(queue.to_a).to be_empty
  end

  it "applies a judge deny, not final" do
    ruling = ruled(rung(spawn_answering("deny")), bash)

    expect([ruling.verdict, ruling.final?]).to eq([:deny, false])
  end

  it "parks an unsure call for the human, journaling that the judge deferred" do
    ruling = ruled(rung(spawn_answering("defer")), bash) { |pending| pending.approve(surface: "human_spec") }

    expect([ruling.verdict, ruling.authority]).to eq(%i[allow human])
    expect(escalations.sole).to include("rung" => "auto", "verdict" => "abstain", "reason" => "deferred",
                                        "tool_use_id" => "tu_bash")
  end

  it "parks after the bound when the judge hangs, journaling a fault" do
    hung = spawn_answering { sleep 5 }

    ruling = ruled(rung(hung, timeout: 0.05), bash) { |pending| pending.deny(surface: "human_spec") }

    expect([ruling.verdict, ruling.rung]).to eq([:deny, "surfaces"])
    expect(escalations.sole).to include("rung" => "auto", "verdict" => "abstain", "reason" => "fault",
                                        "faulted" => true)
  end

  it "parks a judge's error result as a fault" do
    spawn = spawn_answering { Lain::Tool::Result.error("approve") }

    ruled(rung(spawn), bash) { |pending| pending.deny(surface: "human_spec") }

    expect(escalations.sole).to include("reason" => "fault", "faulted" => true)
  end

  it "journals what made the judge fault" do
    spawn = spawn_answering { raise IOError, "provider down" }

    ruled(rung(spawn), bash) { |pending| pending.deny(surface: "human_spec") }

    expect(escalations.sole).to include("reason" => "fault", "error" => "IOError: provider down")
  end

  it "journals an error result as what made the judge fault" do
    spawn = spawn_answering { Lain::Tool::Result.error("cannot restrict to absent tools: grep") }

    ruled(rung(spawn), bash) { |pending| pending.deny(surface: "human_spec") }

    expect(escalations.sole["error"]).to include("cannot restrict to absent tools: grep")
  end

  it "does not let an automatic surface's allow stand over a judge fault" do
    ladder = Lain::Approval::Escalation.new([rung(spawn_answering { raise IOError, "down" })], journal:)

    ruling = Sync do |task|
      settled = task.async { ladder.rule(bash, context) }
      task.with_timeout(1) { queue.dequeue }.approve(surface: Lain::Approval::SecretSurface::SURFACE)
      settled.wait
    end

    expect(ruling.verdict).to eq(:deny)
  end

  it "hands the judge the requester the context names" do
    spawn = spawn_answering("approve")

    ruled(rung(spawn), bash, within: context.with(requester: "researcher-7"))

    expect(spawn.calls.sole[:prompt]).to include("researcher-7")
  end

  describe "tier 0" do
    it "never asks the judge about a read on a credential-named path, and parks it" do
      spawn = spawn_answering("approve")

      ruling = ruled(rung(spawn), call("read_file", { "path" => ".env" })) do |pending|
        pending.deny(surface: "human_spec")
      end

      expect(spawn.calls).to be_empty
      expect(ruling.rung).to eq("surfaces")
      expect(escalations.sole).to include("rung" => "auto", "verdict" => "abstain", "reason" => "unjudgeable",
                                          "tool" => "read_file")
    end

    it "never asks the judge about a write on a protected path or a command run in a named secret directory" do
      spawn = spawn_answering("approve")
      effects = [call("write_file", { "path" => ".lain/config.rb", "content" => "x" }), bash("ls", "cwd" => "secrets")]

      parked = effects.map do |effect|
        tool = nil
        ruled(rung(spawn), effect) do |pending|
          tool = pending.tool.to_s
          pending.deny(surface: "human_spec")
        end
        tool
      end

      expect(spawn.calls).to be_empty
      expect(parked).to eq(%w[write_file bash])
      expect(escalations.map { _1["reason"] }).to eq(%w[unjudgeable unjudgeable])
    end

    it "judges a call whose path is ordinary" do
      spawn = spawn_answering("approve")

      ruling = ruled(rung(spawn), call("write_file", { "path" => "lib/a.rb", "content" => "x" }))

      expect([ruling.verdict, spawn.calls.size]).to eq([:allow, 1])
    end

    describe "on disk" do
      around do |example|
        Dir.mktmpdir("lain-judged") do |dir|
          @base = File.realpath(dir)
          example.run
        end
      end

      let(:home) { File.join(@base, "home") }
      let(:root) { File.join(home, "project") }

      def asked_about(effect, within)
        spawn = spawn_answering("approve")
        ruled(rung(spawn), effect, within:) { |pending| pending.deny(surface: "human_spec") }
        spawn.calls.size
      end

      it "never asks the judge about an ordinary name that links to a credential" do
        FileUtils.mkdir_p(root)
        File.write(File.join(root, ".env"), "TOKEN=1\n")
        File.symlink(".env", File.join(root, "notes.txt"))

        expect(asked_about(call("read_file", { "path" => "notes.txt" }), context)).to eq(0)
      end

      it "counts a named directory below a checkout the cwd sits under" do
        checkout = File.join(@base, "spikes", "w1")
        FileUtils.mkdir_p([root, File.join(checkout, "sub"), File.join(checkout, "secrets")])
        File.write(File.join(checkout, "secrets", "prod.yml"), "hunter2\n")
        inside = context.with(worker_env: Lain::WorkerEnv.new(cwd: File.join(checkout, "sub"), env: {}, checkout:))

        expect(asked_about(call("read_file", { "path" => File.join(checkout, "secrets", "prod.yml") }),
                           inside)).to eq(0)
      end
    end
  end

  describe "unattended" do
    let(:unattended) { described_class::Unattended.new }

    it "refuses what the judge cannot settle, naming --non-interactive" do
      ruling = ruled(rung(spawn_answering("defer"), asking: unattended), bash)

      expect(ruling.verdict).to eq(:deny)
      expect(ruling.reason).to include("--non-interactive")
    end

    it "refuses a barred call finally, telling the model only a human could approve it" do
      ruling = ruled(rung(spawn_answering("approve"), asking: unattended), bash,
                     within: context.with(automatic_approval_barred: true))

      expect([ruling.verdict, ruling.final?]).to eq([:deny, true])
      expect(ruling.told).to include("only a human").and include("--non-interactive")
    end

    it "does not claim the judge was asked about a call it was not allowed to judge" do
      ruling = ruled(rung(spawn_answering("approve"), asking: unattended), call("read_file", { "path" => ".env" }))

      expect(ruling.reason).to include("--non-interactive").and include("not allowed to judge")
    end

    it "still applies a clear approve" do
      expect(ruled(rung(spawn_answering("approve"), asking: unattended), bash).verdict).to eq(:allow)
    end
  end

  it "sends a barred call to the human without asking the judge, parked as humans-only" do
    spawn = spawn_answering("approve")
    barred = context.with(automatic_approval_barred: true)
    humans_only = nil

    ruling = ruled(rung(spawn), bash, within: barred) do |pending|
      humans_only = pending.humans_only?
      pending.approve(surface: "human_spec")
    end

    expect([spawn.calls, humans_only, ruling.authority]).to eq([[], true, :human])
  end
end
