# frozen_string_literal: true

require "async"
require "fileutils"
require "open3"
require "rbconfig"
require "securerandom"
require "stringio"
require "tmpdir"

# The VM keeps provider keys in ~/.config/lain/provider.env. Everything is real between the model's call and the
# file: the board a chat builds, the tool stack the tool guard builds over it, the tools, the sandbox and the file.
RSpec.describe "A provider key saved in the VM", :seam do
  let(:key) { "sk-ant-fixture-#{SecureRandom.hex(8)}" }
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:chronicle) do
    instance_double(Lain::CLI::Chronicle, record_journal: journal,
                                          instrumentation: Lain::Agent::Instrumentation.new(journal:))
  end
  let(:toolset) { Lain::Toolset.new([Lain::Tools::ReadFile.new, Lain::Tools::Grep.new, Lain::Tools::Bash.new]) }

  around do |example|
    Dir.mktmpdir("vk") do |dir|
      @base = File.realpath(dir)
      @home = File.join(@base, "home")
      @repo = File.join(@base, "repo")
      FileUtils.mkdir_p([File.dirname(key_file), File.join(@repo, "tmp")])
      File.write(key_file, "ANTHROPIC_API_KEY=#{key}\n")
      File.chmod(0o600, key_file)
      example.run
    ensure
      @board&.mode_switch&.switch(Lain::Mode.new, surface: "spec")
    end
  end

  def key_file = File.join(@home, ".config", "lain", "provider.env")
  attr_reader :home, :repo

  def paths = Lain::Paths.new(env: { "HOME" => @home, "XDG_STATE_HOME" => File.join(@base, "state") })
  def project = Lain::Project.new(root: @repo, cwd: @repo, kind: :project, detected_by: :git)
  def session = @session ||= Lain::Session.new(worker_env: Lain::WorkerEnv.default.with(cwd: @repo))

  def board
    @board ||= Lain::CLI::Wiring::BoardBuild.for(
      human: Lain::CLI::Human.new(kind: :terminal), chronicle:, options: {}, judge: Lain::CLI::Switchboard::DEFERRING,
      model: "m", toolset:, project:, paths:, verdict: Lain::CLI::Wiring::BoardBuild.shell_verdict(project:, paths:)
    ).bind_session(session)
  end

  def stack = Lain::CLI::ToolGuard.stack(chronicle, board).to_a

  def dispatch(name, input) = dispatch_call(name, input, toolset:, layers: stack, context: session)

  # A call that must not park: a pending here would wait on nobody, so the bound turns a wrongly parked call into a
  # failure rather than a hang.
  def unparked(name, input) = Sync { |task| task.with_timeout(10) { dispatch(name, input) } }

  # The key's shape is masked wherever it shows, so its line's name is what tells a read from a refusal.
  def show_no_key = satisfy { |result| !result.content.include?(key) && !result.content.include?("ANTHROPIC_API_KEY=") }

  def parked_and_denied(name, input)
    Sync do |task|
      call = task.async { dispatch(name, input) }
      pending = task.with_timeout(10) { board.approvals.dequeue }
      pending.deny(surface: "tty")
      [pending, call.wait]
    end
  end

  it "reaches CLI::Backend in a lain started from bin/lain-vm shell" do
    vm = VmProviderKeySpec::FakeVm.new(@base)

    saved = vm.run("secret", "ANTHROPIC_API_KEY", stdin_data: "#{key}\n")
    started = vm.run("shell")

    expect(saved).to be_success
    expect(started.output).to include("Lain::Provider::Anthropic")
  end

  it "refuses read_file and grep on the key file" do
    read = unparked("read_file", { "path" => key_file })
    grepped = unparked("grep", { "pattern" => "sk-ant", "path" => key_file })

    expect(read.content).to include("refused", "protected path")
    expect(grepped.content).to include("returns nothing")
    expect([read, grepped]).to all(show_no_key)
  end

  it "refuses read_file and grep through a project link to the key file" do
    File.symlink(key_file, File.join(@repo, "notes.txt"))

    read = unparked("read_file", { "path" => "notes.txt" })
    grepped = unparked("grep", { "pattern" => "sk-ant", "path" => "notes.txt" })

    expect(read.content).to include("refused", "protected path")
    expect(grepped.content).to include("returns nothing")
    expect([read, grepped]).to all(show_no_key)
  end

  it "asks before read_file opens /proc/self/environ, and shows nothing when refused" do
    pending, result = with_env("ANTHROPIC_API_KEY" => key) do
      parked_and_denied("read_file", { "path" => "/proc/self/environ" })
    end

    expect(pending.tool).to eq("read_file")
    expect(result).to show_no_key
  end

  it "refuses an approved cat of the key file as protected" do
    board.mode_switch.switch(Lain::Mode.new(approval: :bypass), surface: "spec")

    result = unparked("bash", { "command" => "cat #{key_file}" })

    expect(result.content).to include("refused", "protected path")
    expect(result).to show_no_key
  end

  # The path check reads a command's words as written, so a glob, a `..` or a second name for the inode passes it
  # and runs. Only the output redactor stands between these and the key, and only while it knows the line's shape.
  describe "an approved cat through another spelling of the key file" do
    {
      "a glob" => ->(spec) { "cat #{File.dirname(spec.key_file)}/provider.*" },
      "a .. inside the key's directory" => ->(spec) { "cat #{spec.home}/.config/lain/../lain/provider.env" },
      "a .. out of the project" => ->(spec) { "cat #{spec.repo}/../home/.config/lain/provider.env" },
      "a hard link in the project" => lambda { |spec|
        File.link(spec.key_file, File.join(spec.repo, "hl.txt"))
        "cat hl.txt"
      }
    }.each do |spelling, command|
      it "runs it and withholds the output, refusing nothing, through #{spelling}" do
        board.mode_switch.switch(Lain::Mode.new(approval: :bypass), surface: "spec")

        result = unparked("bash", { "command" => command.call(self) })

        expect(result.content).to include("withheld")
        expect(result.content).not_to include("protected path")
        expect(result).to show_no_key
      end
    end
  end

  describe "a confined call, through a real sandbox" do
    let(:fence) { Lain::Confine::Bwrap.fence_binary }
    let(:sandbox_journal) { RecordingChannel.new }

    before do
      skip("bwrap or strace is not installed") unless %w[/usr/bin/bwrap /usr/bin/strace].all? { File.executable?(_1) }
      skip("lain-fence is not built at #{fence} -- run `bundle exec rake compile`") unless File.executable?(fence)
      skip("tmux is not installed") unless system("tmux", "-V", %i[out err] => File::NULL)
    end

    def policy
      @policy ||= Lain::Sensitivity::Policy.new(
        sensitivity: Lain::Sensitivity.new(home: @home, cwd: @repo, root: @repo), home: @home, root: @repo
      )
    end

    def sandboxed
      masks = Lain::Confine::MaskList.new(root: @repo, policy: -> { policy })
      Lain::Confine::Sandbox.new(root: @repo, home: @home, masks:, fence:, journal: sandbox_journal,
                                 probe: Lain::Confine::Probe.new(fence:, journal: sandbox_journal),
                                 workspace: true, tmpdir: File.join(@repo, "tmp"))
                            .wrap(Lain::Exec::Local.new, requirer: "Spec")
    end

    def run_confined(command)
      ruling = Lain::Approval::Escalation::Ruling.allow(rung: "rules", because: "spec", rule: "composed_term")
      request = Lain::Confine::Request.new(ruling:, executables: [], cwd: @repo, root: @repo, tool_use_id: "toolu_1")
      sandboxed.call(command:, cwd: @repo, env: ENV.to_h, timeout: 10, confinement: request)
    end

    # The server lives where a cockpit's does, in the host's /tmp, holding the key as a launched tmux holds it.
    def with_tmux_holding_key
      Dir.mktmpdir("vk", "/tmp") do |dir|
        socket = File.join(dir, "s")
        system({ "ANTHROPIC_API_KEY" => key }, "tmux", "-S", socket, "new-session", "-d", "-s", "k", exception: true)
        yield socket
      ensure
        system("tmux", "-S", socket, "kill-server", %i[out err] => File::NULL) if socket
      end
    end

    it "prints no key from its environment, the key file or the tmux server" do
      with_tmux_holding_key do |socket|
        held, = Open3.capture2("tmux", "-S", socket, "show-environment", "-g", "ANTHROPIC_API_KEY")
        capture = with_env("ANTHROPIC_API_KEY" => key) do
          run_confined("env; cat #{key_file}; tmux -S #{socket} show-environment -g; echo finished")
        end

        expect(held).to include(key)
        expect(capture.stdout).to include("PATH=", "finished")
        expect(capture.stdout + capture.stderr).not_to include(key)
        expect(capture.stdout + capture.stderr).not_to include("ANTHROPIC_API_KEY=")
      end
    end
  end
