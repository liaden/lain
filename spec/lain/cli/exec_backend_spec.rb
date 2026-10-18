# frozen_string_literal: true

require "fileutils"
require "rubygems/package"
require "stringio"

# The one seam that turns `--exec <name>` into an execution backend. Every
# example here runs with NO docker on the box: availability is decided from an
# INJECTED PATH, so both answers -- refused, and resolved -- are reachable on a
# machine that has never installed docker, which is exactly the machine the
# refusal exists for.
RSpec.describe Lain::CLI::ExecBackend do
  around do |example|
    Dir.mktmpdir("lain-exec-backend") do |dir|
      @bin = File.join(File.realpath(dir), "bin")
      FileUtils.mkdir_p(@bin)
      example.run
    end
  end

  # A PATH holding nothing at all: the box with no docker, stated rather than
  # inherited from whatever the machine running the suite happens to have.
  let(:empty_path) { @bin }

  # The same PATH with an executable named `docker` on it. Contents are
  # irrelevant -- the resolver asks whether the client EXISTS, never what it
  # answers (see the class doc on why the daemon is not probed here).
  def docker_on_path
    File.write(File.join(@bin, "docker"), "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, File.join(@bin, "docker"))
    @bin
  end

  # `root:` is REQUIRED on the resolver now (see its constructor's note, and
  # spec/lain/project/root_defaults_spec.rb): what it becomes is a container's
  # mount, and a working-directory default is how the wrong tree gets mounted
  # silently. An obviously-fake default here keeps every example that does not
  # care about the root readable, while the ones that do still state their own.
  def resolve(name = nil, path: empty_path, root: "/srv/exec-backend-project", **)
    described_class.resolve(name, path:, root:, **)
  end

  describe "the default" do
    it "is the in-process backend when no exec option is given" do
      expect(resolve).to be_a(Lain::Exec::Local)
    end

    it "is what the explicit default name resolves to as well" do
      expect(resolve(described_class::DEFAULT)).to be_a(Lain::Exec::Local)
    end

    # The default costs nothing and asks the environment nothing: a box with no
    # docker resolves it from an empty PATH exactly as before.
    it "needs no docker to resolve, so an unflagged run is untouched by this card" do
      expect { resolve }.not_to raise_error
    end
  end

  describe "the advertised set" do
    it "resolves every name it advertises, so the help text and the mapping cannot drift" do
      path = docker_on_path

      expect(described_class::BACKENDS.map { |name| resolve(name, path:).class })
        .to eq([Lain::Exec::Local, Lain::Exec::Docker])
    end

    it "refuses an unrecognized name, naming the valid set" do
      expect { resolve("podman") }
        .to raise_error(described_class::Unknown, /unknown exec backend "podman".*local.*docker/m)
    end

    # `core` is a real backend of the seam and deliberately NOT selectable
    # here: it needs a started daemon client and a reactor to hold it, neither
    # of which a flag can hand over. Refusing it by name beats resolving it
    # into something that dies at the first command.
    it "refuses the core backend by name rather than half-wiring it" do
      expect { resolve("core") }.to raise_error(described_class::Unknown)
    end
  end

  describe "an unusable backend" do
    it "refuses at resolve when there is no docker client on PATH, naming the flag and the client" do
      expect { resolve("docker") }
        .to raise_error(described_class::Unavailable, /--exec docker.*docker.*PATH/m)
    end

    # A directory named `docker` is not a client. `File.executable?` says true
    # for every directory, so the presence test has to ask both questions.
    it "does not mistake a directory named docker for the client" do
      FileUtils.mkdir_p(File.join(@bin, "docker"))

      expect { resolve("docker") }.to raise_error(described_class::Unavailable)
    end

    # Still a {Lain::Error}, so exe/lain renders it as a message and exits
    # nonzero instead of printing a backtrace -- the property that makes
    # "refuses by name" true at the terminal.
    it "keeps that refusal inside the taxonomy exe/lain rescues" do
      expect { resolve("docker") }.to raise_error(Lain::Error)
      expect { resolve("podman") }.to raise_error(Lain::Error)
    end
  end

  describe "the docker backend it builds" do
    it "carries the image it was given" do
      expect(resolve("docker", path: docker_on_path, image: "ruby:3.4-slim").tag).to eq("ruby:3.4-slim")
    end

    it "falls back to the backend's own default image when none is named" do
      expect(resolve("docker", path: docker_on_path).tag).to eq(Lain::Exec::Docker::DEFAULT_IMAGE)
    end

    # Thor hands an unset --exec-image through as nil, and a nil image would
    # reach `docker run` as a missing argument rather than as a default.
    it "treats an explicitly nil image as none given" do
      expect(resolve("docker", path: docker_on_path, image: nil).tag).to eq(Lain::Exec::Docker::DEFAULT_IMAGE)
    end

    it "mounts the project it was resolved for, not the directory the resolver ran in" do
      expect(resolve("docker", path: docker_on_path, root: @bin).project).to eq(@bin)
    end

    # `realpath`, not `expand_path`, and {IsolationBackend} spells it the same
    # way for the same reason: a symlinked root would mount as
    # `<symlink>:<symlink>`, and everything inside the container that RESOLVES
    # (git, `__dir__`, a `..` that crosses the link) would then disagree with
    # the path the command was handed. The seam spec realpaths its tmpdir, so
    # without this the two halves of this card mount different strings.
    it "mounts the resolved root, so a symlinked project cannot mount as its own link" do
      link = File.join(File.dirname(@bin), "link-to-bin")
      File.symlink(@bin, link)

      expect(resolve("docker", path: docker_on_path, root: link).project).to eq(File.realpath(@bin))
    end

    # The tolerance `expand_path` had, which {Project::Resolver.resolved} keeps:
    # a root naming nothing on disk is not this object's to refuse.
    it "still answers a root that names nothing on disk" do
      absent = File.join(@bin, "not", "here")

      expect(resolve("docker", path: docker_on_path, root: absent).project).to eq(absent)
    end
  end

  describe "#resolver" do
    let(:fresh) { Lain::Shell::Executable::Resolver::NeverFresh }

    def backend_for(name, path: empty_path) = described_class.new(name, path:, root: "/srv/app")

    it "resolves a docker backend's programs from its image" do
      expect(backend_for("docker", path: docker_on_path).resolver(fresh:)).to be_a(Lain::Exec::Docker::Resolver)
    end

    # A real client process on PATH, so the backend, its Image and the resolver are the ones a launch builds.
    it "resolves an image program through the client the launch found, journalling the listing" do
      id = "d529dd0c6e5597ac7e4a3e2dea65c3fcc6173f4cae713c409265c1dd9914a11b"
      root = File.dirname(@bin)
      tar = File.join(root, "image.tar")
      File.binwrite(tar, StringIO.new(+"", "w+b").tap do |io|
        Gem::Package::TarWriter.new(io) do |w|
          w.mkdir("bin/", 0o755)
          w.add_file_simple("bin/busybox", 0o755, 0) { nil }
          w.add_symlink("bin/uname", "/bin/busybox", 0o777)
        end
      end.string)
      File.write(File.join(docker_on_path, "docker"), <<~SH)
        #!/bin/sh
        case "$1" in
          image) printf '%s\n["PATH=/bin"]\nnull\n' #{id} ;;
          export) cp #{tar} "$3" ;;
        esac
      SH
      journal = []
      paths = Lain::Paths.new(env: { "HOME" => root, "XDG_CACHE_HOME" => File.join(root, "cache") })
      built = described_class.new("docker", path: @bin, root:, journal:, paths:)

      stage = with_env("PATH" => "#{@bin}:#{ENV.fetch("PATH")}") do
        built.resolver(fresh:).for(Lain::WorkerEnv.new(cwd: root, env: {}))
             .call(Lain::Shell::Term.of(%w[uname -a])).sole
      end

      expect(stage).to have_attributes(resolved: "/bin/uname", klass: :system, anomalies: [])
      expect(journal.sole).to have_attributes(id:, listed: true)
    end

    it "tells the launch's notice when the client cannot export the image" do
      File.write(File.join(docker_on_path, "docker"), <<~SH)
        #!/bin/sh
        case "$1" in
          image) printf '%s\n["PATH=/bin"]\nnull\n' #{"d" * 64} ;;
          export) echo 'daemon gone' >&2; exit 1 ;;
        esac
      SH
      root = File.dirname(@bin)
      notices = []
      paths = Lain::Paths.new(env: { "HOME" => root, "XDG_CACHE_HOME" => File.join(root, "cache") })
      built = described_class.launch({ exec: "docker" }, env_pass: [], root:, path: @bin, paths:,
                                                         notice: ->(text) { notices << text })

      with_env("PATH" => "#{@bin}:#{ENV.fetch("PATH")}") do
        built.resolver(fresh:).for(Lain::WorkerEnv.new(cwd: root, env: {})).call(Lain::Shell::Term.of(%w[ls]))
      end

      expect(notices.sole).to include("docker export exited 1: daemon gone")
    end

    it "resolves on the host for the local backend and for no flag" do
      resolvers = [described_class::DEFAULT, nil].map { backend_for(_1).resolver(fresh:) }

      expect(resolvers).to all(be_a(Lain::Shell::Executable::Resolver))
    end
  end

  describe "#backend" do
    it "builds the backend once, so every reader holds the same object" do
      built = described_class.new("docker", path: docker_on_path, root: "/srv/app")

      expect(built.backend).to equal(built.backend)
    end
  end

  describe ".launch" do
    it "reads the exec flags from the options and builds the child env from the project's env pass" do
      built = described_class.launch({ exec: "docker", exec_image: "img:1" }, env_pass: %w[DATABASE_URL],
                                                                              root: "/srv/app", path: docker_on_path)

      expect(built.backend).to be_a(Lain::Exec::Docker).and have_attributes(tag: "img:1")
      expect(built.child_env.passes?("DATABASE_URL")).to be(true)
    end

    it "hands a local child the host's value for a passed name" do
      built = described_class.launch({}, env_pass: %w[LAIN_T1_LAUNCH], root: @bin)
      stdout = with_env("LAIN_T1_LAUNCH" => "from-host") do
        built.backend.call(command: "printenv LAIN_T1_LAUNCH", cwd: @bin, env: ENV.to_h, timeout: 10).stdout
      end

      expect(stdout).to eq("from-host\n")
    end
  end

  describe "what it holds for the launch" do
    it "reads back the child env, journal, paths and notice it was given" do
      child_env = Lain::Exec::ChildEnv.new(pass: %w[DATABASE_URL])
      journal = Lain::Channel.new
      paths = Lain::Paths.new
      notice = ->(_text) {}

      held = described_class.new(root: "/srv/app", child_env:, journal:, paths:, notice:)

      expect([held.child_env, held.journal, held.paths, held.notice])
        .to match([equal(child_env), equal(journal), equal(paths), equal(notice)])
    end
  end

  # Real processes, because what is claimed is what a child SEES: a ChildEnv a
  # backend held but never applied would pass any assertion made on the object.
  describe "the child environment it builds the backend over" do
    let(:passing) { Lain::Exec::ChildEnv.new(pass: %w[DATABASE_URL]) }

    def host(&) = with_env("PATH" => "#{@bin}:#{ENV.fetch("PATH")}", "DATABASE_URL" => "postgres://db", &)

    def printed(backend, command)
      host { backend.call(command:, cwd: @bin, env: ENV.to_h, timeout: 10).stdout }
    end

    it "hands a local child the names it passes" do
      expect(printed(resolve(root: @bin, child_env: passing), "printenv DATABASE_URL")).to eq("postgres://db\n")
    end

    it "withholds those names from a local child when none are passed" do
      expect(printed(resolve(root: @bin), "printenv DATABASE_URL")).to eq("")
    end

    it "hands the docker client the names it passes, and names each one to cross into the container" do
      client = File.join(docker_on_path, "docker")
      File.write(client, "#!/bin/sh\nprintf '%s|%s' \"$DATABASE_URL\" \"$*\"\n")

      value, argv = printed(resolve("docker", path: @bin, root: @bin, child_env: passing), "true").split("|")

      expect([value, argv]).to match(["postgres://db", a_string_including("--env DATABASE_URL")])
      expect(argv).not_to include("postgres://db")
    end
  end
end
