# frozen_string_literal: true

require "rake"
require "rb_sys/extensiontask"
require "tmpdir"

RSpec.describe "Rakefile", :seam do
  around do |example|
    Dir.mktmpdir("lain-rakefile") do |home|
      @state_home = File.realpath(home)
      example.run
    end
  end

  let(:root) { File.expand_path("..", __dir__) }
  let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => @state_home, "HOME" => @state_home }) }

  # A forked child, because a flock is per open file description and this process would share its own.
  def lock_free_elsewhere?
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      writer.write(Lain::Isolation::SuiteLock.for(paths:).try { nil } ? "free" : "held")
    ensure
      exit!(0)
    end
    writer.close
    reader.read.tap { Process.wait(pid) } == "free"
  end

  it "runs the parallel suite while another process cannot take the suite lock" do
    recorded = []
    app = Rake::Application.new
    # Building the extension task shells out to cargo, which this spec has no business needing.
    allow(RbSys::ExtensionTask).to receive(:new)
    allow(TOPLEVEL_BINDING.receiver).to receive(:sh) { |*args| recorded << [args.last, lock_free_elsewhere?] }

    with_env("XDG_STATE_HOME" => @state_home, "LAIN_SUITE_LOCK_HELD" => nil) do
      Rake.with_application(app) do
        load File.join(root, "Rakefile")
        Rake::Task[:pspec].invoke
      end
    end

    expect(recorded.map { |command, free| [command.include?("parallel_rspec"), free] }).to eq([[true, false]])
  end

  describe "the compile task" do
    def compile_on(host_os)
      commands = []
      app = Rake::Application.new
      allow(RbSys::ExtensionTask).to receive(:new)
      allow(TOPLEVEL_BINDING.receiver).to receive(:sh) { |*args| commands << args.last }
      stub_const("RbConfig::CONFIG", RbConfig::CONFIG.merge("host_os" => host_os))
      out = StringIO.new
      previous = $stdout
      Rake.with_application(app) do
        load File.join(root, "Rakefile")
        $stdout = out
        Rake::Task[:compile].invoke
      ensure
        $stdout = previous
      end
      [commands, out.string]
    end

    it "builds the fence on linux" do
      commands, = compile_on("linux-gnu")

      expect(commands).to eq(["cargo build -p lain-fence --release"])
    end

    it "skips the fence on darwin and says the sandbox runs degraded" do
      commands, said = compile_on("darwin24")

      expect([commands, said]).to match([[], /lain-fence is Linux-only.*degraded/])
    end
  end

  describe "the daemon:build task" do
    def build_with_git(sha)
      built = nil
      allow(RbSys::ExtensionTask).to receive(:new)
      allow(TOPLEVEL_BINDING.receiver).to receive(:`).with(/git rev-parse/).and_return(sha)
      allow(TOPLEVEL_BINDING.receiver).to receive(:sh) { |*args| built = args }
      Rake.with_application(Rake::Application.new) do
        load File.join(root, "Rakefile")
        Rake::Task["daemon:build"].invoke
      end
      built
    end

    it "builds the release lain-daemon, stamping the git sha it reports as its build id" do
      env, command = build_with_git("0123456789ab\n")

      expect([command, env]).to eq(["cargo build -p lain-daemon --release", { "LAIN_GIT_SHA" => "0123456789ab" }])
    end

    it "stamps nothing outside a git checkout, so the binary reports unknown" do
      env, command = build_with_git("")

      expect([command, env]).to eq(["cargo build -p lain-daemon --release", {}])
    end
  end
end
