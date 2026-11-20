# frozen_string_literal: true

require "fileutils"
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

      # How a chat ended: its status, nil when it was killed for running too long, and the last line
      # it wrote to stderr.
      Exit = Data.define(:status, :why) do
        def success? = !status.nil? && status.success?

        # @return [String] what the item's line says, with the stderr line when the chat printed one
        def failure
          return "timed out" unless status

          how = status.exitstatus ? "chat exited #{status.exitstatus}" : "chat killed by signal #{status.termsig}"
          why.empty? ? how : "#{how}: #{why}"
        end
      end

      KILL_AFTER = 10
      POLL = 0.1
      SOURCE = "lain"
      WAITS = { 1 => "not landed", 2 => "wait timed out", 3 => "no drainer" }.freeze
      INTERRUPTED = 130
      WHY_CHARS = 300
      LOG_BYTES = 1 << 20
      CHUNK = 1 << 16
      DRAIN = 2
      READS_PER_DRAIN = 16
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
      # @param logs [String] an existing directory only the owner can enter, where each chore's stderr log is kept
      # @param secrets [#to_a] values masked wherever the chat's stderr holds them
      def initialize(queue:, backend:, lain:, land:, notices:, paths:, logs:, max_cost:, chat_timeout: 3600,
                     wait_timeout: 1800, spawner: Process.method(:spawn),
                     secrets: Sensitivity::Secrets::Source::DEFAULT)
        @queue = queue
        @backend = backend
        @lain = lain
        @land = land
        @notices = notices
        @paths = paths
        @logs = logs
        @max_cost = max_cost
        @chat_timeout = chat_timeout
        @wait_timeout = wait_timeout
        @spawner = spawner
        @secrets = secrets
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

      # Reads a chat's stderr from a pipe and keeps only masked text: in the log, in the last line, and in
      # memory. The masking is {Sensitivity::TextMask::Stream}'s, so a line or key block is shown once whole,
      # or in pieces past its caps; a grandchild that outlives the chat and writes after the pipe is closed
      # gets EPIPE and loses that output. Nothing here blocks, so the runner's own wait loop pumps it.
      class Tail
        # @return [String] the last non-empty masked line, cut short
        attr_reader :last_line

        # @param source [IO] the read end of the chat's stderr
        # @param log [String] the file the masked text is written to, readable by its owner only
        # @param secrets [Array<String>] values masked wherever the output holds them
        def initialize(source, log:, secrets:)
          @source = source
          FileUtils.rm_f(log)
          @file = File.open(log, File::WRONLY | File::CREAT | File::EXCL, 0o600)
          @file.sync = true
          @log = log
          @stream = Sensitivity::TextMask.new(secrets:).stream
          @last_line = ""
          @carry = "".b
          @kept = []
          @kept_bytes = 0
          @written = 0
          @cut = false
          @open = true
        end

        # Reads what is there, up to {READS_PER_DRAIN} chunks, so a flood cannot hold the wait loop.
        #
        # @param wait [Numeric] the longest to wait for the first chunk
        # @return [void]
        def drain(wait)
          return sleep(wait) unless @open

          reads = 0
          reads += 1 while reads < READS_PER_DRAIN && read_chunk?(reads.zero? ? wait : 0)
        rescue IOError
          @open = false
        end

        # Reads until every writer has closed or a grandchild holding the pipe has had {DRAIN} seconds.
        #
        # @return [Tail] self, with the log closed and its cut, if any, said
        def finish
          deadline = RunClock::MONOTONIC.call + DRAIN
          drain(0.05) while @open && RunClock::MONOTONIC.call < deadline
          emit(@stream << @carry)
          emit(@stream.finish)
          close
          File.write(@log, "[stderr cut: only the last #{@kept_bytes} bytes are kept]\n#{@kept.join}") if @cut
          self
        end

        # @return [void]
        def close
          @file.close unless @file.closed?
        end

        private

        def read_chunk?(wait)
          return false unless @source.wait_readable(wait)

          chunk = @source.read_nonblock(CHUNK, exception: false)
          return @open = false if chunk.nil?

          emit(@stream << whole(chunk)) if chunk.is_a?(String)
          true
        end

        # A read can end inside a character, and the stream's UTF-8 scrub would turn the split halves into U+FFFD.
        def whole(chunk)
          bytes = @carry + chunk.b
          held = incomplete_tail(bytes)
          @carry = bytes.byteslice(bytes.bytesize - held, held)
          bytes.byteslice(0, bytes.bytesize - held)
        end

        def incomplete_tail(bytes)
          back = (1..[3, bytes.bytesize].min).find { bytes.getbyte(-_1) & 0xC0 != 0x80 }
          lead = back && bytes.getbyte(-back)
          lead && lead >= 0xC0 && utf8_width(lead) > back ? back : 0
        end

        def utf8_width(lead)
          case lead
          when 0xF0.. then 4
          when 0xE0.. then 3
          else 2
          end
        end

        def emit(masked)
          masked = masked.scrub
          lines = masked.lines
          remember(masked)
          keep(lines)
          write(lines.join)
        end

        def write(text)
          room = LOG_BYTES - @written
          return unless room.positive?

          kept = text.byteslice(0, room)
          @file.write(kept)
          @written += kept.bytesize
        end

        def remember(masked)
          segments = masked.split(/[\r\n]/).map { _1.gsub(/[[:cntrl:]]/, "").strip }
          found = segments.reverse_each.find { !_1.empty? }
          @last_line = found[0, WHY_CHARS] if found
        end

        def keep(lines)
          lines.each do |line|
            @kept << line
            @kept_bytes += line.bytesize
          end
          return unless @kept_bytes > LOG_BYTES

          @cut = true
          @kept_bytes -= @kept.shift.bytesize while @kept_bytes > LOG_BYTES
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
        ran, session = chat(item, lease.origin.path)
        after_chat(item, lease, ran, session)
      end

      # Judged by what the chat committed, not how it exited: a chat stopped at its ceiling after
      # committing has still done the work.
      def after_chat(item, lease, ran, session)
        head = head_of(lease)
        return released(lease, failed(item, session, ended(UNREADABLE, ran))) if head.nil?
        return released(lease, unmoved(item, ran, session)) if head == lease.origin.base

        landed(item, lease, session, head, ran)
      end

      def unmoved(item, ran, session)
        return failed(item, session, ran.failure) unless ran.success?
        return Outcome.new(item:, status: :researched, session:, sha: nil, note: "researched") if research?(item)

        failed(item, session, "no commit")
      end

      def head_of(lease)
        Isolation::Checkout.of(lease.origin.path).target("HEAD")
      rescue Isolation::Checkout::Failed
        nil
      end

      def landed(item, lease, session, head, ran)
        waited, refusal = waited_on(item, lease.origin.path)
        return failed(item, session, ended(refusal, ran), sha: head) if refusal
        raise Interrupt if waited == INTERRUPTED
        return failed(item, session, ended(WAITS.fetch(waited), ran), sha: head) unless waited.zero?

        done = research?(item) ? :researched : :landed
        released(lease, Outcome.new(item:, status: done, session:, sha: head, note: ended(done.to_s, ran)))
      end

      def research?(item) = item.tag == Brief::RESEARCH

      def ended(note, ran) = ran.success? ? note : "#{note}; #{ran.failure}"

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

      # A release that fails keeps the outcome, so landed work is never claimed again and re-run.
      def released(lease, outcome)
        lease.release
        outcome
      rescue Error => e
        outcome.with(note: "#{outcome.note}; release failed: #{e.message}")
      end

      # @return [Array(Exit, String), Array(Exit, nil)] how the chat ended, and the session it filed,
      #   nil when it filed none
      def chat(item, path)
        before = sessions(path)
        status, why = spawned(item, path)
        [Exit.new(status:, why:), (sessions(path) - before).max_by { |session| File.mtime(session) }]
      end

      # The chat's stderr goes through a pipe so each line is masked before any byte of it is written.
      def spawned(item, path)
        reader, writer = IO.pipe
        tail = Tail.new(reader, log: stderr_log(item), secrets: @secrets.to_a)
        pid = @spawner.call(*argv(item, path), pgroup: true, chdir: path, in: File::NULL, out: File::NULL, err: writer)
        writer.close
        [ran(pid, tail), tail.finish.last_line]
      ensure
        tail&.close
        [writer, reader].compact.each { _1.close unless _1.closed? }
      end

      def stderr_log(item) = File.join(@logs, "#{item.id}.stderr.log")

      # Whatever unwinds the runner first stops the chat, so it never spends on with nobody reading it.
      def ran(pid, tail)
        status = reaped(pid, deadline(@chat_timeout), tail)
        status || stopped(pid, tail)
      ensure
        stopped(pid, tail) unless status || reaped?(pid)
      end

      def argv(item, path)
        [RbConfig.ruby, @lain, "chat", "--root", path, "--cwd", path, "--non-interactive", "--approval", "auto",
         "--max-cost", @max_cost.to_s, "--confirm-price-tier", "refuse", "--prompt", Brief.for(item)]
      end

      def stopped(pid, tail)
        group.terminate(pid, reaper: lambda {
          tail.drain(0)
          reaped(pid, 0, tail)
        })
        reaped(pid, deadline(POLL), tail)
        nil
      end

      def group = Shell::ProcessGroup.new(clock: RunClock::MONOTONIC, grace: KILL_AFTER, poll: POLL)

      def reaped?(pid)
        !Process.wait2(pid, Process::WNOHANG).nil?
      rescue Errno::ECHILD
        true
      end

      def reaped(pid, deadline, tail)
        status = Process.wait2(pid, Process::WNOHANG)&.last
        until status || now >= deadline
          tail.drain(POLL)
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
