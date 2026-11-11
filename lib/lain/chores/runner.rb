# frozen_string_literal: true

require "rbconfig"

module Lain
  module Chores
    # Drains the chore file one item at a time: claim it, cut a lease for it,
    # run a headless `lain chat` inside the lease, land what it committed, and
    # write the answer back into the item's line and onto the feed.
    #
    # A lease is kept, unreleased, whenever a commit is waiting on a human: a
    # landing that failed, timed out, found no drainer or was refused. Every
    # other end releases it, and the backend keeps one holding uncommitted work.
    class Runner
      include Enumerable

      KILL_AFTER = 10
      POLL = 0.1
      SOURCE = "lain"
      WAITS = { 1 => "not landed", 2 => "wait timed out", 3 => "no drainer" }.freeze
      INTERRUPTED = 130
      UNREADABLE = "cannot read the lease's HEAD, so nothing is landed from it"

      # @param queue [Queue] the chore file
      # @param backend [#acquire] cuts a lease per item, as {CLI::IsolationBackend.resolve} answers
      # @param lain [String] the `exe/lain` the chat runs from
      # @param land [#call] a lease path to the {CLI::Land} that lands from it
      # @param notices [#call] the feed, {Notices::Feed} or {Notices::Null}
      # @param paths [Paths] where a chat in a lease files its session
      # @param max_cost [Numeric] the chat's --max-cost, in dollars
      # @param chat_timeout [Numeric] seconds before a chat is killed
      # @param wait_timeout [Numeric] seconds to wait on a landing
      # @param spawner [#call] starts the chat, with Process.spawn's arguments
      def initialize(queue:, backend:, lain:, land:, notices:, paths:, max_cost:, chat_timeout: 3600,
                     wait_timeout: 1800, spawner: Process.method(:spawn))
        @queue = queue
        @backend = backend
        @lain = lain
        @land = land
        @notices = notices
        @paths = paths
        @max_cost = max_cost
        @chat_timeout = chat_timeout
        @wait_timeout = wait_timeout
        @spawner = spawner
      end

      # @yieldparam outcome [Outcome] one per item taken, until no item is open
      # @return [Enumerator, nil]
      # @raise [Interrupt] when a landing wait was interrupted; the item stays claimed
      def each
        return enum_for(:each) unless block_given?

        while (item = next_claim)
          yield finished(attempt(item))
        end
      end

      private

      def next_claim = @queue.open.lazy.filter_map { |item| claimed(item) }.first

      def claimed(item)
        @queue.claim(item)
      rescue Queue::Taken
        nil
      end

      def finished(outcome)
        @queue.finish(outcome.item, outcome: outcome.finished, note: outcome.summary)
        @notices.call(SOURCE, outcome.item.text, outcome.body)
        outcome
      end

      def attempt(item)
        lease = @backend.acquire(item.id)
        status, session = chat(item, lease.origin.path)
        after_chat(item, lease, status, session)
      end

      def after_chat(item, lease, status, session)
        return released(lease, failed(item, session, chat_failure(status))) unless status&.success?
        return released(lease, Outcome.new(item:, status: :researched, session:, sha: nil, note: "researched")) if
          item.tag == Brief::RESEARCH

        head = head_of(lease)
        return released(lease, failed(item, session, UNREADABLE)) if head.nil?
        return released(lease, failed(item, session, "no commit")) if head == lease.origin.base

        landed(item, lease, session, head)
      end

      def head_of(lease)
        Isolation::Checkout.of(lease.origin.path).target("HEAD")
      rescue Isolation::Checkout::Failed
        nil
      end

      def landed(item, lease, session, head)
        waited, refusal = waited_on(item, lease.origin.path)
        return failed(item, session, refusal, sha: head) if refusal
        raise Interrupt if waited == INTERRUPTED
        return failed(item, session, WAITS.fetch(waited), sha: head) unless waited.zero?

        released(lease, Outcome.new(item:, status: :landed, session:, sha: head, note: "landed"))
      end

      # @return [Array(Integer, nil), Array(nil, String)] the wait's answer, or the refusal's message
      def waited_on(item, path)
        lander = @land.call(path)
        [lander.wait(lander.queued("HEAD", id: item.id).id, timeout: @wait_timeout), nil]
      rescue Error => e
        [nil, e.message]
      end

      def failed(item, session, note, sha: nil)
        Outcome.new(item:, status: :failed, session:, sha:, note:)
      end

      def chat_failure(status)
        return "timed out" unless status

        status.exitstatus ? "chat exited #{status.exitstatus}" : "chat killed by signal #{status.termsig}"
      end

      # A release that fails keeps the outcome, so landed work is never claimed again and re-run.
      def released(lease, outcome)
        lease.release
        outcome
      rescue Error => e
        outcome.with(note: "#{outcome.note}; release failed: #{e.message}")
      end

      # @return [Array(Process::Status, String), Array(nil, String)] how the chat exited, nil when it
      #   was killed for running too long, and the session it filed, nil when it filed none
      def chat(item, path)
        before = sessions(path)
        [ran(@spawner.call(*argv(item, path), pgroup: true, chdir: path, in: File::NULL, out: File::NULL,
                                              err: File::NULL)),
         (sessions(path) - before).max_by { |session| File.mtime(session) }]
      end

      # Whatever unwinds the runner first stops the chat, so it never spends on with nobody reading it.
      def ran(pid)
        status = reaped(pid, deadline(@chat_timeout))
        status || stopped(pid)
      ensure
        stopped(pid) unless status || reaped?(pid)
      end

      def argv(item, path)
        [RbConfig.ruby, @lain, "chat", "--root", path, "--cwd", path, "--non-interactive", "--approval", "auto",
         "--max-cost", @max_cost.to_s, "--confirm-price-tier", "refuse", "--prompt", Brief.for(item)]
      end

      def stopped(pid)
        group.terminate(pid, reaper: -> { reaped(pid, 0) })
        reaped(pid, deadline(POLL))
        nil
      end

      def group = Shell::ProcessGroup.new(clock: RunClock::MONOTONIC, grace: KILL_AFTER, poll: POLL)

      def reaped?(pid)
        !Process.wait2(pid, Process::WNOHANG).nil?
      rescue Errno::ECHILD
        true
      end

      def reaped(pid, deadline)
        status = Process.wait2(pid, Process::WNOHANG)&.last
        until status || now >= deadline
          sleep(POLL)
          status = Process.wait2(pid, Process::WNOHANG)&.last
        end
        status
      rescue Errno::ECHILD
        nil
      end

      def deadline(seconds) = now + seconds

      def now = RunClock::MONOTONIC.call

      # A retried item reuses its lease's path, so the directory can hold an earlier run's session.
      def sessions(path) = Dir.glob(File.join(@paths.filing_dir(root: path), "*.ndjson"))
    end
  end
end
