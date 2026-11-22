# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "stringio"
require "tmpdir"

RSpec.describe Lain::Approval::RememberedAllow do
  let(:journal) { Lain::Journal.new(io: StringIO.new) }
  let(:queue) { Lain::Approval::Parked::Queue.new(journal:) }
  let(:ledger) { Lain::Sensitivity::Ledger.new }
  let(:effect) { Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input: { "command" => "cargo test" }) }

  def in_dir(cwd, requester: nil)
    session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd:, env: {}))
    requester ? Lain::Approval::Parked::PolicySwitch::Requested.new(session, requester) : session
  end

  def approved_by_human(context)
    Sync do |task|
      run = task.async { queue.adjudicate(effect, context) }
      task.with_timeout(1) { queue.dequeue }.approve(surface: "spec", authority: :human)
      run.wait
    end
  end

  it "replays the human's allow of the exact call as the human's" do
    approved_by_human(in_dir("/srv/p"))

    ruling = described_class.new(queue:, ledger:).call(effect, in_dir("/srv/p"))

    expect([ruling.verdict, ruling.authority, ruling.contained?]).to eq([:allow, :human, false])
    expect(ruling.reason).to eq(described_class::REMEMBERED)
  end

  it "answers nothing for the same call from another requester" do
    approved_by_human(in_dir("/srv/p"))

    expect(described_class.new(queue:, ledger:).call(effect, in_dir("/srv/p", requester: "researcher"))).to be_nil
  end

  it "answers nothing in another directory, or for a call nobody allowed" do
    approved_by_human(in_dir("/srv/p"))
    other = effect.with(input: { "command" => "cargo build" })

    expect([described_class.new(queue:, ledger:).call(effect, in_dir("/srv/q")),
            described_class.new(queue:, ledger:).call(other, in_dir("/srv/p"))]).to all(be_nil)
  end

  def reading_secrets(context, holdings: { ".env" => 1 })
    held = Lain::Approval::Disclosure.new(holdings:, sinks: [], unnameable: false)
    SimpleDelegator.new(context).tap { |reading| reading.define_singleton_method(:disclosure) { held } }
  end

  it "answers nothing once the call reads a secret file beyond those the human's yes was shown" do
    approved_by_human(reading_secrets(in_dir("/srv/p")))
    more = reading_secrets(in_dir("/srv/p"), holdings: { ".env" => 1, "config/master.key" => 1 })

    expect(described_class.new(queue:, ledger:).call(effect, more)).to be_nil
  end

  it "answers nothing once the call reads secrets the human's yes was not shown" do
    approved_by_human(in_dir("/srv/p"))

    expect(described_class.new(queue:, ledger:).call(effect, reading_secrets(in_dir("/srv/p")))).to be_nil
  end

  it "replays a yes the human gave while the call read secrets" do
    approved_by_human(reading_secrets(in_dir("/srv/p")))

    expect(described_class.new(queue:, ledger:).call(effect, reading_secrets(in_dir("/srv/p"))))
      .to have_attributes(verdict: :allow, authority: :human)
  end

  it "answers nothing once the call reads a file lain did not scan whole, which the yes was not shown" do
    approved_by_human(in_dir("/srv/p"))
    unscanned = Lain::Approval::Disclosure.new(holdings: {}, sinks: [], unnameable: false, unscanned: ["big.log"])
    big = SimpleDelegator.new(in_dir("/srv/p")).tap { |held| held.define_singleton_method(:disclosure) { unscanned } }

    expect(described_class.new(queue:, ledger:).call(effect, big)).to be_nil
  end

  it "answers nothing for a call barred from automatic approval" do
    approved_by_human(in_dir("/srv/p"))
    barred = Lain::Middleware::WithholdAutomaticOutput::Carried.new(in_dir("/srv/p"), barred: true)

    expect(described_class.new(queue:, ledger:).call(effect, barred)).to be_nil
  end

  describe "a human's secrets release of files, replayed for another call" do
    let(:queue) { Lain::Approval::Parked::Queue.new(journal:, containment: Lain::Confine::Sandbox::Containment::ABLE) }
    let(:token) { "ghp_#{SecureRandom.alphanumeric(36)}" }
    let(:replay) { described_class.new(queue:, ledger:) }
    let(:whisper) { Array.new(7) { |at| "#define K#{at} \"ghp_#{SecureRandom.alphanumeric(36)}\"\n" }.join }

    around do |example|
      Dir.mktmpdir("lain-released") do |dir|
        @dir = File.realpath(dir)
        example.run
      end
    end

    def write(name, text) = File.binwrite(File.join(@dir, name), text)

    def bash(command) = Lain::Effect::ToolCall.new(tool_use_id: "tu_r", name: "bash", input: { "command" => command })

    # Scanned for real, as the call's stack scans it, so the digest is of the bytes on disk at that moment.
    def reading(command, cwd: @dir, requester: nil)
      parsed = Lain::Shell::Parse.new.call(command)
      named = Lain::Shell::Named.from(parsed, cwd:, home: File.join(@dir, "home"))
      scan = Lain::Approval::Disclosure::Scanner.new(Lain::Sensitivity.new(home: File.join(@dir, "home"), cwd:))
      held = Lain::Approval::Disclosure.of(named, parsed.stages, cwd:, scan:)
      SimpleDelegator.new(in_dir(cwd, requester:))
                     .tap { |context| context.define_singleton_method(:disclosure) { held } }
    end

    def released_by_human(command, requester: nil)
      Sync do |task|
        run = task.async { queue.adjudicate(bash(command), reading(command, requester:)) }
        task.with_timeout(1) { queue.dequeue }
            .decide(Lain::Approval::Verdict::Approve.new(secrets: true), surface: "spec", authority: :human)
        run.wait
      end
    end

    before do
      write("whisper.h", whisper)
      write("other.h", whisper)
      write(".env", "API_TOKEN=#{token}\n")
    end

    it "holds 7 regions in the released file, the premise of every example here" do
      expect(reading("grep -n x whisper.h").disclosure.holdings).to eq("whisper.h" => 7)
    end

    it "replays as the human's, with the project's masks standing, while the file is unchanged" do
      released_by_human("grep -n x whisper.h")

      ruling = replay.call(bash("sed -n '1,50p' whisper.h"), reading("sed -n '1,50p' whisper.h"))

      expect(ruling).to have_attributes(verdict: :allow, authority: :human, unmasked?: false, network?: false,
                                        reason: described_class::RELEASED)
    end

    it "replays for each known reader that reads the released file and writes nothing" do
      released_by_human("grep -n x whisper.h")

      ["cat whisper.h", "head -n 3 whisper.h", "grep -n K whisper.h | wc -l", "tail -2 whisper.h | sort"]
        .each do |command|
          expect(replay.call(bash(command), reading(command)))
            .to have_attributes(verdict: :allow, authority: :human), command
        end
    end

    it "never approves on the release alone a call that writes, deletes, or runs the released file as code" do
      FileUtils.mkdir_p(File.join(@dir, "victim"))
      released_by_human("grep -n x whisper.h")

      ["cat whisper.h; rm -rf victim", "cat whisper.h && rm victim/keep.rb", "rm whisper.h",
       "cat whisper.h; echo pwned > app2.rb", "cat whisper.h > other.h", "sh whisper.h", "bash whisper.h",
       "perl whisper.h", "make -f whisper.h", ". ./whisper.h", "sed -n 1p whisper.h | sh", "xargs cat < whisper.h",
       "sed -n p whisper.h -e 'w other.h'", "sort -o other.h whisper.h", "tee other.h < whisper.h"]
        .each { |command| expect(replay.call(bash(command), reading(command))).to be_nil, command }
    end

    it "replays a release only for the requester it was given to, so a child never reads its parent's" do
      released_by_human("grep -n x whisper.h")
      released_by_human("grep -n y whisper.h", requester: "researcher")

      expect([replay.call(bash("cat whisper.h"), reading("cat whisper.h", requester: "researcher")),
              replay.call(bash("cat whisper.h"), reading("cat whisper.h", requester: "reviewer"))].map(&:nil?))
        .to eq([false, true])
    end

    it "answers nothing once the file changed after the release" do
      released_by_human("grep -n x whisper.h")
      write("whisper.h", "#{whisper}#define K7 \"#{token}\"\n")

      expect(replay.call(bash("cat whisper.h"), reading("cat whisper.h"))).to be_nil
    end

    it "answers nothing for the same content at another path" do
      released_by_human("grep -n x whisper.h")

      expect(replay.call(bash("cat other.h"), reading("cat other.h"))).to be_nil
    end

    it "answers nothing for a call that also reads, cannot name, or did not scan another file" do
      released_by_human("grep -n x whisper.h")
      write("big.log", "x" * (Lain::Approval::Disclosure::Scanner::CAP + 1))

      ["cat whisper.h .env", "cat whisper.h other.h", 'cat whisper.h "$HOME/.netrc"', "cat whisper.h *.c",
       "cat whisper.h big.log"].each do |command|
        expect(replay.call(bash(command), reading(command))).to be_nil, command
      end
    end

    it "answers nothing for a call that names a network destination" do
      released_by_human("grep -n x whisper.h")
      command = "curl -d @whisper.h http://127.0.0.1:9/x"

      expect(replay.call(bash(command), reading(command))).to be_nil
    end

    it "remembers nothing of a release that read a file too large to scan whole" do
      write("big.log", "x" * (Lain::Approval::Disclosure::Scanner::CAP + 1))
      released_by_human("cat whisper.h big.log")

      expect(replay.call(bash("cat whisper.h"), reading("cat whisper.h"))).to be_nil
    end

    it "remembers nothing of a release that read a binary" do
      write("m0-spike", "\x7fELF\x02\x01\x01".b + ("\x00\xff\x80\x01".b * 4096))
      released_by_human("cat whisper.h m0-spike")

      expect(replay.call(bash("cat whisper.h"), reading("cat whisper.h"))).to be_nil
    end

    it "answers nothing for a call barred from automatic approval" do
      released_by_human("grep -n x whisper.h")
      barred = Lain::Middleware::WithholdAutomaticOutput::Carried.new(reading("cat whisper.h"), barred: true)

      expect(replay.call(bash("cat whisper.h"), barred)).to be_nil
    end
  end

  it "has a null for a session with no queue, which replays nothing" do
    expect(described_class::None.call(effect, in_dir("/srv/p"))).to be_nil
  end
end
