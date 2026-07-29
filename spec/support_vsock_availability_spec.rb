# frozen_string_literal: true

# Deliberately OUTSIDE spec/support/, for the exact reason
# spec/support_matchers_spec.rb gives in its own header: spec_helper
# glob-requires `spec/support/**/*.rb` as configuration, and RSpec's own
# discovery separately `load`s every `spec/**/*_spec.rb` -- which does not
# consult $LOADED_FEATURES, so the earlier `require` dedupes nothing. A
# `_spec.rb` inside that glob would run twice. This file tests
# spec/support/vsock_availability.rb and spec/support/vsock_daemon.rb, so it
# lives one level up, where only discovery finds it -- there is no
# spec/lain/support/ directory to put it in instead.

require "rspec/core/sandbox"
require "socket"
require "stringio"
require "tmpdir"
require "fileutils"

# Fixture-only constants kept out of the RSpec block (Lint/ConstantDefinitionInBlock;
# spec/lain/tools/core_exec_spec.rb:7 does the same for the same reason).

# VMADDR_CID_LOCAL -- the loopback CID, dialed from the host. Convention and
# legibility, NOT necessity: an earlier draft of this comment claimed CID_HOST(2)
# "connects then fails ENOTCONN on write", and that was measured against a port
# with nothing listening, so the ENOTCONN came from the dead port rather than the
# CID. Re-measured against a live CID_ANY listener, LOCAL(1) and HOST(2) are
# behaviourally indistinguishable -- ping, binary bytes, 1 MiB and 8-way demux all
# pass on both; only CID_ANY fails, with ENODEV. Test-local: T5's real
# Transport::Vsock defines its own.
VSOCK_SPEC_CID_LOCAL = 1

# A stand-in "lain-core" honoring this card's ASSUMED T4 contract (see
# spec/support/vsock_daemon.rb's header for the full contract and why it is only
# assumed): bind AF_VSOCK per the scheme argv, write the bound port to
# "<tracing_path>.port", then answer any connection with a fixed reply. This lets
# the daemon-helper scenario below exercise VsockDaemon's actual mechanics against
# a REAL AF_VSOCK bind/accept/connect without waiting on T4 to land.
VSOCK_SPEC_FAKE_DAEMON_SOURCE = <<~RUBY
  require "socket"

  scheme, tracing_path = ARGV
  port_arg = scheme.delete_prefix("vsock:")
  port = port_arg.empty? ? 0xFFFFFFFF : Integer(port_arg)

  socket = Socket.new(Socket::AF_VSOCK, Socket::SOCK_STREAM, 0)
  socket.bind([Socket::AF_VSOCK, 0, port, 0xFFFFFFFF, 0, 0, 0, 0].pack("SSLLCCCC"))
  socket.listen(1)
  bound_port = socket.getsockname.unpack("SSLLCCCC")[2]
  File.write("\#{tracing_path}.port", bound_port.to_s)

  loop do
    connection, = socket.accept
    connection.write("pong\\n")
    connection.close
  end
RUBY

