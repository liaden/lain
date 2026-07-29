# frozen_string_literal: true

require "fileutils"
require "timeout"

# {Core::Child}'s failure branches, which client_spec only ever reached
# incidentally (it drives the CLIENT, so a Child that raises is scaffolding
# there, not the subject). Each example here names one branch: the connect
# budget expiring while the daemon lives, the dead-on-arrival exit, TERM
# against a pid that is already gone, and the reap memo.
#
# :core, like client_spec: FOUR examples drive the REAL compiled daemon,
# because "externally killed" and "reaped twice" are only honest against a
# process that actually served. The other four use stand-in binaries, so the
# no-socket branches never depend on the Rust build behaving badly.
RSpec.describe Lain::Core::Child, :core do
  # A throwaway XDG runtime dir injected through Paths -- nothing touches the
  # machine's real /run/user, and parallel workers cannot collide.
  let(:runtime_base) { Dir.mktmpdir("lain-core-child") }
  let(:paths) { Lain::Paths.new(env: { "XDG_RUNTIME_DIR" => runtime_base }) }

  after { FileUtils.rm_rf(runtime_base) }

  def child(binary: described_class::BINARY) = described_class.new(paths:, binary:)

  # A stand-in daemon handed the SAME argv the real binary gets and free to
  # IGNORE it -- unlike client_spec's `fake_daemon`, which binds the socket
  # first, because the branches under test here are exactly the ones where no
  # socket ever appears. Generated into the per-example tempdir (outside
  # `runtime_dir`, so `prepare_runtime_dir`'s unlink cannot reach it), since
  # `binary:` is an injected seam and needs no committed fixture.
  def stub_daemon(name, body)
    path = File.join(runtime_base, name)
    File.write(path, "#!#{RbConfig.ruby}\n#{body}\n")
    File.chmod(0o755, path)
    path
  end

  # A reaper whose own exception report is silenced: Thread#value re-raises it
  # for the example to fail on, and the default report would also smear the
  # raise across the suite's stderr.
  def reaper_thread(daemon)
    Thread.new do
      Thread.current.report_on_exception = false
      daemon.reap
    end
  end

  # Park until every reaper is blocked (in wait2, or on the guard). Fails LOUDLY
  # on expiry -- prompt_breaker_spec.rb's own idiom -- because a bounded wait
  # that merely RETURNED would let the example proceed as though the threads had
  # parked, and its whole subject is the interleaving that arranging the park
  # creates. A wait that fails open is an example that can quietly stop testing
  # its subject.
  def await_parked(threads)
    Timeout.timeout(2) { sleep(0.005) until threads.all? { |thread| thread.status == "sleep" } }
  end

  describe "a daemon that never accepts" do
    # Alive for far longer than CONNECT_BUDGET and never binding: the connect
    # loop only ever sees ENOENT, and the dead-on-arrival check never fires.
    let(:never_accepts) { stub_daemon("never-accepts", "sleep 60") }

    it "fails as Unreachable, naming the socket path and the connect budget" do
      daemon = child(binary: never_accepts)

      expect { daemon.start }.to raise_error(described_class::Unreachable) do |error|
        expect(error.message).to include(daemon.socket_path, "within #{described_class::CONNECT_BUDGET}s")
      end
    end

    it "reclaims the daemon on that failure: the pid is TERMed and reaped, never leaked" do
      daemon = child(binary: never_accepts)
      expect { daemon.start }.to raise_error(described_class::Unreachable)

      # A reaped pid is gone from the table entirely, so signal 0 -- the
      # existence probe -- refuses. A leaked child would still be sleeping,
      # and `Process.kill(0, pid)` would quietly succeed. Probed this way
      # rather than by calling #reap, which would park for the full 60s
      # against exactly the leak this example exists to catch.
      expect { Process.kill(0, daemon.pid) }.to raise_error(Errno::ESRCH)
    end
  end

  describe "a daemon that exits before accepting" do
    let(:dies_at_once) { stub_daemon("dies-at-once", "exit 3") }

    it "fails as Died with the real exit status, never as a connect timeout" do
      expect { child(binary: dies_at_once).start }.to raise_error(Lain::Core::Died, /exit 3/)
    end

    it "memoizes that status, so a later reap answers from the memo instead of ECHILD" do
      daemon = child(binary: dies_at_once)
      expect { daemon.start }.to raise_error(Lain::Core::Died)

      # The WNOHANG probe already collected the status; without the memo this
      # second wait2 would raise Errno::ECHILD on a pid nobody can reap twice.
      expect(daemon.reap.exitstatus).to eq(3)
    end
  end

  describe "a pid that is already gone" do
    it "tolerates TERM against it: the ESRCH is swallowed and #stop still answers" do
      daemon = child
      daemon.start.close
      Process.kill("KILL", daemon.pid)
      daemon.reap # collects the status, which retires the pid from the table

      expect { daemon.stop }.not_to raise_error
    end

    it "keeps the killed status as the last word -- #stop never overwrites the memo" do
      daemon = child
      daemon.start.close
      Process.kill("KILL", daemon.pid)
      killed = daemon.reap
      daemon.stop

      expect(daemon.reap).to be(killed)
      expect(killed.termsig).to eq(Signal.list.fetch("KILL"))
    end
  end

  describe "#reap" do
    it "collects the status exactly once: a second reap answers from the memo" do
      daemon = child
      daemon.start.close
      Process.kill("TERM", daemon.pid)
      first = daemon.reap

      expect(daemon.reap).to be(first)
    end

    # The guard's whole reason for existing (see Child#initialize): the
    # client's reader fiber and #stop can both arrive, and `Process.wait2`
    # parks its caller -- so the second arrival must wait for the memo. Both
    # threads are parked INSIDE #reap before the daemon is asked to die, which
    # is the interleaving an unguarded `@status ||= wait2` loses: one thread
    # takes the status, the other wakes into Errno::ECHILD.
    it "guards concurrent arrivals: two reapers park, and both get the one status" do
      daemon = child
      socket = daemon.start
      reapers = Array.new(2) { reaper_thread(daemon) }
      await_parked(reapers)
      Process.kill("TERM", daemon.pid)

      statuses = reapers.map(&:value)

      expect(statuses.last).to be(statuses.first)
    ensure
      socket&.close
    end
  end
end
