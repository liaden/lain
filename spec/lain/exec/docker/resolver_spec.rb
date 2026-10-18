# frozen_string_literal: true

require "fileutils"
require "json"
require "rubygems/package"
require "stringio"

RSpec.describe Lain::Exec::Docker::Resolver do
  around do |example|
    Dir.mktmpdir("lain-docker-resolver") do |dir|
      @dir = File.realpath(dir)
      @root = File.join(@dir, "project")
      FileUtils.mkdir_p(File.join(@root, "bin"))
      File.write(File.join(@root, "bin", "check"), "#!/bin/sh\n")
      File.chmod(0o755, File.join(@root, "bin", "check"))
      example.run
    end
  end

  let(:id) { "d529dd0c6e5597ac7e4a3e2dea65c3fcc6173f4cae713c409265c1dd9914a11b" }
  let(:paths) { Lain::Paths.new(env: { "HOME" => @dir, "XDG_CACHE_HOME" => File.join(@dir, "cache") }) }
  let(:journal) { [] }
  let(:notices) { [] }
  let(:notice) { ->(text) { notices << text } }
  let(:worker_env) { Lain::WorkerEnv.new(cwd: @root, env: { "PATH" => "/usr/bin:/bin" }) }

  def capture(stdout = "", exit_status: 0, stderr: "") = Lain::Exec::Capture.new(exit_status:, stdout:, stderr:)

  # uname sits only under /usr/local/bin, which execvp's default PATH does not search.
  def inspected(entrypoint: nil, as: id)
    capture("#{as}\n#{JSON.generate(["PATH=/usr/local/bin:/bin"])}\n#{JSON.generate(entrypoint)}\n")
  end

  def alpine_tar
    io = StringIO.new(+"", "w+b")
    Gem::Package::TarWriter.new(io) do |w|
      w.mkdir("bin/", 0o755)
      w.add_file_simple("bin/busybox", 0o755, 0) { nil }
      %w[ls cat].each { w.add_symlink("bin/#{_1}", "/bin/busybox", 0o777) }
      w.mkdir("usr/", 0o755)
      w.mkdir("usr/local/", 0o755)
      w.mkdir("usr/local/bin/", 0o755)
      w.add_symlink("usr/local/bin/uname", "../../../bin/busybox", 0o777)
    end
    io.string
  end

  def written = ->(file) { File.binwrite(file, alpine_tar) && capture }

  def in_turn(answers) = ->(_) { answers.size > 1 ? answers.shift : answers.first }

  def client(inspect: inspected, export: written, version: "Docker version 27.3.1")
    verbs = { "image" => in_turn(Array(inspect)), "create" => ->(_) { capture }, "rm" => ->(_) { capture },
              "export" => export, "--version" => ->(_) { capture("#{version}\n") } }
    Class.new do
      attr_reader :calls

      define_method(:initialize) { @calls = [] }

      define_method(:call) do |command:, **|
        argv = command.stages.first.argv
        @calls << argv
        verbs.fetch(argv[1]).call(argv[3])
      end
    end.new
  end

  def resolver_over(exec, fresh: Lain::Shell::Executable::Resolver::NeverFresh)
    docker = Lain::Exec::Docker.new(project: @root, image: "alpine:latest", exec:)
    described_class.new(docker:, root: @root, fresh:, journal:, paths:, notice:)
  end

  def stage(resolver, *argv, env: worker_env) = resolver.for(env).call(Lain::Shell::Term.of(argv)).sole

  def exports(exec) = exec.calls.count { _1[1] == "export" }

  def records = journal.grep(Lain::Telemetry::ExecImage)

  it "resolves an image program to its path in the listing, class system, with no anomaly" do
    resolved = stage(resolver_over(client), "uname", "-a")

    expect(resolved).to have_attributes(resolved: "/usr/local/bin/uname", realpath: "/bin/busybox", klass: :system,
                                        anomalies: [])
  end

  # The container works in the cwd's realpath, which is what is mounted, so a link to it is not followed by name.
  it "resolves a relative program in a symlinked cwd outside the project where the container runs it" do
    real = File.join(@dir, "elsewhere")
    FileUtils.mkdir_p(real)
    File.write(File.join(real, "tool"), "#!/bin/sh\n")
    File.chmod(0o755, File.join(real, "tool"))
    File.symlink(real, File.join(@dir, "link"))

    resolved = stage(resolver_over(client), "./tool", env: worker_env.with(cwd: File.join(@dir, "link")))

    expect(resolved).to have_attributes(resolved: File.join(real, "tool"), anomalies: [])
  end

  it "builds an image's listing into a filesystem once per image ID" do
    resolver = resolver_over(client)
    allow(Lain::Shell::Executable::ListedStat).to receive(:new).and_call_original

    2.times { stage(resolver, "ls") }

    expect(Lain::Shell::Executable::ListedStat).to have_received(:new).once
  end

  it "resolves a project script on the host, class project" do
    resolved = stage(resolver_over(client), "bin/check")

    expect(resolved).to have_attributes(resolved: File.join(@root, "bin", "check"), klass: :project)
    expect(resolved.to_journal).to include("resolved" => File.join(@root, "bin", "check"))
  end

  it "searches the image's PATH, not the one the worker lends" do
    resolved = stage(resolver_over(client), "ls", env: worker_env.with(env: { "PATH" => "/evil" }))

    expect(resolved).to have_attributes(resolved: "/bin/ls", klass: :system, skipped: [])
  end

  # A session freshness that has lost its rule answers every path fresh, and an image path must still not be.
  it "reads an image path as never fresh and a mounted one by the session's freshness" do
    fresh = Lain::Shell::Executable::Fresh.unknown(StandardError.new("lineage unreadable"), faults: [])
    resolver = resolver_over(client, fresh:)

    expect([stage(resolver, "ls").fresh, stage(resolver, "bin/check").fresh]).to eq([false, true])
  end

  # Under podman the caller is root in the container; ListedStat#writable? being false keeps an image file system.
  it "resolves image programs as system under a client that names itself podman" do
    resolved = stage(resolver_over(client(version: "podman version 5.2.0")), "ls")

    expect(resolved).to have_attributes(klass: :system, fresh: false)
  end

  it "journals the listing once per image ID, however many calls resolve" do
    resolver = resolver_over(client)
    2.times { stage(resolver, "ls") }

    expect(records).to eq([Lain::Telemetry::ExecImage.new(image: "alpine:latest", id:, listed: true, reason: nil)])
  end

  it "journals again when the tag comes to name a new image ID" do
    other = id.tr("d", "e")
    resolver = resolver_over(client(inspect: [inspected, inspected(as: other)]))
    2.times { stage(resolver, "ls") }

    expect(records.map(&:id)).to eq([id, other])
  end

  describe "where it keeps today's unresolved answer" do
    def unresolved?(executable)
      executable.to_journal.slice("klass", "anomalies") == { "klass" => "unresolved",
                                                             "anomalies" => ["container_backend"] }
    end

    it "leaves an image with an entrypoint unresolved, exports nothing, and journals why" do
      exec = client(inspect: inspected(entrypoint: ["/usr/local/bin/actionlint"]))

      expect(unresolved?(stage(resolver_over(exec), "ls"))).to be(true)
      expect(exports(exec)).to eq(0)
      expect(records.sole)
        .to have_attributes(id:, listed: false, reason: a_string_including('ENTRYPOINT ["/usr/local/bin/actionlint"]'))
      expect(notices).to be_empty
    end

    it "leaves a tag the client cannot inspect unresolved" do
      expect(unresolved?(stage(resolver_over(client(inspect: capture(exit_status: 125))), "ls"))).to be(true)
    end

    it "tells the human once per image ID when the listing fails, naming the failure" do
      resolver = resolver_over(client(export: ->(_) { capture(exit_status: 1, stderr: "daemon gone") }))

      first = stage(resolver, "ls")
      stage(resolver, "ls")

      expect(unresolved?(first)).to be(true)
      expect(notices.sole).to include("docker export exited 1: daemon gone")
      expect(records.sole).to have_attributes(listed: false, reason: "docker export exited 1: daemon gone")
    end

    it "names the cache file to delete for a failure cached on disk" do
      resolver = resolver_over(client(export: ->(_) { raise Lain::Exec::Timeout, "export ran long" }))

      expect(unresolved?(stage(resolver, "ls"))).to be(true)
      expect(notices.sole).to include("delete #{paths.exec_image_listing(id)} and relaunch to retry")
    end
  end
end
