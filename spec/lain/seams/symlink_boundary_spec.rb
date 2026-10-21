# frozen_string_literal: true

require "async"
require "fileutils"
require "stringio"
require "tmpdir"

# The path boundary judges a link where it lands. Everything is real between the
# model's call and the file: the board a chat builds for its project, the tool
# stack the tool guard builds over it, the tools and the links on disk.
RSpec.describe "A symlink is judged where it lands", :seam do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:chronicle) do
    instance_double(Lain::CLI::Chronicle, record_journal: journal,
                                          instrumentation: Lain::Agent::Instrumentation.new(journal:))
  end
  let(:toolset) do
    Lain::Toolset.new([Lain::Tools::ReadFile.new, Lain::Tools::WriteFile.new, Lain::Tools::Grep.new,
                       Lain::Tools::ListFiles.new])
  end

  around do |example|
    Dir.mktmpdir("lain-symlink-boundary") do |dir|
      @base = File.realpath(dir)
      @home = File.join(@base, "home")
      @repo = File.join(@base, "repo")
      FileUtils.mkdir_p([File.join(@home, ".ssh"), @repo])
      File.write(File.join(@home, ".ssh", "id_qa"), "PRIVATE KEY\n")
      example.run
    ensure
      @board&.mode_switch&.switch(Lain::Mode.new, surface: "spec")
    end
  end

  def key = File.join(@home, ".ssh", "id_qa")
  def link(name, target, under: @repo) = File.symlink(target, File.join(under, name))

  def paths = Lain::Paths.new(env: { "HOME" => @home, "XDG_STATE_HOME" => File.join(@base, "state") })
  def project = Lain::Project.new(root: @repo, cwd: @repo, kind: :project, detected_by: :git)
  def session = @session ||= Lain::Session.new(worker_env: Lain::WorkerEnv.default.with(cwd: @cwd || @repo))

  def board
    @board ||= Lain::CLI::Wiring::BoardBuild.for(
      chronicle:, options: {}, judge: Lain::CLI::Switchboard::DEFERRING,
      model: "m", toolset:, project:, paths:,
      verdict: Lain::CLI::Wiring::BoardBuild.shell_verdict(project:)
    ).bind_session(session)
  end

  def stack = Lain::CLI::ToolGuard.stack(chronicle, board).to_a

  def dispatch(name, input) = dispatch_call(name, input, toolset:, layers: stack, context: session)

  # A call that must not park: a pending here would wait on nobody, so the
  # bound turns a wrongly parked call into a failure rather than a hang.
  def unparked(name, input) = Sync { |task| task.with_timeout(10) { dispatch(name, input) } }

  # The human at the surface refuses unless told otherwise.
  def parked(name, input, approve: false)
    Sync do |task|
      call = task.async { dispatch(name, input) }
      pending = task.with_timeout(10) { board.approvals.dequeue }
      approve ? pending.approve(surface: "tty") : pending.deny(surface: "tty")
      [pending, call.wait]
    end
  end

  def git(*args) = SeedRepo.git(@repo, *args).stdout

  it "refuses a read through a link to a denied file, and parks nothing" do
    link("notes.txt", key)

    result = unparked("read_file", { "path" => "notes.txt" })

    expect(result.content).to include("refused")
    expect(result.content).not_to include("PRIVATE KEY")
    expect(journal_records(journal_io,
                           "read_refused")).to contain_exactly(include("path" => "notes.txt", "reason" => "protected"))
    expect(journal_records(journal_io, "approval_pending")).to be_empty
  end

  it "asks a human before reading through a link to a gated file" do
    File.write(File.join(@repo, ".env.local"), "PLAIN=value\n")
    link("readme2.txt", ".env.local")

    pending, result = parked("read_file", { "path" => "readme2.txt" })

    expect(pending).to have_attributes(tool: "read_file", outstanding: Lain::Approval::Parked::Queue::Outstanding::NONE)
    expect(result.content).not_to include("PLAIN=value")
  end

  it "asks a human before writing through a link to a gated file" do
    FileUtils.mkdir_p(File.join(@repo, "config"))
    link("cfg.txt", "config/master.key")

    pending, = parked("write_file", { "path" => "cfg.txt", "content" => "x" })

    expect(pending.tool).to eq("write_file")
    expect(File.exist?(File.join(@repo, "config", "master.key"))).to be(false)
  end

  it "resolves a relative link against the worker's cwd, not the project's" do
    @cwd = File.join(@base, "worker").tap { FileUtils.mkdir_p(_1) }
    link("notes.txt", key, under: @cwd)

    result = unparked("read_file", { "path" => "notes.txt" })

    expect(result.content).to include("refused")
    expect(result.content).not_to include("PRIVATE KEY")
  end

  it "resolves a relative link against the plan checkout under /mode plan" do
    FileUtils.cp_r("#{SeedRepo.at({ "notes.txt" => "ordinary in the checkout\n" })}/.", @repo)
    board.mode_switch.switch(Lain::Mode.new(scope: :plan), surface: "spec")
    spike = session.scope.root
    File.delete(File.join(spike, "notes.txt"))
    link("notes.txt", key, under: spike)

    result = unparked("read_file", { "path" => "notes.txt" })

    expect(result.content).to include("refused")
    expect(result.content).not_to include("PRIVATE KEY")
  end

  # The record carries who asked and for which call, never a reason; the
  # malformed verdict itself is pinned in the policy's own spec.
  it "parks a looping link rather than raising" do
    link("loop", "loop")

    pending, = parked("read_file", { "path" => "loop" })

    expect(pending.tool).to eq("read_file")
    expect(journal_records(journal_io,
                           "approval_pending")).to contain_exactly(include("tool" => "read_file",
                                                                           "tool_use_id" => "tu_1"))
  end

  # Under /mode bypass a gated call is approved with nobody asked, so a dangling
  # link onto a denied file must be refused outright rather than gated.
  it "refuses a write through a dangling link onto a denied file under /mode bypass" do
    board.mode_switch.switch(Lain::Mode.new(approval: :bypass), surface: "spec")
    link("ak", File.join(@home, ".ssh", "id_new"))

    result = unparked("write_file", { "path" => "ak", "content" => "ATTACKER\n" })

    expect(result.content).to include("refused", "no approval can lift this")
    expect(File.exist?(File.join(@home, ".ssh", "id_new"))).to be(false)
  end

  it "refuses a write through a dangling link whose .. climbs out of a linked directory under /mode bypass" do
    board.mode_switch.switch(Lain::Mode.new(approval: :bypass), surface: "spec")
    FileUtils.mkdir_p(File.join(@home, ".ssh", "config.d"))
    link("sd", File.join(@home, ".ssh", "config.d"))
    link("dk", "sd/../id_kern")

    result = unparked("write_file", { "path" => "dk", "content" => "ATTACKER\n" })

    expect(result.content).to include("refused", "no approval can lift this")
    expect(File.exist?(File.join(@home, ".ssh", "id_kern"))).to be(false)
    expect(File.exist?(File.join(@repo, "id_kern"))).to be(false)
  end

  # The linked directory is ~/.ssh itself, so listing it asks first, exactly as
  # listing ~/.ssh by name does; an approval still does not show the key.
  it "withholds a denied file listed or grepped through a linked directory" do
    link("keys", File.join(@home, ".ssh"))

    _, listed = parked("list_files", { "path" => "keys" }, approve: true)
    _, grepped = parked("grep", { "pattern" => "KEY", "path" => "keys" }, approve: true)

    expect(listed.content).to eq("1 path withheld (protected)")
    expect(grepped.content).to eq("1 match withheld (protected)")
  end

  it "masks a link under a directory named ~ at its target's label" do
    git("init", "-q")
    FileUtils.mkdir_p(File.join(@repo, "~"))
    link("shadow", "/etc/shadow", under: File.join(@repo, "~"))
    link("notes", key, under: File.join(@repo, "~"))
    policy = Lain::Sensitivity::Policy.new(
      sensitivity: Lain::Sensitivity.new(home: @home, cwd: @repo, root: @repo), home: @home, root: @repo
    )
    list = Lain::Confine::MaskList.new(root: @repo, policy: -> { policy })

    expect(git("ls-files", "-co")).to include("~/shadow", "~/notes")
    expect(list.masks.map { [_1.path, _1.reason] })
      .to contain_exactly(["/etc/shadow", policy.judge("/etc/shadow", cwd: @repo).reason], [key, :protected])
  end

  # A directory named `~` already holds that name in the repo above, so the bare link gets a repo of its own.
  it "masks a link named exactly ~ at its target's label" do
    @repo = File.join(@base, "tilde").tap { FileUtils.mkdir_p(_1) }
    git("init", "-q")
    link("~", key)
    policy = Lain::Sensitivity::Policy.new(
      sensitivity: Lain::Sensitivity.new(home: @home, cwd: @repo, root: @repo), home: @home, root: @repo
    )
    list = Lain::Confine::MaskList.new(root: @repo, policy: -> { policy })

    expect(git("ls-files", "-co")).to eq("~\n")
    expect(list.masks.map { [_1.path, _1.reason] }).to eq([[key, :protected]])
  end

  it "reads through a link to an ordinary file with no prompt" do
    File.write(File.join(@repo, "b.txt"), "plain words\n")
    link("a.txt", "b.txt")

    expect(unparked("read_file", { "path" => "a.txt" }).content).to include("plain words")
  end

  # git lists a nested repo as 1 leaf, so the names beneath it are what a real
  # sandbox must still hide.
  describe "a directory the listing shows as 1 leaf, through a real sandbox" do
    let(:fence) { Lain::Confine::Bwrap.fence_binary }

    before do
      skip("bwrap or strace is not installed") unless %w[/usr/bin/bwrap /usr/bin/strace].all? { File.executable?(_1) }
      skip("lain-fence is not built at #{fence} -- run `bundle exec rake compile`") unless File.executable?(fence)
      skip("bwrap cannot make a user namespace on this host") unless
        system("/usr/bin/bwrap", "--ro-bind", "/", "/", "--", "true", %i[out err] => File::NULL)
    end

    def secret(path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "SECRETBYTES\n")
    end

    def policy
      @policy ||= Lain::Sensitivity::Policy.new(
        sensitivity: Lain::Sensitivity.new(home: @home, cwd: @repo, root: @repo), home: @home, root: @repo
      )
    end

    def sandboxed
      journal = RecordingChannel.new
      masks = Lain::Confine::MaskList.new(root: @repo, policy: -> { policy })
      Lain::Confine::Sandbox.new(root: @repo, home: @home, masks:, probe: Lain::Confine::Probe.new(fence:, journal:),
                                 fence:, journal:).wrap(Lain::Exec::Local.new, requirer: "Spec")
    end

    def run_confined(command)
      ruling = Lain::Approval::Escalation::Ruling.allow(rung: "rules", because: "spec", rule: "composed_term")
      request = Lain::Confine::Request.new(ruling:, executables: [], cwd: @repo, root: @repo, tool_use_id: "toolu_1")
      sandboxed.call(command:, cwd: @repo, env: {}, timeout: 10, confinement: request)
    end

    it "hides a secret inside a nested repo, which judge still denies" do
      secret(File.join(@repo, ".aws", "credentials"))
      SeedRepo.git(File.join(@repo, ".aws"), "init", "-q")
      git("init", "-q")

      capture = run_confined("cat .aws/credentials")

      expect(git("ls-files", "-co")).to eq(".aws/\n")
      expect(capture.stdout + capture.stderr).not_to include("SECRETBYTES")
      expect(policy.judge(File.join(@repo, ".aws", "credentials"), cwd: @repo)).to be_denied
    end

    it "hides what judge gates beneath a link named .ssh into the project" do
      secret(File.join(@repo, "keys", "config"))
      link(".ssh", "keys")
      git("init", "-q")

      capture = run_confined("cat .ssh/config")

      expect(capture.stdout + capture.stderr).to include("Permission denied")
      expect(capture.stdout + capture.stderr).not_to include("SECRETBYTES")
      expect(policy.judge(File.join(@repo, ".ssh", "config"), cwd: @repo)).to be_gated
    end

    # A file name is bytes: a listing hands them over binary, a caller as UTF-8, and the root may be either.
    {
      "a project root that is not ASCII" => %w[café keys],
      "a landing whose name is not ASCII" => %w[repo clés],
      "a root and a landing whose names are not ASCII" => %w[café clés],
      "a landing whose name is not valid UTF-8" => ["repo", "\xFFk".b]
    }.each do |shape, (root_name, landing)|
      secrets = %w[config .env].freeze

      it "judges, marks and hides alike, in any encoding, under #{shape}" do
        @repo = File.join(@base, root_name)
        secrets.each { secret(File.join(@repo.b, landing.b, _1.b)) }
        link(".ssh", landing)
        git("init", "-q")
        spelled = File.join(@repo, ".ssh", "config")

        capture = run_confined("cat .ssh/config")

        expect(policy.judge(spelled, cwd: @repo)).to be_gated
        expect([spelled.b, ".ssh/config".b, ".ssh/config"].map { policy.judge(_1, cwd: @repo.b) })
          .to all(eq(policy.judge(spelled, cwd: @repo)))
        expect(policy.marks(File.join(@repo, ".ssh").b)).to eq(policy.marks(File.join(@repo, ".ssh")))
        expect(policy.marks(File.join(@repo, ".ssh"))).not_to eq(policy.marks(File.join(@repo.b, landing.b)))
        masks = Lain::Confine::MaskList.new(root: @repo, policy: -> { policy }).masks.map { _1.path.b }
        expect(secrets.map { File.join(@repo.b, landing.b, _1.b) })
          .to all(satisfy { |file| masks.any? { file == _1 || file.start_with?("#{_1}/") } })
        expect(capture.stdout + capture.stderr).not_to include("SECRETBYTES")
      end
    end
  end
end
