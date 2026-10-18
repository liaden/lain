# frozen_string_literal: true

require "json"
require "rubygems/package"
require "stringio"

RSpec.describe Lain::Exec::Docker::Image do
  subject(:image) { described_class.new(tag: "alpine:latest", exec:, cwd: "/srv/project") }

  let(:id) { "d529dd0c6e5597ac7e4a3e2dea65c3fcc6173f4cae713c409265c1dd9914a11b" }
  let(:exec) { recording_exec_answering_in_turn(inspected) }

  let(:inspected) do
    narrowed(id, { "Env" => ["PATH=/usr/bin:/bin", "A=b=c"], "Entrypoint" => ["/usr/local/bin/actionlint"] })
  end

  let(:question) do
    ["docker", "image", "inspect", "--format", "{{.Id}}\n{{json .Config.Env}}\n{{json .Config.Entrypoint}}",
     "alpine:latest"]
  end

  def capture(stdout, exit_status: 0, stderr: "") = Lain::Exec::Capture.new(exit_status:, stdout:, stderr:)

  def narrowed(id, config, exit_status: 0)
    capture([id, JSON.generate(config["Env"]), JSON.generate(config["Entrypoint"]), ""].join("\n"), exit_status:)
  end

  def recording_exec_answering_in_turn(*answers)
    Class.new do
      attr_reader :calls

      define_method(:initialize) { @calls = [] }

      define_method(:call) do |command:, cwd:, env:, timeout:|
        @calls << { argv: command.stages.first.argv, cwd:, env:, timeout: }
        answer = answers.size > 1 ? answers.shift : answers.first
        answer.is_a?(Exception) ? raise(answer) : answer
      end
    end.new
  end

  describe "#pin" do
    it "asks the client to inspect the tag and pins its ID, environment and entrypoint" do
      pin = image.pin(30)

      expect(exec.calls.map { _1[:argv] }).to eq([question])
      expect(pin).to eq(described_class::Pin.new(id:, env: { "PATH" => "/usr/bin:/bin", "A" => "b=c" },
                                                 entrypoint: ["/usr/local/bin/actionlint"]))
    end

    it "strips the sha256 prefix docker puts on an ID" do
      exec = recording_exec_answering_in_turn(narrowed("sha256:#{id}", {}))

      expect(described_class.new(tag: "alpine:latest", exec:, cwd: "/").pin(30).id).to eq(id)
    end

    it "pins an empty environment and entrypoint for an image that declares neither" do
      exec = recording_exec_answering_in_turn(narrowed(id, { "Env" => nil, "Entrypoint" => nil }))

      pin = described_class.new(tag: "alpine:latest", exec:, cwd: "/").pin(30)

      expect([pin.env, pin.entrypoint]).to eq([{}, []])
    end

    it "spends at most its own budget, and less when the asking deadline is shorter" do
      image.pin(600)
      image.pin(1)

      expect(exec.calls.map { _1[:timeout] }).to eq([described_class::INSPECT_BUDGET, 1])
    end

    it "asks again on every call, so a rebuilt tag is seen at once" do
      other = id.tr("d", "e")
      exec = recording_exec_answering_in_turn(inspected, narrowed(other, {}))
      image = described_class.new(tag: "alpine:latest", exec:, cwd: "/")

      expect([image.pin(30).id, image.pin(30).id]).to eq([id, other])
    end

    it "is nil for an image the client does not have, and pulls nothing" do
      exec = recording_exec_answering_in_turn(capture("", exit_status: 125))

      expect(described_class.new(tag: "alpine:latest", exec:, cwd: "/").pin(30)).to be_nil
      expect(exec.calls.map { _1[:argv] }).to eq([question])
    end

    it "is nil when the client exits nonzero, whatever it printed" do
      exec = recording_exec_answering_in_turn(narrowed(id, {}, exit_status: 1))

      expect(described_class.new(tag: "alpine:latest", exec:, cwd: "/").pin(30)).to be_nil
    end

    it "is nil for an environment whose bytes are not valid UTF-8" do
      exec = recording_exec_answering_in_turn(capture("#{id}\n[\"X=\xff\xfe\"]\nnull\n".b))

      expect(described_class.new(tag: "alpine:latest", exec:, cwd: "/").pin(30)).to be_nil
    end

    it "is nil for an ID whose bytes are not valid UTF-8" do
      exec = recording_exec_answering_in_turn(capture("\xff#{id[1..]}\nnull\nnull\n".force_encoding(Encoding::UTF_8)))

      expect(described_class.new(tag: "alpine:latest", exec:, cwd: "/").pin(30)).to be_nil
    end

    # docker refuses an upper-case reference, so such an ID could never be run.
    it "is nil for an ID in upper case" do
      exec = recording_exec_answering_in_turn(narrowed(id.upcase, {}))

      expect(described_class.new(tag: "alpine:latest", exec:, cwd: "/").pin(30)).to be_nil
    end

    it "keeps an environment entry with no value as an empty one, and a value's spaces and equals signs" do
      exec = recording_exec_answering_in_turn(narrowed(id, { "Env" => ["BARE", "GREETING=hello there=you"] }))

      pin = described_class.new(tag: "alpine:latest", exec:, cwd: "/").pin(30)

      expect(pin.env).to eq("BARE" => "", "GREETING" => "hello there=you")
    end

    # A wrong signature on the injected exec is a bug, not a missing image.
    it "lets an exec that rejects its arguments raise" do
      exec = recording_exec_answering_in_turn(ArgumentError.new("unknown keyword: :cwd"))

      expect { described_class.new(tag: "alpine:latest", exec:, cwd: "/").pin(30) }
        .to raise_error(ArgumentError, "unknown keyword: :cwd")
      expect(exec.calls.size).to eq(1)
    end

    it "is nil for an ID that is not 64 hex characters" do
      exec = recording_exec_answering_in_turn(narrowed("not-an-id", {}))

      expect(described_class.new(tag: "alpine:latest", exec:, cwd: "/").pin(30)).to be_nil
    end

    it "is nil for an answer that is not an inspect listing" do
      ["", id, "#{id}\nnot json\nnull", "#{id}\n{}\nnull", "#{id}\n\"PATH=/bin\"\nnull", "#{id}\n[]\n[1]"]
        .each do |stdout|
          exec = recording_exec_answering_in_turn(capture(stdout))

          expect(described_class.new(tag: "alpine:latest", exec:, cwd: "/").pin(30)).to be_nil
        end
    end

    it "is nil when the client does not answer in time" do
      exec = recording_exec_answering_in_turn(Lain::Exec::Timeout.new("inspect never answered"))

      expect(described_class.new(tag: "alpine:latest", exec:, cwd: "/").pin(30)).to be_nil
    end

    # An image's whole inspect carries its build history and its whole Config
    # its labels; either outgrows the bash ceiling a real client's capture is cut at.
    it "pins an image whose whole inspect would not fit the capture, through a real client" do
      Dir.mktmpdir("lain-docker-image-inspect") do |dir|
        bin = File.realpath(dir)
        File.write(File.join(bin, "docker"), <<~SH)
          #!/bin/sh
          big="$(head -c 40000 /dev/zero | tr '\\0' x)"
          case "$4" in
            *'.Config.Env'*) printf '%s\\n["PATH=/bin"]\\nnull\\n' #{id} ;;
            *) printf '%s {"Env":["PATH=/bin"],"Labels":{"big":"%s"}}\\n' #{id} "$big" ;;
          esac
        SH
        File.chmod(0o755, File.join(bin, "docker"))

        pin = with_env("PATH" => "#{bin}:#{ENV.fetch("PATH")}") do
          described_class.new(tag: "alpine:latest", exec: Lain::Exec::Local.new, cwd: bin).pin(10)
        end

        expect(pin&.id).to eq(id)
      end
    end

    it "pins a deeply frozen value" do
      expect(Ractor.shareable?(image.pin(30))).to be(true)
    end
  end

  describe "#reference" do
    it "names the pinned ID" do
      expect(image.reference(30)).to eq(id)
    end

    it "falls back to the tag when nothing is pinned" do
      exec = recording_exec_answering_in_turn(capture("", exit_status: 125))

      expect(described_class.new(tag: "alpine:latest", exec:, cwd: "/").reference(30)).to eq("alpine:latest")
    end
  end

  describe "#listing" do
    let(:cache) { Dir.mktmpdir("lain-image-cache") }
    let(:paths) { Lain::Paths.new(env: { "HOME" => cache, "XDG_CACHE_HOME" => cache }) }
    let(:pin) { described_class::Pin.new(id:, env: { "PATH" => "/usr/bin:/bin" }, entrypoint: []) }
    let(:other_pin) { pin.with(id: id.tr("d", "e")) }

    after { FileUtils.remove_entry(cache) }

    def alpine_tar
      io = StringIO.new(+"", "w+b")
      Gem::Package::TarWriter.new(io) do |w|
        w.mkdir("bin/", 0o755)
        w.add_file_simple("bin/busybox", 0o755, 4) { _1.write("\x7fELF") }
        w.add_symlink("bin/ls", "/bin/busybox", 0o777)
        w.mkdir("usr/", 0o755)
        w.mkdir("usr/bin/", 0o755)
        w.add_symlink("usr/bin/env", "../../bin/busybox", 0o777)
        w.mkdir("opt/", 0o755)
        w.mkdir("opt/bin/", 0o755)
        w.add_file_simple("opt/bin/tool", 0o755, 0) { nil }
        w.mkdir("etc/", 0o755)
        w.add_file_simple("etc/motd", 0o644, 0) { nil }
      end
      io.string
    end

    def written = ->(file) { File.binwrite(file, alpine_tar) && capture("") }

    def client(export: written, create: ->(_) { capture("") }, remove: ->(_) { capture("") })
      verbs = { "export" => export, "create" => create, "rm" => remove }
      Class.new do
        attr_reader :calls

        define_method(:initialize) { @calls = [] }

        define_method(:call) do |command:, **|
          argv = command.stages.first.argv
          @calls << argv
          verbs.fetch(argv[1]).call(argv[1] == "export" ? argv[3] : argv.last)
        end
      end.new
    end

    def exports(client) = client.calls.count { _1[1] == "export" }

    def image_over(exec) = described_class.new(tag: "alpine:latest", exec:, cwd: "/srv/project")

    def failure(reason, cache) = described_class::Failure.new(reason:, cache:)

    it "exports once, then reads the listing from the cache" do
      exec = client

      listings = [image_over(exec).listing(pin, paths:), image_over(exec).listing(pin, paths:)]

      expect(exports(exec)).to eq(1)
      expect(listings.first).to eq(listings.last)
      expect(listings.first.failure).to be_nil
      expect(listings.first.entries.keys).to include("/bin/ls", "/bin/busybox", "/usr/bin/env", "/usr/bin", "/")
      expect(listings.first.entries.keys).not_to include("/etc/motd")
    end

    it "searches the PATH the image declares" do
      listing = image_over(client).listing(pin.with(env: { "PATH" => "/opt/bin" }), paths:)

      expect(listing.entries.keys).to include("/opt/bin/tool")
      expect(listing.entries.keys).not_to include("/bin/ls")
    end

    it "searches /bin and /usr/bin for an image that declares no PATH" do
      listing = image_over(client).listing(pin.with(env: {}), paths:)

      expect(listing.entries.keys).to include("/bin/ls", "/usr/bin/env")
      expect(listing.entries.keys).not_to include("/opt/bin/tool")
    end

    it "is deeply frozen, listed or failed" do
      listed = image_over(client).listing(pin, paths:)
      failed = image_over(client(export: ->(_) { capture("", exit_status: 125) })).listing(other_pin, paths:)

      expect([Ractor.shareable?(listed), Ractor.shareable?(failed), failed.entries]).to eq([true, true, nil])
    end

    it "creates the container it exports from, and removes it" do
      exec = client
      image_over(exec).listing(pin, paths:)

      create, export, remove = exec.calls
      name = create[create.index("--name") + 1]
      expect(create.values_at(0, 1, -2, -1)).to eq(["docker", "create", id, "true"])
      expect([export.values_at(1, 4), remove]).to eq([["export", name], ["docker", "rm", "-f", name]])
    end

    it "still lists when the removal does not answer in time" do
      listing = image_over(client(remove: lambda { |_|
        raise Lain::Exec::Timeout, "rm never answered"
      })).listing(pin, paths:)

      expect(listing.entries.keys).to include("/bin/ls")
    end

    it "finishes removing the container when its task is stopped during the removal" do
      removed = []
      exec = client(remove: lambda do |name|
        sleep 0.1
        removed << name
        capture("")
      end)

      Sync do |top|
        task = top.async { image_over(exec).listing(pin, paths:) }
        sleep 0.01 until exec.calls.any? { _1[1] == "rm" }
        task.stop
        task.wait
      end

      expect(removed).to eq([exec.calls.first[exec.calls.first.index("--name") + 1]])
    end

    it "finishes removing the container when its thread is interrupted during the removal" do
      removed = []
      exec = client(remove: lambda do |name|
        sleep 0.1
        removed << name
        capture("")
      end)

      thread = Thread.new { image_over(exec).listing(pin, paths:) }
      sleep 0.01 until exec.calls.any? { _1[1] == "rm" }
      thread.raise(Interrupt)

      expect { thread.join }.to raise_error(Interrupt)
      expect(removed.size).to eq(1)
    end

    it "exports once when parallel askers ask together" do
      exec = client(export: lambda do |file|
        sleep 0.05
        written.call(file)
      end)
      image = image_over(exec)

      listings = Sync { |task| Array.new(3) { task.async { image.listing(pin, paths:) } }.map(&:wait) }

      expect([exports(exec), listings.uniq.size, listings.first.entries.nil?]).to eq([1, 1, false])
    end

    it "keys the cache by image ID" do
      exec = client
      image_over(exec).listing(pin, paths:)
      cached_a = File.binread(paths.exec_image_listing(id))

      image_over(exec).listing(other_pin, paths:)

      expect(exports(exec)).to eq(2)
      expect(File.binread(paths.exec_image_listing(id))).to eq(cached_a)
    end

    it "reads a malformed cache file as a miss" do
      File.write(paths.exec_image_listing(id), "{\"entries\": 3}")
      exec = client

      expect(image_over(exec).listing(pin, paths:).entries).to include("/bin/ls")
      expect(exports(exec)).to eq(1)
    end

    it "reads a cache row of the wrong shape as a miss" do
      File.write(paths.exec_image_listing(id), JSON.generate(entries: [["/bin", "directory", "755", 0, 0, nil]]))
      exec = client

      expect(image_over(exec).listing(pin, paths:).entries).to include("/bin/ls")
      expect(exports(exec)).to eq(1)
    end

    it "caches an unreadable tar as a failure, naming the cache file" do
      exec = client(export: ->(file) { File.binwrite(file, "x" * 1024) && capture("") })

      listings = Array.new(2) { image_over(exec).listing(pin, paths:) }

      expect(exports(exec)).to eq(1)
      expect(listings.map(&:entries)).to eq([nil, nil])
      expect(listings.map { _1.failure.cache }.uniq).to eq([paths.exec_image_listing(id)])
      expect(listings.map { _1.failure.reason }.uniq.size).to eq(1)
      expect(listings.first.failure.reason).to start_with("docker export wrote an unreadable tar: ")
    end

    it "keeps a listing, and names no cache file for a failure, when the cache cannot be written" do
      FileUtils.chmod(0o555, File.dirname(paths.exec_image_listing(id)))
      unreadable = client(export: ->(file) { File.binwrite(file, "x" * 1024) && capture("") })

      listed = image_over(client).listing(pin, paths:)
      failed = image_over(unreadable).listing(other_pin, paths:)

      expect(listed.entries).to include("/bin/ls")
      expect([failed.entries, failed.failure.cache]).to eq([nil, nil])
      expect(Dir.children(File.dirname(paths.exec_image_listing(id)))).to be_empty
    ensure
      FileUtils.chmod(0o755, File.dirname(paths.exec_image_listing(id)))
    end

    it "retries a client error in a new Image, and not in the same one" do
      answers = [capture("", stderr: "daemon down", exit_status: 125)]
      exec = client(export: ->(file) { answers.shift || written.call(file) })
      image = image_over(exec)

      reason = "docker export exited 125: daemon down"
      refused = described_class::Listing.new(entries: nil, failure: failure(reason, nil))
      expect([image.listing(pin, paths:), image.listing(pin, paths:)].uniq).to eq([refused])
      expect(exports(exec)).to eq(1)

      expect(image_over(exec).listing(pin, paths:).entries).to include("/bin/ls")
      expect(exports(exec)).to eq(2)
    end

    it "retries a create that did not answer in time in a new Image" do
      answers = [Lain::Exec::Timeout.new("create never answered")]
      exec = client(create: ->(_) { answers.empty? ? capture("") : raise(answers.shift) })

      first = image_over(exec).listing(pin, paths:)
      second = image_over(exec).listing(pin, paths:)

      expect([first.entries, first.failure.cache]).to eq([nil, nil])
      expect(second.entries).to include("/bin/ls")
    end

    it "names the create's budget when the create does not finish in time", :seam do
      stub_const("#{described_class}::INSPECT_BUDGET", 1)
      Dir.mktmpdir("lain-docker-bin") do |dir|
        File.write(File.join(dir, "docker"), "#!/bin/sh\necho created\n[ \"$1\" = create ] && exec sleep 30\nexit 0\n")
        File.chmod(0o755, File.join(dir, "docker"))

        listing = with_env("PATH" => "#{dir}:#{ENV.fetch("PATH")}") do
          described_class.new(tag: "alpine:latest", exec: Lain::Exec::Local.new, cwd: dir).listing(pin, paths:)
        end

        expect(listing.failure).to eq(failure("docker create did not finish in 1s", nil))
      end
    end

    # Through the production backend, with a fake client on PATH whose
    # export outlives the budget.
    it "caches a slow export as a failure and removes the container it created", :seam do
      stub_const("#{described_class}::LISTING_BUDGET", 1)
      Dir.mktmpdir("lain-docker-bin") do |dir|
        log = File.join(dir, "invocations")
        File.write(File.join(dir, "docker"),
                   "#!/bin/sh\necho \"$*\" >> #{log}\n[ \"$1\" = export ] && exec sleep 30\nexit 0\n")
        File.chmod(0o755, File.join(dir, "docker"))

        answers = with_env("PATH" => "#{dir}:#{ENV.fetch("PATH")}") do
          Array.new(2) { described_class.new(tag: "alpine:latest", exec: Lain::Exec::Local.new, cwd: dir) }
               .map { _1.listing(pin, paths:) }
        end

        invocations = File.readlines(log, chomp: true)
        name = invocations.first[/--name (\S+)/, 1]
        expect(answers.uniq).to eq([described_class::Listing.new(
          entries: nil, failure: failure("docker export did not finish in 1s", paths.exec_image_listing(id))
        )])
        expect(invocations.grep(/\Aexport /).size).to eq(1)
        expect(invocations).to include("rm -f #{name}")
      end
    end
  end

  it "spawns nothing when built" do
    expect([image.tag, exec.calls]).to eq(["alpine:latest", []])
  end
end
