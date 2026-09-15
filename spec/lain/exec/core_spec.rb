# frozen_string_literal: true

require "async"
require "fileutils"
require "tmpdir"

# The out-of-process arm of the exec seam. Everything here is asserted at the
# WIRE, with a recording client duck rather than the real daemon, because what
# this backend owns is the request it builds; what the daemon does with one is
# pinned against the real thing in spec/lain/core/.
RSpec.describe Lain::Exec::Core do
  # Records the params it was handed and replies with a clean exec outcome.
  let(:recorder) do
    Class.new do
      attr_reader :params

      def initialize(outcome = nil)
        @outcome = outcome || { "exit_status" => 0, "stdout" => "", "stderr" => "", "timed_out" => false }
      end

      def call(_method, params)
        @params = params.first
        @outcome
      end
    end
  end

  let(:client) { recorder.new }

  def run(command: "echo hi", env: ENV.to_h, cwd: "/tmp", timeout: 5, with: client, grace: described_class::GRACE)
    Sync { described_class.new(client: with, grace:).call(command:, cwd:, env:, timeout:) }
  end

  describe "the request it puts on the wire" do
    it "sends the command as `sh -c`, the resolved cwd, and the timeout in milliseconds" do
      run(command: "echo hi", cwd: "/tmp", timeout: 5)

      expect(client.params).to include("argv" => ["sh", "-c", "echo hi"], "cwd" => "/tmp",
                                       "timeout_ms" => 5000)
    end

    it "returns the daemon's capture in the shape the local arm returns" do
      capture = run(with: recorder.new({ "exit_status" => 3, "stdout" => "out", "stderr" => "err",
                                         "timed_out" => false }))

      expect(capture).to have_attributes(exit_status: 3, stdout: "out", stderr: "err")
    end

    # This arm holds everything the daemon replied with, so what it counts is
    # what it holds; the in-process arm counts past what it holds.
    it "counts the whole reply as the capture's size" do
      capture = run(with: recorder.new({ "exit_status" => 0, "stdout" => "x" * 70_000, "stderr" => "err",
                                         "timed_out" => false }))

      expect(capture.size).to eq(70_003)
    end
  end

  # The out-of-process half of exec. The daemon is lain's OWN child, so it
  # already carries BUNDLE_GEMFILE: an env map that merely OMITS the key leaves
  # the daemon's copy in place. Only an explicit nil -- msgpack nil, the
  # server's remove-the-key marker -- takes it away.
  describe "lain's own toolchain does not reach the daemon's child" do
    it "maps each framework variable to an explicit nil, never to an omission" do
      with_env("BUNDLE_GEMFILE" => "/lain/Gemfile", "RUBYOPT" => "-rbundler/setup") do
        run(env: ENV.to_h)

        wire = client.params.fetch("env")
        expect(wire).to include("BUNDLE_GEMFILE" => nil, "RUBYOPT" => nil)
        expect(wire.key?("BUNDLE_GEMFILE")).to be(true)
      end
    end

    it "still lends what the caller lent, and keeps GEM_HOME" do
      with_env("GEM_HOME" => "/tmp/lain-t1-gems") do
        run(env: ENV.to_h.merge("LAIN_LENT" => "on loan"))

        expect(client.params.fetch("env")).to include("LAIN_LENT" => "on loan",
                                                      "GEM_HOME" => "/tmp/lain-t1-gems")
      end
    end

    # The differential that matters here: both backends have to decide the
    # SAME environment, or the transport becomes observable in what a command
    # can see. Compared against the map the local arm hands its runner.
    it "decides the same environment as the local backend, key for key" do
      with_env("BUNDLE_GEMFILE" => "/lain/Gemfile", "RSPEC_OPTS" => "--seed 1") do
        captured = nil
        pipeline = lambda do |_term, env:, capture:, **|
          captured = env
          capture.finish(0)
        end
        Lain::Exec::Local.new(pipeline:).call(command: "true", cwd: "/tmp", env: ENV.to_h, timeout: 5)
        run(env: ENV.to_h)

        expect(client.params.fetch("env")).to eq(captured)
      end
    end
  end

  describe "a deadline the daemon enforced" do
    it "raises Exec::Timeout naming the server-side kill and carrying the partial capture" do
      killed = recorder.new({ "exit_status" => 0, "stdout" => "partial", "stderr" => "noise",
                              "timed_out" => true })

      expect { run(command: "sleep 9", with: killed) }
        .to raise_error(Lain::Exec::Timeout, /killed server-side by lain-core.*partial.*noise/m)
    end

    # The daemon's captures arrive BINARY, so a non-ASCII command interpolated
    # beside a high byte would raise an encoding error in place of the timeout.
    it "raises Exec::Timeout for a non-ASCII command whose capture holds non-ASCII bytes" do
      killed = recorder.new({ "exit_status" => nil, "stdout" => "✅\n".b, "stderr" => "caf\xE9".b,
                              "timed_out" => true })

      expect { run(command: "echo ✅; sleep 9", with: killed) }
        .to raise_error(Lain::Exec::Timeout) { |error| expect(error.message.b).to include("✅".b, "caf\xE9".b) }
    end
  end

  # A deadline the daemon did NOT enforce is a different fact, and the backend
  # says so in its own words rather than letting Async::TimeoutError -- a type
  # this contract never advertised -- past a caller's `rescue Exec::Timeout`.
  describe "a deadline the daemon failed to enforce" do
    let(:mute) do
      Class.new do
        def call(_method, _params) = Async::Task.current.sleep(30)
      end.new
    end

    it "raises Exec::Unenforced naming the timeout and the grace" do
      expect { run(command: "sleep 9", with: mute, timeout: 1, grace: 0.1) }
        .to raise_error(Lain::Exec::Unenforced,
                        "lain-core failed to enforce the 1s timeout within 0.1s grace -- " \
                        "no reply from the boundary")
    end

    it "is a Timeout, so one rescue still covers a caller that need not tell them apart" do
      expect { run(command: "sleep 9", with: mute, timeout: 1, grace: 0.1) }
        .to raise_error(Lain::Exec::Timeout)
    end
  end

  # Parity with the in-process arm is a property of the one renderer, and it
  # has to survive the in-process arm holding only part of what it counts.
  describe "against the real daemon", :core do
    let(:runtime_base) { Dir.mktmpdir("lain-exec-core") }

    let(:invocation) { Lain::Tool::Invocation.new(tool_use_id: "tu_1") }

    after { FileUtils.rm_rf(runtime_base) }

    def through_daemon(command)
      Sync do
        child = Lain::Core::Child.new(paths: Lain::Paths.new(env: { "XDG_RUNTIME_DIR" => runtime_base }))
        client = Lain::Core::Client.start(transport: child)
        begin
          Lain::Tools::Bash.new(exec: described_class.new(client:)).call({ command: }, invocation)
        ensure
          client.stop
        end
      end
    end

    it "refuses output over the ceiling byte-identically to the in-process arm" do
      command = "head -c 1048576 /dev/zero | tr '\\0' x; exit 3"

      daemon = through_daemon(command)
      local = Lain::Tools::Bash.new.call({ command: }, invocation)

      expect(daemon.content).to eq(local.content)
      expect(daemon.content).to include("is 1048576 bytes", "exit status: 3")
    end
  end

  # The seam's contract admits a String or a term; this backend admits only the
  # first. Packing a term would put ["sh", "-c", [["printf", "hi"]]] on the wire,
  # which the daemon rejects at decode -- surfacing as a spawn refusal a caller
  # then misreports as a bad cwd. Threading these backends into Tools::Bash,
  # which DOES hold terms, stops this being unreachable there.
  describe "a shape it has no wire for" do
    # A caller holding a term can ask before it offers one, which is what stops
    # Tools::Bash handing this backend a shape it has no wire for. The row is
    # the whole of this backend's share of the seam's truth table -- it takes no
    # term at all -- and the shared contract is what checks its refusal against
    # its own answer rather than against a copy of the rule kept here.
    let(:backend) { described_class.new(client:) }

    def run_term(term) = run(command: term)
    def terms_taken = []
    def terms_refused = [[%w[printf hi]], [%w[grep foo], %w[wc -l]]]

    it_behaves_like "an exec backend answering for a term"

    it "refuses a term by name, rather than packing one the daemon cannot decode" do
      expect { run(command: [%w[printf hi]]) }
        .to raise_error(Lain::Exec::Unsupported, /no wire shape for a term/)
    end

    # Nothing reaches the wire, and nothing falls back to the string arm: a join
    # back would hand `sh -c` the very command the term path keeps away from it.
    it "refuses at the door, so neither a packed term nor a rejoined string is sent" do
      expect { run(command: [%w[printf hi]]) }.to raise_error(Lain::Exec::Unsupported)

      expect(client.params).to be_nil
    end
  end
end
