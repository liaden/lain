# frozen_string_literal: true

require "async"
require "fileutils"
require "mixlib/shellout"
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
      chronicle:, options: {}, model: "m", toolset:, project:, paths:,
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

  def records(type) = Lain::Journal.records(journal_io.string.lines, type:).to_a

  def git(*args)
    Mixlib::ShellOut.new("git", "-C", @repo, *args, environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB)
                    .run_command.tap(&:error!).stdout
  end

  it "refuses a read through a link to a denied file, and parks nothing" do
    link("notes.txt", key)

    result = unparked("read_file", { "path" => "notes.txt" })

    expect(result.content).to include("refused")
    expect(result.content).not_to include("PRIVATE KEY")
    expect(records("read_refused")).to contain_exactly(include("path" => "notes.txt", "reason" => "protected"))
    expect(records("approval_pending")).to be_empty
  end

  it "asks a human before reading through a link to a gated file" do
    File.write(File.join(@repo, ".env.local"), "PLAIN=value\n")
    link("readme2.txt", ".env.local")

    pending, result = parked("read_file", { "path" => "readme2.txt" })

    expect(pending).to have_attributes(tool: "read_file", outstanding: Lain::Approval::Queue::Outstanding::NONE)
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
    expect(records("approval_pending")).to contain_exactly(include("tool" => "read_file", "tool_use_id" => "tu_1"))
  end

  # Under /mode auto a gated call is approved with nobody asked, so a dangling
  # link onto a denied file must be refused outright rather than gated.
  it "refuses a write through a dangling link onto a denied file under /mode auto" do
    board.mode_switch.switch(Lain::Mode.new(approval: :auto), surface: "spec")
    link("ak", File.join(@home, ".ssh", "id_new"))

    result = unparked("write_file", { "path" => "ak", "content" => "ATTACKER\n" })

    expect(result.content).to include("refused", "no approval can lift this")
    expect(File.exist?(File.join(@home, ".ssh", "id_new"))).to be(false)
  end

  it "refuses a write through a dangling link whose .. climbs out of a linked directory under /mode auto" do
    board.mode_switch.switch(Lain::Mode.new(approval: :auto), surface: "spec")
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

  it "reads through a link to an ordinary file with no prompt" do
    File.write(File.join(@repo, "b.txt"), "plain words\n")
    link("a.txt", "b.txt")

    expect(unparked("read_file", { "path" => "a.txt" }).content).to include("plain words")
  end
end
