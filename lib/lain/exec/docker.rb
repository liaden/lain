# frozen_string_literal: true

module Lain
  module Exec
    # The container backend: one `docker run --rm` per command, the project
    # mounted at its own path, the scrubbed environment named on the command
    # line. Deliberately bare -- no image building, lifecycle, daemon reuse or
    # networking policy.
    #
    # A CONTAINER IS NOT A SANDBOX. The project is mounted READ-WRITE on the
    # operator's own daemon, as the calling user; what changes is WHERE the
    # command's toolchain comes from. The tier-3 approval gate
    # ({Tools::Bash#requires_approval?} plus Middleware::Gate) is still the
    # security boundary, and the mount is why that holds: every write a
    # container makes is a write the approved command asked for, in the tree
    # that command would have written on the host. The mount set is the cwd and
    # the project and nothing else -- a cwd outside the project is mounted too,
    # rather than left to `docker run`'s habit of creating an absent `--workdir`
    # as an empty directory.
    #
    # ⚠️ Shares {Core}'s namespace hazard in reverse: a bare `Core` here is
    # {Exec::Core}, never {Lain::Core}.
    class Docker
      # Named because {CLI::ExecBackend} probes PATH for exactly this file
      # before resolving a run onto this backend; two spellings, two answers.
      CLI = "docker"

      # A floor, not a recommendation. Any real use names its own image
      # (`--exec-image`): what a container backend is FOR is running the
      # project's commands against the project's own toolchain.
      DEFAULT_IMAGE = "alpine:latest"

      # `--rm` because nothing here names, reuses or reaps a container, so
      # nothing may leave one behind. `--quiet` because an image absent locally
      # makes the client narrate its pull progress onto the same stderr the
      # command's output rides, and a tool result carrying transfer noise reads
      # to the model as the command's own. Measured not to touch the command's
      # streams: a forced fresh pull loses every `Trying to pull`/`Copying blob`
      # line while stdout, stderr and a failed pull's diagnostic survive.
      RUN = [CLI, "run", "--rm", "--quiet"].freeze

      # An ALLOWLIST, because a denylist is the wrong shape for an unbounded
      # problem: the ten-name one this replaced missed `LD_LIBRARY_PATH` (this
      # repo's OWN required export), `GEM_HOME`, `RUBYLIB`, `TMPDIR`,
      # `XDG_RUNTIME_DIR` and `SSH_AUTH_SOCK`, every one a HOST path absent
      # inside the container. {Exec.child_env} keeps `GEM_*` DELIBERATELY so the
      # child finds its gems; that is a host fact and it reverses here, which is
      # why no patched denylist could have been correct. Two omissions, met here
      # rather than in a failing command: `LANGUAGE` does not cross though
      # `LANG` and `LC_*` do, and it OUTRANKS `LC_MESSAGES`, so a container can
      # answer in a different language from its host; `http_proxy`,
      # `HTTPS_PROXY` and `NO_PROXY` have no in-band route at all -- a container
      # needs those exact names and the `LAIN_` hatch cannot rename -- so behind
      # a proxy an `apk add` in the container hangs. Bake those into the image.
      CROSSES = /\A(?:LANG\z|LC_[A-Z]+\z|TZ\z|TERM\z|NO_COLOR\z|CI\z|LAIN_)/

      # @param image [String] what `docker run` starts from
      # @param project [String] the directory mounted at its own path, and the
      #   directory the CLIENT is run from. REQUIRED, with no `Dir.pwd` default,
      #   because this value is MOUNTED: a root taken from the working directory
      #   shows a container whichever subdirectory the shell happened to be in,
      #   leaving every path above it missing INSIDE while it still resolves
      #   outside, and nothing at the call site would look wrong in review.
      # @param exec [#call] the backend the `docker` client itself runs through.
      #   The reuse is the point: the deadline, the process-group kill, the live
      #   sinks and the {Timeout} mapping are one implementation, not three.
      # @param user [String] the `--user` value, WHERE ONE IS PASSED -- the
      #   CALLING user, so a file written into the mounted project is owned the
      #   way {Local} would have owned it. {UserMapping} decides whether it is
      #   passed at all.
      # @param prober [#call] what asks the client which of those it is.
      #   Defaulted through the same inner backend, so a doubled `exec:` doubles
      #   the probe and a unit example spawns nothing.
      def initialize(project:, image: DEFAULT_IMAGE, exec: Local.new,
                     user: "#{Process.uid}:#{Process.gid}", prober: Prober.new(exec:, cwd: project))
        @image = image
        @project = project
        @exec = exec
        @user_mapping = UserMapping.new(user:, prober:)
        freeze
      end

      attr_reader :image, :project

      # A container takes ONE argv, so the answer is about the TERM's shape and
      # not about this backend -- which is why the seam's predicate is asked
      # with one. It is the CALLER's term that is answered for, never the
      # single docker argv every command is wrapped into below; that wrapper is
      # one stage for a pipe as much as for anything else.
      #
      # @param term [Array<Array<String>>] the term a caller is about to offer
      # @return [Boolean] true for a one-stage term
      def takes_term?(term) = term.size == 1

      # ⚠️ NO VALUE GOES ON THE COMMAND LINE. `/proc/<pid>/cmdline` is
      # WORLD-READABLE while `/proc/<pid>/environ` is owner-only, so a
      # `--env NAME=value` argv would disclose to every user on the box what
      # {Local} -- passing the same values by fork inheritance -- keeps private.
      # Measured against a real {WorkerEnv.default}: 62 such flags, carrying
      # `CLAUDE_CODE_MESSAGING_TOKEN`, `STARSHIP_SESSION_KEY` and, in any real
      # chat, `ANTHROPIC_API_KEY`. So the argv carries bare `--env NAME` and the
      # client is handed the value as an override -- no `--env-file` either,
      # which would be a second copy with a temp-file lifecycle this backend has
      # no business owning. The override is ADDITIVE, so the operator's
      # `DOCKER_HOST` and `DOCKER_CONTEXT` survive untouched.
      #
      # @param command [String, Array<Array<String>>] a shell command string,
      #   or a single-stage TERM
      # @param cwd [String] already resolved by the caller ({WorkerEnv#resolve})
      # @param env [Hash] the caller's overrides, before the framework scrub
      # @param timeout [Numeric] seconds before the client's process group is
      #   killed. `docker run` proxies signals to the container's PID 1 in
      #   non-TTY mode, so the ordinary TERM reaches the command; a container
      #   that ignores TERM outlives the client's KILL, a leak this backend
      #   names rather than manages.
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
      # before it is spent from the same budget.
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
      # removal is the absence of a NAME: a container inherits nothing, so a
      # variable exists only where it is named -- {Core}'s opposite, whose
      # daemon holds its own copy and needs the nil sent. The scrub stays in the
      # chain so the two rules cannot come to disagree about a name only one of
      # them knows.
      #
      # @return [Hash] the name => value map that crosses, which is BOTH the
      #   client's override map and, by its keys, the argv's `--env` names
      def crossing(env)
        Exec.child_env(env).select { |name, value| !value.nil? && CROSSES.match?(name) }
      end

      def envs(names) = names.flat_map { |name| ["--env", name] }

      def entrypoint(command) = command.is_a?(String) ? ["sh", "-c", command] : one_stage(command)

      # Refused rather than joined back into a string: joining would hand a
      # shell the very command the term path exists to keep away from one
      # ({Shell::Verdict}'s rule). The rule itself is {#takes_term?}, read here
      # rather than restated, so the answer and the refusal cannot disagree.
      def one_stage(term)
        return term.first if takes_term?(term)

        raise Unsupported, "docker run takes one argv and a pipe needs a shell, so this backend has no " \
                           "shape for a #{term.size}-stage term: #{term.inspect}"
      end

      # HOW THE CALLING USER APPEARS INSIDE THE CONTAINER, which is not one
      # answer for every client. `--user 1000:1000` is right for docker, whose
      # daemon runs as root and would otherwise leave root-owned files in the
      # operator's tree. It is INVERTED for rootless podman, where the host user
      # is ALREADY the container's root. Measured on one bind mount:
      #
      #   --user 1000  ->  uid=1000(tara), and `cat`/`touch` both denied
      #   no --user    ->  uid=0(root),    and the file lands owned by tara
      #
      # Asking what the CLIENT is is not the same as asking whether it is
      # rootless, and the gap is known: a ROOTFUL podman names itself podman,
      # gets no `--user`, and drops root-owned files in the operator's tree.
      # Accepted, because that answer lives behind `info` -- the one question
      # this probe will not ask, since it contacts a daemon and can hang. The
      # way out of a wrong answer is `--exec local`.
      #
      # Holds the only mutable state in this file, which is why it is an object
      # of its own and {Docker} itself stays frozen. THE MEMO TAKES NO LOCK, and
      # not because two commands cannot overlap: {CLI::Wiring::BaseTools.build}
      # hands the whole tool floor ONE backend and {Tools::Subagent} IS
      # `parallel_safe?`, so siblings fan out as concurrent fibers through this
      # shared object and `||=` yields mid-computation -- three siblings
      # measured THREE probes. The race is benign, every racer's Array equal; a
      # lock would buy one fewer subprocess and cost holding one across a spawn.
      class UserMapping
        # ANCHORED: a client names itself in the first word it prints, and
        # `Docker version 27.3.1 (podman-compat shim)` is a docker client that
        # merely mentions the other one. An unanchored match would map it to
        # root and hand the operator the very root-owned files `--user` averts.
        PODMAN = /\A\s*podman\b/i

        def initialize(user:, prober:)
          @user = user
          @prober = prober
        end

        # @param timeout [Numeric] the asking command's deadline, which bounds
        #   the question: a command asking for one second may not wait ten on a
        #   client that will not answer. Ignored once the answer is memoised.
        # @return [Array<String>] the `--user` fragment of the argv, EMPTY for a
        #   client that already runs the command as the host user. LAZY,
        #   load-bearingly: {CLI::ExecBackend.resolve} builds a backend twice per
        #   launch and neither build may spawn. Memoised on the Array, truthy
        #   even when empty, so no sentinel is needed for "not yet asked".
        def flags(timeout) = @flags ||= maps_caller_to_root?(timeout) ? [] : ["--user", @user]

        private

        # AN ANSWER THAT DOES NOT ARRIVE KEEPS THE FLAG THIS BACKEND HAS ALWAYS
        # PASSED, and the rescue belongs HERE, on the object that asks, rather
        # than on the default {Prober} that also rescues: `prober:` is a
        # documented injection seam and a seam promises nothing about what comes
        # back through it. Both steps are inside it because both can raise -- an
        # injected prober by raising, and `match?` by being handed a String
        # tagged UTF-8 whose bytes are not valid UTF-8, which {Shell::Pipeline}
        # cannot produce but a decoding `exec:` such as {Exec::Core} can.
        def maps_caller_to_root?(timeout)
          PODMAN.match?(@prober.call(timeout).to_s)
        rescue StandardError
          false
        end
      end

      # Asked through THE SAME inner backend the client itself runs through, so
      # the operator's `DOCKER_HOST` reaches the question exactly as it reaches
      # the run. `--version` and never `info`: the version line contacts NO
      # daemon, so the question costs one local process and cannot hang the way
      # `docker info` can against a remote `DOCKER_HOST`. It is also the only
      # place the answer is -- `docker version --format '{{.Client.Version}}'`
      # returns a bare `6.1.0` under the podman shim, no vendor word in it.
      class Prober
        QUESTION = [CLI, "--version"].freeze

        # A CEILING, not the deadline: the probe gets the SMALLER of this and
        # the deadline of the command it is asked for, so a generous caller does
        # not license an unbounded wait and an impatient one is not overrun.
        TIMEOUT = 10

        def initialize(exec:, cwd:)
          @exec = exec
          @cwd = cwd
          freeze
        end

        # @param timeout [Numeric] the asking command's whole deadline, which
        #   this spends at most {TIMEOUT} of
        # @return [String, nil] whatever the client said on stdout -- the shim
        #   banner rides stderr and is not it -- or nil when asking failed. A
        #   convenience, not the boundary: {UserMapping} is conservative about
        #   every prober. No sinks are passed, so {Local} defaults them to
        #   {Sink::Null} and the version line cannot land in a tool result or in
        #   the Journal, a stray line in somebody else's record.
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
