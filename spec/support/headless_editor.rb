# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "timeout"

# The one spawn-wait-reap for every spec that drives a REAL headless nvim over
# msgpack-RPC. Twenty-one sites hand-rolled it in five variants, and what they
# differed in was never the editor: whether the reap was guarded against a pid
# that never spawned, whether the observing connection was dropped at teardown,
# whether the dance sat inline or in a pair of class methods returning a triple.
# So it is expressed once here, and what a spec genuinely differs in -- where the
# editor stands, what it is started with, whether it wants the runtime injected --
# is an argument.
#
# What this owns, so that no caller has to remember it: the editor is given back
# on every way out of the hook including the ones RSpec does not catch, the reap
# escalates rather than waiting forever, and the socket is a name no other
# example can be holding. Each of those is a defect somewhere if it is left to a
# call site, and the reasons are at the methods that carry them.
module HeadlessEditor
  # `--clean` so a developer's own config never reaches a spec. `-n` (no swap
  # file) is not tidiness: an editor TERM'd with a modified buffer leaves its
  # swap beside the fixture, and the next example's `bufload` answers
  # `E325: ATTENTION` -- a cascade that names nothing about itself. A spec that
  # needs the option rather than the flag passes `args:`.
  COMMAND = %w[nvim --headless --clean -n].freeze

  # Generous, because it bounds a startup and not a behaviour: the editor is up
  # in single-digit milliseconds, and anything approaching this is a box under
  # load or an nvim that died in its own argv.
  WAIT = 10

  # One editor: the process, the socket it listens on, and the connections a spec
  # observes it through.
  class Session
    # How long TERM is given before KILL. A healthy editor exits in milliseconds,
    # so this is never spent on one; it is spent only on one that was going to
    # cost the suite far more.
    GRACE = 2

    # Fine enough that the usual case -- an editor already gone -- costs well
    # under a millisecond, across the five hundred reaps a `--tag nvim` run does.
    POLL = 0.002

    attr_reader :socket_path, :pid

    def initialize(socket_path, pid)
      @socket_path = socket_path
      @pid = pid
    end

    # A connection of this spec's own; callers are expected to want more than one.
    def connect = HeadlessEditor.connect(@socket_path)

    # A connection with the assembled runtime chunk already injected, exactly as
    # {Lain::Frontend::Neovim} injects it -- the same three arguments in the same
    # order, so a spec is never testing a runtime the frontend would not have
    # produced.
    def with_runtime
      connect.tap do |client|
        client.exec_lua(Lain::Frontend::Neovim::RuntimeLoader.new.source,
                        [Lain::VERSION, Lain::Frontend::Neovim.protocol, client.channel_id])
      end
    end

    # TERM, then KILL, and never an unbounded wait. Three orphaned editors were
    # reaped by hand on this box on 2026-09-13 -- one of them 1 day 21 hours old
    # -- and two of them ignored TERM. A `Process.wait` with no deadline turns
    # that into a hang, which {SpecWatchdog} then reports as a STUCK example at a
    # location with nothing to do with the cause while the editor survives
    # anyway; under `parallel_rspec` that is a worker reporting fewer examples and
    # zero failures, the shape a run cannot tell from a pass.
    #
    # By the pid this object spawned, never by name: `pkill -f nvim` matches a
    # human's own cockpit, and this shell's argv besides. Idempotent, because an
    # example is allowed to kill its own editor -- that is what the frontend's
    # teardown group does, and ESRCH/ECHILD is how it arrives here.
    def reap
      Process.kill("TERM", @pid)
      return if exited_within?(GRACE)

      Process.kill("KILL", @pid)
      Process.wait(@pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    ensure
      FileUtils.rm_f(@socket_path)
    end

    private

    # `WNOHANG` polled against a deadline of our own, because the whole point is
    # that the deadline belongs to the reaper rather than to the child.
    def exited_within?(grace)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + grace
      reaped = Process.wait(@pid, Process::WNOHANG)
      until reaped || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep POLL
        reaped = Process.wait(@pid, Process::WNOHANG)
      end
      !reaped.nil?
    end
  end

  # Spawned and listening, or nothing.
  #
  # An `ensure` with a handover flag rather than a `rescue`, and both halves of
  # that matter. While this method is on the stack the CALLER's session local is
  # still nil, so the caller's own `ensure` has nothing to reap -- this is the one
  # window a caller cannot cover. And what actually arrives in that window is
  # {SpecWatchdog::Stuck}, which is deliberately `< Exception` so that no
  # `rescue => e` can swallow it, or an `Interrupt`: a `rescue StandardError`
  # would let both straight past and leave the editor running. An `ensure` sees
  # every way out, `throw` included.
  def self.start(name, chdir: nil, args: [], wait: WAIT)
    socket = socket_path(name)
    session = Session.new(socket, spawn(*COMMAND, *args, "--listen", socket,
                                        **{ chdir:, out: File::NULL, err: File::NULL }.compact))
    Timeout.timeout(wait) { sleep 0.02 until File.exist?(socket) }
    handed_over = true
    session
  ensure
    session&.reap unless handed_over
  end

  # One client attached to a listening editor. The gem is required HERE rather
  # than at the top of the file because `spec/support` is eager-loaded in every
  # one of the twelve workers, and a run that drives no editor should not pay
  # 47ms to load a client it never opens.
  def self.connect(socket_path)
    require "neovim"
    Neovim.attach_unix(socket_path)
  end

  # `SocketTmpdir::BASE` (`/tmp`), not `Dir.tmpdir`: that helper exists because a
  # UNIX socket's `sun_path` is 104 bytes on darwin and a per-user `$TMPDIR`
  # spends half the budget before the fixture's own name -- and nvim's
  # `serverstart` is `pcall`-wrapped, so the overflow is a silent empty
  # `serverlist()` rather than a raise. Resolved at call time, because the support
  # glob loads this file before that one.
  #
  # `SecureRandom` rather than `Kernel#rand`, and then a refusal if the path is
  # taken. `spec_helper.rb:71` seeds `Kernel#rand` from the RSpec seed, which
  # makes the draw a stream of a million rather than a key -- and a repeat bites
  # exactly when an earlier editor OUTLIVED its example, because {.start} waits on
  # `File.exist?` and a leaked socket is already there: the second editor's
  # `serverstart` fails under nvim's `pcall`, silently, and the example spends its
  # run driving the stranger. A name nobody can be holding is the fix; refusing
  # out loud when one is, is the failure a reader can act on.
  def self.socket_path(name)
    File.join(SocketTmpdir::BASE, "#{name}-#{Process.pid}-#{SecureRandom.hex(6)}.sock").tap do |path|
      raise "#{path} already exists -- an editor leaked and this example would have driven it" if File.exist?(path)
    end
  end

  # The whole of an `around` hook, and the only hook it belongs in: the reap is an
  # `ensure`, so from a `before` it would take the editor away before the example
  # ever ran.
  #
  #     around { |example| headless_editor("lain-nvim-layout-spec", runtime: true) { example.run } }
  #
  # `@socket` and `@editor` are ASSIGNED here, which is a TRANSITIONAL contract
  # rather than the interface: those are the names the twenty converted files
  # already read, more than two hundred times between them, and renaming them
  # would have been churn spent to say the same thing. A NEW caller should take
  # the yielded {Session} instead, which names the socket and the pid without a
  # convention to remember.
  def headless_editor(name, chdir: nil, runtime: false, args: [], wait: WAIT)
    session = HeadlessEditor.start(name, chdir:, args:, wait:)
    @socket = session.socket_path
    @editor = session.with_runtime if runtime
    yield session
  ensure
    session&.reap
  end

  # The observing connection: the frontend drives one, this is another, so an
  # assertion is about what the editor actually did rather than about the
  # frontend's own bookkeeping. Memoized for the example, which is the whole of
  # its life -- RSpec builds a fresh group instance per example.
  def inspector = @inspector ||= HeadlessEditor.connect(@socket)
end

RSpec.configure { |config| config.include HeadlessEditor }
