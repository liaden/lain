# frozen_string_literal: true

require "fileutils"
require "securerandom"

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module HeadlessEditorSpecSupport
  # A stand-in `nvim`: it never creates the socket it was given, so the harness's
  # own wait is what fails, and with the env var it ignores TERM the way two of
  # the three orphaned editors reaped by hand on this box on 2026-09-13 did.
  #
  # ONE PROCESS, and that is the whole reason it is ruby rather than the two-line
  # shell script it started as. `/bin/sh` FORKS `sleep 600` rather than exec'ing
  # it, so killing the shell orphans a grandchild whose argv is a bare
  # `sleep 600` -- invisible to the tag search below, reparented to init, and
  # alive for ten minutes. A spec asserting that nothing leaked, leaking. Twelve
  # were cleared off this box before this file shipped.
  DIR = SocketTmpdir.persistent("lain-headless-editor-shim")
  SHIM = File.join(DIR, "nvim")

  File.write(SHIM, <<~RUBY)
    #!#{RbConfig.ruby}
    Signal.trap("TERM") {} if ENV["LAIN_HEADLESS_EDITOR_SPEC_IGNORE_TERM"] == "1"
    sleep 600
  RUBY
  File.chmod(0o755, SHIM)

  # Stands in for `SpecWatchdog::Stuck`, which is `< Exception` precisely so that
  # nothing downstream can rescue it away. Reproducing that ancestry is the whole
  # point of the double below -- a `StandardError` would prove nothing.
  class Ambush < Exception; end # rubocop:disable Lint/InheritException
end

