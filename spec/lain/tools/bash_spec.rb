# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Tools::Bash do
  subject(:tool) { described_class.new }

  let(:channel) { RecordingChannel.new }

  def invocation(tool_use_id: "tu_1")
    Lain::Tool::Invocation.new(tool_use_id:, channel:)
  end

  it "has a model-facing name and description" do
    expect(tool.name).to eq("bash")
    expect(tool.description).to be_a(String)
    expect(tool.description).not_to be_empty
  end

  # Tier 3: a String command goes through `sh -c`, and the model fully
  # controls it. Effect::Handler::Gate gates on exactly this flag.
  it "is gated by approval, being tier 3" do
    expect(tool.requires_approval?).to be(true)
  end

  it "runs a command and captures its stdout" do
    result = tool.call({ command: "echo hello" }, invocation)
    expect(result).to be_ok
    expect(result.content).to include("exit status: 0")
    expect(result.content).to include("hello")
  end

  it "captures stderr alongside stdout" do
    result = tool.call({ command: "echo oops 1>&2" }, invocation)
    expect(result.content).to include("oops")
  end

  it "reports a nonzero exit status in the content, not as is_error" do
    # A nonzero exit is often exactly what the model asked to observe (grep
    # with no matches); the tool ran correctly, so this is not a tool failure.
    result = tool.call({ command: "exit 3" }, invocation)
    expect(result).to be_ok
    expect(result.content).to include("exit status: 3")
  end

  it "runs in the given cwd" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "marker.txt"), "here")
      result = tool.call({ command: "ls", cwd: dir }, invocation)
      expect(result.content).to include("marker.txt")
    end
  end

  describe "timeout" do
    # The real process-group kill, end to end: TERM actually hits a live
    # `sleep 5` group and mixlib reaps it. The injected factory only shortens
    # the TERM->KILL grace -- mixlib-shellout hardcodes `sleep 3` inside
    # reap_errant_child with no option to configure it, and 3 idle seconds
    # would dominate the whole suite's runtime.
    it "kills a command that runs past its timeout" do
      short_grace = lambda do |*args, **opts|
        Mixlib::ShellOut.new(*args, **opts).tap do |shell_out|
          def shell_out.sleep(_grace) = super(0.1)
        end
      end

      result = described_class.new(shell_out_factory: short_grace)
                              .call({ command: "sleep 5", timeout: 1 }, invocation)
      expect(result).to be_error
      expect(result.content).to match(/timed out/)
    end

    # The rescue->Result mapping in isolation: no subprocess, no clock.
    it "maps CommandTimeout to an error Result naming the timeout" do
      timed_out = Class.new do
        def run_command = raise Mixlib::ShellOut::CommandTimeout, "Command timed out after 7s"
      end
      tool = described_class.new(shell_out_factory: ->(*, **) { timed_out.new })

      result = tool.call({ command: "sleep 5", timeout: 7 }, invocation)
      expect(result).to be_error
      expect(result.content).to match(/timed out after 7s/)
    end
  end

  describe "attributed live streaming" do
    it "emits stdout bytes as Telemetry::ToolOutput carrying the invocation's tool_use_id and stream" do
      tool.call({ command: "echo from_stdout" }, invocation(tool_use_id: "tu_abc"))

      stdout_events = channel.events.select { |e| e.stream == :stdout }
      expect(stdout_events).not_to be_empty
      expect(stdout_events).to all(be_a(Lain::Telemetry::ToolOutput))
      expect(stdout_events).to all(have_attributes(tool_use_id: "tu_abc"))
      expect(stdout_events.map(&:bytes).join).to include("from_stdout")
    end

    it "emits stderr bytes on the :stderr stream, distinct from stdout" do
      tool.call({ command: "echo to_err 1>&2" }, invocation(tool_use_id: "tu_xyz"))

      stderr_events = channel.events.select { |e| e.stream == :stderr }
      expect(stderr_events).not_to be_empty
      expect(stderr_events).to all(have_attributes(tool_use_id: "tu_xyz"))
      expect(stderr_events.map(&:bytes).join).to include("to_err")
    end
  end

  it "does nothing observable when no channel is injected (Null Object default)" do
    bare = Lain::Tool::Invocation.new(tool_use_id: "tu_1")
    expect { tool.call({ command: "echo quiet" }, bare) }.not_to raise_error
  end

  # The WorkerEnv the Session lends: the default is byte-identical to today
  # (process ENV + Dir.pwd), an injected one isolates env and cwd.
  describe "worker env (session-lent env and cwd)" do
    def invocation_with(session)
      Lain::Tool::Invocation.new(tool_use_id: "tu_1", context: session, channel:)
    end

    it "inherits the process env under the default WorkerEnv" do
      ENV["LAIN_WE_PROBE"] = "from_process"
      result = tool.call({ command: "echo $LAIN_WE_PROBE" }, invocation_with(Lain::Session.new))
      expect(result.content).to include("from_process")
    ensure
      ENV.delete("LAIN_WE_PROBE")
    end

    it "exposes an injected env var to the command" do
      env = ENV.to_h.merge("DATABASE_URL" => "postgres://sandbox/db")
      session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: Dir.pwd, env:))
      result = tool.call({ command: "echo $DATABASE_URL" }, invocation_with(session))
      expect(result.content).to include("postgres://sandbox/db")
    end

    it "runs in the WorkerEnv cwd when the input names none" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "marker.txt"), "here")
        session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: dir, env: ENV.to_h))
        result = tool.call({ command: "ls" }, invocation_with(session))
        expect(result.content).to include("marker.txt")
      end
    end

    it "resolves a relative input cwd against the WorkerEnv cwd" do
      Dir.mktmpdir do |dir|
        Dir.mkdir(File.join(dir, "sub"))
        File.write(File.join(dir, "sub", "inner.txt"), "x")
        session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: dir, env: ENV.to_h))
        result = tool.call({ command: "ls", cwd: "sub" }, invocation_with(session))
        expect(result.content).to include("inner.txt")
      end
    end

    # WorkerEnv is an OVERRIDE, not confinement (B3's foundation): mixlib applies
    # `environment:` per-key onto the child's already-inherited ENV and never
    # clears it, so a host var the injected env omits still reaches the command.
    # This pins that true behavior -- probe tmp/b1-probes/env_semantics.rb.
    it "leaks a host env var the injected WorkerEnv omits (additive override, not confinement)" do
      ENV["LAIN_HOST_ONLY"] = "leaked"
      curated = { "DATABASE_URL" => "postgres://sandbox" } # deliberately omits LAIN_HOST_ONLY
      session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: Dir.pwd, env: curated))

      result = tool.call({ command: "echo host=[$LAIN_HOST_ONLY]" }, invocation_with(session))

      expect(result.content).to include("host=[leaked]")
    ensure
      ENV.delete("LAIN_HOST_ONLY")
    end

    # The sanctioned scrub: an explicit nil VALUE (not an absent key) removes a
    # var, because mixlib's child does `ENV[k] = nil`, and Ruby's `ENV[k] = nil`
    # deletes. WorkerEnv preserves the nil marker through make_shareable.
    it "scrubs a host env var mapped to nil in the injected WorkerEnv" do
      ENV["LAIN_SCRUB_ME"] = "leaked"
      scrubbed = ENV.to_h.merge("LAIN_SCRUB_ME" => nil)
      session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: Dir.pwd, env: scrubbed))

      result = tool.call({ command: "echo host=[$LAIN_SCRUB_ME]" }, invocation_with(session))

      expect(result.content).to include("host=[]")
    ensure
      ENV.delete("LAIN_SCRUB_ME")
    end
  end
end
