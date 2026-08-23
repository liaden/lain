# frozen_string_literal: true

require "fileutils"

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
      expect(resolve("docker", path: docker_on_path, image: "ruby:3.4-slim").image).to eq("ruby:3.4-slim")
    end

    it "falls back to the backend's own default image when none is named" do
      expect(resolve("docker", path: docker_on_path).image).to eq(Lain::Exec::Docker::DEFAULT_IMAGE)
    end

    # Thor hands an unset --exec-image through as nil, and a nil image would
    # reach `docker run` as a missing argument rather than as a default.
    it "treats an explicitly nil image as none given" do
      expect(resolve("docker", path: docker_on_path, image: nil).image).to eq(Lain::Exec::Docker::DEFAULT_IMAGE)
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
end