# THE EXCEPTION TO "a helper is exercised by the specs that use it", and the same
# exception the async-ceremony helper gets: everything this file asserts is
# behaviour under FAILURE -- an editor that ignores TERM, an exception RSpec never
# sees, a socket name a leak already took -- and the twenty specs that use the
# harness cannot demonstrate any of it, because they pass. Each example here was a
# review finding first: a `Process.wait` with no deadline, a `rescue StandardError`
# that the watchdog's own exception walks past, and a name drawn from a seeded
# `Kernel#rand`.
#
# NOT `:nvim`. Two of these examples deliberately put a stand-in ahead of the real
# editor on PATH and the rest spawn no editor at all, so this file has to keep
# running on a box that has no nvim -- which is the tag's whole purpose.
RSpec.describe HeadlessEditor, :seam do
  # By pid, and only ever one this example spawned.
  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  # Every process whose argv carries this tag AND THIS PROCESS'S PID, which the
  # socket name already holds. The pid is not decoration: on the bare tag this
  # matches a previous run's leak and a concurrent agent's worktree too, so an
  # example that never touched `.start` reds citing a pid from somebody else's
  # run. It is also why this is not `pkill -f nvim`, which would find a human's
  # own cockpit.
  def survivors(tag) = `pgrep -fa #{tag}-#{Process.pid}`.lines.map(&:strip).reject { |line| line.include?("pgrep") }

  # The shim ahead of the real editor, restored whatever happens: this is the one
  # file in the tree that wants `nvim` to resolve to something else.
  def with_shim(ignore_term: false)
    path = ENV.fetch("PATH")
    ENV["PATH"] = "#{HeadlessEditorSpecSupport::DIR}:#{path}"
    ENV["LAIN_HEADLESS_EDITOR_SPEC_IGNORE_TERM"] = "1" if ignore_term
    yield
  ensure
    ENV["PATH"] = path
    ENV.delete("LAIN_HEADLESS_EDITOR_SPEC_IGNORE_TERM")
  end

  def spare_socket(tag) = File.join(SocketTmpdir::BASE, "#{tag}-#{Process.pid}-#{SecureRandom.hex(6)}.sock")

  # A child that ignores TERM, AND HAS SAID SO. Without the handshake the reap
  # races ruby's own startup and lands before `Signal.trap` runs -- which is a
  # green example asserting nothing, the shape this file exists to catch.
  def term_ignoring_child(ready)
    script = 'Signal.trap("TERM") {}; File.write(ENV.fetch("READY"), "1"); sleep 600'
    spawn({ "READY" => ready }, RbConfig.ruby, "-e", script, out: File::NULL, err: File::NULL).tap do
      Timeout.timeout(10) { sleep 0.01 until File.exist?(ready) }
    end
  end

  describe "#reap" do
    # The blocker this spec exists for. An unbounded `Process.wait` on an editor
    # that ignores TERM does not merely leak it: the hang is attributed by
    # {SpecWatchdog} to whatever example is current, so the run reports STUCK at a
    # place with nothing to do with the cause -- and under `parallel_rspec`, a
    # worker that simply carries fewer examples and no failures.
    it "escalates to KILL when the editor ignores TERM, instead of waiting on it forever" do
      socket = spare_socket("headless-editor-spec-term")
      FileUtils.touch(socket)
      ready = "#{socket}.ready"
      pid = term_ignoring_child(ready)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      described_class::Session.new(socket, pid).reap
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(alive?(pid)).to be(false)
      expect(File.exist?(socket)).to be(false)
      # BOTH bounds, and the lower one is the real assertion: under GRACE would
      # mean TERM was honoured after all and the escalation never ran.
      expect(elapsed).to be_between(described_class::Session::GRACE, described_class::Session::GRACE + 3)
    ensure
      FileUtils.rm_f(ready.to_s)
    end

    # The frontend's teardown group kills its own editor mid-example; ESRCH and
    # ECHILD are how that reaches the hook, and the socket still has to go.
    it "answers an editor the example already killed itself" do
      socket = spare_socket("headless-editor-spec-gone")
      FileUtils.touch(socket)
      pid = spawn(RbConfig.ruby, "-e", "sleep 600", out: File::NULL, err: File::NULL)
      Process.kill("KILL", pid)
      Process.wait(pid)

      expect { described_class::Session.new(socket, pid).reap }.not_to raise_error
      expect(File.exist?(socket)).to be(false)
    end
  end

  describe ".start" do
    # The window a caller cannot cover: while `start` is on the stack the caller's
    # own session local is still nil, so its `ensure` has nothing to reap.
    it "gives the editor back when the socket never appears and the editor ignores TERM" do
      tag = "headless-editor-spec-no-listen"
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      with_shim(ignore_term: true) do
        expect { described_class.start(tag, wait: 0.3) }.to raise_error(Timeout::Error)
      end

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      expect(elapsed).to be_between(described_class::Session::GRACE, described_class::Session::GRACE + 3)
      expect(survivors(tag)).to be_empty
    end

    # `rescue StandardError` would let this straight past, which is what made the
    # ancestry of the double above the point of the example rather than a detail.
    it "gives the editor back when an exception RSpec itself would never catch arrives during the wait" do
      tag = "headless-editor-spec-ambushed"
      allow(Timeout).to receive(:timeout).and_raise(HeadlessEditorSpecSupport::Ambush)

      with_shim do
        expect { described_class.start(tag) }.to raise_error(HeadlessEditorSpecSupport::Ambush)
      end

      expect(survivors(tag)).to be_empty
    end
  end

  describe ".socket_path" do
    # A taken name means an earlier editor outlived its example: `start` waits on
    # `File.exist?`, so it would return instantly and the example would spend its
    # run driving the stranger, while its own editor's `serverstart` failed
    # silently under nvim's `pcall`.
    it "refuses a path that is already taken, rather than attaching to the leak that left it" do
      allow(SecureRandom).to receive(:hex).and_return("0123456789ab")
      path = described_class.socket_path("headless-editor-spec-reuse")
      FileUtils.touch(path)

      expect { described_class.socket_path("headless-editor-spec-reuse") }
        .to raise_error(/already exists/)
    ensure
      FileUtils.rm_f(path) if path
    end

    it "draws a name a seeded Kernel#rand cannot reproduce" do
      Kernel.srand(4242)
      first = described_class.socket_path("headless-editor-spec-seeded")
      Kernel.srand(4242)

      expect(described_class.socket_path("headless-editor-spec-seeded")).not_to eq(first)
    end
  end
end
