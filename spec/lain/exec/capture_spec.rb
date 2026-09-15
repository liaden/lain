# frozen_string_literal: true

# What a command said, bounded while it is being said. The filling half holds a
# capped number of bytes and counts the rest, so a command that prints 200 MiB
# costs its size in a counter rather than in memory, and the human watching the
# live stream still sees every byte of it.
RSpec.describe Lain::Exec::Capture do
  describe "a capture built from whole streams" do
    it "counts the bytes it holds when it is handed no size, which is the daemon arm's truth" do
      capture = described_class.new(exit_status: 3, stdout: "out✅", stderr: "err")

      expect(capture.size).to eq("out✅".bytesize + 3)
    end

    it "has no ceiling, since it held every byte" do
      expect(described_class.new(exit_status: 0, stdout: "x", stderr: "").ceiling).to eq(Float::INFINITY)
    end

    it "keeps a size it is handed, which may exceed what it holds" do
      capture = described_class.new(exit_status: 0, stdout: "x", stderr: "", size: 200_000_000)

      expect(capture).to have_attributes(stdout: "x", size: 200_000_000)
    end
  end

  describe Lain::Exec::Capture::Bounded do
    subject(:bounded) { described_class.new(ceiling: 9, stdout_sink: out, stderr_sink: err) }

    let(:out) { RecordingChannel.new }
    let(:err) { RecordingChannel.new }

    def held(capture) = capture.stdout.bytesize + capture.stderr.bytesize

    it "counts every byte of both streams, past what it retains" do
      bounded.take(:stdout, "a" * 8).take(:stderr, "b" * 8).take(:stdout, "c" * 1000)

      expect(bounded.finish(0).size).to eq(1016)
    end

    it "finishes carrying its ceiling, so a renderer can refuse past what it held" do
      expect(bounded.take(:stdout, "hi").finish(0).ceiling).to eq(9)
    end

    it "retains one byte past its ceiling, across both streams together" do
      bounded.take(:stdout, "a" * 8).take(:stderr, "b" * 8).take(:stdout, "c" * 1000)
      capture = bounded.finish(0)

      expect(held(capture)).to eq(10)
      expect(capture).to have_attributes(stdout: "aaaaaaaa", stderr: "bb")
    end

    it "holds everything it was handed when that fits" do
      capture = bounded.take(:stdout, "hi").take(:stderr, "oops").finish(1)

      expect(capture).to have_attributes(exit_status: 1, stdout: "hi", stderr: "oops", size: 6)
    end

    # The live stream is the human's, and a refusal is about what the MODEL is
    # handed, so nothing past the ceiling is withheld from a sink.
    it "forwards every chunk to its own stream's sink, including those past the ceiling" do
      bounded.take(:stdout, "a" * 8).take(:stderr, "b" * 8).take(:stdout, "c" * 1000)

      expect(out.events.join).to eq(("a" * 8) + ("c" * 1000))
      expect(err.events.join).to eq("b" * 8)
    end

    it "finishes into a value no later chunk can change" do
      capture = bounded.take(:stdout, "hi").finish(0)

      expect(Ractor.shareable?(capture)).to be(true)
    end

    # A timeout's report is built from what was retained and nothing else, so a
    # flood before the kill cannot put more than the ceiling into a message.
    it "reports what it retained, and nothing past the ceiling" do
      bounded.take(:stdout, "a" * 8).take(:stderr, "b" * 1_000_000)

      expect(bounded.report).to include("STDOUT: aaaaaaaa", "STDERR: bb\n")
      expect(bounded.report.bytesize).to be < 100
    end

    it "reports bytes that are not text without raising" do
      bounded.take(:stdout, "caf\xE9".b).take(:stderr, "✅")

      expect(bounded.report.b).to include("caf\xE9".b, "✅".b)
    end

    it "sends nothing anywhere when it is handed no sinks" do
      quiet = described_class.new(ceiling: 3)

      expect(quiet.take(:stdout, "hello").finish(0)).to have_attributes(stdout: "hell", size: 5)
    end
  end
end
