# frozen_string_literal: true

require "rake"
require "rb_sys/extensiontask"
require "tmpdir"

RSpec.describe "Rakefile pspec task", :seam do
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
end
