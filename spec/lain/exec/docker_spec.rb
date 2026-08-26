# frozen_string_literal: true

require "fileutils"
require "socket"

# Why a real container run may not happen here, in the operator's own words.
# Three separate preconditions with three different fixes, so the skip names
# WHICH one is missing rather than saying "no docker" for all of them --
# spec/support/tags.rb's :core and :vsock blocks are the shape.
#
# The image is required to be PRESENT LOCALLY on purpose: a :seam spec touches
# no network, and letting `docker run` pull would make the first run of this
# file a download.
#
# ⚠️ ASKED ONCE, FROM A `before(:context)`, and never at file load. tags.rb's
# :nvim and :core gates read a CHEAP LOCAL fact (a binary on PATH, a built
# artifact); `docker info` asks a DAEMON, which on a box with a remote
# `DOCKER_HOST` can hang. At load that cost is paid by every parallel_rspec
# worker before any example is selected -- including under `--tag '~seam'`,
# which selects none of them. RSpec's own once-per-group hook runs only when
# the group has an example to run, which is exactly the condition wanted, and
# it needs no memo of its own: measured at 0 probes under `--tag '~seam'` and
# 1 for the whole group otherwise.
#
# A top-level module, not a constant inside `RSpec.describe do ... end` -- one
# of those lands on Object, where another spec file spelling the same name
# silently clobbers it.
module DockerBackendAvailability
  IMAGE = Lain::Exec::Docker::DEFAULT_IMAGE

  # `system`'s own tri-state, kept rather than collapsed: `true` (ran, exit 0),
  # `false` (ran, exited nonzero) and `nil` (could not be executed at all --
  # `Errno::ENOENT` under the hood) are three different findings, and only the
  # last one is "nothing on PATH". Collapsing `false` into `nil` is exactly how
  # "no `docker` client on PATH" used to read on a `podman-docker` box where a
  # client plainly IS on PATH and merely failed to answer -- the reason named
  # what was looked for, not what running the probe actually found.
  def self.probe(*argv) = system(*argv, out: File::NULL, err: File::NULL)

  # @param prober [#call] answers each probe argv with {.probe}'s own
  #   true/false/nil vocabulary. Defaults to the real probe, so production
  #   behaviour is unchanged; a unit example injects a canned one so the three
  #   reasons below are each driven directly, with no client to remove.
  # @return [String, nil] why a real container will not run here, naming the
  #   probe that answered and what it found -- or nil once every probe is
  #   satisfied
  def self.unavailability(prober: method(:probe))
    version = prober.call("docker", "--version")
    return "`docker --version` found nothing to run -- no docker or podman-docker client on PATH" if version.nil?
    return "`docker --version` ran but exited nonzero -- a `docker` on PATH that will not answer" unless version

    info = prober.call("docker", "info")
    return "found a client on PATH, but its daemon is not answering `docker info`" unless info

    return nil if prober.call("docker", "image", "inspect", IMAGE)

    "found a client and a daemon, but the image #{IMAGE} is not present locally -- " \
      "run `docker pull #{IMAGE}`; a :seam spec must not pull it"
  end
end

