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
    # A CONTAINER IS NOT A SANDBOX, and this backend claims no confinement.
    # It runs as the calling user on a project mounted READ-WRITE, on the
    # operator's own daemon; a command that could rewrite the tree through
    # {Local} can rewrite it through this. What changes is WHERE the command's
    # toolchain comes from -- the image's, not the host's -- which is the whole
    # reason it is here. The tier-3 approval gate ({Tools::Bash#requires_approval?}
    # plus Effect::Handler::Gate) is still the security boundary, exactly as it
    # is for the other two backends, and the mount is why that remains true:
    # every write a container makes is a write the approved command asked for,
    # in the same tree the same approved command would have written on the
    # host. Nothing here is reachable without an approval, and nothing here
    # reaches a path the approval did not already cover.
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
      # @param user [String] the `--user` value. The CALLING user, so a file a
      #   command writes into the mounted project is owned the way {Local}
      #   would have owned it -- root-owned files appearing in the operator's
      #   own tree is a footgun this backend has no business handing out.
      #   Its cost is that an image with no matching `/etc/passwd` entry gives
      #   the command no `$HOME`, which is the ordinary container trade.
      def initialize(project:, image: DEFAULT_IMAGE, exec: Local.new,
                     user: "#{Process.uid}:#{Process.gid}")
        @image = image
        @project = project
        @exec = exec
        @user = user
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
        @exec.call(command: [argv(command, cwd, crossing.keys)], cwd: @project, env: crossing,
                   timeout:, stdout_sink:, stderr_sink:)
      end

      private

      def argv(command, cwd, names)
        RUN + ["--user", @user] + mounts(cwd) + ["--workdir", cwd] + envs(names) + [@image] + entrypoint(command)
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
    end
  end
end
