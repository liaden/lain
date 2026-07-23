# frozen_string_literal: true

require "json"
require "tmpdir"

# T3: resolving `--fork "<session>@<digest-prefix>"` into the parent file and
# the FULL digest of the fork point. The file part reuses Resume::Selector's
# rules (empty picks the newest); the digest prefix resolves against the turn
# digests RECORDED in that file -- the same fold-membership set a chained load
# later verifies -- so a selector can only ever name a turn the parent
# actually recorded.
RSpec.describe Lain::CLI::ForkPoint do
  around do |example|
    Dir.mktmpdir { |dir| @state_home = dir and example.run }
  end

  let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => @state_home }) }
  let(:context) { Lain::Context.new(model: "recorded-model", max_tokens: 512, system: "be terse") }
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }

  subject(:fork_point) { described_class.new(dir: paths.sessions_dir) }

  def text(body) = [{ "type" => "text", "text" => body }]

  def chain(*bodies)
    bodies.each_with_index.inject(Lain::Timeline.empty(store: Lain::Store.new)) do |timeline, (body, i)|
      timeline.commit(role: i.even? ? :user : :assistant, content: text(body))
    end
  end

  def session_records(timeline)
    header = Lain::SessionRecord.header(context:, toolset:, head: nil)
    closer = Lain::Telemetry::SessionClosed.new(head: timeline.head_digest, reason: :exit).to_journal
    [header] + timeline.to_a.map { |turn| Lain::SessionRecord.turn(turn) } + [closer]
  end

  def write_session(name, timeline)
    path = File.join(paths.sessions_dir, name)
    File.write(path, "#{session_records(timeline).map { |record| JSON.generate(record) }.join("\n")}\n")
    path
  end

  let(:three) { chain("first", "ack", "second") }
  let(:ancestor) { three.to_a[1].digest }
  before { write_session("20260101T000000-1.ndjson", three) }

  def hex(digest) = digest.delete_prefix("blake3:")

  describe "#call" do
    it "resolves <file-prefix>@<digest-prefix> to the file's path and the full recorded digest" do
      point = fork_point.call("20260101@#{hex(ancestor)[0, 12]}")

      expect(point.path).to eq(File.join(paths.sessions_dir, "20260101T000000-1.ndjson"))
      expect(point.digest).to eq(ancestor)
    end

    it "accepts the digest prefix with its scheme too" do
      expect(fork_point.call("20260101@#{ancestor[0, 19]}").digest).to eq(ancestor)
    end

    it "a bare @<digest-prefix> resolves against the newest session" do
      newer = chain("hello", "there")
      write_session("20260202T000000-1.ndjson", newer)

      point = fork_point.call("@#{hex(newer.head_digest)[0, 12]}")

      expect(point.path).to eq(File.join(paths.sessions_dir, "20260202T000000-1.ndjson"))
      expect(point.digest).to eq(newer.head_digest)
    end

    it "refuses a selector with no fork point, showing the expected shape" do
      expect { fork_point.call("20260101") }
        .to raise_error(Lain::CLI::Resume::Refusal, /@<digest-prefix>/)
    end

    it "refuses an empty digest prefix" do
      expect { fork_point.call("20260101@") }
        .to raise_error(Lain::CLI::Resume::Refusal, /@<digest-prefix>/)
    end

    it "refuses a prefix matching no recorded turn, naming it and the file" do
      expect { fork_point.call("20260101@feedface") }
        .to raise_error(Lain::CLI::Resume::Refusal) do |error|
          expect(error.message).to include("feedface", "20260101T000000-1.ndjson")
        end
    end

    it "refuses an ambiguous digest prefix, naming the candidates" do
      expect { fork_point.call("20260101@blake3:") }
        .to raise_error(Lain::CLI::Resume::Refusal) do |error|
          expect(error.message).to include("ambiguous", *three.to_a.map(&:digest))
        end
    end

    it "delegates the file part to Resume::Selector, so an unknown file refuses namedly" do
      expect { fork_point.call("nope@#{hex(ancestor)[0, 12]}") }
        .to raise_error(Lain::CLI::Resume::Refusal, /nope/)
    end

    # T3 fix round (probe 3a): a prefix that only partially spells the scheme
    # ("b", "bl", "bla") must not match EVERY digest through
    # `"blake3:...".start_with?` -- matching is hex-only below a full
    # "blake3:" prefix.
    it "matches hex-only unless the prefix carries the full scheme -- '@bla' resolves nothing" do
      expect { fork_point.call("20260101@bla") }
        .to raise_error(Lain::CLI::Resume::Refusal, /no turn matching/)
    end

    # T3 fix round (probe 3c): a hand-edited or foreign turn record without a
    # "digest" key refuses namedly, never a raw KeyError backtrace.
    it "refuses a malformed turn record missing its digest, naming the file" do
      records = [Lain::SessionRecord.header(context:, toolset:, head: nil),
                 { "type" => "turn", "role" => "user", "content" => text("x") }]
      File.write(File.join(paths.sessions_dir, "20260104T000000-1.ndjson"),
                 "#{records.map { |record| JSON.generate(record) }.join("\n")}\n")

      expect { fork_point.call("20260104@abcd") }
        .to raise_error(Lain::CLI::Resume::Refusal) do |error|
          expect(error.message).to include("20260104T000000-1.ndjson", "digest")
        end
    end

    # T3 fix round (probe 5d): the file can vanish between the Selector's
    # listing and this read (a reaped ephemeral, an external rename) -- a raw
    # Errno::ENOENT must not escape.
    it "maps a file vanishing between listing and read to a named Refusal" do
      path = File.join(paths.sessions_dir, "20260101T000000-1.ndjson")
      allow(File).to receive(:foreach).and_wrap_original do |original, *args|
        raise Errno::ENOENT, args.first if args.first == path

        original.call(*args)
      end

      expect { fork_point.call("20260101@#{hex(ancestor)[0, 12]}") }
        .to raise_error(Lain::CLI::Resume::Refusal, /20260101T000000-1\.ndjson/)
    end

    # T3 fix round (probe 6c): a bare "@<prefix>" must not silently land on a
    # scratch file `lain sessions` hides -- the durable view is the
    # resolvable one, mirroring Resume::Selector's bare pick.
    it "a bare @<digest-prefix> ignores ephemeral sessions" do
      scratch = chain("scratchy")
      write_session("20260303T000000-9.btw.ndjson", scratch)

      point = fork_point.call("@#{hex(three.head_digest)[0, 12]}")

      expect(File.basename(point.path)).to eq("20260101T000000-1.ndjson")
      expect { fork_point.call("@#{hex(scratch.head_digest)[0, 12]}") }
        .to raise_error(Lain::CLI::Resume::Refusal, /no turn matching/)
    end
  end
end