RSpec.describe "vsock spec harness (spec/support/vsock_availability.rb, spec/support/vsock_daemon.rb)" do
  describe "VsockAvailability.available?" do
    it "answers true or false and never raises, on this host" do
      result = nil
      expect { result = VsockAvailability.available? }.not_to raise_error
      expect(result).to be(true).or be(false)
    end

    it "leaks no descriptor across repeated probing" do
      skip "no /proc/self/fd on this host -- descriptor-leak check needs procfs" unless Dir.exist?("/proc/self/fd")

      before_count = Dir.children("/proc/self/fd").size
      200.times { VsockAvailability.available? }
      after_count = Dir.children("/proc/self/fd").size

      expect(after_count).to eq(before_count)
    end

    # Regression for panel finding 2 (Evans): this is the only /proc reference
    # in the suite, it carries no tag, and the chunk's own Grounding names
    # Joel's work MacBook as a host of unknown eligibility -- a hard failure
    # here on a procfs-less host would break `pre-commit run --all-files`
    # rather than skip like every other missing-capability guard in this
    # suite. Proven in an isolated RSpec::Core::Sandbox group (same technique
    # as the :vsock gate tests above) rather than by finding a real host
    # without /proc, which this machine is not.
    it "skips (never fails) the descriptor-leak check when procfs is unavailable" do
      allow(Dir).to receive(:exist?).with("/proc/self/fd").and_return(false)
      status = nil

      RSpec::Core::Sandbox.sandboxed do |config|
        config.output_stream = config.error_stream = StringIO.new
        group = RSpec.describe("isolated") do
          it("probe") do
            unless Dir.exist?("/proc/self/fd")
              skip "no /proc/self/fd on this host -- descriptor-leak check needs procfs"
            end
            raise "should never reach here"
          end
        end
        group.run(config.reporter)
        status = group.examples.first.execution_result.status
      end

      expect(status).to eq(:pending)
    end

    # Ruby's socket constants are #ifdef-guarded per platform (panel finding,
    # Evans): a host whose Ruby was built without AF_VSOCK support has no
    # Socket::AF_VSOCK at all, and the first Gherkin scenario is explicit --
    # "with or without vsock support ... never raises". Removing and restoring
    # the real constant is deterministic and needs no such host to prove.
    it "answers false, not NameError, on a host without Socket::AF_VSOCK at all" do
      real_af_vsock = Socket::AF_VSOCK
      Socket.send(:remove_const, :AF_VSOCK)
      begin
        result = nil
        expect { result = VsockAvailability.available? }.not_to raise_error
        expect(result).to be(false)
      ensure
        Socket.const_set(:AF_VSOCK, real_af_vsock)
      end
    end
  end

  # The :vsock tag's gate -- a config.filter_run_excluding(:vsock) plus a
  # config.before(:each, :vsock) hook -- is spec/support/tags.rb's to own
  # (shared-file wiring, per the plan's Orchestrator contract); T3 hands back
  # its exact text rather than editing that file. Reproduced BYTE-FOR-BYTE
  # here (see .handback-T3.md for the diff itself) so the gate's behaviour is
  # proven before the diff lands, not merely asserted. Each example below
  # runs the reproduced gate inside a fresh RSpec::Core::Sandbox -- rspec-core's
  # own supported mechanism for testing a filter/hook against an isolated
  # configuration + world, so nothing here touches the real suite that is
  # currently running this very file.
  describe "the :vsock gate" do
    # A fresh Configuration also gets the gate: filter_run_excluding(:vsock)
    # plus the before-hook, in one step since every call site here wants
    # both. Silences the default `progress` formatter too -- a nested run's
    # dots would otherwise interleave with the real suite's own output.
    def install_vsock_gate(config)
      config.output_stream = config.error_stream = StringIO.new
      config.filter_run_excluding(:vsock)
      config.before(:each, :vsock) do
        reason = "host cannot bind AF_VSOCK -- vsock_loopback unavailable" unless VsockAvailability.available?
        reason ||= "lain-core binary not built -- run `bundle exec rake core:build` to run :vsock specs" \
          unless File.executable?(Lain::Core::Child::BINARY)
        skip(reason) if reason
      end
    end

    # Runs a one-example isolated group with the gate installed, optionally
    # simulating `--tag vsock` on the command line (`opt_in:`), and returns
    # whether the example body actually ran plus the example itself (so a
    # caller can inspect its execution_result).
    def run_gated_example(*tags, opt_in:)
      executed = false
      example = nil
      RSpec::Core::Sandbox.sandboxed do |config|
        install_vsock_gate(config)
        # rspec-core gives a bare `--tag` priority over a config-level
        # exclusion for THAT tag only -- this is what a real `--tag vsock`
        # invocation does (see the doubly-tagged trap test below).
        config.filter_manager.include(vsock: true) if opt_in
        group = RSpec.describe("isolated") { it("probe", *tags) { executed = true } }
        group.run(config.reporter)
        example = group.examples.first
      end

      [executed, example]
    end

    # Every other example here proves {install_vsock_gate} -- a COPY of the real
    # wiring in spec/support/tags.rb, because a spec cannot install that wiring on
    # itself. Two texts with no link drift silently: the day tags.rb loses the
    # exclusion, those examples stay green and :vsock specs start running in every
    # default suite run. This is the one assertion against the REAL configuration,
    # so the copy cannot outlive the original.
    it "is installed on the real configuration, not only on the sandboxed copy" do
      expect(RSpec.configuration.filter_manager.exclusions[:vsock]).to be(true)
    end

    it "skips rather than fails when the host cannot bind AF_VSOCK, naming the missing transport" do
      allow(VsockAvailability).to receive(:available?).and_return(false)
      # .and_call_original first (Patterson NIT): a bare `.with(BINARY)` stub
      # alone would raise "received with unexpected arguments" for any OTHER
      # File.executable? call this nested run happens to make -- falling back
      # to the real method keeps the constraint narrow instead of brittle.
      allow(File).to receive(:executable?).and_call_original
      allow(File).to receive(:executable?).with(Lain::Core::Child::BINARY).and_return(true)

      executed, example = run_gated_example(:vsock, opt_in: true)

      expect(executed).to be(false)
      expect(example.execution_result.status).to eq(:pending)
      expect(example.execution_result.pending_message).to include("vsock_loopback unavailable")
    end

    it "skips rather than fails when the binary is missing, naming the binary" do
      allow(VsockAvailability).to receive(:available?).and_return(true)
      allow(File).to receive(:executable?).and_call_original
      allow(File).to receive(:executable?).with(Lain::Core::Child::BINARY).and_return(false)

      executed, example = run_gated_example(:vsock, opt_in: true)

      expect(executed).to be(false)
      expect(example.execution_result.status).to eq(:pending)
      expect(example.execution_result.pending_message).to include("binary not built")
    end

    it "does not run a :vsock example with no tag filter applied -- the default posture" do
      executed, example = run_gated_example(:vsock, opt_in: false)

      expect(executed).to be(false)
      # Filtered out before RSpec ever ran it -- not even attempted, let
      # alone skipped, distinguishing "excluded by default" from "skipped by
      # the before-hook" above.
      expect(example.execution_result.status).to be_nil
    end

    # The trap this whole card exists to close: a CLI `--tag` lifts a
    # config-level exclusion for THAT tag only. An example carrying BOTH
    # :vsock and :core stays excluded under `--tag vsock` (config still
    # excludes :core), so a run that opts into :vsock alone would pass green
    # having executed a doubly-tagged example zero times -- exactly the
    # silent-pass this card's critical tagging rule forbids.
    it "keeps a :vsock, :core doubly-tagged example excluded under --tag vsock alone" do
      executed = false

      RSpec::Core::Sandbox.sandboxed do |config|
        install_vsock_gate(config)
        config.filter_run_excluding(:core)
        config.filter_manager.include(vsock: true)

        group = RSpec.describe("isolated") { it("vsock and core", :core, :vsock) { executed = true } }
        group.run(config.reporter)
      end

      expect(executed).to be(false)
    end
  end

  describe VsockDaemon do
    # Generated per example into a throwaway directory, matching
    # spec/lain/core/client_spec.rb's `fake_daemon` pattern -- `binary:` is an
    # injected seam, so no committed fixture script is needed.
    def fake_vsock_binary(dir)
      path = File.join(dir, "fake-lain-core")
      File.write(path, "#!#{RbConfig.ruby}\n#{VSOCK_SPEC_FAKE_DAEMON_SOURCE}")
      File.chmod(0o755, path)
      path
    end

    # A "daemon" that exits immediately with a chosen status, never binding
    # anything or writing a ready file -- proves {VsockDaemon::Died} carries
    # the real exit status rather than a generic timeout that never elapsed.
    def fake_dying_binary(dir, status)
      path = File.join(dir, "fake-dying-core")
      File.write(path, "#!#{RbConfig.ruby}\nexit #{status}\n")
      File.chmod(0o755, path)
      path
    end

    it "spawns a reachable daemon over vsock and reclaims it on teardown", :vsock do
      dir = Dir.mktmpdir("vsock-daemon-spec")
      pid = nil

      VsockDaemon.run(binary: fake_vsock_binary(dir)) do |daemon|
        client = Socket.new(Socket::AF_VSOCK, Socket::SOCK_STREAM, 0)
        client.connect([Socket::AF_VSOCK, 0, daemon.port, VSOCK_SPEC_CID_LOCAL, 0, 0, 0, 0].pack("SSLLCCCC"))
        reply = client.read(5)
        client.close

        expect(reply).to eq("pong\n")
        pid = daemon.pid
      end

      expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
    ensure
      FileUtils.remove_entry(dir, true) if dir
    end

    # Regression for panel finding 3 (Patterson): bare start/.../stop left a
    # daemon running when the caller raised before reaching #stop -- exactly
    # what the plan's Grounding warns would make T5's "nothing is listening"
    # scenario pass for the wrong reason. `.run`'s `ensure daemon&.stop` must
    # fire even though the block never returns normally.
    it "reclaims the daemon even when the block raises", :vsock do
      dir = Dir.mktmpdir("vsock-daemon-spec")
      pid = nil

      expect do
        VsockDaemon.run(binary: fake_vsock_binary(dir)) do |daemon|
          pid = daemon.pid
          raise "boom"
        end
      end.to raise_error("boom")

      expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
    ensure
      FileUtils.remove_entry(dir, true) if dir
    end

    it "raises Died naming the real exit status when the daemon dies before reporting readiness", :vsock do
      dir = Dir.mktmpdir("vsock-daemon-spec")

      expect { VsockDaemon.new(binary: fake_dying_binary(dir, 3)).start }
        .to raise_error(VsockDaemon::Died, /exited before ever reporting a vsock port/)
    ensure
      FileUtils.remove_entry(dir, true) if dir
    end
  end
end
