# frozen_string_literal: true

require "json"

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

  def capture(stdout, exit_status: 0) = Lain::Exec::Capture.new(exit_status:, stdout:, stderr: "")

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

  it "spawns nothing when built" do
    expect([image.tag, exec.calls]).to eq(["alpine:latest", []])
  end
end