# The SKIP REASON's own quality, exercised without touching a real client.
# `.unavailability` takes an injected `prober:` for exactly this -- a unit
# example hands it a canned true/false/nil answer per probe, the same
# vocabulary `system` itself returns, and reads the sentence that comes back.
# No `:seam` tag: nothing here spawns a subprocess.
RSpec.describe DockerBackendAvailability do
  # @return [Array(#call, Array<Array<String>>)] a prober that answers each
  #   call from `results`, in order, and a log of the argv it was asked --
  #   so an example can assert BOTH the sentence produced and which probes it
  #   took to produce it.
  def canned_prober(*results)
    calls = []
    prober = lambda do |*argv|
      calls << argv
      results.shift
    end
    [prober, calls]
  end

  describe ".unavailability" do
    it "names docker --version and that nothing on PATH could even run it" do
      prober, calls = canned_prober(nil)

      reason = described_class.unavailability(prober:)

      expect(reason).to include("docker --version")
      expect(reason).to include("PATH")
      expect(calls).to eq([%w[docker --version]])
    end

    it "names docker info and that its daemon did not answer, once a client is found" do
      prober, calls = canned_prober(true, false)

      reason = described_class.unavailability(prober:)

      expect(reason).to include("docker info")
      expect(reason).to include("daemon")
      expect(calls).to eq([%w[docker --version], %w[docker info]])
    end

    it "names the image and that it is not present locally, once a daemon answers" do
      prober, calls = canned_prober(true, true, false)

      reason = described_class.unavailability(prober:)

      expect(reason).to include(described_class::IMAGE)
      expect(reason).to include("not present locally")
      expect(calls.last).to eq(["docker", "image", "inspect", described_class::IMAGE])
    end

    it "is nil once a client, a daemon and the image all answer" do
      prober, = canned_prober(true, true, true)

      expect(described_class.unavailability(prober:)).to be_nil
    end
  end
end

