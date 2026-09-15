# frozen_string_literal: true

require "open3"

module Lain
  module Shell
    # Runs a TERM -- `[["grep", "-r", "foo", "."], ["wc", "-l"]]` -- and never a
    # string. This is the half of the triage layer that makes {Shell::Verdict}'s
    # allow sound: no shell is asked to interpret the model's bytes, so a
    # parser/shell disagreement degrades to a broken command instead of an
    # attacker-chosen one. `time { echo PWNED; }` is the measured case -- under
    # `sh -c` it prints PWNED, and as the argv the parser reconstructs it cannot.
    #
    # "No shell" is a claim about the COMMAND STRING, and it is worth stating
    # that precisely, because one path does reach `/bin/sh`: `execvp` falls back
    # to it on ENOEXEC, so naming an executable file with no shebang runs that
    # FILE under a shell. Both arms do this identically -- it is `execvp`'s
    # behaviour, not this object's -- and the shell still never sees the model's
    # command string, only a path already resolved. The property survives; the
    # absolute does not.
    #
    # The string arm runs here too, as the one-stage term `["/bin/sh", "-c", command]`
    # that {Exec::Local} builds from the model's own string, so one runner owns
    # the session, the kill, the capture and the child's stdin for both
    # arms. Whether a shell reads the model's bytes is therefore decided by the
    # term a caller hands over, never here -- and an allow's term cannot name
    # `sh`, which {Verdict} abstains on by name.
    #
    # There is deliberately NO path from here back to a string. A caller that
    # holds an allow holds a term and nothing else ({Verdict::Decision} does not
    # carry the source), and this object never falls back to `sh -c` when a term
    # will not run -- a fallback would hand the shell exactly the command the
    # term path was chosen to keep away from it.
    #
    # == Every stage reaches exec as argv, including the one-word ones
    #
    # `Process.spawn("ls")` is not `exec("ls")`: a lone String argument gets
    # re-split on whitespace, and one holding a metacharacter goes through
    # `/bin/sh` outright. Every stage is therefore spawned in the
    # `[program, argv0]` form, which cannot do either, and reaches its own
    # program as argv through {SETSID}. `[["echo hi"]]` looks for a program
    # literally named `echo hi` and fails, which is the correct answer.
    #
    # == The predicate downstream of a pipe, and why it defaults to refusing
    #
    # Pipeline safety is not the conjunction of per-stage safety
    # (planning/tool-use-algebra.md §6 "The trap, and the law that matters"). A
    # pipe opens a SECOND channel: stdin now carries bytes the previous stage
    # chose. `sh`, `ruby` and `psql` are ordinary programs with fixed argv and
    # become an execution primitive the moment something upstream writes their
    # input. So a stage after a pipe must be ON {STDIN_SAFE}; membership is not
    # the absence of a denylist entry. The first stage is not judged here at all
    # -- its stdin is `/dev/null`, and what its PROGRAM may do is {Verdict}'s
    # question, not this object's.
    #
    # == Refusals are shaped like a shell's, not like an exception
    #
    # Nothing to run, a NUL byte, an unresolvable program, a missing cwd, a stage
    # refused downstream: each comes back as a capture carrying a non-zero
    # status and one line on stderr, because the consumer is a model reading tool
    # output and a second result shape would only be a second thing to handle. A
    # timeout is the one exception, and it is an exception because the caller has
    # to distinguish "the tool could not produce a result" from "the command
    # exited non-zero" -- which is exactly the distinction {Tools::Bash} already
    # draws between an error result and a rendered exit status.
    #
    # == One divergence from `sh -c`, measured and deliberate
    #
    # A shell BUILTIN with no binary on disk -- `exit`, `cd`, `export`, `unset` --
    # is `command not found` here, where `sh -c "exit 3"` exits 3. There is no
    # honest way to close that gap: implementing builtins would make this a shell,
    # and re-running the string would surrender the property the term path exists
    # for. Everything else in the accepted subset renders byte-identically
    # through {Tools::Bash.render_output}, and there is a spec.
    class Pipeline
      # The command outlived its deadline and its process groups were killed.
      # Carries the capture's report of what the command said before it died.
      class Timeout < Lain::Error; end

      # This host cannot start a command in a session of its own, so no command
      # is run at all: raised when the runner is built, not once per command.
      class SessionUnavailable < Lain::Error; end

      # A reason not to run, and the status a shell would report it under.
      Refusal = Data.define(:status, :message)

      # THE GENERATING RULE, and it is about STDIN and nothing else: bytes
      # arriving on stdin may influence only what the stage writes to its own
      # standard streams. They may not make it execute a program, and they may
      # not NAME anything -- a file, a host, a program -- that it then acts on.
      #
      # What the rule deliberately does NOT cover is what a stage's own ARGV can
      # ask for. `sort -o FILE` writes a file, and it stays on this list, because
      # the path came from argv and `curl -o FILE` reaches exactly the same place
      # as a single stage with no pipe at all. Judging argv is {Verdict}'s job
      # and the tier-3 premise of the whole tool; adding it here would buy
      # nothing and blur the one question this predicate answers. `patch` is
      # excluded BY the rule -- the diff on its stdin names the files it edits.
      # `tee` is excluded by a step of caution the rule does not compel: its
      # paths come from argv, so the rule admits it, and a bare `tee` mid-term is
      # rare enough that the strict answer costs nothing.
      #
      # An ALLOWLIST, because "I have no evidence this is safe under
      # attacker-chosen stdin" is the honest reading of an absence. Membership
      # therefore requires having READ the program's flags, not having recognised
      # its name: `rg` sat here until `echo hi | rg --pre=id foo` was measured
      # executing `id` -- the `time` defect, self-inflicted. Hand-maintained and
      # incomplete, in the direction that costs a refusal rather than an
      # execution.
      #
      # `sh`, `ruby`, `python`, `awk`, `sed` and `psql` are the case this list
      # exists for. They are also on {Verdict}'s name denylist and so abstain
      # before reaching here -- this list does not depend on that.
      STDIN_SAFE = %w[
        cat tac head tail sort uniq wc cut tr nl rev fold expand unexpand
        column comm paste join pr shuf strings
        grep egrep fgrep
        base32 base64 od xxd hexdump cksum
        md5sum sha1sum sha224sum sha256sum sha384sum sha512sum
        gzip gunzip zcat bzip2 bunzip2 xz unxz zstd
        diff jq
      ].freeze

      # The two statuses a shell uses for a command it declined to run, borrowed
      # so a model reading the output reads something it already knows.
      NOT_FOUND = 127
      NOT_PERMITTED = 126

      # What a shell reports when it cannot enter its cwd. Refusing up front
      # answers with it rather than raising out of `spawn`.
      CHDIR_FAILED = 1

      # What starts every stage in a session of its own. Ruby's `spawn` has no
      # session option, and `pgroup:` alone leaves a stage on lain's controlling
      # terminal: a command opening /dev/tty then writes into the chat pane and
      # stops on a read until its deadline, where in a new session the open fails
      # at once. Spawned WITHOUT `pgroup:`, so it is not a group leader and calls
      # `setsid()` itself rather than forking -- the session, its group and the
      # stage then share one pid, which is what the kill signals. Absolute, so a
      # child PATH the caller curated cannot lose it; util-linux, and Linux only.
      SETSID = "/usr/bin/setsid"

      # How often a running command is asked whether its stages have exited,
      # while a pipe it left open still has nothing to read.
      POLL = 0.05

      # Once every stage has exited, everything they wrote is already queued in
      # the pipes and is taken first, without waiting; this long is then allowed
      # for more from a background child still holding a pipe open, which past
      # it is its own business, neither waited on nor killed.
      DRAIN = 0.1

      # Linux's ioctl for how many bytes a pipe holds right now. The queue is
      # measured rather than read until empty, so a background child that keeps
      # writing cannot hold the drain open.
      FIONREAD = 0x541B

      # What `IO.select` answers with when nothing became readable in time.
      NOTHING_READY = [[].freeze].freeze

      # A killed stage has no exit status; a shell reports 128 + the signal.
      SIGNAL_BASE = 128

      # One `read(2)` per ready stream. Large enough that a chatty command does
      # not turn into thousands of channel events, small enough to stay live.
      CHUNK = 65_536

      # Seconds between TERM and KILL. Injectable, because a spec that has to wait
      # it out pays for it in wall clock.
      DEFAULT_GRACE = 3.0

      # Everything a refusal writes is prefixed as a shell prefixes its own name,
      # so the line reads as coming from lain rather than from the program.
      PREFIX = "lain: "

      # What the backstop below says, and it says it because the alternative is
      # a lie. `spawn` raises in the PARENT, per stage, in order -- so by the
      # time it raises, every earlier stage is already running and detached, and
      # its side effects have happened. Measured: unlinking stage 2's binary
      # inside the pre-flight/spawn window produced `command not found` while
      # stage 1's `touch` had already created its file. Two consequences ride
      # here rather than in a comment nobody reads: the exit status cannot be
      # read as "nothing ran", and Open3's own ensure never fires on this path,
      # so its inter-stage pipes are closed by the GC rather than promptly.
      PARTIALLY_STARTED = "a stage could not be started, and an earlier stage may already have run"

      # @param grace [Numeric] seconds between TERM and KILL
      # @param clock [#call] the monotonic seconds deadlines are measured on
      # @param setsid [String] the {SETSID} every stage is started through,
      #   checked here so a host without one fails once and by name
      # @raise [SessionUnavailable] when it is not an executable file
      def initialize(grace: DEFAULT_GRACE, clock: RunClock::MONOTONIC, setsid: SETSID)
        unless File.file?(setsid) && File.executable?(setsid)
          raise SessionUnavailable, "#{setsid} is not an executable file, and every tool command starts through " \
                                    "it: it gives the command a session of its own, so the command never shares " \
                                    "lain's terminal -- install util-linux, which provides it"
        end

        @grace = grace
        @clock = clock
        @setsid = setsid
        freeze
      end

      # @param term [Array<Array<String>>] argv arrays, joined by pipes and by
      #   nothing else -- the shape {Verdict::Decision#term} hands over.
      # @param cwd [String] already resolved by the caller ({WorkerEnv#resolve})
      # @param env [Hash] overrides applied ONTO the inherited environment, with
      #   a nil value scrubbing a key -- the {WorkerEnv} contract, which `spawn`
      #   implements natively.
      # @param timeout [Numeric] seconds before the process groups are killed
      # @param capture [Exec::Capture::Bounded] what each stage's bytes are
      #   taken into as they arrive, and where a refusal's own line is written
      #   when the term never runs at all. The caller's, so what a run holds is
      #   bounded by what the caller chose to retain.
      # @return [Exec::Capture] for every TERM, including every one that cannot run --
      #   which is the totality that matters, because a term is built from a
      #   {Tool::Input} the model wrote. NOT for every OBJECT: a term that is not
      #   an Array of Arrays (a bare String, nil) raises `NoMethodError`, loudly,
      #   because that is a caller's bug rather than a model's input.
      # @raise [Timeout] when the deadline passes, after the groups are killed
      # @raise [StandardError] whatever a caller's sink raises mid-pump, after
      #   the groups are killed -- see {Run#collect}
      def call(term, cwd:, env:, timeout:, capture:)
        refusals = Refusals.new(term:, cwd:, env:).causes
        return refuse(refusals.first, capture) unless refusals.empty?

        Run.new(term:, cwd:, env:, timeout:, grace: @grace, clock: @clock, setsid: @setsid, capture:).call
      rescue SystemCallError, ArgumentError => e
        refuse(Refusal.new(status: NOT_FOUND, message: "#{PARTIALLY_STARTED}: #{e.class}: #{e.message}"), capture)
      end

      private

      def refuse(refusal, capture)
        capture.take(:stderr, "#{PREFIX}#{refusal.message}\n").finish(refusal.status)
      end

      # Why a term will not be run, asked before anything is spawned. Up front
      # because `Open3` spawns each stage from the PARENT in sequence: an ENOENT
      # on stage two raises only after stage one is already running and detached,
      # so a late refusal is a leaked process as well as a raise.
      #
      # Separate from {Pipeline} for the same reason {Verdict::Doubts} is
      # separate from {Verdict}: this reads one term for everything wrong with
      # it, and Pipeline owns running one that is not.
      class Refusals
        NUL = "\0"

        TIERS = %i[foreign_words nothing_to_run nul_arguments missing_cwd refused_downstream unresolvable].freeze

        def initialize(term:, cwd:, env:)
          @term = term
          @cwd = cwd
          @env = env
          freeze
        end

        # First tier with something to say wins, so the line names the reader's
        # nearest cause. Ordered by how early it makes the term unrunnable.
        #
        # LAZY, where {Verdict::Doubts}'s equivalent is eager, for two reasons
        # the pure version does not have: these tiers stat the filesystem, and
        # the later ones read an argv the earlier ones have not yet vouched for
        # -- `unresolvable` asking `[[]]` for its program finds nothing there.
        def causes
          TIERS.lazy.map { |tier| send(tier) }.find { |tier| !tier.empty? } || []
        end

        private

        # A term's words are Strings, and refusing anything else is DELIBERATE
        # rather than incidental. An Integer or a Symbol would merely crash, but
        # a Hash as a stage's last element is worse: Open3 does
        # `cmd_opts.update cmd.pop if Hash === cmd.last`, so it would become
        # arbitrary SPAWN OPTIONS -- another `chdir`, another `in`, an fd
        # redirection. Nothing but `nul_arguments` reaching for `#b` and getting
        # a NoMethodError stood between that and `spawn`, which is defence by
        # accident. This is the same defence on purpose, which is why it runs
        # first.
        def foreign_words
          offenders = words.grep_v(String)
          offenders.empty? ? [] : [not_found("#{offenders.first.inspect}: argument is not a String")]
        end

        def nothing_to_run
          return [] unless @term.empty? || @term.any? { |argv| argv.empty? || argv.any?(&:empty?) }

          [not_found("there is no command to run")]
        end

        # A NUL parses CLEAN into an ordinary word (`parse.rb:86`) and `exec`
        # answers it with an ArgumentError, so it reaches this object from any
        # tool call and must not raise out of one.
        def nul_arguments
          offenders = words.select { |word| word.b.include?(NUL) }
          offenders.empty? ? [] : [not_found("#{offenders.first.b.delete(NUL).inspect}: argument contains a NUL byte")]
        end

        def missing_cwd
          return [] if File.directory?(@cwd)

          [Refusal.new(status: CHDIR_FAILED, message: "cannot enter #{@cwd}: no such directory")]
        end

        # Bare names only. A basename match would accept `/tmp/sort`, which is
        # the attacker's spelling of a name on the list; requiring the bare word
        # costs a legitimate caller an absolute path and buys the whole check.
        def refused_downstream
          offenders = @term.drop(1).map(&:first).reject { |program| STDIN_SAFE.include?(program) }
          return [] if offenders.empty?

          [Refusal.new(status: NOT_PERMITTED,
                       message: "#{offenders.first}: not permitted downstream of a pipe")]
        end

        # Advisory, not a security check -- `exec` remains the authority and the
        # window between the two is real. Its job is to keep a doomed stage from
        # being discovered halfway through spawning a pipeline.
        def unresolvable
          offenders = @term.map(&:first).reject { |program| resolvable?(program) }
          offenders.empty? ? [] : [not_found("#{offenders.first}: command not found")]
        end

        # Against the TERM's cwd, not the process's: `./build.sh` is a program
        # the child resolves after its chdir, and asking `Dir.pwd` about it would
        # refuse a legitimate call whenever a WorkerEnv names a different
        # directory -- which is the whole point of a WorkerEnv.
        def resolvable?(program)
          return executable?(program) if program.include?(File::SEPARATOR)

          search_path.any? { |dir| executable?(File.join(dir, program)) }
        end

        def executable?(path)
          absolute = File.expand_path(path, @cwd)
          File.file?(absolute) && File.executable?(absolute)
        end

        # The child's PATH, which is the override's when it names one. An EMPTY
        # element means the current directory to a shell; it is dropped here,
        # which refuses rather than resolves -- the strict direction.
        def search_path
          raw = @env.key?("PATH") ? @env["PATH"] : ENV.fetch("PATH", "")
          raw.to_s.split(File::PATH_SEPARATOR).reject(&:empty?)
        end

        # One level only: a nested Array must stay VISIBLE to {#foreign_words}
        # rather than be flattened into the words it holds.
        def words = @term.flatten(1)

        def not_found(message) = Refusal.new(status: NOT_FOUND, message:)
      end

      # One execution: the spawn, the pump, the kill, filling a capture as bytes
      # arrive -- which is why it is a per-call object and {Pipeline} itself is
      # frozen.
      class Run
        def initialize(term:, cwd:, env:, timeout:, grace:, clock:, setsid:, capture:)
          @term = term
          @cwd = cwd
          @env = env
          @timeout = timeout
          @grace = grace
          @clock = clock
          @setsid = setsid
          @capture = capture
        end

        # Every stage's stderr shares ONE pipe, as `sh -c "a | b"` gives them one
        # terminal. Open3 applies a pipeline-level `:in` to the first command
        # only and everything else to all of them, which is exactly the split
        # this needs.
        def call
          err_read, err_write = IO.pipe
          Open3.pipeline_r(*commands, options(err_write)) do |out, threads|
            err_write.close
            collect({ out => :stdout, err_read => :stderr }, threads)
            @capture.finish(exit_status(threads))
          end
        ensure
          [err_read, err_write].each { |io| io.close unless io.nil? || io.closed? }
        end

        private

        # `[program, argv0]` rather than a bare String: see the class comment on
        # why a one-word stage would otherwise be re-split. `setsid` hands the
        # program to `execvp` as its own argv, so the stage is still never
        # re-split, and `--` keeps a program named like an option from being read
        # as one.
        def commands
          @term.map { |argv| [@env, [@setsid, "setsid"], "--", *argv] }
        end

        # Each stage leads its own session, and so its own group ({SETSID}),
        # which is what lets a timeout kill the command's own descendants rather
        # than just the stage. `in:` is `/dev/null` because the first stage would
        # otherwise inherit lain's stdin and read the human's keystrokes, and
        # `crates/lain-core/src/exec.rs:202` sets `Stdio::null()`, so every arm
        # agrees. The redirect happens in the spawned child at the descriptor, so
        # nothing reopens this process's own stdin, whose offset a regular file
        # shares with every child holding it. `close_others:` because a
        # descriptor this process holds without close-on-exec -- inherited from
        # whatever launched lain, or opened by native code -- would otherwise
        # reach every command, and a leaked pipe end keeps a reader from EOF.
        def options(err_write)
          { in: File::NULL, err: err_write, chdir: @cwd, unsetenv_others: false, close_others: true }
        end

        # EVERY raise kills first, not just a Timeout. A sink is the caller's
        # object -- `Sink::IOAdapter` over a channel a detached frontend has
        # closed raises IOError mid-pump -- and letting that escape means
        # Open3's ensure joins wait threads with NO deadline, so a 2-second
        # timeout was measured still blocked at 8 seconds on a 30-second stage.
        # The kill has to happen INSIDE the block for the same reason.
        def collect(streams, threads)
          pump(streams, threads)
        rescue Timeout
          terminate(threads)
          raise Timeout, @capture.report
        rescue StandardError
          terminate(threads)
          raise
        end

        # The command is over when every stage has exited, not when every pipe
        # has closed: a child a stage put in the background can hold a pipe open
        # for as long as it likes. Pipes that closed first leave only the exits
        # to wait for, under the same deadline.
        def pump(streams, threads)
          deadline = clock + @timeout
          open = streams.keys
          open = read_ready(open, streams, ready(open, deadline)) until open.empty? || threads.none?(&:alive?)
          open.empty? ? reap(threads, deadline) : drain(open, streams)
        end

        def ready(open, deadline)
          remaining = deadline - clock
          raise Timeout unless remaining.positive?

          readable(open, remaining.clamp(0, POLL))
        end

        def drain(open, streams)
          open.each { |io| take_queued(io, streams.fetch(io)) }
          window = clock + DRAIN
          while open.any? && clock < window
            open = read_ready(open, streams, readable(open, (window - clock).clamp(0, DRAIN)))
          end
        end

        def take_queued(io, stream)
          remaining = queued(io)
          remaining -= take_now(io, stream, remaining) while remaining.positive?
        end

        # At most `most` bytes, never blocking; nothing to read, or EOF, ends the
        # take by answering for all of it.
        def take_now(io, stream, most)
          chunk = io.read_nonblock(most.clamp(1, CHUNK), exception: false)
          return most unless chunk.is_a?(String)

          @capture.take(stream, chunk)
          chunk.bytesize
        end

        def queued(io)
          count = [0].pack("i")
          io.ioctl(FIONREAD, count)
          count.unpack1("i")
        end

        def reap(threads, deadline)
          threads.each { |thread| thread.join((deadline - clock).clamp(0, @timeout)) }
          raise Timeout if threads.any?(&:alive?)
        end

        def readable(open, seconds) = (IO.select(open, nil, nil, seconds) || NOTHING_READY).first

        def read_ready(open, streams, ready)
          finished = ready.select { |io| read_chunk(io, streams.fetch(io)).nil? }
          open - finished
        end

        def read_chunk(io, stream)
          chunk = io.readpartial(CHUNK)
          @capture.take(stream, chunk)
          chunk
        rescue EOFError
          nil
        end

        # One grace for every stage together, ending early once no stage's group
        # has a member left. The KILL then goes to every group whatever became
        # of its leader: a leader that died on TERM says nothing about a child in
        # its group that ignores it.
        def terminate(threads)
          signal(threads, "TERM")
          grace_ends = clock + @grace
          sleep(POLL) while clock < grace_ends && threads.any? { |thread| populated?(thread.pid) }
          signal(threads, "KILL")
        end

        def populated?(group)
          Process.kill(0, -group)
          true
        rescue Errno::ESRCH, Errno::EPERM
          false
        end

        def signal(threads, name)
          threads.each do |thread|
            Process.kill(name, -thread.pid)
          rescue Errno::ESRCH, Errno::EPERM
            nil # already empty, or no longer ours to signal
          end
        end

        # The LAST stage's status, because `pipefail` is off in an unadorned
        # shell and the string arm reports what the shell reports.
        def exit_status(threads)
          status = threads.map(&:value).last
          status.exitstatus || (SIGNAL_BASE + status.termsig)
        end

        def clock = @clock.call
      end

      private_constant :Refusals, :Run
    end
  end
end
