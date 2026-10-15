# frozen_string_literal: true

module Lain
  module CLI
    # `lain land`: queue a commit for the merge coordinator, drain a branch's
    # queue, wait on one entry's result, and say what is queued and who is
    # draining. Each verb answers a String for exe/lain to say, except {#wait},
    # which writes to its sink and answers the exit status.
    #
    # THE DRAINER IS TOLD ITS PROJECT. A detached `lain land drain` is handed
    # the main worktree's root on its command line rather than finding one from
    # its own directory, so the journal and the verify tree it keys are the
    # submitter's project however the child was started.
    class Land
      POLL = 0.05

      # How long a queued entry may go without a live drainer before {#wait} gives up on one.
      NO_DRAINER_AFTER = 5

      # EPERM means the process exists under another user.
      ALIVE = lambda do |pid|
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      # @param cwd [String] the checkout the command runs in
      # @param paths [Paths] where the drainer's journal and verify tree live
      # @param sink [#puts] where {#wait} says what became of the entry
      # @param spawner [#drain] starts the detached drainer; see {Isolation::MergeCoordinator::Spawner}
      # @param drain_for [#call] builds the drainer, as {Isolation::MergeCoordinator::Drain.for}
      # @param shell_out_factory [#call] builds every git subprocess
      # @param clock [#call] monotonic seconds, which time {#wait}'s timeout
      # @param sleeper [#call] waits between {#wait}'s polls
      # @param wall_clock [#call] answers now, against which a drain lock holder's time is told
      # @param alive [#call] whether a pid names a running process
      def initialize(cwd:, paths: Paths.new, sink: Sink::Null.new,
                     spawner: Isolation::MergeCoordinator::Spawner.new,
                     drain_for: Isolation::MergeCoordinator::Drain.method(:for),
                     shell_out_factory: Shell::Out.public_method(:new), clock: RunClock::MONOTONIC,
                     sleeper: Kernel.method(:sleep), wall_clock: -> { Time.now }, alive: ALIVE)
        @cwd = File.expand_path(cwd)
        @paths = paths
        @sink = sink
        @spawner = spawner
        @drain_for = drain_for
        @shell_out_factory = shell_out_factory
        @clock = clock
        @sleeper = sleeper
        @wall_clock = wall_clock
        @alive = alive
      end

      # Nothing here holds a lock, so the drainer is spawned holding none of ours.
      # @param ref [String] the commit to land, resolved in the cwd's checkout
      # @param branch [String, nil] the branch to land on; the main worktree's when nil
      # @param id [String, nil] the worker's name; the cwd checkout's directory name when nil
      # @return [String] the entry id and its place in the queue
      # @raise [Lain::Error] when the ref does not resolve, its anchor cannot be
      #   written, or no branch is named and the main worktree is detached
      def enqueue(ref = "HEAD", branch: nil, id: nil)
        root = main_root
        branch ||= checked_out(root)
        here = git(@cwd)
        home = home(root, branch)
        usable!(home.drain_lock)
        spool = Isolation::MergeCoordinator::Spool.new(home)
        entry = spool.enqueue(anchored(here, ref, id || File.basename(toplevel(here))))
        position = spool.pending.take_while { |each| each.id != entry.id }.size + 1
        "queued #{entry.id} for #{branch} at position #{position}; #{drainer(root, branch, home)}"
      end

      # @param branch [String, nil] the branch whose queue is drained; the main worktree's when nil
      # @param project [String, nil] the project root; the cwd's main worktree when nil
      # @return [String] how many batches this run landed
      def drain(branch: nil, project: nil)
        root = project ? File.expand_path(project) : main_root
        branch ||= checked_out(root)
        count = @drain_for.call(repo_root: root, branch:, paths: @paths, shell_out_factory: @shell_out_factory).call
        "landed #{count} #{count == 1 ? "batch" : "batches"} on #{branch}"
      end

      # @param id [String] the entry {#enqueue} named
      # @param branch [String, nil] the branch it was queued for; the main worktree's when nil
      # @param timeout [Numeric, nil] seconds to wait; forever when nil
      # @return [Integer] 0 when the work is on the branch, 1 when it is not, 2 on
      #   timeout, 3 when no live process has held the drain lock for 5 seconds
      #   (a drainer still booting can be reported so), and 130 on
      #   Ctrl-C, the shell's code for a SIGINT, as every other interrupted lain
      #   command answers
      # @raise [Lain::Error] when the id is not one the spool mints, or the
      #   branch's spool has neither queued nor answered it
      def wait(id, branch: nil, timeout: nil)
        root = main_root
        branch ||= checked_out(root)
        home = home(root, branch)
        spool = Isolation::MergeCoordinator::Spool.new(home)
        known!(spool, id, branch)
        deadline = timeout && (@clock.call + timeout)
        result = poll(spool, id, deadline, home)
        return waited_out(id, timeout, branch, home, deadline) if result.nil?

        told(result.report, id, branch)
      rescue Interrupt
        @sink.puts("interrupted while waiting on #{id}; it is still queued unless it has landed since")
        130
      end

      # @param branch [String, nil] the branch whose queue is shown; the main worktree's when nil
      # @return [String] the pending entries, and who holds the drain lock and for how long
      def status(branch: nil)
        root = main_root
        branch ||= checked_out(root)
        home = home(root, branch)
        [*queue_lines(Isolation::MergeCoordinator::Spool.new(home).pending, branch), holder_line(home)].join("\n")
      end

      private

      def usable!(lock)
        lock.holder
        lock.writable!
      end

      def git(dir) = Isolation::Checkout.new(dir, shell_out_factory: @shell_out_factory)

      def home(root, branch)
        Isolation::MergeCoordinator::Home.for(repo_root: root, branch:, shell_out_factory: @shell_out_factory)
      end

      def main_root = Isolation::MergeCoordinator.main_root(@cwd, shell_out_factory: @shell_out_factory)

      def checked_out(root)
        Isolation::WorkingBranch.checked_out(repo_root: root, shell_out_factory: @shell_out_factory).name
      end

      def toplevel(checkout)
        shell = checkout.run("rev-parse", "--show-toplevel")
        raise Error, "#{@cwd} is in no git checkout, so there is nothing to land" unless shell.exitstatus.zero?

        shell.stdout.strip
      end

      # Compare-and-swap, so two enqueues racing on one worker name fail
      # loudly rather than one silently replacing the other's anchor.
      def anchored(checkout, ref, id)
        sha = checkout.target("#{ref}^{commit}")
        raise Error, "#{ref} names no commit in #{@cwd}" if sha.empty?

        anchor = Isolation::Worktree::Handback::Naming.new(id).ref
        held = checkout.target(anchor)
        write!(checkout, anchor, sha, held) unless held == sha
        Isolation::LandingQueue::Worker.new(id:, ref: anchor, sha:)
      end

      def write!(checkout, anchor, sha, held)
        write = checkout.update_ref(anchor, sha, held, reason: "lain land enqueue")
        raise Error, "could not anchor #{sha} at #{anchor}: #{write.stderr.strip}" unless write.exitstatus.zero?
      end

      def drainer(root, branch, home)
        return "a drainer is landing it" if @spawner.drain(branch:, root:, home:)

        format(Isolation::MergeCoordinator::Spawner::BY_HAND, branch:)
      end

      # The result is written before the entry is deleted, so an id with
      # neither was never queued for this branch. The second read of the result
      # covers a drainer completing the entry between the first and the listing.
      def known!(spool, id, branch)
        return if spool.result(id) || spool.pending.any? { |entry| entry.id == id } || spool.result(id)

        raise Error, "no landing #{id} was queued for #{branch}"
      end

      def poll(spool, id, deadline, home)
        attended = @clock.call
        result = spool.result(id)
        until result || expired?(deadline) || @clock.call - attended >= NO_DRAINER_AFTER
          @sleeper.call(POLL)
          result = spool.result(id)
          attended = @clock.call if live_holder(home)
        end
        result
      end

      def waited_out(id, timeout, branch, home, deadline)
        return still_queued(id, timeout) if expired?(deadline)

        said(3, "#{id} is queued and no drainer is landing it#{stale_note(home)}; " \
                "#{format(Isolation::MergeCoordinator::Spawner::BY_HAND, branch:)}")
      end

      def stale_note(home)
        holder = home.drain_lock.holder
        holder.empty? ? "" : " (stale holder line from pid #{holder_pid(holder)})"
      end

      def holder_pid(holder) = holder[/\Apid=(\d+)/, 1].to_i

      def live_holder(home)
        holder = home.drain_lock.holder
        holder unless holder.empty? || !@alive.call(holder_pid(holder))
      end

      def expired?(deadline) = !deadline.nil? && @clock.call >= deadline

      def still_queued(id, timeout) = said(2, "#{id} is still queued after #{timeout}s")

      def told(report, id, branch)
        return said(0, "#{id} landed at #{report.sha}") if report.moved?
        return said(0, "#{id} was already on #{branch}") if report.kind == :nothing_to_do

        said(1, ["#{id} did not land: #{report.kind}", report.summary].reject(&:empty?).join("\n"))
      end

      def said(status, line)
        @sink.puts(line)
        status
      end

      def queue_lines(pending, branch)
        return ["nothing queued for #{branch}"] if pending.empty?

        ["#{pending.size} queued for #{branch}:",
         *pending.map { |entry| "  #{entry.id} #{entry.worker.id} #{entry.worker.sha[0, 12]}" }]
      end

      # Never a try on the lock: a drainer starting while status held it would
      # fail its own try and leave its entry for the next enqueue. So a
      # holder line is believed when its pid is alive, since one killed with
      # SIGKILL never empties it. The line is written when the lock is taken
      # and emptied when it is let go, so while it names a holder the file's
      # mtime is when that holder took it.
      def holder_line(home)
        holder = home.drain_lock.holder
        return "no drainer running" if holder.empty?

        pid = holder_pid(holder)
        return "no drainer running; a stale holder line from pid #{pid} was left" unless @alive.call(pid)

        held = [(@wall_clock.call - File.mtime(File.join(home.dir, "drain.lock"))).to_i, 0].max
        "drain lock held by #{holder} for #{held}s"
      end
    end
  end
end
