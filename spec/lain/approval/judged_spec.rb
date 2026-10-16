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

  def rung(spawn, asking: Lain::Approval::Escalation::Surfaces.new(queue), timeout: 30, under: policy, **rest)
    described_class.new(judge: Lain::Approval::Judge.new(role_spawn: spawn, timeout:), policy: under, asking:,
                        journal:, **rest)
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

  # Denies whatever parks, and lets a call the judge settled finish unparked.
  def settled(subject, effect, within: context)
    Sync do |task|
      human = task.async { queue.dequeue.deny(surface: "human_spec") }
      subject.call(effect, within).tap { human.stop }
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

  describe "what a human is shown of the judge" do
    let(:told) { [] }

    it "tells the display which call the judge approved" do
      ruled(rung(spawn_answering("approve"), display: told), bash("git log --oneline -5"))

      expect(told).to eq([Lain::Telemetry::JudgeApproved.new(call: 'bash({"command" => "git log --oneline -5"})')])
    end

    it "says nothing about a call the judge denied" do
      ruled(rung(spawn_answering("deny"), display: told), bash)

      expect(told).to be_empty
    end

    it "marks the parked call as one the judge deferred" do
      ruled(rung(spawn_answering("defer")), bash) do |pending|
        expect(pending.judge_deferred?).to be(true)
        pending.approve(surface: "human_spec")
      end
    end

    it "keeps the requester and directory of the call it marks" do
      ruled(rung(spawn_answering("defer")), bash) do |pending|
        expect([pending.requester, pending.cwd]).to eq(["main", root])
        pending.approve(surface: "human_spec")
      end
    end

    it "does not mark a call the judge faulted on" do
      ruled(rung(spawn_answering { Lain::Tool::Result.error("approve") }), bash) do |pending|
        expect(pending.judge_deferred?).to be(false)
        pending.deny(surface: "human_spec")
      end
    end

    it "does not mark a call it never judged" do
      ruled(rung(spawn_answering("approve")), bash("cat ~/.ssh/id_rsa")) do |pending|
        expect(pending.judge_deferred?).to be(false)
        pending.deny(surface: "human_spec")
      end
    end

    it "does not mark a call parked with no judge at all" do
      parked = Sync do |task|
        task.async { queue.adjudicate(bash, context) }
        task.with_timeout(1) { queue.dequeue }.tap { _1.deny(surface: "human_spec") }
      end

      expect(parked.judge_deferred?).to be(false)
    end
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

  describe "what the judge is told about where the call runs" do
    def prompt_for(effect, within: context)
      spawn = spawn_answering("approve")
      ruled(rung(spawn), effect, within:)
      spawn.calls.sole[:prompt].lines.map(&:strip)
    end

    it "names the project root, the leased working directory and the requester" do
      lease = Lain::WorkerEnv.new(cwd: "/state/leases/r1", env: {}, checkout: "/state/leases/r1")
      leased = context.with(worker_env: lease, requester: "researcher")

      expect(prompt_for(bash("ls"), within: leased))
        .to include("project root: #{root.inspect}", "working directory: \"/state/leases/r1\"",
                    "requester: \"researcher\"")
    end

    it "shows a path under the home but outside the project as outside" do
      expect(prompt_for(bash("ls ~/.cargo/registry")))
        .to include("outside the project root: #{"#{home}/.cargo/registry".inspect}")
    end

    it "shows the walk root of a glob with an absolute pattern as outside" do
      expect(prompt_for(call("glob", { "pattern" => "/tmp/x/**/*.rs" })))
        .to include("outside the project root: \"/tmp/x\"")
    end

    it "shows a path in the requester's own checkout as not outside" do
      lease = Lain::WorkerEnv.new(cwd: "/state/leases/r1", env: {}, checkout: "/state/leases/r1")
      leased = context.with(worker_env: lease, requester: "researcher")

      expect(prompt_for(bash("ls src"), within: leased)).to include("outside the project root: none")
    end

    it "shows a path in a related directory as not outside" do
      related = Lain::Sensitivity::Rules.new(related: ["#{home}/notes"])
      under = Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: root, root:, rules: related),
                                            home:, root:)
      spawn = spawn_answering("approve")

      settled(rung(spawn, under:), bash("ls ~/notes"))

      expect(spawn.calls.sole[:prompt]).to include("outside the project root: none")
    end

    it "shows a path inside the project as not outside" do
      expect(prompt_for(bash("ls src"))).to include("outside the project root: none")
    end
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

    describe "a bash command" do
      def parked_unjudged(command, under: policy, **rest)
        spawn = spawn_answering("approve")
        ruling = ruled(rung(spawn, under:), bash(command, **rest)) { |pending| pending.deny(surface: "human_spec") }
        [ruling.rung, spawn.calls.size, escalations.last&.slice("rung", "reason", "tool")]
      end

      def judged?(command, under: policy)
        spawn = spawn_answering("approve")
        settled(rung(spawn, under:), bash(command))
        spawn.calls.size == 1
      end

      it "never asks the judge about a read of a credential, and parks it" do
        expect(parked_unjudged("cat .env"))
          .to eq(["surfaces", 0, { "rung" => "auto", "reason" => "unjudgeable", "tool" => "bash" }])
      end

      it "never asks the judge about a command whose paths it cannot name" do
        expect(parked_unjudged('cat "$X"').take(2)).to eq(["surfaces", 0])
      end

      it "never asks the judge about a cd into a credential directory" do
        expect(parked_unjudged("cd secrets && ls").take(2)).to eq(["surfaces", 0])
      end

      it "never asks the judge about a credential the command's cwd field puts it beside" do
        expect(parked_unjudged("cat shadow", "cwd" => "/etc").take(2)).to eq(["surfaces", 0])
      end

      it "reads ~ under the policy's home, and parks it where the policy has none" do
        expect([judged?("ls ~/project/lib"),
                judged?("ls ~/project/lib", under: Lain::Sensitivity::Policy::Null.instance)]).to eq([true, false])
      end

      it "judges a command keyed by symbol, and parks one with no readable command rather than faulting" do
        asked = [{ command: "ls src" }, nil, "ls src", { "command" => %w[ls src] }].map do |input|
          spawn = spawn_answering("approve")
          ruling = settled(rung(spawn), call("bash", input))
          [ruling.verdict, spawn.calls.size]
        end

        expect(asked).to eq([[:allow, 1], [:deny, 0], [:deny, 0], [:deny, 0]])
      end

      it "parks a command whose cwd field cannot be resolved, rather than faulting" do
        rulings = ["~nosuchuser-lain-spec", "a\0b"].map { parked_unjudged("ls", "cwd" => _1).take(2) }

        expect(rulings).to eq([["surfaces", 0], ["surfaces", 0]])
      end

      it "still asks the judge about an ordinary command" do
        spawn = spawn_answering("approve")

        ruling = ruled(rung(spawn), bash("git log --oneline -5"))

        expect([ruling.verdict, spawn.calls.size]).to eq([:allow, 1])
      end
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
        settled(rung(spawn), effect, within:)
        spawn.calls.size
      end

      it "never asks the judge about an ordinary name that links to a credential" do
        FileUtils.mkdir_p(root)
        File.write(File.join(root, ".env"), "TOKEN=1\n")
        File.symlink(".env", File.join(root, "notes.txt"))

        expect(asked_about(call("read_file", { "path" => "notes.txt" }), context)).to eq(0)
      end

      describe "a bash command's patterns" do
        before do
          FileUtils.mkdir_p([File.join(root, "secrets"), File.join(root, "src"), File.join(home, ".ssh")])
          File.write(File.join(root, ".env"), "TOKEN=1\n")
          File.write(File.join(root, "secrets", "a"), "hunter2\n")
          File.write(File.join(root, "src", "a.rb"), "1\n")
          File.write(File.join(home, ".ssh", "id_rsa"), "key\n")
        end

        def asked_about_command(command) = asked_about(bash(command), context)

        it "never asks the judge about a glob that matches a credential" do
          commands = ["cat .en?", "cat .e*", "cat .[e]nv", "ls secret?", "cat ~/.ss?/id_rsa"]

          expect(commands.to_h { [_1, asked_about_command(_1)] }).to eq(commands.to_h { [_1, 0] })
        end

        it "asks the judge about a glob whose matches are all ordinary" do
          expect(asked_about_command("cat src/*.rb *env")).to eq(1)
        end

        it "never asks the judge about a glob with more matches than it may weigh" do
          many = File.join(root, "many")
          FileUtils.mkdir_p(many)
          (described_class::Reach::MATCHES + 1).times { File.write(File.join(many, "f#{_1}.txt"), "") }

          expect(asked_about_command("cat many/*.txt")).to eq(0)
        end

        it "never asks the judge about a recursive read of a tree whose only credential is .env" do
          FileUtils.mkdir_p(File.join(root, "only"))
          File.write(File.join(root, "only", ".env"), "TOKEN=1\n")
          File.write(File.join(root, "only", "a.rb"), "1\n")

          expect([asked_about_command("grep -r needle only"), asked_about_command("grep -r needle src")]).to eq([0, 1])
        end

        it "never asks the judge about a recursive read through a link to a directory holding .env" do
          elsewhere = File.join(@base, "elsewhere")
          holder = File.join(root, "holder")
          FileUtils.mkdir_p([elsewhere, holder])
          File.write(File.join(elsewhere, ".env"), "TOKEN=1\n")
          File.symlink(elsewhere, File.join(holder, "d"))
          File.symlink(holder, File.join(holder, "loop"))
          commands = ["grep -R needle holder", "rg -L needle holder", "cp -rL holder copy", "diff -r holder src",
                      "tar chf x.tar holder", "zip -r x.zip holder"]

          expect(commands.to_h { [_1, asked_about_command(_1)] }).to eq(commands.to_h { [_1, 0] })
        end

        it "judges a tree-free git command by the entries its <rev>:<path> matches, dot directories included" do
          FileUtils.mkdir_p(File.join(root, ".hidden"))
          File.symlink(File.join(root, ".env"), File.join(root, ".hidden", "notes"))

          expect([asked_about_command("git ls-tree HEAD:src"), asked_about_command("git ls-tree HEAD:notes")])
            .to eq([1, 0])
        end

        it "walks a link back up the tree once, and judges the tree" do
          File.symlink(File.join(root, "src"), File.join(root, "src", "again"))

          expect(asked_about_command("grep -R needle src")).to eq(1)
        end

        it "never asks the judge about a recursive read of a tree it cannot read whole" do
          locked = File.join(root, "locked", "inner")
          FileUtils.mkdir_p(locked)
          File.chmod(0o000, locked)

          expect(asked_about_command("grep -r needle locked")).to eq(0)
        ensure
          File.chmod(0o755, locked)
        end

        it "matches a glob under a directory whose own name holds glob characters" do
          odd = %w[w[1] w{a,b}].map { File.join(root, _1) }
          FileUtils.mkdir_p(odd)
          odd.each { File.write(File.join(_1, ".env"), "TOKEN=1\n") }

          within = odd.map { context.with(worker_env: Lain::WorkerEnv.new(cwd: _1, env: {})) }

          expect(within.map { asked_about(bash("cat .e*"), _1) }).to eq([0, 0])
        end

        it "asks the judge about a git log that prints no file contents, in a tree too big to walk" do
          wide = File.join(root, "wide")
          FileUtils.mkdir_p(wide)
          (described_class::Reach::ENTRIES + 1).times { File.write(File.join(wide, "f#{_1}"), "") }

          expect([asked_about_command("git log --oneline -5"), asked_about_command("git log -p")]).to eq([1, 0])
        end

        it "never asks the judge about a recursive read of a tree larger than it may walk" do
          wide = File.join(root, "wide")
          FileUtils.mkdir_p(wide)
          (described_class::Reach::ENTRIES + 1).times { File.write(File.join(wide, "f#{_1}"), "") }

          expect(asked_about_command("grep -r x wide")).to eq(0)
        end
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
