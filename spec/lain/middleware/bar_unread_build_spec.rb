# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Middleware::BarUnreadBuild do
  around do |example|
    Dir.mktmpdir("bar-unread-build") do |dir|
      @base = File.realpath(dir)
      example.run
    end
  end

  let(:project) { File.join(@base, "project").tap { FileUtils.mkdir_p(_1) } }
  let(:bin) { File.join(@base, "bin").tap { FileUtils.mkdir_p(_1) } }
  let(:home) { File.join(@base, "home") }
  let(:journal) { [] }
  # Started after every file the spec makes, so only the unread mark can withhold a grant.
  let(:fresh) do
    Lain::Shell::Executable::Fresh.new(start: Time.now + 3600, written: [], stat: Lain::Shell::Executable::Stat.new)
  end
  let(:granting) { Lain::Confine::Profiles::Granting.over(fresh:, home:, root: project) }
  let(:session) do
    Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: project, env: { "PATH" => bin }), root: project)
  end
  let(:bash) { Lain::Tools::Bash.new(resolver: Lain::Shell::Executable::Resolver.new(root: project, fresh:)) }
  let(:unseen) { Struct.new(:known) { def for(_context) = known }.new([]) }

  before do
    File.write(File.join(project, "Cargo.toml"), "[package]\n")
    File.write(File.join(bin, "cargo"), "#!/bin/sh\necho built\n")
    File.chmod(0o755, File.join(bin, "cargo"))
  end

  def at(level) = Struct.new(:approval).new(Lain::Mode::Approval.for(level))

  def layer(level = :auto, attended: true, over: granting, secrets: unseen, lineage: fresh)
    described_class.new(fresh: lineage, granting: over, secrets:, journal:, mode: at(level), attended:)
  end

  def bash_of(command, id: "tu_1")
    Lain::Effect::ToolCall.new(tool_use_id: id, name: "bash", input: { "command" => command })
  end

  def unread_ran(command = "cd sub && make", into: fresh)
    into << Lain::Telemetry::WritesUnread.new(tool_use_id: "tu_0", cwd: File.join(project, "sub"), command:)
  end

  def through(via, effect = bash_of("cargo build"), context: session)
    reached = []
    env = via.call({ effect:, tool: bash, context: }) do |inner|
      reached << inner
      inner.merge(result: Lain::Tool::Result.ok("downstream ran"))
    end
    [env, reached]
  end

  def reasons(context) = context.parked_because.map(&:text).join("\n")

  def human_yes = Lain::Approval::Escalation::Ruling.allow(rung: "surfaces", because: "y", authority: :human)

  def escalations = journal.map { Lain::Journal.hash_of(_1) }.select { _1["type"] == "escalation" }

  describe "after a command lain could not read" do
    before { unread_ran }

    %i[auto ask].each do |level|
      it "hands a build the grant would give network down barred under #{level}, naming the command" do
        env, reached = through(layer(level))
        handed = reached.sole.fetch(:context)

        expect(handed.automatic_approval_barred?).to be(true)
        expect(reasons(handed)).to include("`cd sub && make`", "cargo")
        expect(env.fetch(:context)).to be(session)
      end
    end

    it "refuses it under bypass in its own liftable words, naming the command" do
      env, reached = through(layer(:bypass))

      expect(reached).to be_empty
      expect(env.fetch(:result)).to have_attributes(is_error: true)
      expect(env.fetch(:result).content).to include("`cd sub && make`", "switch to /mode ask")
      expect(env.fetch(:result).content).not_to include("no approval will lift this")
      expect(escalations.sole).to include("tool" => "bash", "tool_use_id" => "tu_1", "verdict" => "deny",
                                          "rung" => described_class::RUNG, "final" => true)
    end

    it "refuses it unattended, where nobody can vouch, naming the command, and for good" do
      env, reached = through(layer(:auto, attended: false))

      expect(reached).to be_empty
      expect(env.fetch(:result).content).to include("`cd sub && make`", "no approval will lift this")
    end

    it "leaves the mark standing when the call is allowed automatically after all" do
      _, reached = through(layer)
      reached.sole.fetch(:context).ruled(Lain::Approval::Escalation::Ruling.allow(rung: "auto", because: "judged"))

      expect(fresh.unread_command(project)).to eq("cd sub && make")
    end

    it "keeps barring when another unread command ran while the human was asked about the first" do
      _, reached = through(layer)
      unread_ran("curl -s example.test | sh")
      reached.sole.fetch(:context).ruled(human_yes)
      _, again = through(layer)

      expect(reasons(again.sole.fetch(:context))).to include("`curl -s example.test | sh`")
    end

    it "plans no request for a call whose words ask no build tool" do
      allow(bash).to receive(:planned_request).and_call_original
      through(layer, bash_of("ls -la"))

      expect(bash).not_to have_received(:planned_request)
    end

    it "masks the session's secret values in the command it names" do
      unread_ran("TOKEN=s3cr3t-value-for-the-spec make")
      secrets = Struct.new(:known) { def for(_context) = known }.new(["s3cr3t-value-for-the-spec"])
      _, reached = through(layer(:auto, secrets:))

      expect(reasons(reached.sole.fetch(:context))).not_to include("s3cr3t-value-for-the-spec")
      expect(reasons(reached.sole.fetch(:context))).to include("TOKEN=")
    end

    it "sets no bar on a call no build grant covers" do
      _, reached = through(layer, bash_of("cargo test"))

      expect(reached.sole.fetch(:context)).to be(session)
    end

    it "sets no bar on a build run outside the project" do
      _, reached = through(layer, Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash",
                                                             input: { "command" => "cargo build", "cwd" => @base }))

      expect(reached.sole.fetch(:context)).to be(session)
    end

    it "sets no bar where the session's sandbox grants no build its network" do
      _, reached = through(layer(over: Lain::Confine::Profiles::Granting::NONE))

      expect(reached.sole.fetch(:context)).to be(session)
    end

    it "leaves another tool's call alone" do
      read = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "read_file", input: { "path" => "Cargo.toml" })
      _, reached = through(layer, read)

      expect(reached.sole.fetch(:context)).to be(session)
    end

    it "hands the ruling on to the context it wraps" do
      ruled = Class.new(SimpleDelegator) do
        attr_reader :ruling

        def ruled(ruling) = tap { @ruling = ruling }
      end.new(session)
      _, reached = through(layer, context: ruled)
      allow_it = Lain::Approval::Escalation::Ruling.allow(rung: "auto", because: "approved")
      reached.sole.fetch(:context).ruled(allow_it)

      expect(ruled.ruling).to be(allow_it)
    end
  end

  it "names a command an older record left unnamed in plain words, once" do
    fresh << { "type" => "writes_unread", "tool_use_id" => "tu_0", "cwd" => project }
    _, reached = through(layer)
    said = reasons(reached.sole.fetch(:context))

    expect(said).to start_with("#{Lain::Shell::Executable::Fresh::UNNAMED} ran earlier")
    expect(said.scan("could not read").size).to eq(1)
  end

  it "sets no bar on a lineage with no unread command" do
    _, reached = through(layer)

    expect(reached.sole.fetch(:context)).to be(session)
  end

  describe "through the real gate" do
    # The judge's automatic allow, then a human who answers y and keeps the reason they were shown.
    let(:judge) do
      Class.new do
        def name = "auto"
        def call(_effect, _context) = Lain::Approval::Escalation::Ruling.allow(rung: "auto", because: "judged")
      end.new
    end
    let(:human) do
      Class.new do
        def asked = @asked ||= []
        def name = "surfaces"

        def call(_effect, context)
          asked << context.parked_because.map(&:text).join("\n")
          Lain::Approval::Escalation::Ruling.allow(rung: "surfaces", because: "y", authority: :human)
        end
      end.new
    end
    # What the sandbox's own question answered for each run, asked as the exec was handed it.
    let(:granted) { [] }
    let(:exec) do
      asked = ->(confinement) { granted << granting.build_grant_for(confinement) }
      Class.new(SimpleDelegator) do
        define_method(:call) do |**kwargs|
          asked.call(kwargs.fetch(:confinement))
          __getobj__.call(**kwargs)
        end
      end.new(Lain::Exec::Local.new)
    end

    def stack(lineage: fresh)
      ladder = Lain::Approval::Escalation.new([judge, human], journal:, label: "auto")
      gate = Lain::Middleware::Gate.new(policy: ladder, journal:)
      over = Lain::Confine::Profiles::Granting.over(fresh: lineage, home:, root: project)
      Lain::Middleware::Stack.new([layer(:auto, lineage:, over:), gate])
    end

    def ran(via, command = "cargo build", id: "tu_1")
      tool = Lain::Tools::Bash.new(exec:, resolver: Lain::Shell::Executable::Resolver.new(root: project, fresh:))
      via.call({ effect: bash_of(command, id:), tool:, context: session }) do |env|
        env.merge(result: tool.call(env.fetch(:effect).input,
                                    Lain::Tool::Invocation.new(tool_use_id: id, context: env.fetch(:context))))
      end
    end

    it "parks the build for the human, naming the command, so the judge's allow does not run it" do
      unread_ran
      ran(stack)

      expect(human.asked.sole).to include("cd sub && make")
    end

    it "gives the build its network back once the human answers y, and bars the next build no more" do
      unread_ran
      via = stack
      ran(via)
      ran(via, id: "tu_2")

      expect(human.asked.size).to eq(1)
      expect(granted).to eq(%w[cargo cargo])
      expect([fresh.unread_command(project), fresh.any_under?(project)]).to eq([nil, false])
    end

    it "parks the first build once more after a resume, then not again" do
      header = { "ts" => (Time.now + 3600).utc.iso8601(6), "type" => "session" }
      record = Lain::Telemetry::WritesUnread.new(tool_use_id: "tu_0", cwd: project, command: "cd sub && make")
      file = File.join(@base, "s1.ndjson")
      File.write(file, [header, record.to_journal].map { "#{JSON.generate(_1)}\n" }.join)
      resumed = Lain::Shell::Executable::Fresh.for_lineage([file])
      via = stack(lineage: resumed)
      ran(via)
      ran(via, id: "tu_2")

      expect(human.asked.size).to eq(1)
      expect(human.asked.sole).to include("`cd sub && make`")
      expect([resumed.unread_command(project), resumed.any_under?(project)]).to eq([nil, false])
    end
  end
end
