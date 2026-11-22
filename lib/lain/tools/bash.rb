# frozen_string_literal: true

module Lain
  module Tools
    # Tier 3 (free-form): runs a shell command via `sh -c`. Handing the backend
    # a STRING command rather than a {Shell::Term} is exactly what makes this tier
    # 3 rather than tier 2 -- a term `exec`s with no shell at all, while a
    # String goes through the shell and the model fully controls that string.
    #
    # == Two arms, chosen by {Shell::Verdict}, and one rendering
    #
    # Every call is offered to the verdict first. It answers *"is this command
    # syntactically literal and fully understood?"* -- never "is it safe" --
    # and it is free to abstain, which most commands do.
    #
    # * *allow* -- {Shell::Pipeline} runs the RECONSTRUCTED ARGV, wherever the
    #   backend has a shape for one. No shell is started, so a disagreement
    #   between that parser and a real shell degrades to a broken command
    #   rather than an attacker-chosen one. A backend that answers
    #   `#takes_term?` with false -- {Exec::Docker} handed a pipe --
    #   is given the model's own string, which is the only arm it ever had for
    #   that command. What still never happens is a term JOINED back into a string: that would hand `sh -c` a command
    #   this tool composed, and the term path exists to keep one away from it.
    #
    #   NAME WHAT THE FALLBACK TRADES AWAY. "No string is composed" and "no
    #   shell sees this command" are different claims, and only the first
    #   survives: a shell DOES read the model's string on that path --
    #   {Exec::Docker} runs it as `["sh", "-c", command]` INSIDE the container
    #   -- so the term arm's no-shell property is gone there, and what carries
    #   safety in its place is containment plus the same gate, never the
    #   absence of a shell.
    # * *anything else* -- the string runs through `sh -c`, under the same gate.
    #
    # Both arms render through {.render_output}, so which one ran is not
    # observable in the tool result. A shell BUILTIN with no binary would be
    # `command not found` on the term arm, which is why {Shell::Verdict}
    # abstains on one and the string arm runs it.
    #
    # Neither arm is run here: both go to an injected {Lain::Exec} backend,
    # which decides the child's environment. This tool owns the CHOICE of arm
    # and the rendering of what came back.
    #
    # A PROCESS BOUNDARY IS NOT A SECURITY BOUNDARY. The child inherits our
    # uid, filesystem and network; {Shell::Pipeline} adds no seccomp, landlock,
    # namespace or chroot confinement of its own. What it DOES make correct:
    # capture, attribution, timeout and reaping -- each stage leads its own
    # session, so it never shares lain's terminal, and a timeout kills its whole
    # group and not just the shell.
    # Real safety is {#requires_approval?} plus a human or policy on the other
    # end of {Middleware::Gate}, and eventually OS confinement in the
    # out-of-process Rust exec boundary. NEVER this tool's input validation,
    # which checks only that `timeout` is a sane number.
    class Bash < Tool
      DEFAULT_TIMEOUT = 120
      # Shell::Verdict::SHELL_BUILTINS omits names that also have a binary, but the shell runs these itself.
      SHELL_RUNS_ITSELF = %w[echo printf test pwd kill true false].freeze
      private_constant :SHELL_RUNS_ITSELF
      MAX_TIMEOUT = 600

      # A command's output is a WHOLE ARTIFACT in {Tool::Bounds}' sense -- its
      # first N bytes read like the answer and are not -- so it is refused over
      # the ceiling rather than truncated. Stdout and stderr count together,
      # because both ride the one result.
      OUTPUT_BOUND = Tool::Bounds::Artifact.new(limit: Tool::Bounds::CEILINGS.fetch("bash"))

      # Both are available to EVERY command, which keeps the refusal from
      # being a dead end: command output is the one artifact the caller shapes
      # before it exists, so `| tail -n 200` is one edit to the command already
      # being written.
      NARROWER = [
        "re-run it with the output narrowed through head, tail or grep",
        "redirect it to a file and read one window of that with read_file"
      ].freeze

      # A timeout's report quotes what the command printed, and the daemon's
      # quotes the command too, so there a long command alone can put it over
      # the ceiling.
      TIMEOUT_NARROWER = [
        "re-run it as a shorter command -- put a long one in a script file and run that",
        "narrow its output through head, tail or grep"
      ].freeze

      # A spill keeps both streams in one file in the order they arrived, so
      # its head is not split into the two sections a whole result has.
      SPILLED_STREAMS = "--- stdout and stderr, as they arrived ---\n"

      # What a timeout reports in place of captured output that was not text.
      TIMEOUT_OUTPUT_NOT_TEXT = "what it printed before then was not valid UTF-8 text, so none of it is " \
                                "recorded -- re-run it with the output narrowed through `| head -c`, " \
                                "`| xxd | head` or `| file -`"

      # How to narrow a stream that was not text, handed the count of its
      # leading bytes that were. Per stream, because `| head -c` acts on stdout
      # and would narrow the stream that was fine; no `head -c 0` when nothing
      # leading was text, since that keeps nothing.
      STREAM_ADVICE = {
        stdout: lambda do |kept|
          [*("keep only the text with `| head -c #{kept}`" if kept.positive?),
           "look at its bytes with `| xxd | head`", "identify it with `| file -`"].join(", or ")
        end,
        stderr: lambda do |_kept|
          "discard stderr with `2>/dev/null`, or look at its bytes with `2>&1 >/dev/null | xxd | head`"
        end
      }.freeze

      # The wire shape: a required command String, plus optional cwd and timeout.
      #
      # `command`'s description is where the two-arm rule is written. It states
      # a capability rather than a rule: the research behind it measured
      # adherence to a stated syntax constraint topping out near two thirds and
      # failing SILENTLY into ordinary shell, so anything phrased as a mandate
      # would be false for a third of calls.
      #
      # THE GENERALISATION IS ITSELF A CLAIM, and it needs measuring exactly
      # like the list of constructs does. An earlier wording named `less` under
      # "runs a program named in its own arguments" -- but `less` belongs to
      # {Shell::Verdict}'s shell-escape family, whose rule is a documented
      # escape INTO a shell, so a model reasoning from the stated rule would
      # conclude `vim README.md` takes the argv path when it does not. Prose
      # that is wrong about its own example is worse than an incomplete list,
      # because the reader cannot detect it. Both arms are named now, and
      # spec/lain/tools/bash_spec.rb re-measures every program this string
      # mentions against the real verdict rather than restating the rule.
      #
      # "More than one line" rather than "no newlines", because a TRAILING one
      # still allows: `"ls -la\n"` reaches allow with the one-stage term `ls -la`.
      class Input < Tool::Input
        field :command, :string, required: true,
                                 description: "Shell command to run. A command whose every stage is a literal " \
                                              "program with literal words, optionally joined by pipes or `&&` -- " \
                                              "`cat README.md | head -20` -- can run as argv with no shell " \
                                              "process anywhere, and does wherever the backend running it takes " \
                                              "argv. So can a stage followed by `2>/dev/null`, by " \
                                              "`&>/dev/null`, or by `>/dev/null` when no pipe follows it. " \
                                              "Everything else goes through `sh -c`: more than one line, " \
                                              "quoting or escaping of any kind, `;`, `||`, `&`, any other " \
                                              "redirection, `$` expansion, globs or `~`, and any program that " \
                                              "can run a program named in its own arguments or that can drop " \
                                              "the user into a shell -- git, tar, rsync, sudo, less, vim, man, " \
                                              "psql, and interpreters such as sh, python or awk. Both forms are " \
                                              "accepted; the simple one is the one that keeps a shell out of " \
                                              "the picture."
        field :cwd, :string, description: "Working directory for the command. Defaults to the current directory."
        field :timeout, :integer,
              description: "Seconds to allow before the command's whole process group is killed -- and, " \
                           "under a container backend, before its container is stopped and removed too, " \
                           "rather than left running behind the killed client. " \
                           "Defaults to #{DEFAULT_TIMEOUT}, max #{MAX_TIMEOUT}."

        validates :timeout, numericality: { greater_than: 0, less_than_or_equal_to: MAX_TIMEOUT }, allow_nil: true
      end

      input_model Input

      # The one place BOTH exec arms turn captures into a {Tool::Result},
      # shared so the differential's byte-identity cannot drift out from under
      # its specs. {OUTPUT_BOUND} is applied HERE for that reason: a ceiling
      # checked per arm would be two ceilings that happen to agree today, and
      # the daemon arm would have a third or none.
      #
      # The exit status rides in the refusal's SUBJECT rather than being
      # dropped, because it is the one fact a truncation would have preserved
      # and the model usually asked the question to learn it.
      #
      # The size is the one the capture COUNTED, which the in-process arm keeps
      # past the bytes it retains, so a 200 MiB flood is refused naming 200 MiB
      # while only a byte past the ceiling of it was ever held.
      #
      # The HUMAN still sees every byte: both arms stream through
      # {Sink::IOAdapter} as output is produced, which is right for a live
      # terminal -- a refusal is about what the MODEL is handed. It does mean
      # the cockpit and the transcript diverge above this ceiling, which matters
      # on a bench whose product is the comparison of the two.
      #
      # Both streams are read through {Tool::ResultBlock::Text} before they are
      # joined. A capture turns ASCII-8BIT at its first high byte, so joining
      # first would raise `Encoding::CompatibilityError` beside a UTF-8 stream
      # and hand a commit bytes it refuses otherwise; asked here, a stream that
      # is not text is refused naming this tool and the stream, where the block
      # builder downstream could name neither.
      #
      # @param capture [Exec::Capture] what ran
      # @return [Tool::Result] ok with the rendered output, or a refusal
      #   carrying none of it
      def self.render_output(capture)
        exit_status = capture.exit_status
        bound = bound_for(capture)
        unless bound.admits?(capture.size)
          return bound.refusal(subject: "the command's output (exit status: #{exit_status})",
                               size: capture.size, narrower: NARROWER)
        end

        streams = { stdout: capture.stdout, stderr: capture.stderr }
                  .transform_values { |bytes| Tool::ResultBlock::Text.new(bytes) }
        refused = streams.reject { |_stream, text| text.text? }
        return refused_stream(*refused.first, exit_status) unless refused.empty?

        Tool::Result.ok("exit status: #{exit_status}\n" \
                        "--- stdout ---\n#{ended_line(streams.fetch(:stdout))}" \
                        "--- stderr ---\n#{streams.fetch(:stderr)}")
      end

      # A token's boundary lookahead needs a following character, so one at the
      # end of stdout would sit against the frame's dash and escape the mask.
      def self.ended_line(text)
        text = text.to_s
        return text if text.empty? || text.end_with?("\n")

        "#{text}\n"
      end
      private_class_method :ended_line

      # The lower of this tool's bound and the capture's own ceiling: a backend
      # that held less than the tool admits must still be refused past what it
      # held, or part of an artifact renders as the whole of it.
      def self.bound_for(capture)
        capture.ceiling < OUTPUT_BOUND.limit ? Tool::Bounds::Artifact.new(limit: capture.ceiling) : OUTPUT_BOUND
      end
      private_class_method :bound_for

      # The exit status rides here for the reason it rides the size refusal.
      def self.refused_stream(stream, text, exit_status)
        text.refusal("bash's #{stream} (exit status: #{exit_status})", advice: STREAM_ADVICE.fetch(stream))
      end
      private_class_method :refused_stream

      # @param exec [#call] the {Lain::Exec} backend a command is run through,
      #   injected so the transport is a run's choice and a spec can substitute
      #   one whose TERM->KILL grace is short
      # @param verdict [#call] `String -> Shell::Verdict::Decision`, the choice
      #   of arm, injected so a spec can pin either arm for one command and
      #   compare their bytes
      # @param journal [#<<] where every call's {Telemetry::ShellArm} record
      #   lands. Null by default, so a tool built with no session around it --
      #   {Subagent} runs an ungated handler, and `bash_spec` constructs this
      #   tool alone -- writes nowhere and no caller guards on nil.
      # @param resolver [#for] names what each stage resolves to before it runs;
      #   the null default resolves every stage unresolved
      # @param spill [Tool::Spill, Tool::Spill::Null] where output over the
      #   ceiling is kept whole; the Null keeps nothing, so such output is refused
      def initialize(exec: Exec::Local.new, verdict: Shell::Verdict.new, journal: Channel::Null.instance,
                     resolver: Shell::Executable::Resolver::NULL, spill: Tool::Spill::Null)
        super()
        @exec = exec
        @verdict = verdict
        @journal = journal
        @resolver = resolver
        @spilled = Tool::Bounds::Spilled.new(limit: OUTPUT_BOUND.limit, spill:)
      end

      def name = "bash"

      # The shape guidance lives on {Input}'s `command` field; what is left here
      # is the one claim this string used to get wrong, that a shell always runs
      # the command.
      #
      # It carries the backend caveat too, rather than leaning on the field to
      # supply it. {#arm_for} asks `takes_term?` before it offers, so an allow
      # is not on its own enough -- {Exec::Docker} refuses a multi-stage term
      # -- and stating the property that is KEPT while omitting the one that is
      # surrendered is exactly the defect this subsystem has already been
      # caught at once.
      def description
        "Runs a shell command and returns its exit status, stdout, and " \
          "stderr. A command that is fully understood runs as argv with no " \
          "shell process at all, wherever the backend running it takes argv; " \
          "`sh -c` runs the rest. The command's whole process group is killed " \
          "if it runs past its timeout, and under a container backend the " \
          "container itself is stopped and removed, not just the client that " \
          "started it."
      end

      # Tier 3: the model fully controls `command`.
      #
      # STAYS TRUE now that a term arm exists, because the flag describes the
      # TOOL and not one call through it -- the tool still takes a string the
      # model wrote. WHICH calls may skip a human is the escalation ladder's
      # question, asked per call and answered from the verdict.
      def requires_approval? = true

      # What this tool makes of an input, offered so a caller that must decide
      # ABOUT a call can read what the call will run on. The approval ladder's
      # rules rung holds this exact object -- it fetches the tool the executor
      # would dispatch -- so the term a rule judges and the term {#perform}
      # hands the backend come from ONE {Shell::Verdict} asked twice, which is
      # frozen and pure, rather than from two whose agreement nothing enforces.
      # The gate's parse may be threaded in, so the term a rule judges comes
      # from the same parse the tool runs on.
      #
      # @param input [Input] a validated input for this tool
      # @param parsed [Shell::Parse::Result, nil] the gate's parse of the command, judged in place of parsing it again
      # @return [Shell::Verdict::Decision] the arm, its reason, and the term
      def decision_for(input, parsed: nil) = decided(input.command, parsed)

      # The words each stage of this call would run as argv, read before the call is approved and without
      # resolving a program, which is the cheap half of {#planned_request}.
      #
      # @param input [Hash] the call's input, as the model sent it
      # @param context [#worker_env, nil] the session the call runs in
      # @return [Array<Array<String>>] none on the string arm
      # @raise [Tool::InvalidInput] when the input does not validate
      def planned_argvs(input, context)
        _, decision = planned(input, context)
        argv_on(arm_for(decision), decision)
      end

      # The request a run of this call would hand its exec, built the same way and before the call is approved,
      # so a layer ahead of the gate can ask the sandbox's own questions of it. It journals nothing.
      #
      # @param input [Hash] the call's input, as the model sent it
      # @param context [#worker_env, nil] the session the call runs in
      # @param tool_use_id [String]
      # @return [Confine::Request]
      # @raise [Tool::InvalidInput] when the input does not validate
      def planned_request(input, context, tool_use_id:)
        checked, decision = planned(input, context)
        request_planned(checked, decision, planned_env(checked, context), context, tool_use_id:)
      end

      # The request a run of this call would hand its exec, as {#planned_request} builds it, and every program the
      # run is read to exec: on an allow the request's own stages, which the run checks, and otherwise each program
      # word a shell given the string would find, read into its substitutions and `sh -c` scripts, since a shell
      # runs those too.
      #
      # @param input [Hash] the call's input, as the model sent it
      # @param context [#worker_env, nil] the session the call runs in
      # @param tool_use_id [String]
      # @return [Array(Confine::Request, Array<Shell::Executable>)]
      # @raise [Tool::InvalidInput] when the input does not validate
      def planned_run(input, context, tool_use_id:)
        checked, decision = planned(input, context)
        worker_env = planned_env(checked, context)
        request = request_planned(checked, decision, worker_env, context, tool_use_id:)
        [request, decision.allow? ? request.executables : shell_runs(decision, worker_env)]
      end

      protected

      # Exit status rides in the returned content, NOT `is_error`: a nonzero
      # exit is frequently what the model asked to observe. `is_error` means
      # the tool itself could not produce a result -- a timeout, or output too
      # large to hand back -- never a subprocess's own exit code.
      #
      # The pending spill is deleted however the call ends unless it was kept
      # or handed on, so a timeout or a raise never leaves output on disk.
      def perform(input, invocation)
        pending = @spilled.pending
        kept = false
        result, kept = output(ran(input, invocation, pending), pending, invocation)
        result
      rescue Exec::Timeout => e
        timed_out(input, e)
      ensure
        pending.discard unless kept
      end

      private

      def ran(input, invocation, pending)
        command = input.command
        decision = decided(command, Middleware::ParsedCommand.carried(command, invocation.context))
        parse = decision.parse
        arm = arm_for(decision)
        journal_arm(decision, arm, invocation)
        options = runtime(input, invocation, pending)
        confinement = journalled_confinement(parse, decision, invocation, options[:cwd], arm)
        run_journalling_writes(parse, options, invocation) do
          executed(on_arm(arm, command, decision), confinement, options)
        end
      end

      def decided(command, parsed) = parsed ? @verdict.of(parsed) : @verdict.call(command)

      # A layer that decides whether a spill may be kept is handed it, and the
      # result names the pending file until that layer settles it; with no
      # such layer nothing decides, so the file is kept at once.
      #
      # @return [Array(Tool::Result, Boolean)] the result, and whether the
      #   pending file was kept or handed on
      def output(capture, pending, invocation)
        return [self.class.render_output(capture), false] if OUTPUT_BOUND.admits?(capture.size) || !pending.spilled?

        held = Tool::Spill::Held.new(pending:, render: ->(path) { spilled(capture, pending, path) },
                                     refusal: -> { self.class.render_output(capture) })
        context = session_of(invocation)
        return [held.commit, true] unless context.respond_to?(:spilled)

        context.spilled(held)
        [held.provisional, true]
      end

      def spilled(capture, pending, path)
        handed = @spilled.handback(head: pending.head, size: pending.size, kept: pending.kept, path:,
                                   beside: "exit status: #{capture.exit_status}\n#{SPILLED_STREAMS}")
        tier = Exec::Sandboxed::Tier.last_line(capture.stderr)
        Tool::Result.ok(tier ? "#{handed}\n#{tier}" : handed)
      end

      # The Journal's only account of arm selection when no ladder ran: the
      # approval gate journals a `shell verdict` line from inside its escalation
      # record, but a gate over {Middleware::Gate::ApproveAll} -- a child of a
      # run with no chat -- consults no rung and writes nothing. Under
      # `/mode auto` the ladder's triage rung does run and journal, so this
      # record is the one account every gate shares.
      #
      # Written BEFORE the command runs, so a call that times out still leaves
      # an account of the arm it chose. And written on EVERY call, both arms:
      # what a bench asks of these records is what FRACTION of commands earn the
      # deterministic arm, which a denominator missing the uninteresting calls
      # cannot answer.
      #
      # It carries BOTH questions, because they have different answers: the
      # `verdict` is what was decided -- the object the approval ladder judged
      # the same command with -- and the `arm` is what ran. An allow whose
      # backend had no shape for the term reaches a shell, and under
      # `--exec docker` that is every allowed pipe.
      #
      # The arm is the value #perform already resolved and is about to hand the
      # backend, passed in rather than re-derived here. Re-asking `takes_term?`
      # would make the record a SECOND derivation of what ran, and nothing makes
      # the two agree by construction: {Lain::Exec} is a duck with three
      # implementations and its contract asks a backend for an answer, never for
      # a pure function of the term. The three that ship would agree today. That
      # is the same argument the shared {Shell::Verdict} rests on one seam
      # further out -- one object consulted once, rather than two readings whose
      # agreement is a coincidence nothing enforces.
      def journal_arm(decision, arm, invocation)
        journal_record(Telemetry::ShellArm.new(tool_use_id: invocation.tool_use_id, verdict: decision.name,
                                               arm:, reason: decision.reason, term: decision.term))
      end

      def journalled_confinement(parse, decision, invocation, cwd, arm)
        parsed = parsed_stages(decision, session_of(invocation).worker_env.with(cwd:))
        stages = journal_resolution(parse.source, decision, invocation, cwd, arm, parsed:)
        request_for(stages, session_of(invocation), cwd, argv_on(arm, decision),
                    tool_use_id: invocation.tool_use_id, grants: parsed&.map(&:executable) || [])
      end

      def planned_env(checked, context)
        worker_env = (context || Session::Null.instance).worker_env
        worker_env.with(cwd: worker_env.resolve(checked.cwd))
      end

      def request_planned(checked, decision, worker_env, context, tool_use_id:)
        stages = resolve(checked.command, decision, worker_env)
        request_for(stages, context || Session::Null.instance, worker_env.cwd, argv_on(arm_for(decision), decision),
                    tool_use_id:, grants: grants_of(decision, worker_env))
      end

      def shell_runs(decision, worker_env)
        bound = @resolver.for(worker_env)
        ShellRuns.new(home: worker_env.env["HOME"]).argvs(decision.parse.source)
                 .map { bound.call(Shell::Term.of(_1)).first }
      end

      def planned(input, context)
        checked = validate_input!(input)
        command = checked.command
        [checked, decided(command, Middleware::ParsedCommand.carried(command, context))]
      end

      # Written before the exec, so a call that times out still leaves the account.
      # Resolved where the command runs, since a relative PATH entry and a build
      # tool's run files are read from there.
      #
      # A parsed stage is a guess at what the shell will run, so it is
      # journalled and handed to the confinement as a grant, never as proof:
      # the stages the call is checked against stay what the verdict resolved.
      def journal_resolution(command, decision, invocation, cwd, arm, parsed:)
        stages = resolve(command, decision, session_of(invocation).worker_env.with(cwd:))
        journal_record(Telemetry::ExecResolution.new(tool_use_id: invocation.tool_use_id,
                                                     stages: recorded(parsed, stages, arm)))
        stages
      end

      # Only a command the verdict did not allow reaches a shell that reads it, so only its stages are read.
      def parsed_stages(decision, worker_env)
        return if decision.allow?

        Parsed.new(resolver: @resolver, worker_env:).of(decision.parse)
      end

      def grants_of(decision, worker_env) = parsed_stages(decision, worker_env)&.map(&:executable) || []

      def recorded(parsed, stages, arm)
        entries = parsed&.map { Parsed.entry(_1) } || stages.map(&:to_journal)
        arm == :string ? entries.map { shell_answered(_1) } : entries
      end

      # A shell given the string runs these itself, so the file PATH finds did not run.
      def shell_answered(entry)
        SHELL_RUNS_ITSELF.include?(entry["name"]) ? entry.merge("resolved" => nil, "builtin" => true) : entry
      end

      # The one place a request is built, the run's and a plan's alike. A context no ladder ruled through gets
      # the ruling that allowed nothing.
      def request_for(stages, context, cwd, argv, tool_use_id:, grants: [])
        shadows = SessionShadows.new(context.worker_env.with(cwd:))
        ruling = context.respond_to?(:ruling) ? context.ruling : Confine::Request::UNRULED
        Confine::Request.new(ruling:, executables: shadows.over(stages), argv:, cwd:, root: context.worker_env.checkout,
                             tool_use_id:, grants: shadows.over(grants),
                             bounds: context.worker_env.bounds || Sensitivity::Bounds::NONE)
      end

      # On the string arm a shell reads the words, so none are vouched for.
      def argv_on(arm, decision) = arm == :term ? decision.term.stages.map(&:argv) : []

      def resolve(command, decision, worker_env)
        return [Shell::Executable.unresolved(command)] unless decision.allow?

        @resolver.for(worker_env).call(decision.term)
      end

      # Stats after the call, timeout included: a killed command may already
      # have truncated its target. A command it cannot read is marked instead,
      # since what it wrote has no name to stat.
      #
      # @param parse [Shell::Parse::Result] the command as the model wrote it, parsed
      # @param options [Hash] the spawn options the command runs under
      # @param invocation [Lain::Tool::Invocation] the call being journalled
      # @option options [String] :cwd the directory the command runs in
      # @option options [Hash] :env the child's environment, whose HOME places a `~` word
      def run_journalling_writes(parse, options, invocation)
        paths = []
        before = {}
        named = Shell::Named.from(parse, cwd: options[:cwd], home: options[:env].to_h["HOME"])
        paths = named.written.map(&:resolved).uniq
        before = paths.to_h { |path| [path, identity(path)&.last] }
        yield
      ensure
        journal_unread(options[:cwd], invocation, parse.source) if named&.opaque?
        journal_writes(paths, before, invocation)
      end

      def journal_unread(cwd, invocation, command)
        journal_record(Telemetry::WritesUnread.new(tool_use_id: invocation.tool_use_id, cwd:, command:))
      end

      # Only a file that is new or whose inode or ctime moved is journalled, so
      # a failed command, a word {Shell::Named} took for a path, and a path that
      # never existed leave nothing for the freshness check to misread.
      def journal_writes(paths, before, invocation)
        paths.each do |path|
          resolved, stat = identity(path)
          journal_record(file_written(resolved, stat, invocation)) if stat && !same_file_version?(stat, before[path])
        end
      end

      def same_file_version?(stat, earlier)
        earlier && stat.ino == earlier.ino && stat.ctime == earlier.ctime
      end

      def file_written(resolved, stat, invocation)
        Telemetry::FileWritten.from_stat(stat, path: resolved, tool_use_id: invocation.tool_use_id)
      end

      # @return [Array(String, File::Stat), nil] resolved path and its stat,
      #   nil when the path is not a file
      def identity(path)
        return unless File.file?(path)

        resolved = File.realpath(path)
        [resolved, File.stat(resolved)]
      rescue SystemCallError
        nil
      end

      # The command has run or is about to, so a journal that cannot take a
      # record must not turn it into a reported failure.
      def journal_record(record)
        @journal << record
      rescue SystemCallError, IOError, Journal::Closed
        nil
      end

      # ASK BEFORE OFFERING. An allow yields a term, but a backend may have no
      # shape for that term, and hearing so as an {Exec::Unsupported} mid-call
      # is how `--exec docker` used to answer an ordinary pipeline with a tool
      # error nobody wrote.
      #
      # @return [Symbol] `:term` or `:string`, resolved ONCE per call and read
      #   twice -- by the backend and by the record.
      def arm_for(decision) = decision.allow? && @exec.takes_term?(decision.term) ? :term : :string

      # What the backend is handed on the resolved arm. The string arm's is
      # `input.command` itself -- never the term rejoined, which would give
      # `sh -c` a command this tool composed -- so it sees exactly the bytes the
      # model wrote, under the same gate.
      def on_arm(arm, command, decision) = arm == :term ? decision.term : command

      # Cwd resolution lives on {WorkerEnv#resolve} -- one rule, so no exec
      # backend can resolve a relative path differently.
      def runtime(input, invocation, pending)
        worker_env = session_of(invocation).worker_env
        { cwd: worker_env.resolve(input.cwd), env: worker_env.env, timeout: seconds(input),
          **pending.tee(invocation.live_display.sinks(invocation)) }
      end

      # A live sink may hold bytes until the command stops, so it is flushed
      # however the command stopped, a timeout included.
      def executed(command, confinement, run)
        @exec.call(command:, confinement:, **run)
      ensure
        run.values_at(:stdout_sink, :stderr_sink).each(&:flush)
      end

      def seconds(input) = input.timeout || DEFAULT_TIMEOUT

      # The backend's message quotes whatever the command printed before it was
      # killed, as far as its capture retained it, so it crosses the same two
      # checks the output does: the output bound first, then the text boundary.
      # The boundary's own refusal is not used: its byte count would measure the
      # backend's report, and `head -c` at that count cuts the command's output
      # somewhere else.
      #
      # A sandboxed call's message ends with the tier line, which is set aside before either check and put back
      # after, so a replaced report still ends with it and the line never counts toward the bound.
      def timed_out(input, error)
        tier = Exec::Sandboxed::Tier.last_line(error.message)
        report = timeout_report(error.message.byteslice(0, error.message.bytesize - tier.to_s.bytesize))
        shown = tier ? "#{report.sub(/\n?\z/, "\n")}#{tier}" : report
        Tool::Result.error("command timed out after #{seconds(input)}s: #{shown}")
      end

      def timeout_report(message)
        size = message.bytesize
        unless OUTPUT_BOUND.admits?(size)
          return OUTPUT_BOUND.message(subject: "its report, which quotes what it printed and on some backends " \
                                               "the command,", size:, narrower: TIMEOUT_NARROWER)
        end

        text = Tool::ResultBlock::Text.new(message)
        text.text? ? text.to_s : TIMEOUT_OUTPUT_NOT_TEXT
      end

      # The stages the string arm will hand a shell, each resolved in the
      # directory it runs in, for the journal and the confinement's grants.
      class Parsed
        BASIS = "parsed"

        # @param resolver [#for] binds to a cwd, so each stage resolves where it runs
        # @param worker_env [WorkerEnv] the call's env, at the call's cwd
        def initialize(resolver:, worker_env:)
          @resolver = resolver
          @worker_env = worker_env
        end

        # A journal step must not fail the call it describes, so a command
        # whose stages cannot be told leaves the record it would have had
        # without the parse, and grants nothing.
        #
        # @param parse [Shell::Parse::Result]
        # @return [Array<Shell::Stages::Stage>, nil] one per stage a shell would
        #   exec, builtins left out; nil when its stages cannot be told
        def of(parse)
          read = Shell::Stages.from(parse, worker_env: @worker_env, resolver: @resolver)
          read.stages if read.known?
        end

        # @param stage [Shell::Stages::Stage]
        # @return [Hash] the stage's journal entry, marked as parsed
        def self.entry(stage) = stage.executable.to_journal.merge("basis" => BASIS, "cwd" => stage.directory)
      end
      private_constant :Parsed

      # The argv of each program a shell given the string would exec: every stage's, each stage of every command
      # and process substitution the grammar finds, which is how quoting and heredoc bodies are read as bash reads
      # them, and each stage of a shell's `-c` script, to a depth of {DEPTH}. Leading assignments are dropped; a
      # builtin, and a program word that still expands, name nothing a resolver could find.
      #
      # {#executables} reads for a caller that must name every program a command runs, so what it cannot read is
      # never dropped: each word that expands and each builtin in {RUNS_CODE} is unresolved, and so is each
      # {Unread} reason the command shows. Where a list decides, it lists what is known to be safe, so a shape
      # nobody listed parks.
      class ShellRuns
        DEPTH = 3
        # Every parse of one command draws from this. Realistic commands peak near 3.5 KB summed, and the bound keeps a
        # nested or fanned-out command to a few full parses' worth of work.
        READ_BYTES = 16_384
        SHELLS = %w[sh bash dash zsh].freeze
        SCRIPT_FLAG = /\A-[A-Za-z]*c[A-Za-z]*\z/
        OPTION = /\A[-+]/
        VALUED = /\A[-+][oO]\z/
        ASSIGNMENT = /\A[A-Za-z_][A-Za-z0-9_]*=/
        EXPANDS = /[$`*?\[{]/
        QUOTED = /\A(['"])(.*)\1\z/m
        SINGLE_QUOTED = /\A'.*'\z/m
        SPLICES = /[$`]/
        SUBSTITUTIONS = "(command_substitution) @substitution\n(process_substitution) @substitution"
        DELIMITERS = /\A(?:\$\(|[<>]\(|`)|(?:\)|`)\z/
        # Each runs a string as code (`eval`, `trap`, `bind -x`, `complete -C`, `fc`, `mapfile -C`), loads a file
        # as code (`source`, `.`, `enable -f`), or chooses what a later word runs (`exec`, `command`, `builtin`,
        # `hash -p`, `alias`, `jobs -x`), so no file a resolver finds for the word stands for what runs. The rest
        # assign to or test a variable they are named (`read`, `let`, `printf -v`, `test -v`, `[ -v`, `getopts`,
        # `wait -p`), and bash evaluates an array subscript in that name, which can hold a command substitution the
        # quoting hides.
        RUNS_CODE = (%w[eval trap bind complete compgen fc mapfile readarray source . enable exec command builtin hash
                        alias read let printf test getopts wait jobs] << "[").freeze
        # Builtins that bash runs whatever PATH holds, beyond those the shell verdict lists.
        BUILTINS_ON_PATH = %w[kill].freeze
        # A builtin's operand may be evaluated as arithmetic (`shift`, `exit`, `ulimit`, `kill`), and an array
        # subscript there runs a command substitution, so a builtin is dropped only when every operand is plain.
        PLAIN_OPERAND = %r{\A[-+]?[A-Za-z0-9_.,:/=%@+]*\z}

        # Why a command's words cannot name what it runs.
        Unread = Data.define(:reason) do
          # @return [Shell::Executable] a stage nothing is known about but this reason
          def executable = Shell::Executable.unresolved(reason)
        end

        # A loop's body runs on words its head makes up at run time.
        LOOP = Unread.new(reason: "a loop's body")
        # A variable can choose which file a later word runs (`PATH`) or what a program loads (`LD_PRELOAD`).
        ASSIGNED = Unread.new(reason: "a variable assignment or declaration")
        BROKEN = Unread.new(reason: "a command the parser could not read")
        NESTED = Unread.new(reason: "a script nested past the reading depth")
        # `[[ -v ]]`, `[ -v ]` and `unset` evaluate an array subscript in the name they are given.
        SUBSCRIPTED = Unread.new(reason: "a test or unset that may evaluate an array subscript")
        # Both resolve against the call's cwd, never the directory a `cd` before them moved to.
        MOVED = Unread.new(reason: "a relative word after a directory change")
        # A function can take the name of any program, so the word no longer names the file that runs.
        FUNCTION = Unread.new(reason: "a shell function")
        # `${x:=...}` assigns, and an arithmetic, a subscript or `@P` evaluates what a value holds.
        EXPANDED = Unread.new(reason: "a parameter or arithmetic expansion that can assign or evaluate")
        # The shell that receives the script undoes a backslash this reading keeps.
        ESCAPED = Unread.new(reason: "a script whose backslashes the shell would undo")
        # The outer shell expands a `$` or a backtick in a script it does not single-quote, before the inner one runs.
        SPLICED = Unread.new(reason: "a script the outer shell expands before the inner one reads it")
        SESSION_ENV = Unread.new(reason: "a variable the session lends that loads code before the command")
        # Only the options listed in {ShellOptions} are known to run no startup file, profile or hook.
        STARTUP = Unread.new(reason: "a shell option that may run a startup file or hook")
        # Only bash-family grammar is read, so a zsh, ksh, csh or fish script's expansions are not.
        FOREIGN = Unread.new(reason: "a script in a shell whose grammar lain does not read")
        # Only {Interpreters} lists what inline code or a preload cannot reach a file the words do not name.
        INLINE = Unread.new(reason: "an interpreter's code or preload that may load a file the words do not name")
        # Only {ROUTE_PROGRAMS}, each with its options read, is known to load no code beyond what its words and
        # run files show.
        UNLISTED = Unread.new(reason: "a program lain does not know to load only the code its words show")
        # A listed program's options are read by value, so a word whose value is not known could be any of them.
        UNKNOWN_WORD = Unread.new(reason: "a word whose value lain cannot read, given to a program with options")
        # make reads an included makefile, which is no run file the resolver names. A heuristic, read line by line:
        # it parks an `include` and any `$(eval`, `$(file` or `$(shell`, which can load another file with no include
        # line, and a makefile it cannot read.
        INCLUDED = Unread.new(reason: "a makefile that includes another")
        # A builtin evaluates its operand as arithmetic, where a subscript runs a command.
        OPERAND = Unread.new(reason: "a builtin operand that may be evaluated")
        # A substitution is parsed again inside each that holds it, and a `-c` script once more, so the parses of
        # one command are cut off at {READ_BYTES} rather than left quadratic in the nesting.
        UNBUDGETED = Unread.new(reason: "substitutions and scripts that together pass the bytes lain reads in one " \
                                        "command")
        DIRECTORY = Unread.new(reason: "a directory change")
        private_constant :DIRECTORY

        DIRECTORY_CHANGERS = %w[cd pushd popd].freeze
        SETTERS = %w[set shopt].freeze
        # Each names a file or library a shell, an interpreter, the loader or git reads before the command's own
        # words run, so with any of them in the child's env no word names everything that runs. None is in
        # `Exec::ChildEnv::KEEP`; GIT_CONFIG_GLOBAL is, and its file is read as git's run file instead.
        LOADER_ENV = %w[BASH_ENV ENV ZDOTDIR PYTHONPATH PYTHONHOME PYTHONSTARTUP NODE_PATH NODE_OPTIONS RUBYLIB RUBYOPT
                        PERL5LIB PERL5OPT PERLLIB LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT GIT_CONFIG_SYSTEM].freeze
        # The shells whose scripts are bash grammar, which is all the parse reads.
        BASH_GRAMMAR = %w[sh bash dash rbash ash busybox].freeze
        SUBSCRIPTING = %w[test_command unset_command].freeze
        SUBSTITUTED = %w[command_substitution process_substitution].freeze
        DECLARATION = "declaration_command"
        FUNCTION_KIND = "function_definition"
        ARITHMETIC = "arithmetic_expansion"
        SHAPES = "(for_statement) @loop\n(c_style_for_statement) @loop\n(while_statement) @loop\n" \
                 "(expansion) @expansion\n(compound_statement) @compound"
        PLAIN_EXPANSION = /\A\$\{[A-Za-z_][A-Za-z0-9_]*\}\z/
        ARITHMETIC_COMMAND = "(("
        ESCAPE = "\\"
        ENV_CHANGE = /\A-|=/

        # The options a shell stage may carry and still run no file the words do not name.
        module ShellOptions
          LETTERS = %w[c e u x v f n a C h B E H P T b m p r].freeze
          LONG = %w[--norc --noprofile --posix --noediting --].freeze
          SET = %w[errexit nounset pipefail xtrace noglob verbose noclobber].freeze
          SHOPT = %w[extglob nullglob globstar dotglob nocaseglob failglob].freeze
          CLUSTER = /\A[-+][A-Za-z]+\z/

          # @param words [Array<String>] a shell stage, its program first
          # @return [Boolean] whether any option before its operands is outside these lists
          def self.unread?(words)
            index = 1
            while (option = words[index])&.match?(OPTION)
              return true unless known?(option, words[index + 1])

              index += option.match?(VALUED) ? 2 : 1
            end
            false
          end

          # `set -o NAME` and `shopt -s NAME` change the running shell as a flag at launch would.
          #
          # @param words [Array<String>] a `set` or `shopt` stage
          # @return [Boolean] whether it names an option outside these lists
          def self.unset?(words)
            words.first == "shopt" ? (words.drop(1).reject { _1.start_with?("-") } - SHOPT).any? : unread?(words)
          end

          def self.known?(option, value)
            return SET.include?(value) if option.match?(/\A[-+]o\z/)
            return SHOPT.include?(value) if option.match?(/\A[-+]O\z/)

            LONG.include?(option) || (option.match?(CLUSTER) && (option[1..].chars - LETTERS).empty?)
          end
          private_class_method :known?
        end

        # The interpreters whose code and preloads are read: what each allows, all else parks. Inline code parks
        # in every spelling (python's `-c`, ruby's `-e`, perl's `-e` and `-E`, node's options), since code can load
        # a file however it likes; a script given by path is a run file, held to the freshness check. Stdin as data
        # passes; one reading its program from stdin names no script, which the resolver already leaves
        # unresolved. ruby and perl leave the cwd off their load paths until a load flag (`-I`, `-r`, `-M`, `-m`,
        # perl's `-d`) or ruby's `-C` puts it back; mawk reads no code but its program word unless `-f` names a
        # file; jq searches only its own library paths until a program `include`s or `import`s a module or `-f`
        # reads one from a file; gawk's `@include` and lua's `require` search ".".
        module Interpreters
          PYTHON = /\Apython[23]?\z/
          RUBY_LOADS = /\A-[A-Za-z]*[IrMLimCe]/
          PERL_LOADS = /\A-[A-Za-z]*[IrMLimdeE]/
          MAWK_LOADS = /\A-[A-Za-z]*[IrMLimf]/
          PYTHON_OPTION = /\A-[A-Za-z]/
          PYTHON_VALUED = %w[-W -X].freeze
          PYTHON_CODE = %w[c i].freeze
          JQ_LOADS = /\A(?:-L|--library-path|-f\z|--from-file)|\b(?:include|import)\b/
          OTHERS = %w[lua luajit gawk nawk original-awk php guile tclsh wish Rscript R julia deno bun sqlite
                      osascript expect].freeze

          # @param name [String] the file the stage runs, as {ShellRuns#program_name} names it
          # @param argv [Array<String>] the stage, its program first
          # @return [Boolean] whether its code may load a file no word names
          def self.unread?(name, argv)
            words = argv.drop(1)
            return python?(words) if name.match?(PYTHON)
            return words.any? { _1.match?(RUBY_LOADS) } if name == "ruby"
            return words.any? { _1.match?(PERL_LOADS) } if name == "perl"
            return words.any? { _1.match?(MAWK_LOADS) } if name == "mawk"
            # Every node option is a way to load code (`--run`, `--test`, `--env-file`, `--watch`, `-r`, `-e`).
            return words.first.to_s.start_with?("-") if %w[node nodejs].include?(name)
            return words.any? { _1.match?(JQ_LOADS) } if name == "jq"

            OTHERS.include?(name)
          end

          # `-c` is inline code, and `-i` reads more code from stdin once the script ends.
          def self.python?(words) = options(words).flat_map { _1.delete_prefix("-").chars }.intersect?(PYTHON_CODE)

          def self.options(words)
            word = words.first
            return [] unless word&.match?(PYTHON_OPTION)

            [word, *options(words.drop(PYTHON_VALUED.include?(word) ? 2 : 1))]
          end
          private_class_method :python?, :options
        end

        # The programs the opaque route lets through, each known to load no code but what its words and run files
        # show once its options are read: a program none of whose options runs another program passes with any,
        # and one that has such options (sed, git, sort, rg, find, make, and the interpreters) passes only the
        # options {Listed} names for it. Any other program parks, so a tool nobody listed is never the gap.
        ROUTE_PROGRAMS = %w[cat ls grep egrep fgrep rg sed mawk wc head tail sort uniq cut tr tee echo true false pwd
                            basename dirname realpath readlink stat date id whoami uname hostname sleep diff cmp comm
                            paste join fold fmt nl od xxd md5sum sha1sum sha256sum sha512sum b2sum base64 du df seq
                            tac rev expand nproc touch mkdir cp mv rm ln chmod find git make jq python ruby perl node
                            nodejs sh bash dash rbash ash busybox].freeze
        # The listed programs read by their options; every other listed one has no option that runs a program.
        WITH_OPTIONS = %w[sed git sort rg find make jq mawk python ruby perl node nodejs sh bash dash rbash ash].freeze
        MAKEFILES = %w[GNUmakefile makefile Makefile].freeze
        INCLUDE = /^[ \t]*-?s?include[ \t]|\$[({](?:eval|file|shell)\b/

        # The options of each listed program that has some that run a program, as an allowlist: a long option
        # passes only spelled whole, since an abbreviation names whatever option it is a prefix of.
        module Listed
          Options = Data.define(:flags, :valued, :long, :long_valued)

          SORT = Options.new(flags: "bcCdfghiMmnRrsuVz", valued: "kotST",
                             long: %w[--ignore-leading-blanks --check --dictionary-order --ignore-case
                                      --general-numeric-sort --human-numeric-sort --ignore-nonprinting --month-sort
                                      --merge --numeric-sort --random-sort --reverse --stable --unique --version-sort
                                      --zero-terminated --debug],
                             long_valued: %w[--key --output --field-separator --buffer-size --temporary-directory
                                             --parallel --sort])
          RG = Options.new(flags: "nilcwvFSHhoUuLqsxNIa0p.", valued: "egtTABCmMrEjdf",
                           long: %w[--line-number --ignore-case --smart-case --case-sensitive --files-with-matches
                                    --files-without-match --count --count-matches --word-regexp --line-regexp
                                    --invert-match --fixed-strings --hidden --no-ignore --no-ignore-vcs --follow --files
                                    --json --no-heading --heading --with-filename --no-filename --only-matching
                                    --multiline --vimgrep --column --no-line-number --null --pretty --quiet
                                    --unrestricted --one-file-system --stats --no-messages --trim --text],
                           long_valued: %w[--regexp --glob --iglob --type --type-not --after-context --before-context
                                           --context --max-count --max-depth --replace --color --colors --sort --sortr
                                           --encoding --threads --max-filesize --ignore-file --file])
          MAKE = Options.new(flags: "kisnBqSwrR", valued: "jl",
                             long: %w[--keep-going --silent --quiet --dry-run --just-print --always-make --question
                                      --no-print-directory --print-directory],
                             long_valued: %w[--jobs --load-average])
          SED = Options.new(flags: "nErsuz", valued: "el",
                            long: %w[--quiet --silent --regexp-extended --separate --unbuffered --null-data --posix
                                     --sandbox --debug],
                            long_valued: %w[--expression --line-length])
          # git takes any unambiguous prefix of a long option, so a prefix of one of these counts as it.
          SED_SCRIPT = %w[-e --expression].freeze
          FIND_OPERATORS = %w[! ( ) ,].freeze
          SHELLS = %w[sh bash dash rbash ash].freeze
          # `-O` opens the matches in a pager it names, in any short cluster (`-iO./evil`).
          PAGER_CLUSTER = /\A-[^-]*O/
          GIT_RUNS = %w[--open-files-in-pager --ext-diff --textconv --exec --upload-pack --receive-pack].freeze
          FIND_TESTS = %w[-name -iname -path -ipath -wholename -iwholename -type -xtype -maxdepth -mindepth -mtime
                          -mmin -atime -amin -ctime -cmin -newer -size -perm -user -group -uid -gid -regex -iregex
                          -regextype -links -inum -samefile -printf -print -print0 -prune -empty -readable -writable
                          -executable -true -false -quit -ls -not -o -a -or -and -L -P -H -xdev -mount -follow
                          -depth -noleaf -daystart ! ( ) ,].freeze
          FIND_VALUED = %w[-name -iname -path -ipath -wholename -iwholename -type -xtype -maxdepth -mindepth -mtime
                           -mmin -atime -amin -ctime -cmin -newer -size -perm -user -group -uid -gid -regex -iregex
                           -regextype -links -inum -samefile -printf].freeze

          # @param name [String] the program, as the route names it
          # @param words [Array<String>] its words after the program, each as bash passes it
          # @return [Boolean] whether every option it is given is on its list
          def self.pass?(name, words)
            case name
            when "sort" then only?(words, SORT)
            when "rg" then only?(words, RG)
            when "make" then only?(words, MAKE) && words.none? { !_1.start_with?("-") && _1.include?("=") }
            when "sed" then (scripts = sed_scripts(words)) && SedScript.plain?(scripts)
            when "git" then git?(words)
            when "find" then find?(words)
            else true
            end
          end

          # Every option a word spells must be listed; a valued one takes the rest of its word or the next.
          def self.only?(words, allowed) = walked(words, allowed) != false

          # Stepped as the tool reads them, so a `--` counts only where an option could stand.
          #
          # @return [Integer, nil, false] where a `--` ends the options; nil when none does; false at an unlisted one
          def self.walked(words, allowed)
            index = 0
            while (word = words[index])
              return index if word == "--"

              taken = option_takes(word, allowed)
              return false if taken.nil?

              index += taken
            end
            nil
          end

          # @return [Integer, nil] how many words the option spends; nil when it is not listed
          def self.option_takes(word, allowed)
            return 1 unless word.start_with?("-") && word.size > 1
            return long_takes(word, allowed) if word.start_with?("--")

            letters = word[1..]
            letters.each_char.with_index do |letter, at|
              return (at == letters.size - 1 ? 2 : 1) if allowed.valued.include?(letter)
              return nil unless allowed.flags.include?(letter)
            end
            1
          end

          def self.long_takes(word, allowed)
            name, value = word.split("=", 2)
            return 1 if allowed.long.include?(name) && value.nil?
            return (value.nil? ? 2 : 1) if allowed.long_valued.include?(name)

            nil
          end

          # sed's options read as getopt does: a cluster's `e` takes the rest of the cluster or the next word as a
          # script, `l` a value, `i` the rest as a backup suffix, and an `f` anywhere parks.
          #
          # @return [Array<String>, nil] each script, or nil when an option is not on sed's list
          def self.sed_scripts(words) = sed_read(words)&.first

          # Past a `--` the first operand is still the script when no `-e` gave one, so that word must be read too.
          #
          # @return [Integer, nil] the last index that may be an option or the script; nil when no `--` ends them
          def self.sed_end(words)
            scripts, _, at = sed_read(words)
            at && (scripts.empty? ? at + 1 : at)
          end

          # @return [Array(Array<String>, Array<String>, Integer), nil] the scripts, the operands, and where a `--`
          #   ended the options; nil when an option is not on sed's list
          def self.sed_read(words)
            scripts = []
            operands = []
            index = 0
            while (word = words[index])
              taken = sed_word(word, words[index + 1], scripts, operands)
              return nil if taken.nil?
              return [finished(scripts, operands + words.drop(index + 1)), operands, index] if taken.zero?

              index += taken
            end
            [finished(scripts, operands), operands, nil]
          end

          # @return [Integer, nil] words spent; 0 at `--`; nil for an unlisted option
          def self.sed_word(word, following, scripts, operands)
            return 0 if word == "--"
            return operands.push(word) && 1 unless word.start_with?("-") && word.size > 1
            return sed_long(word, following, scripts) if word.start_with?("--")

            sed_cluster(word[1..], following, scripts)
          end

          def self.sed_long(word, following, scripts)
            name, value = word.split("=", 2)
            return 1 if SED.long.include?(name) && value.nil?
            return 1 if name == "--in-place"
            return nil unless SED.long_valued.include?(name)

            scripts << (value || following) if name == "--expression"
            value.nil? ? 2 : 1
          end

          def self.sed_cluster(letters, following, scripts)
            at = letters.each_char.find_index { !SED.flags.include?(_1) }
            return 1 if at.nil? || letters[at] == "i"
            return nil unless SED.valued.include?(letters[at])

            rest = letters[(at + 1)..]
            scripts << (rest.empty? ? following : rest) if letters[at] == "e"
            rest.empty? ? 2 : 1
          end

          def self.finished(scripts, operands) = scripts.empty? ? operands.first(1) : scripts

          def self.git?(words)
            Shell::GitReads.facet?(words.first, :read_only) &&
              words.drop(1).none? { |word| word.match?(PAGER_CLUSTER) || runs_by_prefix?(word) }
          end

          def self.runs_by_prefix?(word)
            name = word.split("=", 2).first
            name.start_with?("--") && name.size > 2 && GIT_RUNS.any? { _1.start_with?(name) }
          end

          def self.find?(words)
            index = 0
            while (word = words[index])
              listed = !word.start_with?("-") && !FIND_OPERATORS.include?(word)
              return false unless listed || FIND_TESTS.include?(word)

              index += FIND_VALUED.include?(word) ? 2 : 1
            end
            true
          end

          # Where a program stops reading options: GNU tools read them anywhere; an interpreter or a shell stops at
          # its code or script, after which every word is an argument to that code.
          #
          # @param name [String]
          # @param stage [Array<String>] the program and its words
          # @return [Integer] the index of the last word that may be an option
          def self.options_end(name, stage)
            case name
            when Interpreters::PYTHON then code_or_operand(stage, /\A-[A-Za-z]*c\z/)
            when "ruby", "perl" then code_or_operand(stage, nil, /\A-[A-Za-z]*[eE]\z/)
            when "node", "nodejs", "mawk" then operand(stage)
            when *SHELLS then stage.index { _1.match?(SCRIPT_FLAG) }&.+(1) || operand(stage)
            when "sort" then past(walked(stage.drop(1), SORT), stage)
            when "rg" then past(walked(stage.drop(1), RG), stage)
            when "sed" then past(sed_end(stage.drop(1)), stage)
            when "git" then ended_at(stage) || stage.size
            else stage.size
            end
          end

          # An index into the words after the program, as an index into the stage; none means every word may be one.
          def self.past(at, stage) = at ? at + 1 : stage.size

          # git's read options are too many to step through, so a `--` ends them only after a word that is no bare
          # option: a value-taking option before it would take the `--` as its value.
          def self.ended_at(stage)
            stage.each_index.find do |at|
              at.positive? && stage[at] == "--" && (!stage[at - 1].start_with?("-") || stage[at - 1].include?("="))
            end
          end

          def self.code_or_operand(stage, code, valued = nil)
            index = 1
            while (word = stage[index])
              return index + 1 if code && word.match?(code)
              return index unless word.start_with?("-")

              index += valued && word.match?(valued) ? 2 : 1
            end
            index
          end

          def self.operand(stage) = stage.each_index.find { _1.positive? && !stage[_1].start_with?("-") } || stage.size
          private_class_method :only?, :option_takes, :long_takes, :sed_scripts, :sed_word, :sed_long, :sed_cluster,
                               :finished, :git?, :runs_by_prefix?, :find?,
                               :code_or_operand, :operand, :ended_at, :walked, :sed_read, :sed_end, :past
        end

        # A sed script read command by command, each `s` and `y` by its own delimiter: it passes only when no
        # command runs the pattern space (`e`, or `s`'s `e` flag) and every command is one this reads.
        module SedScript
          PLAIN = "=dDgGhHlnNpPxzF"
          TO_EOL = "aicrRwW"
          LABELS = "btT:"
          NUMBERED = "qQlL"
          FLAGS = /\A[gIiMmp0-9]*w?/

          # @param scripts [Array<String>]
          # @return [Boolean]
          def self.plain?(scripts)
            !scripts.empty? && scripts.all? { readable?(_1) }
          end

          def self.readable?(script)
            scanner = StringScanner.new(script)
            until scanner.eos?
              scanner.skip(/[\s;}]*/)
              break if scanner.eos?
              return false unless command?(scanner)
            end
            true
          end

          def self.command?(scanner)
            return scanner.skip_until(/\n|\z/) if scanner.scan("#")
            return false unless address(scanner) && address_rest(scanner)

            scanner.skip(/\s*!?\s*/)
            letter = scanner.getch
            return false if letter.nil?
            return true if letter == "{"

            body(letter, scanner)
          end

          def self.address(scanner)
            return true if scanner.skip(/\d+|\$/)
            return delimited?(scanner, "/") && scanner.skip(/[IM]*/) if scanner.scan(%r{/})
            return true unless scanner.scan("\\")

            delimiter = scanner.getch
            delimiter && delimited?(scanner, delimiter) && scanner.skip(/[IM]*/)
          end

          def self.address_rest(scanner)
            return true unless scanner.skip(/\s*(?:,|~)\s*/)

            scanner.skip(/[+~]?\d+/) || address(scanner)
          end

          def self.body(letter, scanner)
            case letter
            when "s" then substitute(scanner)
            when "y" then (delimiter = scanner.getch) && Array.new(2) { delimited?(scanner, delimiter) }.all?
            when *TO_EOL.chars then scanner.skip_until(/\n|\z/)
            when *LABELS.chars then scanner.skip(/[^;\n]*/)
            when *NUMBERED.chars then scanner.skip(/\s*\d*/)
            else PLAIN.include?(letter)
            end
          end

          def self.substitute(scanner)
            delimiter = scanner.getch
            return false if delimiter.nil? || delimiter.match?(/[\s\\]/)
            return false unless Array.new(2) { delimited?(scanner, delimiter) }.all?

            flags = scanner.scan(FLAGS).to_s
            scanner.skip_until(/\n|\z/) if flags.end_with?("w")
            scanner.check(/\s*(?:[;}\n]|\z)/) || flags.end_with?("w")
          end

          # Up to the next unescaped delimiter, which it consumes.
          def self.delimited?(scanner, delimiter)
            until scanner.eos?
              character = scanner.getch
              return true if character == delimiter

              scanner.getch if character == "\\"
            end
            false
          end
          private_class_method :readable?, :command?, :address, :address_rest, :body, :substitute, :delimited?
        end

        VERSION = /[-\d.]+\z/
        BUSYBOX = "busybox"

        # What one reading keeps and how it tells a shell from a stage: by name, or by the file the stage runs, which
        # is resolved whole because a shell given no `-c` reads its program from somewhere the words do not name.
        # A frozen value holding a mutable {Budget}, so a `with` copy shares the spend on purpose.
        Reading = Data.define(:reports_unread, :shell, :budget)
        # One stage a reporting reading found, and where its words have no value lain can read.
        Run = Data.define(:argv, :unknown)
        NAMED = ->(argv) { SHELLS.include?(argv.first.rpartition("/").last) && argv.first }

        # What one command's reading may still parse.
        class Budget
          def initialize(bytes)
            @left = bytes
          end

          # Once a draw is refused every later one is too, so a reading never resumes past the point it stopped.
          #
          # @param bytes [Integer]
          # @return [Boolean] whether the bytes were left, which are then spent
          def draw?(bytes)
            @left = bytes <= @left ? @left - bytes : -1
            @left >= 0
          end
        end
        private_constant :Reading, :Run, :NAMED, :Budget

        # @param home [String, nil] what a leading `~/` names, as the shell's HOME
        # @param parse [Shell::Parse]
        def initialize(home:, parse: Shell::Parse.new)
          @home = home
          @parse = parse
        end

        # @param source [String] the command as bash reads it
        # @param depth [Integer] how many nested scripts deep to read
        # @return [Array<Array<String>>]
        def argvs(source, depth = DEPTH)
          read(source, depth, Reading.new(reports_unread: false, shell: NAMED, budget: Budget.new(READ_BYTES)))
        end

        # A `-c` script is found under the wrappers the resolver peels, and a shell is told by the file its name
        # resolves to, so neither `nice sh -c` nor `rbash -c` hides one.
        #
        # @param source [String] the command as bash reads it
        # @param env [#call] `-> Hash{String=>String, nil}`, what the call's commands are lent
        # @yieldparam argv [Array<String>] one stage whose program is a literal word
        # @yieldreturn [Shell::Executable] that stage, resolved where the call runs
        # @return [Array<Shell::Executable>] one per program and per {Unread} reason; none when the words show none
        def executables(source, env:)
          shell = ->(argv) { shell_file(yield(argv)) }
          reading = Reading.new(reports_unread: true, shell:, budget: Budget.new(READ_BYTES))
          entries = settled(read(source, DEPTH, reading))
          entries = [SESSION_ENV, *entries] if lends_code?(env.call)
          entries.map { |entry| entry.is_a?(Unread) ? entry.executable : resolved_stage(entry) { yield _1 } }
        end

        private

        def read(source, depth, reading)
          return unbudgeted(reading) unless reading.budget.draw?(parsed_bytes(source))

          parse = @parse.call(source)
          stages = parse.stages.flat_map { stage(_1.argv, depth, reading) }
          [*unread_in(parse, depth, reading), *stages, *(depth.zero? ? [] : substituted(source, depth - 1, reading))]
        end

        # A name past the kept set reached the child on purpose, through a project's pass list, and nothing says
        # what reads it; a kept one that loads code is barred by name. The kept toolchain names (GEM_*, MISE_*,
        # CARGO_HOME, RUSTUP_HOME, XDG_*, HOME) pass: they are the user's own environment, fixed at launch, and
        # the model cannot set them in a call. Lain's own lend is left out before this reads the env.
        def lends_code?(received)
          received.any? { |name, value| !Exec::ChildEnv::KEEP.match?(name) || loader?(name, value) }
        end

        def loader?(name, value) = LOADER_ENV.include?(name) && !value.to_s.empty?

        def resolved_stage(run)
          argv = run.argv
          program = argv.first
          return Shell::Executable.unresolved(program) if RUNS_CODE.include?(program) || program.match?(EXPANDS)

          found = yield(argv)
          return found if found.klass == :unresolved

          name = program_name(found, argv)
          return INLINE.executable if Interpreters.unread?(name, argv)

          reason = unlisted(name, argv, run.unknown, found)
          reason ? reason.executable : found
        end

        def unlisted(name, argv, unknown, found)
          return UNLISTED unless ROUTE_PROGRAMS.include?(name)

          offset = argv.first.rpartition("/").last == BUSYBOX ? 1 : 0
          stage = argv.drop(offset)
          last = Listed.options_end(name, stage) + offset
          return UNKNOWN_WORD if WITH_OPTIONS.include?(name) && unknown.any? { _1 <= last }
          return UNLISTED unless Listed.pass?(name, stage.drop(1))

          INCLUDED if name == "make" && includes?(found)
        end

        def includes?(found)
          found.run_files.select { MAKEFILES.include?(File.basename(_1.path)) }
               .any? { File.foreach(_1.path).any? { |line| line.match?(INCLUDE) } }
        rescue SystemCallError, IOError
          true
        end

        # The file's name without a version, and a busybox applet by the name it is run as.
        def program_name(found, argv)
          name = File.basename(found.realpath || found.resolved).sub(VERSION, "")
          return name unless name == BUSYBOX

          applet = argv.first.rpartition("/").last == BUSYBOX ? argv[1] : argv.first
          applet.to_s.rpartition("/").last
        end

        def shell_file(executable)
          path = executable.realpath || executable.resolved
          path && Shell::Programs::SHELLS.include?(File.basename(path)) ? File.basename(path) : nil
        end

        def settled(entries)
          moved, rest = entries.partition { _1 == DIRECTORY }
          moved.any? && rest.any? { relative_words?(_1) } ? [MOVED, *rest] : rest
        end

        # A bare program name is searched on PATH, so only a word with a slash, or an operand, is relative.
        def relative_words?(entry)
          entry.is_a?(Run) && entry.argv.each_with_index.any? do |word, index|
            !word.start_with?(File::SEPARATOR, "-") && (index.positive? || word.include?(File::SEPARATOR))
          end
        end

        def unread_in(parse, depth, reading)
          return [] unless reading.reports_unread
          return [BROKEN] if parse.broken?

          [*by_kind(parse, depth), *by_shape(parse)].uniq
        end

        def by_kind(parse, depth)
          kinds = parse.kinds
          [(ASSIGNED if !parse.assignments.empty? || kinds.include?(DECLARATION)),
           (SUBSCRIPTED if kinds.intersect?(SUBSCRIPTING)), (FUNCTION if kinds.include?(FUNCTION_KIND)),
           (EXPANDED if kinds.include?(ARITHMETIC)), (NESTED if depth.zero? && kinds.intersect?(SUBSTITUTED))].compact
        end

        def by_shape(parse)
          shapes = Ext::TreeSitter.query(parse.source, Shell::Parse::LANGUAGE, SHAPES)
          [(LOOP if shapes.any? { _1.fetch("name") == "loop" }), (EXPANDED if shapes.any? { evaluates?(_1) })].compact
        end

        def evaluates?(capture)
          text = capture.fetch("text")
          case capture.fetch("name")
          when "expansion" then !text.match?(PLAIN_EXPANSION)
          when "compound" then text.start_with?(ARITHMETIC_COMMAND)
          else false
          end
        end

        # Every substitution, nested ones too, so each is read for its own stages only, all of them drawing on the
        # command's one budget.
        def substituted(source, depth, reading)
          return [] if source.bytesize > Shell::Parse::MAX_BYTES

          texts = Ext::TreeSitter.query(source, Shell::Parse::LANGUAGE, SUBSTITUTIONS)
                                 .map { _1.fetch("text").gsub(DELIMITERS, "") }
          return unbudgeted(reading) unless reading.budget.draw?(texts.sum(&:bytesize))

          texts.flat_map { @parse.call(_1).stages }.flat_map { stage(_1.argv, depth, reading) }
        end

        # Past the budget a reporting reading parks. The verbatim one lends the confinement only what it read, so a
        # program in the unread part is not named up front by `Profiles#unrunnable`: the sandbox refuses it at run
        # time instead.
        def unbudgeted(reading) = reading.reports_unread ? [UNBUDGETED] : []

        # A parse the length cap refuses reads nothing.
        def parsed_bytes(source) = source.bytesize > Shell::Parse::MAX_BYTES ? 0 : source.bytesize

        def stage(argv, depth, reading)
          raws = argv.drop_while { _1.match?(ASSIGNMENT) }
          return [*own(raws.map { unquoted(_1) }, reading), *verbatim(raws.map { unquoted(_1) }, depth, reading)] \
            unless reading.reports_unread

          values = raws.map { Shell::Named::Word.read(_1)&.text }
          words = values.zip(raws).map { |value, raw| value || raw }
          [*reported_own(words, unknown: unknown_at(values)), *reported(raws, words, depth, reading)]
        end

        # Where bash's quote removal leaves a word lain cannot compute, past the program word.
        def unknown_at(values) = values.each_index.select { |at| at.positive? && values[at].nil? }

        def verbatim(words, depth, reading)
          script = script_of(words) if !depth.zero? && NAMED.call(words)
          script ? read(script, depth - 1, reading) : []
        end

        # Under the wrappers the resolver peels: an `env` that changes a variable, a shell option outside the
        # known ones, a shell whose grammar is not bash's, and the `-c` script a shell is given.
        def reported(raws, words, depth, reading)
          layers = layers(words)
          inner = layers.last
          shell = reading.shell.call(inner)
          inner = inner.drop(1) if inner.first.rpartition("/").last == BUSYBOX
          [*(ASSIGNED if layers.any? { env_change?(_1) }), *(shell ? shell_reasons(raws, inner, shell) : []),
           *script_runs(raws, inner, shell, depth, reading)]
        end

        def shell_reasons(raws, inner, shell)
          [(STARTUP if ShellOptions.unread?(inner)), (FOREIGN unless BASH_GRAMMAR.include?(shell)),
           (SPLICED if spliced?(raws, inner))].compact
        end

        def script_runs(raws, inner, shell, depth, reading)
          script = shell && BASH_GRAMMAR.include?(shell) && !spliced?(raws, inner) && script_of(inner)
          script ? nested(script, depth, reading) : []
        end

        # The script word as written: a `$` or a backtick outside single quotes is the outer shell's to expand.
        def spliced?(raws, inner)
          at = script_index(inner)
          raw = at && raws[raws.size - inner.size + at]
          !raw.nil? && !raw.match?(SINGLE_QUOTED) && raw.match?(SPLICES)
        end

        def layers(words)
          peel = Shell::Executable::Resolver::Peel.of(words, {})
          peel&.outcome == :run ? [words, *layers(peel.command)] : [words]
        end

        def env_change?(words) = words.first.rpartition("/").last == "env" && words[1].to_s.match?(ENV_CHANGE)

        def nested(script, depth, reading)
          return [ESCAPED] if script.include?(ESCAPE)
          return read(script, depth - 1, reading) unless depth.zero?

          [NESTED]
        end

        def own(words, reading)
          program = words.first
          return [] if program.nil? || dropped?(program, reading)

          [[homed(program), *words.drop(1)]]
        end

        def reported_own(words, unknown:)
          program = words.first
          return [] if program.nil?
          return [DIRECTORY] if DIRECTORY_CHANGERS.include?(program)
          return builtin(words) if builtin?(program) && !RUNS_CODE.include?(program)

          [Run.new(argv: [homed(program), *words.drop(1)], unknown:)]
        end

        def builtin?(program) = Shell::Verdict.builtin?(program) || BUILTINS_ON_PATH.include?(program)

        def builtin(words)
          return [OPERAND] unless words.drop(1).all? { _1.match?(PLAIN_OPERAND) }

          SETTERS.include?(words.first) && ShellOptions.unset?(words) ? [STARTUP] : []
        end

        def dropped?(program, reading)
          return !reading.reports_unread if program.match?(EXPANDS)

          Shell::Verdict.builtin?(program) && !(reading.reports_unread && RUNS_CODE.include?(program))
        end

        # The word after the first option that clusters a `c`, as in `bash -e -c`, `bash -lc` and `sh -ec`, reading
        # past an option such as `-o pipefail` or `+O extglob` that takes the next word as its value.
        def script_of(words)
          at = script_index(words)
          at && words[at]
        end

        def script_index(words)
          index = 1
          while (option = words[index])&.match?(OPTION)
            return index + 1 if option.match?(SCRIPT_FLAG) && index + 1 < words.size

            index += option.match?(VALUED) ? 2 : 1
          end
        end

        def homed(word) = @home && word.start_with?("~/") ? File.join(@home, word.delete_prefix("~/")) : word

        def unquoted(word) = word.match(QUOTED)&.[](2) || word
      end

      # A program reached by its path or under a PATH the command set shadows
      # nothing on the search that found it, so each user program is also
      # looked for by name on the session's PATH: a different program of that
      # name there is a shadow however the command reached it. The resolver
      # cannot answer this, since it reads a stage's run files and leaves a
      # bare interpreter unresolved.
      class SessionShadows
        # @param worker_env [WorkerEnv] the session's env, at the call's cwd
        # @param host_env [#to_h] what a child inherits before the worker's env is laid over it
        def initialize(worker_env, host_env: ENV)
          @cwd = worker_env.cwd
          @path = host_env.to_h.merge(worker_env.env).compact.fetch("PATH", Shell::Executable::Resolver::Bound::DEFAULT_PATH)
        end

        # @param executables [Array<Shell::Executable>]
        # @return [Array<Shell::Executable>] each with the session's other programs of its name added to `shadowed`
        def over(executables) = executables.map { widened(_1) }

        private

        def widened(executable)
          shadowed = executable.klass == :user ? executable.shadowed | others(executable) : executable.shadowed
          executable.with(shadowed:, wrappers: executable.wrappers.map { widened(_1) })
        end

        def others(executable)
          name = File.basename(executable.resolved)
          @path.split(":", -1).map { File.expand_path(name, _1.empty? ? @cwd : File.expand_path(_1, @cwd)) }
               .select { File.file?(_1) && File.executable?(_1) }.reject { landed(_1) == executable.realpath }
        end

        def landed(path)
          File.realpath(path)
        rescue SystemCallError
          path
        end
      end
      private_constant :SessionShadows
    end
  end
end
