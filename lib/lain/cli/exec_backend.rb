# frozen_string_literal: true

module Lain
  module CLI
    # Turns `--exec <name>` into the {Lain::Exec} backend a run's commands
    # become processes through -- the seam {IsolationBackend} is for
    # `--isolation` and {Backend} for `--provider`. {BACKENDS} is the single
    # authority both the resolution and the flag's help text read, so the two
    # cannot drift.
    #
    # A BAD FLAG IS REFUSED HERE, NOT AT THE FIRST COMMAND. `--exec docker` on
    # a box with no docker client is an operator mistake about the environment
    # the run was started in, and it is cheap to detect now. Deferring it to
    # the first `bash` call surfaces it, mid-run and after a session record
    # exists, as `docker: command not found` inside a tool result -- which
    # reads to a model as a broken command and to the operator as nothing at
    # all.
    #
    # THE PROBE IS THE CLIENT, NOT THE DAEMON. An absent binary is a flag the
    # operator cannot have meant, while an unreachable daemon is a machine that
    # may come back, and asking `docker info` at launch would make every chat's
    # startup wait on a daemon socket. A daemon that is down therefore still
    # surfaces as a tool error, named here rather than pretended away.
    #
    # A CONTAINER IS NOT A SANDBOX. Nothing this resolves confines anything;
    # see {Exec::Docker}'s own class doc. What `--exec` selects is where a
    # command's toolchain comes from, never what it is permitted to do -- that
    # is still the tier-3 approval gate, for every name in {BACKENDS}.
    class ExecBackend
      # An unrecognized `--exec` name, loud and naming the valid set. It
      # subclasses {Lain::Error} beside the object that raises it, so the exe
      # layer maps it to a clean Thor::Error.
      class Unknown < Error; end

      # A known name this box cannot run: `--exec docker` with no docker
      # client on PATH. Refused at launch, for the class doc's reason.
      class Unavailable < Error; end

      # The backends `--exec` selects between, in the order help text lists
      # them: the in-process baseline first, since it is the default.
      #
      # {Exec::Core} is a real backend of this seam and is deliberately NOT
      # here. It needs a STARTED {Lain::Core::Client} and the Async reactor
      # holding it, neither of which a flag can hand over -- so a bench
      # constructs {Tools::CoreExec} explicitly instead. An unresolvable name
      # refused by name beats one resolved into a backend that dies at its
      # first command.
      BACKENDS = %w[local docker].freeze

      # An unset flag arrives as nil and falls through to this constant rather
      # than a Thor default, so one authority answers "what does no `--exec`
      # mean?"
      DEFAULT = "local"

      # @return [#call] the resolved backend
      def self.resolve(...) = new(...).backend

      # @param name [String, nil] the `--exec` value; nil means {DEFAULT}
      # @param image [String, nil] the `--exec-image` value; nil means
      #   {Exec::Docker::DEFAULT_IMAGE}. Thor hands an unset String option
      #   through as nil, so nil has to mean "none given" rather than reaching
      #   `docker run` as a missing argument.
      # @param root [String] the project the backend is resolved FOR: what a
      #   container mounts. The {Project}'s root, passed explicitly so a run
      #   from a subdirectory works on the project it is in, not on the
      #   directory the shell happened to be in.
      #
      #   RESOLVED, not merely expanded. A container mounts this path AT
      #   ITSELF, so a symlinked root would mount as `<symlink>:<symlink>` and
      #   everything inside that RESOLVES -- git, `__dir__`, a `..` crossing
      #   the link -- would disagree with the path the command was handed.
      #   {Project::Resolver.resolved} keeps the tolerance a lexical expansion
      #   had for a root naming nothing on disk. Required, with no default: the
      #   one caller that does not care says so at its own call site rather
      #   than inheriting a silence.
      # @param path [String] the PATH the client is looked for on; injected so
      #   both answers -- refused, and resolved -- are reachable in a spec on a
      #   box that has never installed docker
      # @param filesystem [#file?, #executable?] the two questions the probe
      #   asks, injected on the same rule
      def initialize(name = nil, root:, image: nil, path: ENV.fetch("PATH", ""), filesystem: File)
        @name = name || DEFAULT
        @image = image || Exec::Docker::DEFAULT_IMAGE
        @root = Project::Resolver.resolved(File.expand_path(root), File)
        @path = path
        @filesystem = filesystem
      end

      # @return [#call] the concrete backend
      # @raise [Unknown] on a name outside {BACKENDS}
      # @raise [Unavailable] for `docker` with no docker client on PATH
      def backend
        case backend_name
        when "docker" then docker
        else Exec::Local.new
        end
      end

      private

      # Validated once, so the mapping above only ever sees a name already
      # known to be in {BACKENDS}.
      def backend_name
        return @name if BACKENDS.include?(@name)

        raise Unknown, "unknown exec backend #{@name.inspect}, expected one of #{BACKENDS.inspect}"
      end

      def docker
        refuse_without_client!
        Exec::Docker.new(image: @image, project: @root)
      end

      def refuse_without_client!
        return if on_path?(Exec::Docker::CLI)

        raise Unavailable, "--exec docker needs the `#{Exec::Docker::CLI}` client and there is none on PATH; " \
                           "install it, or use --exec #{DEFAULT}"
      end

      # BOTH questions, because `File.executable?` answers true for every
      # directory: a directory named `docker` on PATH is not a client.
      def on_path?(client)
        @path.split(File::PATH_SEPARATOR).any? do |dir|
          candidate = File.join(dir, client)
          @filesystem.file?(candidate) && @filesystem.executable?(candidate)
        end
      end
    end
  end
end