# The container arm of the exec seam. Split in two on purpose, because the two
# halves answer different questions and only one of them needs a docker daemon:
#
# * The ARGV this backend builds is asserted against a recording inner backend.
#   That is where the mount set, the workdir, the scrub and the refusal live,
#   and every one of them is decided before a container exists.
# * What a real container actually does is asserted in the :seam block below,
#   which skips -- loudly, naming the missing precondition -- without docker.
RSpec.describe Lain::Exec::Docker do
  subject(:backend) { described_class.new(image: "img:1", project:, exec: inner, user: "1000:1000") }

  # Stands in for the inner {Lain::Exec} backend the docker argv is run
  # through, recording the whole call rather than only the command: the cwd and
  # env this backend hands the DOCKER CLIENT are decisions of its own.
  #
  # `calls` because the client is asked what it IS through this same backend,
  # so a run is now TWO invocations of it and both the order between them and
  # the DEADLINE each is given are decisions of this backend's. The singular
  # readers stay the LAST call, which is the run -- every example below that
  # asserts an argv means that one.
  let(:inner) do
    Class.new do
      attr_reader :command, :cwd, :env, :timeout, :sinks, :calls

      def initialize = @calls = []

      def call(command:, cwd:, env:, timeout:, **sinks)
        @calls << { command:, cwd:, env:, timeout: }
        @command = command
        @cwd = cwd
        @env = env
        @timeout = timeout
        @sinks = sinks
        Lain::Exec::Capture.new(exit_status: 0, stdout: "", stderr: "")
      end
    end.new
  end

  let(:project) { "/srv/project" }

  def run(command: "echo hi", cwd: project, env: {}, timeout: 30, **)
    backend.call(command:, cwd:, env:, timeout:, **)
  end

  # One argv Array inside a one-stage TERM: the docker client is exec'd
  # directly, never through a shell of ours.
  def argv
    expect(inner.command.size).to eq(1)
    inner.command.first
  end

  def flag_values(name) = argv.each_cons(2).select { |flag, _| flag == name }.map(&:last)

  describe "the docker invocation it builds" do
    # STRUCTURE, not the first four elements: what follows `--rm` depends on
    # which client is answering (see "how the calling user reaches the
    # container" below), and a positional assertion on the head would pin an
    # argv this backend deliberately does not always build.
    it "runs one throwaway container per command" do
      run

      expect(argv.first(3)).to eq(%w[docker run --rm])
    end

    it "puts the image immediately before what the container is asked to run" do
      run(command: "echo hi")

      expect(argv.last(4)).to eq(["img:1", "sh", "-c", "echo hi"])
    end

    # With the image absent, the client narrates its own pull progress
    # into the same stderr the command's own output rides, so a tool result
    # carries transfer noise the model then reads as if it were the command's
    # own. `--quiet` asks the client not to.
    it "asks the client not to narrate its own image-pull progress" do
      run(command: "echo hi")

      expect(argv).to include("--quiet")
      expect(argv.last(4)).to eq(["img:1", "sh", "-c", "echo hi"])
    end

    it "hands the command to `sh -c` inside the container, exactly as the local arm does" do
      run(command: "echo one && echo two")

      expect(argv.last(3)).to eq(["sh", "-c", "echo one && echo two"])
    end

    it "passes the caller's timeout through to whatever runs the client" do
      run(timeout: 7)

      expect(inner.timeout).to eq(7)
    end

    it "streams the caller's live sinks, because the client's own stdout is the command's" do
      out = []
      run(stdout_sink: out)

      expect(inner.sinks).to include(stdout_sink: out)
    end
  end

  describe "what the container can see" do
    it "mounts the project at its own path, so the paths in a command mean the same thing" do
      run

      expect(flag_values("--volume")).to eq(["/srv/project:/srv/project"])
    end

    it "works in the cwd the caller resolved" do
      run(cwd: "/srv/project/lib")

      expect(flag_values("--workdir")).to eq(["/srv/project/lib"])
    end

    it "mounts nothing extra for a cwd inside the project" do
      run(cwd: "/srv/project/lib")

      expect(flag_values("--volume")).to eq(["/srv/project:/srv/project"])
    end

    # The mount set is exactly {project} plus {cwd}, and never more. That is
    # STRICTLY narrower than the local backend, which hands the command the
    # whole host filesystem -- it is not confinement, and the class doc says so.
    it "mounts a cwd that lies outside the project as well, rather than working in an empty directory" do
      run(cwd: "/tmp/elsewhere")

      expect(flag_values("--volume")).to eq(["/srv/project:/srv/project", "/tmp/elsewhere:/tmp/elsewhere"])
    end

    it "mounts the project once when the cwd IS the project" do
      run(cwd: project)

      expect(flag_values("--volume")).to eq(["/srv/project:/srv/project"])
    end

    # A sibling whose name merely STARTS with the project's is not inside it.
    it "does not take a lexical prefix for containment" do
      run(cwd: "/srv/project-notes")

      expect(flag_values("--volume").size).to eq(2)
    end

    # ONE OF THE TWO MECHANISMS, named as one. Files a command writes end up
    # owned the way the local backend owns them either by this flag or by a
    # client that already runs the container as the host user -- so the name
    # says which of the two is being pinned here, and "how the calling user
    # reaches the container" below owns the choice between them.
    it "names the calling user for a client that needs telling" do
      run

      expect(flag_values("--user")).to eq(["1000:1000"])
    end
  end

  # The reason this backend only ever worked on one client: `--user`
  # is not the same INSTRUCTION to every client. Measured on one bind mount:
  #
  #   docker run --rm --user 1000 ... alpine sh -c 'cat seed.txt; touch made'
  #     -> uid=1000(tara)  cat: Permission denied   touch: Permission denied
  #   docker run --rm             ... alpine sh -c 'cat seed.txt; touch made2'
  #     -> uid=0(root)     seed                     made2 owned by tara on the host
  #
  # Under rootless podman the host user is ALREADY the container's root, so
  # naming the host uid maps it to an id that owns nothing; under docker the
  # flag is exactly right. So the question asked is what the CLIENT is, not
  # whether it is rootless -- a ROOTFUL podman behaves like docker, and a fix
  # keyed on "is podman" would break that host instead.
  describe "how the calling user reaches the container" do
    # No `user:` override: these examples are about the CALLING process, which
    # is what the backend defaults to and what the seam below checks for real.
    def backend_asking(prober) = described_class.new(project:, image: "img:1", exec: inner, prober:)

    def run_through(backend) = backend.call(command: "echo hi", cwd: project, env: {}, timeout: 5)

    it "names no user for a client that maps the host user to container root" do
      run_through(backend_asking(->(_timeout) { "podman version 6.1.0\n" }))

      expect(argv).not_to include("--user")
    end

    it "still hands a docker client the calling user, whose files the operator would otherwise not own" do
      run_through(backend_asking(->(_timeout) { "Docker version 27.3.1, build ce12230\n" }))

      expect(flag_values("--user")).to eq(["#{Process.uid}:#{Process.gid}"])
    end

    # Conservative on purpose: a client that will not say what it is keeps the
    # flag this backend has always passed, which is right for every client but
    # the one that names itself.
    it "keeps today's behaviour for a client that answers nothing usable" do
      expect { run_through(backend_asking(->(_timeout) {})) }.not_to raise_error

      expect(flag_values("--user")).to eq(["#{Process.uid}:#{Process.gid}"])
    end

    # SEQUENTIALLY once, which is the property this pins. Sibling subagent
    # fibers share ONE backend and can each reach the question before the memo
    # is written -- measured, benign, and accounted for on {UserMapping}
    # itself: the question is idempotent and every racer computes the same
    # Array.
    it "asks the client once, then answers every later command from the memo" do
      asked = 0
      prober = lambda do |_timeout|
        asked += 1
        "podman version 6.1.0\n"
      end
      backend = backend_asking(prober)

      run_through(backend)
      run_through(backend)

      expect(asked).to eq(1)
    end

    # The prober is not a second transport. The client is asked what it is
    # through the very backend the client itself runs through, which is why
    # every unit example in this file spawns nothing, and why the operator's
    # DOCKER_HOST reaches the question exactly as it reaches the run.
    it "asks the client through the same backend it runs the client through" do
      run

      expect(inner.calls.first[:command]).to eq([%w[docker --version]])
    end

    # THE QUESTION IS SPENT FROM THE CALLER'S BUDGET. A command asking for one
    # second must not wait ten for a client that will not answer -- and it did:
    # a client that slept on `--version` returned a caller's `timeout: 1` after
    # 10.4 seconds, reporting SUCCESS, because the probe carried a deadline of
    # its own that nothing capped.
    it "asks the client within the deadline the command was given, not one of its own" do
      run(timeout: 1)

      expect(inner.calls.first[:timeout]).to eq(1)
    end

    # The other half of the same `min`: a generous caller does not license an
    # unbounded wait on a client that never answers.
    it "does not spend a generous caller's whole deadline on the question" do
      run(timeout: 600)

      expect(inner.calls.first[:timeout]).to eq(10)
    end

    # `@param prober [#call]` is a documented injection seam, and a seam
    # promises nothing about what comes back through it. The conservative
    # answer therefore belongs to the object that ASKS, not to the one default
    # prober that happens to rescue for itself -- an injected prober that
    # raised used to kill the command it was asked on behalf of.
    it "keeps today's behaviour when the prober itself raises" do
      expect { run_through(backend_asking(->(_timeout) { raise "boom" })) }.not_to raise_error

      expect(flag_values("--user")).to eq(["#{Process.uid}:#{Process.gid}"])
    end

    # Matching a Regexp against a String tagged UTF-8 that is not valid UTF-8
    # RAISES. Not reachable through the default prober -- `Shell::Pipeline`
    # hands back ASCII-8BIT -- but reachable the moment `exec:` is something
    # that decodes, `Exec::Core` over msgpack being the one already in the
    # tree. Named `podman` on purpose: the fallback is what protects the
    # command, not a lucky non-match.
    it "keeps today's behaviour when the client answers bytes that are not valid UTF-8" do
      broken = (+"podman \xC3(").force_encoding(Encoding::UTF_8)

      expect { run_through(backend_asking(->(_timeout) { broken })) }.not_to raise_error

      expect(flag_values("--user")).to eq(["#{Process.uid}:#{Process.gid}"])
    end

    # The client NAMES ITSELF in its first word, so that is where the question
    # is asked. A docker client that merely mentions podman further along --
    # a shim, a compat note -- is a docker client, and mapping it to root
    # would hand the operator the root-owned files `--user` exists to prevent.
    it "reads the client's first word, not any mention of podman further along" do
      run_through(backend_asking(->(_timeout) { "Docker version 27.3.1, build ce12230 (podman-compat shim)\n" }))

      expect(flag_values("--user")).to eq(["#{Process.uid}:#{Process.gid}"])
    end

    # `docker --version` contacts no daemon, but a client can still be absent,
    # or hang until the deadline. A failed probe is not a failed command.
    it "keeps today's behaviour when asking the client fails outright" do
      refusing = Class.new do
        attr_reader :command

        def call(command:, **)
          raise Lain::Exec::Timeout, "the client never answered" if command.flatten.include?("--version")

          @command = command
          Lain::Exec::Capture.new(exit_status: 0, stdout: "", stderr: "")
        end
      end.new
      backend = described_class.new(project:, image: "img:1", exec: refusing)

      expect { run_through(backend) }.not_to raise_error

      expect(refusing.command.first).to include("--user")
    end
  end

  # THE BLOCKER THIS ROUND FIXED. `/proc/<pid>/cmdline` is world-readable and
  # `/proc/<pid>/environ` is owner-only, so a value on the docker client's
  # command line is a disclosure `Exec::Local` -- which passes the same values
  # by fork inheritance -- does not make. Measured against a real
  # `WorkerEnv.default`: 62 `--env NAME=value` flags, carrying
  # CLAUDE_CODE_MESSAGING_TOKEN, STARSHIP_SESSION_KEY and, in any real chat,
  # ANTHROPIC_API_KEY. The argv now carries NAMES; the values ride the client's
  # own environment, which is where Local already keeps them.
  describe "what reaches the command line" do
    it "puts no value on the command line, whatever the session is carrying" do
      secret = "sk-ant-do-not-disclose"

      run(env: { "LAIN_TOKEN" => secret, "LANG" => "en_GB.UTF-8" })

      expect(argv.grep(/#{Regexp.escape(secret)}/)).to be_empty
      expect(argv.join(" ")).not_to include(secret)
    end

    it "names the variable instead, so docker forwards it from the client's own environment" do
      run(env: { "LAIN_TOKEN" => "sk-ant-do-not-disclose" })

      expect(flag_values("--env")).to eq(["LAIN_TOKEN"])
    end

    # The client is a host process and keeps the host's environment, so the
    # value has to reach it as an override -- that is the whole mechanism by
    # which a bare `--env NAME` forwards anything.
    it "hands the client the values it will forward, where only its owner can read them" do
      run(env: { "LAIN_TOKEN" => "sk-ant-do-not-disclose" })

      expect(inner.env).to eq({ "LAIN_TOKEN" => "sk-ant-do-not-disclose" })
    end

    # DOCKER_HOST / DOCKER_CONTEXT select which daemon the client addresses and
    # are the operator's to set. An additive override map leaves them in place;
    # the inner backend still applies the framework scrub over the top.
    it "overrides only what crosses, so the operator's daemon selection survives" do
      run(env: { "LAIN_TOKEN" => "x", "DOCKER_HOST" => "ssh://box" })

      expect(inner.env.keys).to eq(["LAIN_TOKEN"])
    end
  end

  # The environment arm, and the SHOULD-FIX that closed with it. The container
  # starts from the image's environment, so a variable crosses only by being
  # named -- which makes the question "what crosses?" an allowlist, not a
  # denylist over an unbounded set.
  describe "what crosses into the container" do
    it "never names a framework variable" do
      capture = backend.call(command: "env", cwd: project, timeout: 5,
                             env: { "BUNDLE_GEMFILE" => "/lain/Gemfile", "RUBYOPT" => "-rbundler/setup" })

      expect(capture.exit_status).to eq(0)
      expect(flag_values("--env")).to be_empty
    end

    it "scrubs a framework variable inherited from the live process, not only one the caller passed" do
      with_env("BUNDLE_GEMFILE" => "/lain/Gemfile") do
        run(env: { "LAIN_LENT" => "on loan" })
      end

      expect(flag_values("--env")).to eq(["LAIN_LENT"])
    end

    it "crosses a variable in lain's own namespace, which is how a session lends one" do
      run(env: { "LAIN_LENT" => "on loan" })

      expect(flag_values("--env")).to include("LAIN_LENT")
    end

    it "crosses locale, which means the same thing on both sides" do
      run(env: { "LANG" => "en_GB.UTF-8", "LC_ALL" => "C", "TZ" => "Europe/London" })

      expect(flag_values("--env")).to eq(%w[LANG LC_ALL TZ])
    end

    # The image describes the machine it is: its own PATH, its own HOME.
    it "leaves the variables that describe the machine to the image" do
      run(env: { "PATH" => "/home/linuxbrew/bin", "HOME" => "/home/tara", "LAIN_LENT" => "1" })

      expect(flag_values("--env")).to eq(["LAIN_LENT"])
    end

    # The measured list from the panel's probe. Every one names a HOST path
    # that does not exist inside the container, and a ten-name denylist had
    # none of them. LD_LIBRARY_PATH is this repo's OWN required export.
    it "crosses none of the host paths a denylist missed" do
      run(env: { "LD_LIBRARY_PATH" => "/home/linuxbrew/.linuxbrew/lib", "GEM_HOME" => "/home/tara/.gem",
                 "RUBYLIB" => "/home/tara/lib", "TMPDIR" => "/home/tara/tmp/lain",
                 "XDG_RUNTIME_DIR" => "/run/user/1000", "SSH_AUTH_SOCK" => "/run/user/1000/ssh-agent" })

      expect(flag_values("--env")).to be_empty
    end

    # THE INVERSION, stated as an example because a comment cannot fail.
    # {Exec.child_env} keeps GEM_* deliberately -- "the child still has to find
    # its gems" -- and that is a HOST fact. A container's gems are the image's,
    # so the same name must NOT cross here.
    it "does not carry GEM_HOME across, though the local arm deliberately keeps it" do
      expect(Lain::Exec.child_env({ "GEM_HOME" => "/host/gems" })).to include("GEM_HOME" => "/host/gems")

      run(env: { "GEM_HOME" => "/host/gems" })

      expect(flag_values("--env")).to be_empty
    end

    it "runs the client from the project, a directory that certainly exists" do
      run(cwd: "/tmp/elsewhere")

      expect(inner.cwd).to eq(project)
    end
  end

  describe "a shape it cannot run" do
    it "runs a single-stage term as argv, with no shell inside the container either" do
      run(command: [%w[grep -r foo .]])

      expect(argv.last(5)).to eq(["img:1", "grep", "-r", "foo", "."])
    end

    # A container takes ONE argv and a pipe needs a shell. Joining the stages
    # back into a string is the one thing this must not do -- it would hand
    # `sh -c` the very command the term path exists to keep away from it
    # (Shell::Verdict's own rule, and {Exec::Core} refuses for it too).
    it "refuses a piped term loudly rather than joining it back into a shell string" do
      expect { run(command: [%w[grep -r foo .], %w[wc -l]]) }
        .to raise_error(Lain::Exec::Unsupported, /one argv|pipe/i)
    end

    it "says the stages out loud in the refusal, so the caller can see what it handed over" do
      expect { run(command: [%w[grep foo], %w[wc -l]]) }
        .to raise_error(Lain::Exec::Unsupported, /grep/)
    end

    # The verdict ALLOWS an ordinary pipeline, so a caller that offered every
    # allowed term here would meet this refusal in ordinary use. That is what
    # the predicate is for: {Tools::Bash} asks first and falls back to the
    # model's own string. The refusal stays, as the answer for a caller that
    # does not ask -- and stays a refusal rather than a rejoin, because a
    # rejoined string is what the term path exists to keep away from a shell.
    it "refuses a term the verdict allows, for any caller that offers one without asking" do
      decision = Lain::Shell::Verdict.new.call("grep -r foo . | wc -l")

      expect(decision).to be_allow
      expect(decision.term.size).to be > 1
      expect { run(command: decision.term) }.to raise_error(Lain::Exec::Unsupported)
    end

    # The only row of the seam's truth table with two different answers in it,
    # which is why the predicate is asked WITH a term: one stage runs, a pipe
    # cannot, and no argument-less question could say so.
    def run_term(term) = run(command: term)
    def terms_taken = [[%w[grep -r foo .]]]
    def terms_refused = [[%w[grep -r foo .], %w[wc -l]]]

    it_behaves_like "an exec backend answering for a term"

    # The wrong answer available here: EVERY command this backend runs reaches
    # its inner backend as one docker argv, so a predicate reading that would
    # call a piped term one-stage. The question is about what the CALLER holds.
    it "answers about the caller's term, never about the docker argv it wraps" do
      run(command: "echo hi")

      expect(inner.command.size).to eq(1)
      expect(backend.takes_term?([%w[echo hi], %w[cat]])).to be(false)
    end
  end

  # The real thing. Everything above decides an argv; this is the only place a
  # container actually starts, and it is why the backend is worth having.
  describe "in a real container", :seam do
    # Two hooks, because `skip` is not supported inside a `before(:context)`:
    # that one asks the question once for the group, this one acts on the
    # answer per example.
    #
    # The cop's hazard is state LEAKING between examples, and what this sets is
    # a String that every example reads and none writes -- the probe's answer
    # cannot change mid-run. The alternatives both cost something real: a class
    # instance variable trips ThreadSafety/ClassInstanceVariable, and a `let`
    # re-probes per example, which on the box this hook exists for (a remote
    # DOCKER_HOST where `docker info` hangs) turns one hang into six.
    before(:context) { @unavailable = DockerBackendAvailability.unavailability } # rubocop:disable RSpec/BeforeAfterAll

    before { skip("Lain::Exec::Docker :seam skipped -- #{@unavailable}") if @unavailable }

    around do |example|
      Dir.mktmpdir("lain-exec-docker") do |dir|
        @project = File.realpath(dir)
        example.run
      end
    end

    # The REAL default image, the real user, the real inner backend -- only the
    # project is a throwaway.
    let(:real) { described_class.new(project: @project) }

    def run_real(command, cwd: @project, env: {}, timeout: 60)
      real.call(command:, cwd:, env:, timeout:)
    end

    it "runs the command somewhere that is not this machine" do
      capture = run_real("hostname")

      expect(capture.exit_status).to eq(0)
      expect(capture.stdout.strip).not_to eq(Socket.gethostname)
    end

    # The QA round's own reproduction of the `--user` defect, run as
    # ONE container so a client that still passed a wrong `--user` fails BOTH
    # halves at once rather than just one of them:
    #
    #   docker run --rm --user 1000 ... alpine sh -c 'cat seed.txt; touch made'
    #     -> uid=1000(tara)  cat: Permission denied   touch: Permission denied
    #   docker run --rm             ... alpine sh -c 'cat seed.txt; touch made'
    #     -> uid=0(root)     seed                     made lands on the host, owned by tara
    it "reads a seeded file and writes a new one, whichever client is installed" do
      File.write(File.join(@project, "seed.txt"), "seed\n")

      capture = run_real("cat seed.txt; touch made")

      expect(capture.stdout).to eq("seed\n")
      made = File.join(@project, "made")
      expect(File.exist?(made)).to be(true)
      expect(File.stat(made).uid).to eq(Process.uid)
    end

    it "keeps lain's own Gemfile out of the container, whatever the host is carrying" do
      capture = with_env("BUNDLE_GEMFILE" => "/home/tara/dev/lain/Gemfile") do
        run_real(%(env; echo scanned), env: ENV.to_h)
      end

      expect(capture.stdout).to include("scanned")
      expect(capture.stdout).not_to include("BUNDLE_GEMFILE")
    end

    it "reports a nonzero exit the way the local backend does" do
      expect(run_real("exit 3").exit_status).to eq(3)
    end

    it "raises the seam's one Timeout when the command outlives its deadline" do
      expect { run_real("sleep 30", timeout: 1) }.to raise_error(Lain::Exec::Timeout)
    end
  end
end