end

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module VmProviderKeySpec
  ROOT = File.expand_path("../../..", __dir__)

  # Runs bin/lain-vm against a fake limactl whose guest is a directory on this host.
  class FakeVm
    Run = Data.define(:output, :status) do
      def success? = status.success?
    end

    LIMACTL = <<~SH
      #!/bin/sh
      if [ "$1" = list ]; then echo Running; exit 0; fi
      [ "$1" = shell ] || exit 0
      shift 4
      cd "$FAKE_GUEST_HOME" || exit 66
      HOME=$FAKE_GUEST_HOME
      export HOME
      if [ "$1" = bash ] && [ "$2" = -lc ]; then exec bash -c "$3"; fi
      exec "$@"
    SH

    # The guest's login shell is a lain that builds its provider, as `lain` would at launch.
    LOGIN = <<~SH
      #!/bin/sh
      exec "$SPEC_RUBY" -I "$SPEC_LIB" -r "$SPEC_BOOTSNAP" -r lain \
        -e 'print Lain::CLI::Backend.new({ provider: "anthropic" }, root: Dir.pwd).provider.class'
    SH

    # @param base [String] a directory this run owns
    def initialize(base)
      @fakes = File.join(base, "fakes")
      @guest = File.join(base, "guest")
      FileUtils.mkdir_p([@fakes, File.join(@guest, "lain")])
      executable("limactl", LIMACTL)
      executable("login", LOGIN)
    end

    # @return [Run]
    def run(*, stdin_data: "")
      output, status = Open3.capture2e(env, File.join(ROOT, "bin", "lain-vm"), *, stdin_data:, chdir: @guest)
      Run.new(output:, status:)
    end

    private

    def executable(name, text)
      path = File.join(@fakes, name)
      File.write(path, text)
      File.chmod(0o755, path)
    end

    def env
      { "PATH" => "#{@fakes}:#{ENV.fetch("PATH")}", "LAIN_VM_NAME" => "spec", "FAKE_GUEST_HOME" => @guest,
        "SHELL" => File.join(@fakes, "login"), "ANTHROPIC_API_KEY" => nil, "OLLAMA_API_KEY" => nil,
        "SPEC_RUBY" => RbConfig.ruby, "SPEC_LIB" => File.join(ROOT, "lib"),
        "SPEC_BOOTSNAP" => File.join(ROOT, "spec", "bootsnap_setup") }
    end
  end
end
