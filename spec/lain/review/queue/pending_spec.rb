# frozen_string_literal: true

require "json"
require "socket"
require "tmpdir"

RSpec.describe Lain::Review::Queue::Pending do
  subject(:pending) { described_class.new(paths:, workspaces:, env:, log:) }

  let(:paths) do
    Lain::Paths.new(env: SpecHome.env({ "XDG_STATE_HOME" => File.join(@dir, "state"),
                                        "XDG_RUNTIME_DIR" => File.join(@dir, "run") }))
  end
  let(:env) { {} }
  # A herdr whose workspaces are the ones it was asked to create.
  let(:workspaces) do
    Class.new do
      def created = @created ||= []

      def create(**call)
        created << call
        "w9:p1"
      end

      def include?(label) = created.any? { _1[:label] == label }
    end.new
  end
  let(:notes) { [] }
  let(:notice) { ->(text) { notes << text } }
  let(:root) { clone_at("api") }
  let(:fields) { { "kind" => "range", "base" => "a" * 40, "head" => "b" * 40, "repo_root" => root } }
  let(:row) { { "id" => "commit:#{root}:#{"b" * 40}", "head_sha" => "b" * 40 } }
  let(:mark) { Lain::Review::Queue::Mark.load(row) }
  let(:log) { Lain::Review::Queue::Log.new(paths:) }

  around do |example|
    Dir.mktmpdir("lain-pending") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  def clone_at(name)
    dir = FileUtils.mkdir_p(File.join(@dir, "roots", name)).first
    FileUtils.cp_r("#{SeedRepo.at(SeedRepo::SEED)}/.", dir)
    dir
  end

  def request(with = fields)
    Lain::Review::Queue::Request.load(with, checkouts: Lain::Review::Queue::Checkouts.new(roots: []))
  end

  def held_files = Dir.glob(File.join(paths.state_home, "queue", "pending", "*"))

  # What a held file says, as {Pending#hold} writes it.
  def held_json(with = fields, named: row) = JSON.generate({ "request" => with, "row" => named })

  def taken = pending.take(root, notice:)&.request&.to_h

  def seen?
    log.seen?(Lain::Review::Queue::Row.new(id: row["id"], rank: :commit, reason: "", request: nil,
                                           head_sha: row["head_sha"]))
  end

  def plant(text, age: 0)
    dir = FileUtils.mkdir_p(File.join(paths.state_home, "queue", "pending")).first
    path = File.join(dir, "#{paths.project_hash(root)}.json")
    File.write(path, text, perm: 0o600)
    File.chmod(0o600, path)
    File.utime(Time.now - age, Time.now - age, path)
    path
  end

  describe "#hold" do
    it "keeps the request for the checkout, readable by its owner alone" do
      pending.hold(request, mark)

      expect(held_files.map { File.stat(_1).mode & 0o777 }).to eq([0o600])
    end

    it "says the review opens with the next cockpit there, outside herdr" do
      expect([pending.hold(request, mark), workspaces.created]).to eq([:pending, []])
    end

    context "when inside herdr" do
      let(:env) { { "HERDR_ENV" => "1" } }

      it "starts a cockpit in a new workspace at the checkout" do
        expect([pending.hold(request, mark), workspaces.created])
          .to eq([:started, [{ cwd: root, command: "lain up --nvim", label: "review api" }]])
      end

      it "says herdr failed, and keeps the review held, when herdr starts nothing" do
        def workspaces.create(**) = nil

        expect([pending.hold(request, mark), held_files.size]).to eq([:herdr_failed, 1])
      end

      it "asks herdr again on the next open after herdr failed" do
        real = workspaces.method(:create)
        attempts = 0
        workspaces.define_singleton_method(:create) { |**call| (attempts += 1) > 1 ? real.call(**call) : nil }

        expect([pending.hold(request, mark), pending.hold(request, mark), workspaces.created.size])
          .to eq([:herdr_failed, :replaced_started, 1])
      end

      it "says both when it replaces a held review and starts a workspace for it" do
        pending.hold(request, mark)
        workspaces.created.clear

        expect([pending.hold(request, mark), workspaces.created.size]).to eq([:replaced_started, 1])
      end

      it "says both when it replaces a held review and herdr starts nothing" do
        pending.hold(request, mark)
        def workspaces.create(**) = nil
        def workspaces.include?(_label) = false

        expect(pending.hold(request, mark)).to eq(:replaced_herdr_failed)
      end

      it "starts no workspace when one for the checkout is open already" do
        def workspaces.include?(label) = label == "review api"

        expect([pending.hold(request, mark), workspaces.created]).to eq([:pending, []])
      end

      it "replaces a held review and starts no second workspace, since the first one takes the new file" do
        pending.hold(request, mark)
        newer = fields.merge("head" => "c" * 40)

        expect([pending.hold(request(newer), mark), workspaces.created.size, taken])
          .to eq([:replaced, 1, newer])
      end
    end

    it "is not a replacement over a stale file" do
      plant(held_json(fields), age: 3 * 86_400)

      expect([pending.hold(request, mark), taken]).to eq([:pending, fields])
    end

    it "is not a replacement over garbage" do
      plant("{not json")

      expect([pending.hold(request, mark), taken]).to eq([:pending, fields])
    end

    it "replaces a held review outside herdr, and says so" do
      pending.hold(request, mark)
      newer = fields.merge("head" => "c" * 40)

      expect([pending.hold(request(newer), mark), held_files.size, taken])
        .to eq([:replaced, 1, newer])
    end
  end

  it "refuses to hold a review where a file stands in for its directory, in 1 line" do
    FileUtils.mkdir_p(File.join(paths.state_home, "queue"))
    File.write(File.join(paths.state_home, "queue", "pending"), "")

    expect { pending.hold(request, mark) }.to raise_error(Lain::Error, /\Alain cannot hold the review in [^\n]+\z/)
  end

  describe "#take" do
    it "says why, and raises nothing, when a file stands in for its directory" do
      FileUtils.mkdir_p(File.join(paths.state_home, "queue"))
      File.write(File.join(paths.state_home, "queue", "pending"), "")

      expect(pending.take(root, notice:)).to be_nil
      expect(notes).to contain_exactly(a_string_including("could not be read"))
    end

    it "says why, and raises nothing, when its directory cannot be entered" do
      pending.hold(request, mark)
      directory = File.join(paths.state_home, "queue", "pending")
      File.chmod(0o000, directory)

      expect(pending.take(root, notice:)).to be_nil
      expect(notes).to contain_exactly(a_string_including("could not be read"))
    ensure
      File.chmod(0o700, directory)
    end

    it "gives back the held request and its row once, and removes it" do
      pending.hold(request, mark)
      held = pending.take(root, notice:)

      expect([held.request.to_h, held.mark, pending.take(root, notice:), held_files, notes])
        .to eq([fields, mark, nil, [], []])
    end

    it "drops a planted file whose row is malformed, with 1 note naming the field and not its value" do
      plant(held_json(named: row.merge("head_sha" => "/mode bypass")))

      expect([pending.take(root, notice:), held_files]).to eq([nil, []])
      expect(notes).to contain_exactly(a_string_including("row.head_sha"))
      expect(notes.join).not_to include("bypass")
    end

    it "drops a planted file that names no row, with 1 note naming the field" do
      plant(JSON.generate({ "request" => fields }))

      expect(pending.take(root, notice:)).to be_nil
      expect(notes).to contain_exactly(a_string_including("row is missing"))
    end

    it "drops a planted file carrying more than a request and its row, with 1 note" do
      plant(JSON.generate({ "request" => fields, "row" => row, "line" => "/mode bypass" }))

      expect(pending.take(root, notice:)).to be_nil
      expect(notes).to contain_exactly(a_string_including("file has a field other than request and row"))
    end

    it "gives nothing to another checkout" do
      pending.hold(request, mark)

      expect([pending.take(clone_at("web"), notice:), held_files.size]).to eq([nil, 1])
    end

    it "drops a planted file Request.load refuses, with 1 note naming the field and not its value" do
      plant(held_json(fields.merge("head" => "/mode bypass")))

      expect([pending.take(root, notice:), held_files]).to eq([nil, []])
      expect(notes).to contain_exactly(a_string_including("head"))
      expect(notes.join).not_to include("bypass")
    end

    it "drops a file that is not JSON, with 1 note" do
      plant("{not json")

      expect([pending.take(root, notice:), held_files, notes.size]).to eq([nil, [], 1])
    end

    it "drops a file naming another checkout's root, with 1 note" do
      plant(held_json(fields.merge("repo_root" => clone_at("web"))))

      expect([pending.take(root, notice:), held_files]).to eq([nil, []])
      expect(notes).to contain_exactly(a_string_including("repo_root"))
    end

    it "drops a request held over 1 day ago, with 1 note" do
      plant(held_json(fields), age: 86_401)

      expect([pending.take(root, notice:), held_files]).to eq([nil, []])
      expect(notes).to contain_exactly(a_string_including("1 day"))
    end

    it "drops a file over 64 KiB, with 1 note" do
      text = held_json
      plant(text + (" " * (65_537 - text.bytesize)))

      expect([pending.take(root, notice:), held_files]).to eq([nil, []])
      expect(notes).to contain_exactly(a_string_including("65536 bytes"))
    end

    it "takes a file of exactly 64 KiB" do
      text = held_json
      plant(text + (" " * (65_536 - text.bytesize)))

      expect(taken).to eq(fields)
    end

    it "drops a file others may read or write, with 1 note" do
      File.chmod(0o640, plant(held_json))

      expect([pending.take(root, notice:), held_files]).to eq([nil, []])
      expect(notes).to contain_exactly(a_string_including("mode"))
    end

    it "drops a file whose time is in the future, with 1 note" do
      plant(held_json(fields), age: -60)

      expect([pending.take(root, notice:), held_files, notes.size]).to eq([nil, [], 1])
    end

    it "does not hang on a FIFO planted in its place, and removes it" do
      FileUtils.mkdir_p(File.dirname(plant("")))
      File.delete(plant(""))
      fifo = File.join(paths.state_home, "queue", "pending", "#{paths.project_hash(root)}.json")
      File.mkfifo(fifo)
      File.chmod(0o600, fifo)

      expect([Timeout.timeout(5) { pending.take(root, notice:) }, held_files]).to eq([nil, []])
      expect(notes).to contain_exactly(a_string_including("not a regular file"))
    end

    it "removes a directory planted in its place, leaving nothing claimed behind" do
      File.delete(plant(""))
      planted = File.join(paths.state_home, "queue", "pending", "#{paths.project_hash(root)}.json")
      FileUtils.mkdir_p(File.join(planted, "inside"))
      File.chmod(0o600, planted)

      expect([pending.take(root, notice:), held_files]).to eq([nil, []])
      expect(notes).to contain_exactly(a_string_including("not a regular file"))
    end

    it "gives a held review to only 1 of several chats starting at once" do
      taken = Array.new(20) do
        pending.hold(request, mark)
        gate = Thread::Queue.new
        takers = Array.new(4) { Thread.new { gate.pop && pending.take(root, notice:) } }
        4.times { gate << true }
        takers.filter_map(&:value).size
      end

      expect(taken.uniq).to eq([1])
    end

    it "names a planted field escaped and cut short, never raw" do
      plant(held_json(fields.merge("\e[31m#{"f" * 200}" => "x")))

      pending.take(root, notice:)

      expect(notes.sole).to include("\\e").and(satisfy { |note| !note.include?("\e") && note.size < 200 })
    end

    it "does not follow a symlink planted in its place" do
      target = File.join(@dir, "elsewhere.json")
      File.write(target, held_json)
      FileUtils.mkdir_p(File.join(paths.state_home, "queue", "pending"))
      File.symlink(target, File.join(paths.state_home, "queue", "pending", "#{paths.project_hash(root)}.json"))

      expect([pending.take(root, notice:), held_files, File.exist?(target), notes.size]).to eq([nil, [], true, 1])
    end
  end

  describe "#offering" do
    # The chat's own producer, which the offering starts and stops around itself. It draws
    # every prompt untouched, since the Intake lets an answer take only an untouched `you>`.
    let(:producer) do
      Class.new do
        def calls = @calls ||= []

        def start(_task) = (calls << :start) && self

        def stop(**) = calls << :stop

        def untouched?(_prompt) = true

        def typed?(_prompt) = false

        def keep(_text) = nil

        def sweep = nil

        def discard_draft = nil
      end.new
    end
    let(:intake) { Lain::Frontend::Intake.new.tap { _1.attach(producer) } }
    let(:offering) { pending.offering(producer, root:, rail: intake, notice:) }
    let(:offered_line) { "lain queue: /review #{"b" * 40} --base #{"a" * 40}  (Enter opens, x drops)" }

    def shown(kind) = Enumerator.produce { intake.published }.find { _1.kind == kind }

    def answer(text) = intake << Lain::Frontend::Intake::Line.new(text:, generation: shown(:human).generation)

    it "offers the held review once the chat first asks at you>, and not before" do
      pending.hold(request, mark)
      offering.start(nil)
      sleep(0.2)
      before = [intake.published.kind, held_files.size]
      you = Thread.new { intake.read(:you, "you> ") }
      offer = shown(:human)
      intake << Lain::Frontend::Intake::Line.new(text: "x", generation: offer.generation)
      intake << Lain::Frontend::Intake::Line.new(text: "quit", generation: shown(:you).generation)
      offering.stop(goodbye: true)

      expect([before, offer.text, you.value, held_files, producer.calls])
        .to eq([[nil, 1], offered_line, "quit", [], %i[start stop]])
    end

    it "holds the review again exactly once, its row unseen, when the chat stops before the human answers" do
      pending.hold(request, mark)
      offering.start(nil)
      Thread.new { intake.read(:you, "you> ") }
      shown(:human)
      offering.stop(goodbye: true)

      expect([held_files.size, pending.take(root, notice:)&.mark, seen?]).to eq([1, mark, false])
    end

    it "marks its row seen when the human takes it with Enter, and holds nothing again" do
      pending.hold(request, mark)
      offering.start(nil)
      you = Thread.new { intake.read(:you, "you> ") }
      answer("")
      line = you.value
      offering.stop(goodbye: true)

      expect([line, seen?, held_files]).to eq(["/review #{"b" * 40} --base #{"a" * 40}", true, []])
    end

    it "leaves its row unseen, and holds nothing again, when the human drops it with Ctrl-D" do
      pending.hold(request, mark)
      offering.start(nil)
      Thread.new { intake.read(:you, "you> ") }
      shown(:human)
      intake << Lain::Frontend::Intake::Eof.new
      offering.stop(goodbye: true)

      expect([seen?, held_files]).to eq([false, []])
    end

    it "leaves the review held when the chat stops before it ever asks, and leaves no thread running" do
      pending.hold(request, mark)
      before = Thread.list
      offering.start(nil)
      offering.stop(goodbye: true)

      expect([held_files.size, (Thread.list - before).select(&:alive?)]).to eq([1, []])
    end

    it "does not hold again a review the human dropped just before the chat stopped, nor mark it seen" do
      pending.hold(request, mark)
      offering.start(nil)
      Thread.new { intake.read(:you, "you> ") }
      answer("x")
      offering.stop(goodbye: true)

      expect([held_files, seen?]).to eq([[], false])
    end

    it "marks seen a review the human took just before the chat stopped, and does not hold it again" do
      pending.hold(request, mark)
      offering.start(nil)
      Thread.new { intake.read(:you, "you> ") }
      answer("")
      offering.stop(goodbye: true)

      expect([held_files, seen?]).to eq([[], true])
    end

    it "says why, and stops cleanly, when the review cannot be held again" do
      pending.hold(request, mark)
      offering.start(nil)
      Thread.new { intake.read(:you, "you> ") }
      shown(:human)
      directory = File.join(paths.state_home, "queue", "pending")
      File.chmod(0o500, directory)

      expect { offering.stop(goodbye: true) }.not_to raise_error
      expect(notes).to contain_exactly(a_string_including("could not be held again"))
    ensure
      File.chmod(0o700, directory)
    end

    it "says why when the line cannot be rebuilt, as a dirty tree that is clean by now" do
      pending.hold(request({ "kind" => "dirty", "repo_root" => root }), mark)
      offering.start(nil)
      Thread.new { intake.read(:you, "you> ") }
      Timeout.timeout(5) { sleep(0.01) until notes.any? }

      expect { offering.stop(goodbye: true) }.not_to raise_error
      expect(notes).to contain_exactly(a_string_including("repo_root"))
    end

    it "holds the review again when another offer is in front of the human" do
      crowded = Class.new do
        attr_reader :asked

        def published = Lain::Frontend::Intake::Prompt.new(kind: :you, text: "you> ", generation: 1)

        def end_offer = nil

        def offer(_request)
          yield :crowded
          @asked = true
          nil
        end
      end.new
      pending.hold(request, mark)
      turned_away = pending.offering(producer, root:, rail: crowded, notice:).tap { _1.start(nil) }
      Timeout.timeout(5) { sleep(0.01) until crowded.asked }
      turned_away.stop(goodbye: true)

      expect(taken).to eq(fields)
    end

    # A rail standing in for the chat's Intake: always at you>, and answering an offer as told.
    def rail_that(&block)
      answer = block
      Class.new do
        attr_reader :asked

        def published = Lain::Frontend::Intake::Prompt.new(kind: :you, text: "you> ", generation: 1)

        def end_offer = nil

        define_method(:offer) do |request, &decided|
          @asked = true
          answer.call(request, decided)
        end
      end.new
    end

    it "holds nothing again when the same review is already offered there, since that offer decides" do
      repeated = rail_that { |_request, decided| decided.call(:repeat) && nil }
      pending.hold(request, mark)
      offering = pending.offering(producer, root:, rail: repeated, notice:).tap { _1.start(nil) }
      Timeout.timeout(5) { sleep(0.01) until repeated.asked }
      offering.stop(goodbye: true)

      expect(held_files).to eq([])
    end

    it "stops within the offers' end bound, holding the review again, when the offer is still being built" do
      stuck = rail_that { sleep }
      pending.hold(request, mark)
      before = Thread.list
      offering = pending.offering(producer, root:, rail: stuck, notice:).tap { _1.start(nil) }
      Timeout.timeout(5) { sleep(0.01) until stuck.asked }
      stopped = Timeout.timeout(Lain::Frontend::Intake::OFFERS_END + 5) { offering.stop(goodbye: true) && true }
      # Timeout starts its own thread the first time any spec uses it.
      left = (Thread.list - before).select(&:alive?).reject { _1.name == "Timeout stdlib thread" }

      expect([stopped, taken, left]).to eq([true, fields, []])
    end

    it "never holds again over a newer review held while it was offered" do
      pending.hold(request, mark)
      offering.start(nil)
      Thread.new { intake.read(:you, "you> ") }
      shown(:human)
      newer = fields.merge("head" => "c" * 40)
      pending.hold(request(newer), mark)
      offering.stop(goodbye: true)

      expect(taken).to eq(newer)
    end
  end

  it "starts a cockpit through a real herdr inside herdr", :seam do
    bin = File.join(@dir, "herdr")
    File.write(bin, <<~SH)
      #!/bin/sh
      echo "$@" >> #{@dir}/herdr.log
      case "$1 $2" in "workspace create") echo '{"result":{"root_pane":{"pane_id":"w9:p1"}}}';; esac
    SH
    File.chmod(0o755, bin)
    real = { "HERDR_ENV" => "1", "HERDR_BIN_PATH" => bin }

    outcome = described_class.new(paths:, env: real).hold(request, mark)

    expect([outcome, File.readlines(File.join(@dir, "herdr.log"), chomp: true)])
      .to eq([:started, ["workspace list", "workspace create --cwd #{root} --label review api --focus",
                         "pane run w9:p1 lain up --nvim"]])
  end
end
