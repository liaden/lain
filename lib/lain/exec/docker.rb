# frozen_string_literal: true

module Lain
  module Exec
    # The container backend: one `docker run --rm` per command, the project
    # mounted at its own path, the scrubbed environment named on the command
    # line. Deliberately bare -- no image building, no lifecycle, no daemon
    # reuse, no networking policy. The point is a backend that genuinely
    # differs from {Local} and {Core}, so the seam is exercised rather than
    # speculative.
    #
    # A CONTAINER IS NOT A SANDBOX, and this backend claims no confinement. It
    # runs on a project mounted READ-WRITE, on the operator's own daemon, as
    # the calling user -- under `--user`, or as a container root the client
    # maps back to that same user. WHICH of those a client gets is
    # {UserMapping}'s question, and so is the one host that gets neither.
    # A command that could rewrite the tree through {Local} can rewrite it
    # through this. What changes is
    # WHERE the command's toolchain comes from -- the image's, not the
    # host's -- which is the whole reason it is here. The tier-3 approval gate
    # ({Tools::Bash#requires_approval?} plus Effect::Handler::Gate) is still
    # the security boundary, exactly as it is for the other two backends, and
    # the mount is why that remains true: every write a container makes is a
    # write the approved command asked for, in the same tree the same approved
    # command would have written on the host. Nothing here is reachable
    # without an approval, and nothing here reaches a path the approval did
    # not already cover.
    #
    # THE MOUNT SET IS THE CWD AND THE PROJECT, AND NOTHING ELSE. A cwd outside
    # the project is mounted too, rather than left to `docker run`'s habit of
    # creating an absent `--workdir` as an empty directory -- a command running
    # in a silently empty tree is the worst answer available. That set is
    # strictly NARROWER than {Local}, which hands every command the whole host
    # filesystem; narrower is not confinement, and the paragraph above stands.
    #
    # ⚠️ This class shares {Core}'s namespace hazard in reverse: a bare `Core`
    # here is {Exec::Core}, never {Lain::Core}. Nothing below needs either.
    class Docker
      # The client this backend drives. Named rather than inlined because
      # {CLI::ExecBackend} probes PATH for exactly this file before resolving
      # a run onto this backend, and two spellings of it would be two answers.
      CLI = "docker"

      # A floor, not a recommendation: busybox `sh` and coreutils and nothing
      # else. Any real use names its own image (`--exec-image`), because what a
      # container backend is FOR is running the project's commands against the
      # project's own toolchain.
      DEFAULT_IMAGE = "alpine:latest"

      # The fixed head of every invocation. `--rm` because the card's whole
      # shape is one container per command: nothing here names, reuses or
      # reaps a container, so nothing may leave one behind either.
      RUN = [CLI, "run", "--rm"].freeze

      # What crosses into the container, as an ALLOWLIST over the caller's
      # environment. It was a ten-name denylist, and a denylist is the wrong
      # shape for an unbounded problem: it missed `LD_LIBRARY_PATH` (this
      # repo's OWN required export), `GEM_HOME`, `RUBYLIB`, `TMPDIR`,
      # `XDG_RUNTIME_DIR` and `SSH_AUTH_SOCK` -- every one of them a HOST path
      # that does not exist inside the container.
      #
      # THE INVERSION WORTH NAMING, because it is why a denylist could not be
      # patched into correctness here: {Exec.child_env} keeps `GEM_*`
      # DELIBERATELY, and its stated reason is that "the child still has to
      # find its gems". That is a HOST fact, and it reverses across this
      # boundary -- a container's gems are the image's, and carrying the host's
      # `GEM_HOME` in points at a directory that is not there. The two rules
      # disagree because the two children are not the same kind of child.
      #
      # So: locale and time, the conventions every image honours, and lain's
      # own namespace -- the documented channel for a session that wants a
      # variable inside the container. Anything else belongs in the image,
      # which is what `--exec-image` is for.
      #
      # TWO KNOWN OMISSIONS, written down so the next operator meets them here
      # rather than in a failing command:
      #
      # * `LANGUAGE` does not cross, though `LANG` and `LC_*` do. It is GNU
      #   gettext's own variant and OUTRANKS `LC_MESSAGES`, so a container can
      #   answer in a different language from the host that started it.
      # * `http_proxy`, `HTTPS_PROXY` and `NO_PROXY` have NO in-band route at
      #   all: a container needs those exact names, and the `LAIN_` escape
      #   hatch cannot carry a name it would have to rename. Behind a proxy an
      #   `apk add` inside the container simply hangs. Bake them into the image,
      #   or widen this constant on purpose.
      #
      # Neither is wrong for a deliberately-bare backend; both are choices, and
      # this is where a reader finds out they were made.
      CROSSES = /\A(?:LANG\z|LC_[A-Z]+\z|TZ\z|TERM\z|NO_COLOR\z|CI\z|LAIN_)/

      # @param image [String] what `docker run` starts from
      # @param project [String] the directory mounted at its own path, and the
      #   directory the CLIENT is run from -- one that certainly exists.
      #
      #   REQUIRED, with no `Dir.pwd` default, and `spec/lain/project/root_defaults_spec.rb`
      #   is the mechanical form of the reason. This value is MOUNTED: a root
      #   silently taken from the working directory shows a container whichever
      #   subdirectory the shell happened to be in, leaving every path above it
      #   missing INSIDE while it still resolves outside -- and nothing about
      #   the call site would look wrong in review. A wrong mount is the one
      #   failure this backend's own design notes single out, so it is the last
      #   thing that should have a convenient default.
      # @param exec [#call] the backend the `docker` client itself runs
      #   through. {Local} by default, and the reuse is the point: the
      #   deadline, the process-group kill, the live sinks and the
      #   {Timeout} mapping are one implementation rather than three.
      # @param user [String] the `--user` value, WHERE ONE IS PASSED. The
      #   CALLING user, so a file a command writes into the mounted project is
      #   owned the way {Local} would have owned it -- root-owned files
      #   appearing in the operator's own tree is a footgun this backend has no
      #   business handing out. Its cost is that an image with no matching
      #   `/etc/passwd` entry gives the command no `$HOME`, which is the
      #   ordinary container trade. Whether it is passed at all is
      #   {UserMapping}'s answer, not this parameter's.
      # @param prober [#call] what asks the client which of those it is, given
      #   the asking command's deadline.
      #   Injected so a spec can put a client this box does not have in front
      #   of the backend, and defaulted to a question asked THROUGH the same
      #   inner backend the client itself runs through, so a doubled `exec:`
      #   doubles the probe too and a unit example spawns nothing.
      def initialize(project:, image: DEFAULT_IMAGE, exec: Local.new,
                     user: "#{Process.uid}:#{Process.gid}", prober: Prober.new(exec:, cwd: project))
        @image = image
        @project = project
        @exec = exec
        @user_mapping = UserMapping.new(user:, prober:)
        freeze
      end

      attr_reader :image, :project

      # The docker client is run as a TERM -- one argv, no shell of ours
      # anywhere on the host side. Any shell in this story is the container's,
      # started by the container from the string the model wrote.
      #
      # ⚠️ NO VALUE GOES ON THE COMMAND LINE. `/proc/<pid>/cmdline` is
      # WORLD-READABLE while `/proc/<pid>/environ` is owner-only, so a
      # `--env NAME=value` argv discloses to every user on the box what {Local}
      # -- which passes the same values by fork inheritance -- keeps private.
      # Measured against a real {WorkerEnv.default}: 62 such flags, carrying
      # `CLAUDE_CODE_MESSAGING_TOKEN`, `STARSHIP_SESSION_KEY` and, in any real
      # chat, `ANTHROPIC_API_KEY`. So the argv carries bare `--env NAME`, which
      # tells docker to forward the value from the CLIENT's own environment --
      # and the client is handed that value as an override here. One map, two
      # uses: the names go on the command line, the values go where only their
      # owner can read them.
      #
      # No `--env-file`, and this is why: a file would be a second copy of data
      # the client already carries, with a temp-file lifecycle this
      # deliberately-bare backend has no business owning.
      #
      # THE OVERRIDE IS ADDITIVE, so `DOCKER_HOST` and `DOCKER_CONTEXT` -- which
      # select the daemon the client addresses, and are the operator's to set --
      # survive untouched; the inner backend still applies {Exec.child_env} over
      # the top, so the client is no more polluted by lain's own bundler than
      # any other child.
      #
      # @param command [String, Array<Array<String>>] a shell command string,
      #   or a single-stage TERM
      # @param cwd [String] already resolved by the caller ({WorkerEnv#resolve})
      # @param env [Hash] the caller's overrides, before the framework scrub
      # @param timeout [Numeric] seconds before the client's process group is
      #   killed. `docker run` proxies signals to the container's PID 1 in
      #   non-TTY mode, so the ordinary TERM reaches the command; a container
      #   that ignores TERM outlives the client's KILL, which is a leak this
      #   deliberately-bare backend names rather than manages.
      # @param stdout_sink [#<<] where stdout bytes are pumped as they arrive
      # @param stderr_sink [#<<] where stderr bytes are pumped as they arrive
      # @return [Capture] what ran, whatever its exit status
      # @raise [Timeout] when the deadline passed and the client was killed
      # @raise [Unsupported] when handed a PIPED term
      def call(command:, cwd:, env:, timeout:, stdout_sink: Sink::Null.new, stderr_sink: Sink::Null.new)
        crossing = crossing(env)
        @exec.call(command: [argv(command, cwd, crossing.keys, timeout)], cwd: @project, env: crossing,
                   timeout:, stdout_sink:, stderr_sink:)
      end

      private

      # `timeout` reaches here for the probe and NOT for the run: the run's
      # deadline is the inner backend's to enforce, but the question asked
      # before it is spent from the same budget, so it has to be told the size
      # of that budget.
      def argv(command, cwd, names, timeout)
        RUN + @user_mapping.flags(timeout) + mounts(cwd) + ["--workdir", cwd] +
          envs(names) + [@image] + entrypoint(command)
      end

      def mounts(cwd)
        mount_points(cwd).flat_map { |path| ["--volume", "#{path}:#{path}"] }
      end

      def mount_points(cwd) = inside_project?(cwd) ? [@project] : [@project, cwd]

      # A lexical prefix is not containment: `/srv/project-notes` is a sibling
      # of `/srv/project`, not a child of it.
      def inside_project?(path) = path == @project || path.start_with?("#{@project}/")

      # An explicit nil from {Exec.child_env} is the REMOVAL lever, and here
      # removal is the absence of a NAME: a container inherits nothing from
      # this process, so a variable is present only where it is named. That
      # makes this the one backend where "scrubbed" and "never mentioned" are
      # the same act -- {Core}'s opposite, whose daemon has its own copy and
      # needs the nil to be sent. The framework family falls outside {CROSSES}
      # anyway; the scrub stays in the chain so the two rules cannot come to
      # disagree about a name only one of them knows.
      #
      # @return [Hash] the name => value map that crosses, which is BOTH the
      #   client's override map and, by its keys, the argv's `--env` names
      def crossing(env)
        Exec.child_env(env).select { |name, value| !value.nil? && CROSSES.match?(name) }
      end

      def envs(names) = names.flat_map { |name| ["--env", name] }

      def entrypoint(command) = command.is_a?(String) ? ["sh", "-c", command] : one_stage(command)

      # A container takes ONE argv and a pipe needs a shell, so a piped term
      # has no shape here. It is refused rather than joined back into a string:
      # joining would hand a shell the very command the term path exists to
      # keep away from one ({Shell::Verdict}'s rule, and {Core}'s for the same
      # reason). {Tools::Bash} holds both shapes, so it is the caller this
      # refusal is addressed to -- it reaches the model as a tool error naming
      # the stages, which is the honest answer to "this backend cannot run
      # that".
      def one_stage(term)
        return term.first if term.size == 1

        raise Unsupported, "docker run takes one argv and a pipe needs a shell, so this backend has no " \
                           "shape for a #{term.size}-stage term: #{term.inspect}"
      end

      # HOW THE CALLING USER APPEARS INSIDE THE CONTAINER -- which is not one
      # answer for every client, and this backend spent its whole life giving
      # docker's. `--user 1000:1000` is right for docker, whose daemon runs as
      # root and would otherwise leave root-owned files in the operator's own
      # tree. It is exactly INVERTED for rootless podman, where the host user
      # is ALREADY the container's root, so naming the host uid maps it to an
      # unprivileged id that owns nothing. Measured on one bind mount:
      #
      #   --user 1000  ->  uid=1000(tara), and `cat`/`touch` both denied
      #   no --user    ->  uid=0(root),    and the file lands owned by tara
      #
      # So the question asked is what the CLIENT is. THAT IS NOT THE SAME AS
      # ASKING WHETHER IT IS ROOTLESS, and the gap is this object's known
      # incompleteness rather than a subtlety it handles: a ROOTFUL podman
      # names itself podman too, gets no `--user` here, and drops root-owned
      # files in the operator's tree -- the exact footgun the flag exists to
      # prevent. Accepted knowingly (chunk-qa-round9, Open decision 2): the
      # rootless/rootful answer lives behind `info`, which is the one question
      # this probe will not ask because it contacts a daemon and can hang, and
      # no rootful host was available to measure a better discriminator
      # against. The client's own word is the cheap question, not the complete
      # one. Nor is there an in-band remedy for that operator: `user:` is a
      # HINT this object may discard, with no `force:` shape today, so the
      # door out of a wrong answer is `--exec local`.
      #
      # Holds the only mutable state in this file -- one memo -- which is why
      # it is an object of its own and {Docker} itself stays frozen
      # ({Shell::Pipeline::Run} is the same shape for the same reason).
      #
      # THE MEMO TAKES NO LOCK, AND NOT BECAUSE TWO COMMANDS CANNOT OVERLAP:
      # they can. {CLI::Wiring::BaseTools.build} hands the whole tool floor
      # ONE backend, and {Tools::Subagent} IS `parallel_safe?`, so sibling
      # subagents fan out as concurrent fibers each running its own bash
      # through that shared object; {Shell::Pipeline} blocks on `Thread#join`
      # and `IO.select`, both hooked by the fiber scheduler, so `||=` yields
      # mid-computation and three siblings measured THREE probes. The race is
      # benign, which is the actual reason: the question is idempotent and
      # every racer computes an equal Array, so the loser's answer is the
      # winner's. A lock would buy one fewer subprocess on a cold fan-out and
      # cost holding a lock across a spawn.
      class UserMapping
        # Matched against what the client says it is, ANCHORED: a client
        # names itself in the first word it prints, and `Docker version
        # 27.3.1 (podman-compat shim)` is a docker client that merely mentions
        # the other one. An unanchored match would map it to root and hand the
        # operator the root-owned files `--user` exists to prevent.
        PODMAN = /\A\s*podman\b/i

        def initialize(user:, prober:)
          @user = user
          @prober = prober
        end

        # @param timeout [Numeric] the deadline of the command this is being
        #   asked for. The question is spent from that budget, so it is bounded
        #   by it: a command asking for one second may not wait ten on a client
        #   that will not answer. Ignored once the answer is memoised, because
        #   the second command asks nothing.
        # @return [Array<String>] the `--user` fragment of the argv, EMPTY for
        #   a client that already runs the command as the host user
        #
        #   LAZY, and this is where the laziness is load-bearing:
        #   {CLI::ExecBackend.resolve} builds a backend twice per launch and
        #   neither build may spawn, so the client is asked on the first
        #   command and never at construction. Memoised on the Array, which is
        #   truthy even when it is empty -- so no sentinel is needed to tell
        #   "no flag" from "not yet asked".
        def flags(timeout) = @flags ||= maps_caller_to_root?(timeout) ? [] : ["--user", @user]

        private

        # AN ANSWER THAT DOES NOT ARRIVE KEEPS THE FLAG THIS BACKEND HAS ALWAYS
        # PASSED, and the rescue belongs HERE, on the object that asks, rather
        # than on the default {Prober} that also happens to rescue: `prober:`
        # is a documented injection seam and a seam promises nothing about
        # what comes back through it. Both steps are inside it, because both
        # can raise -- an injected prober by raising, and `match?` by being
        # handed a String tagged UTF-8 whose bytes are not valid UTF-8, which
        # {Shell::Pipeline} cannot produce but a decoding `exec:` such as
        # {Exec::Core} can.
        #
        # Conservative means today's behaviour, which is right for every
        # client but the one that names itself.
        def maps_caller_to_root?(timeout)
          PODMAN.match?(@prober.call(timeout).to_s)
        rescue StandardError
          false
        end
      end

      # The default {UserMapping} prober: the client, asked what it is, through
      # THE SAME inner backend the client itself runs through. Not a second
      # transport -- the operator's `DOCKER_HOST` reaches the question exactly
      # as it reaches the run, and a spec holding a fake `exec:` spawns nothing
      # here either.
      #
      # `--version` and never `info`: the version line contacts NO daemon, so
      # the question costs one local process and cannot hang the way `docker
      # info` can against a remote `DOCKER_HOST` (docker_spec.rb's own header
      # is the account of that hazard). It is also the only place the answer
      # is: `docker version --format '{{.Client.Version}}'` returns a bare
      # `6.1.0` under the podman shim, with no vendor word in it at all.
      class Prober
        QUESTION = [CLI, "--version"].freeze

        # A CEILING, not the deadline: the probe is given the SMALLER of this
        # and the deadline of the command it is asked for, so a generous
        # caller does not license an unbounded wait on a client that never
        # answers, and an impatient one is not overrun by ten seconds of
        # asking. Long enough for a local process to print one line.
        TIMEOUT = 10

        def initialize(exec:, cwd:)
          @exec = exec
          @cwd = cwd
          freeze
        end

        # @param timeout [Numeric] the asking command's whole deadline, which
        #   this spends at most {TIMEOUT} of
        # @return [String, nil] whatever the client said on stdout -- the shim
        #   banner rides stderr and is not it -- or nil when asking failed at
        #   all. A failed probe is not a failed command. This rescue is a
        #   convenience and not the boundary: {UserMapping} is conservative
        #   about every prober, including the ones it did not build.
        #
        #   NO SINKS ARE PASSED, so {Local} defaults them to {Sink::Null} and
        #   the client's version line cannot land in a tool result or in the
        #   Journal, where it would be a stray line in somebody else's record.
        def call(timeout)
          @exec.call(command: [QUESTION], cwd: @cwd, env: {}, timeout: [TIMEOUT, timeout].min).stdout
        rescue StandardError
          nil
        end
      end

      private_constant :UserMapping, :Prober
    end
  end
end
