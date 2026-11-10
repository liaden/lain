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

  describe "the command pspec and suite:files run" do
    def stub_sh_and_runtime_log(recorded, log_exists)
      allow(RbSys::ExtensionTask).to receive(:new)
      allow(TOPLEVEL_BINDING.receiver).to receive(:sh) { |*args|
        recorded << [args.first, args.last, lock_free_elsewhere?]
      }
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with("tmp/parallel_runtime_rspec.log").and_return(log_exists)
    end

    def commands_for(task, env: {}, log_exists: true)
      recorded = []
      stub_sh_and_runtime_log(recorded, log_exists)
      base = { "XDG_STATE_HOME" => @state_home, "LAIN_SUITE_LOCK_HELD" => nil, "LAIN_SPEC_WORKERS" => "3" }
      with_env(base.merge(env)) do
        Rake.with_application(Rake::Application.new) do
          load File.join(root, "Rakefile")
          Rake::Task[task].invoke
        end
      end
      recorded
    end

    let(:pspec_command) do
      "bundle exec parallel_rspec spec -n 3 --group-by runtime --allowed-missing 100 --test-options " \
        "'--format progress --format ParallelTests::RSpec::RuntimeLogger --out tmp/parallel_runtime_rspec.log'"
    end

    it "keeps pspec's command byte for byte" do
      expect(commands_for(:pspec).map { |_, command, _| command }).to eq([pspec_command])
    end

    it "drops the runtime grouping from pspec's command when there is no log" do
      command = commands_for(:pspec, log_exists: false).first[1]

      expect(command).to start_with("bundle exec parallel_rspec spec -n 3 --test-options ")
    end

    it "runs only the named files, unrecorded, with the slow files on, under the suite lock" do
      env, command, free = commands_for("suite:files", env: { "FILES" => "spec/a_spec.rb\nspec/b_spec.rb" }).first

      expect([env, command, free]).to eq(
        [{ "LAIN_SLOW" => "1" },
         "bundle exec parallel_rspec spec/a_spec.rb spec/b_spec.rb -n 3 --group-by runtime --allowed-missing 100 " \
         "--test-options '--format progress'",
         false]
      )
    end

    it "accepts space separated files" do
      command = commands_for("suite:files", env: { "FILES" => "spec/a_spec.rb spec/b_spec.rb" }).first[1]

      expect(command).to include(" spec/a_spec.rb spec/b_spec.rb -n 3 ")
    end

    it "refuses an empty file list rather than running the tree" do
      expect { commands_for("suite:files", env: { "FILES" => " \n" }) }.to raise_error(/FILES/)
    end
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
end
