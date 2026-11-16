# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Review::Queue::Log do
  let(:dir) { Dir.mktmpdir }
  let(:paths) { Lain::Paths.new(env: { "HOME" => dir, "XDG_STATE_HOME" => dir }) }
  let(:event) { described_class::Event }
  let(:file) { paths.review_queue_log }
  let(:errors) { File.join(dir, "child-errors") }

  after { FileUtils.remove_entry(dir) }

  def row(id, head_sha) = Lain::Review::Queue::Row.new(id:, rank: :direct, reason: "r", request: nil, head_sha:)

  it "folds 4 processes appending 200 events each into 800 parsing lines, no stray blanks, every row kept" do
    pids = Array.new(4) do |worker|
      ForkedChild.start(errors) do
        log = described_class.new(paths: Lain::Paths.new(env: { "HOME" => dir, "XDG_STATE_HOME" => dir }))
        200.times { |i| log.append(event.new(kind: :opened, at: Time.now, row_id: "w#{worker}-#{i}", head_sha: "C")) }
        0
      end
    end
    pids.each { |pid| Process.wait(pid) }
    expect(File.exist?(errors) ? File.read(errors) : "").to eq("")

    lines = File.readlines(file)
    whole = lines.reject { |l| l.strip.empty? }
    ids = whole.map { |l| JSON.parse(l)["row_id"] }

    expect([whole.size, lines.size - whole.size <= 1, ids.uniq.size])
      .to eq([800, true, 800])
  end

  it "answers last_listed_at with the newest :listed event" do
    log = described_class.new(paths:)
    [Time.utc(2026, 11, 16, 9), Time.utc(2026, 11, 16, 11)].each do |at|
      log.append(event.new(kind: :listed, at:, row_id: nil, head_sha: nil))
    end

    expect(log.last_listed_at).to eq(Time.utc(2026, 11, 16, 11))
  end

  it "has no last_listed_at before anything was listed" do
    expect(described_class.new(paths:).last_listed_at).to be_nil
  end

  it "stamps an event that carries no time from the injected clock" do
    now = Time.utc(2026, 11, 16, 12)
    log = described_class.new(paths:, clock: -> { now })
    log.append(event.new(kind: :listed, at: nil, row_id: nil, head_sha: nil))

    expect(log.last_listed_at).to eq(now)
  end

  it "answers notified? by row id at any head" do
    log = described_class.new(paths:)
    log.append(event.new(kind: :notified, at: nil, row_id: "pr:o/r#1", head_sha: "C"))

    expect([log.notified?("pr:o/r#1"), log.notified?("pr:o/r#2")]).to eq([true, false])
  end

  it "skips a torn last line, counts every whole one and notes the torn one once" do
    log = described_class.new(paths:)
    log.append(event.new(kind: :opened, at: nil, row_id: "a", head_sha: "C"))
    File.open(file, "a") { |f| f.write("\n{\"kind\":\"opened\",\"at\":\"2026-11-16T09:00:0") }

    expect([log.seen?(row("a", "C")), log.notes.size, log.notes.first]).to match([true, 1, /torn|malformed/])
  end

  it "counts an event appended after a torn last line, and notes the torn one once" do
    log = described_class.new(paths:)
    log.append(event.new(kind: :opened, at: nil, row_id: "a", head_sha: "C"))
    File.open(file, "a") { |f| f.write("\n{\"kind\":\"opened\",\"at\":\"2026-11-16T09:00:0") }
    log.append(event.new(kind: :opened, at: nil, row_id: "b", head_sha: "C"))

    expect([log.seen?(row("a", "C")), log.seen?(row("b", "C")), log.notes.size]).to eq([true, true, 1])
  end

  describe "a rotation racing the fold" do
    def rotate_before_first_read(log_file)
      rotated = false
      rotate = lambda do
        next if rotated

        rotated = true
        File.rename(log_file, "#{log_file}.1")
      end
      allow(File).to receive(:foreach).and_wrap_original do |orig, *args, &blk|
        rotate.call
        orig.call(*args, &blk)
      end
      allow(File).to receive(:open).and_wrap_original do |orig, *args, &blk|
        rotate.call if args.first == log_file && args.size == 1
        orig.call(*args, &blk)
      end
    end

    it "neither raises nor loses a row that moved to log.1 between the reads" do
      log = described_class.new(paths:)
      log.append(event.new(kind: :opened, at: nil, row_id: "moved", head_sha: "C"))
      rotate_before_first_read(file)

      expect(log.seen?(row("moved", "C"))).to be(true)
    end
  end

  it "raises when a short write is all the disk took" do
    log = described_class.new(paths:)
    allow(File).to receive(:open).and_wrap_original do |orig, *args, &blk|
      orig.call(*args) do |io|
        allow(io).to receive(:syswrite).and_return(3)
        blk.call(io)
      end
    end

    expect { log.append(event.new(kind: :listed, at: nil, row_id: nil, head_sha: nil)) }
      .to raise_error(IOError, /short write/)
  end

  describe "#prune" do
    it "leaves a small log alone" do
      log = described_class.new(paths:)
      log.append(event.new(kind: :opened, at: nil, row_id: "a", head_sha: "C"))
      log.prune

      expect(File.exist?("#{file}.1")).to be(false)
    end

    it "rotates a log over 1 MiB to log.1, replacing the old one, and the fold reads both" do
      log = described_class.new(paths:)
      File.write("#{file}.1", "stale\n")
      log.append(event.new(kind: :opened, at: nil, row_id: "old", head_sha: "C"))
      File.open(file, "a") do |f|
        f.write("\n#{JSON.generate(kind: :listed, at: Time.utc(2026, 1, 1).iso8601, row_id: "x" * 1_048_576)}\n")
      end
      log.prune
      log.append(event.new(kind: :opened, at: nil, row_id: "new", head_sha: "C"))

      expect([File.read("#{file}.1").include?("stale"), File.size(file) < 1000,
              log.seen?(row("old", "C")), log.seen?(row("new", "C"))]).to eq([false, true, true, true])
    end

    # A second rotation drops the older log.1, and with it any notified? history
    # that lived only there: the log is bounded by design, not an archive.
    it "does not rotate a fresh log over log.1 when another pruner got there between the size and the rename" do
      log = described_class.new(paths:)
      File.open(file, "a") do |f|
        f.write("\n#{JSON.generate(kind: :listed, at: Time.utc(2026, 1, 1).iso8601, row_id: "x" * 1_048_576)}\n")
      end
      log.append(event.new(kind: :opened, at: nil, row_id: "old", head_sha: "C"))
      other = described_class.new(paths:)
      interleaved = false
      interleave = lambda do
        next if interleaved

        interleaved = true
        other.prune
        other.append(event.new(kind: :opened, at: nil, row_id: "fresh", head_sha: "C"))
      end
      %i[size stat].each do |reader|
        allow(File).to(receive(reader).and_wrap_original { |orig, *args| orig.call(*args).tap { interleave.call } })
      end
      log.prune

      expect([log.seen?(row("old", "C")), log.seen?(row("fresh", "C")), File.read("#{file}.1").include?("old")])
        .to eq([true, true, true])
    end

    it "treats a log that vanished before the rename as already pruned" do
      log = described_class.new(paths:)

      expect { log.prune }.not_to raise_error
    end

    it "lets an append that opened the log before the rename land in log.1" do
      log = described_class.new(paths:)
      log.append(event.new(kind: :opened, at: nil, row_id: "seed", head_sha: "C"))
      raced = "\n#{JSON.generate(kind: :opened, at: Time.now.iso8601, row_id: "raced", head_sha: "C")}\n"
      File.open(file, File::WRONLY | File::APPEND) do |held|
        File.rename(file, "#{file}.1")
        held.syswrite(raced)
      end

      expect(log.seen?(row("raced", "C"))).to be(true)
    end
  end

  it "refuses an event kind it does not know" do
    expect { event.new(kind: :bogus, at: nil, row_id: nil, head_sha: nil) }.to raise_error(ArgumentError)
  end
end
