# frozen_string_literal: true

require "tmpdir"
require "json"

RSpec.describe Lain::Review::Queue::Poll do
  around do |example|
    Dir.mktmpdir("lain-poll") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:paths) { Lain::Paths.new(env: { "HOME" => @dir, "XDG_STATE_HOME" => @dir }) }
  let(:log) { Lain::Review::Queue::Log.new(paths:) }
  let(:opened_at) { Time.utc(2026, 11, 10, 12) }
  let(:notices) { [] }
  let(:feed) { ->(source, title, body = "") { (notices << [source, title, body]) && true } }
  let(:tokens) { [] }
  let(:workspaces) do
    Class.new do
      def initialize(tokens) = @tokens = tokens
      def token(**fields) = @tokens << fields
    end.new(tokens)
  end
  let(:queries) { [] }
  let(:pulls) { [] }
  let(:reads) do
    Class.new do
      def initialize(pulls, queries)
        @pulls = pulls
        @queries = queries
      end

      def review_requests(query:)
        @queries << query
        @pulls
      end
    end.new(pulls, queries)
  end
  let(:poll) { described_class.new(reads:, log:, counts: counts_file, workspaces:, feed:, orgs:) }
  let(:orgs) { [] }
  let(:counts_file) { File.join(@dir, "reviews.json") }

  def pull(number, via:, requested_at:, title: "PR #{number}")
    Lain::Forge::Gh::ReviewRequest.new(
      repo: "acme/api", number:, title:, url: "https://github.com/acme/api/pull/#{number}", head_sha: "a" * 40,
      author: "alice", paths: [].freeze, paths_truncated: false, requested_at:, via:,
      team: (via == :team ? "acme/core" : nil), my_last_review: nil
    )
  end

  def counted = JSON.parse(File.read(counts_file))

  def seed(direct_new: 2)
    log.append(Lain::Review::Queue::Log::Event.new(kind: :listed, at: opened_at, row_id: nil, head_sha: nil))
    3.times { |i| pulls << pull(i + 1, via: :direct, requested_at: opened_at + (i < direct_new ? 60 : -60)) }
    4.times { |i| pulls << pull(i + 10, via: :team, requested_at: opened_at + 60) }
  end

  describe "the count file" do
    it "holds the totals, the new direct requests and the HUD text" do
      seed
      poll.call

      expect(counted).to include("total" => 7, "direct" => 3, "team" => 4, "new_direct" => 2, "hud" => "rv 7+2",
                                 "stale" => false)
      expect(Time.iso8601(counted.fetch("polled_at"))).to be_a(Time)
    end

    it "shows no plus when nothing is new" do
      seed(direct_new: 0)
      poll.call

      expect(counted).to include("new_direct" => 0, "hud" => "rv 7")
    end
  end

  describe "notices" do
    it "sends one per new direct request on the first poll and none on the second" do
      seed
      poll.call
      poll.call

      expect(notices.size).to eq(2)
      expect(log.notified?("pr:acme/api#1")).to be(true)
      expect(log.notified?("pr:acme/api#3")).to be(false)
    end

    it "keeps a pull request title out of the feed's argv" do
      seed(direct_new: 0)
      pulls << pull(20, via: :direct, requested_at: opened_at + 60, title: "-rf \e[31m\nboom")
      poll.call

      source, title, body = notices.first
      expect([source, title]).to eq(["lain-queue", "review requested"])
      expect(body).to include("acme/api#20", "-rf boom").and(satisfy { !_1.match?(/[[:cntrl:]&&[^\n]]/) })
    end
  end

  it "sets the reviews workspace token" do
    seed
    poll.call

    expect(tokens).to eq([{ label: "reviews", name: "reviews", value: "7 (2 new)" }])
  end

  describe "when GitHub is unreachable" do
    it "keeps the last counts, marks them stale and sends no notice" do
      seed
      poll.call
      notices.clear
      pulls.replace([])
      allow(reads).to receive(:review_requests).and_raise(Lain::Forge::Gh::Reads::Refused, "down")
      poll.call

      expect(counted).to include("total" => 7, "new_direct" => 2, "stale" => true)
      expect(notices).to be_empty
    end

    it "raises when the stale marker cannot be written" do
      seed
      poll.call
      allow(reads).to receive(:review_requests).and_raise(Lain::Forge::Gh::Reads::Refused, "down")
      allow(File).to receive(:rename).and_raise(Errno::EIO)

      expect { poll.call }.to raise_error(Errno::EIO)
    end

    it "writes nothing when there are no last counts" do
      allow(reads).to receive(:review_requests).and_raise(Lain::Forge::Gh::Account::Refused, "no token")
      poll.call

      expect(File.exist?(counts_file)).to be(false)
    end
  end

  describe "a poll into a state home that does not exist yet" do
    let(:counts_file) { paths.review_counts }

    it "creates the directory and writes the counts" do
      seed
      poll.call

      expect(JSON.parse(File.read(counts_file))).to include("hud" => "rv 7+2")
    end
  end

  describe ".hud" do
    let(:counts_file) { paths.review_counts }

    before { FileUtils.mkdir_p(File.dirname(counts_file)) }

    def hud = described_class.hud(paths:)

    it "is empty when no counts file was written" do
      expect(hud).to eq("")
    end

    it "is the line the poll wrote" do
      seed
      poll.call

      expect(hud).to eq("rv 7+2")
    end

    it "says a stale count is in doubt" do
      seed
      poll.call
      allow(reads).to receive(:review_requests).and_raise(Lain::Forge::Gh::Reads::Refused, "down")
      poll.call

      expect(hud).to eq("rv 7+2?")
    end

    it "is empty for a file that is not JSON" do
      File.write(counts_file, "{")

      expect(hud).to eq("")
    end

    it "is empty for JSON that is not an object" do
      ["null", "[]", "[1]", "7", "\"rv 7\""].each do |body|
        File.write(counts_file, body)

        expect(hud).to eq("")
      end
    end

    it "reads a count only when it is rv, digits and an optional +digits" do
      bad = ["rv 7#[fg=red]", "rv 1\e[31m#(id)\r\n\e]0;x\a", "rv 7\n", "rv +", "rv 7++", "rv 7+", "rv", "",
             "rv #{"9" * 100_000}a", " rv 7"]
      bad.each do |text|
        File.write(counts_file, JSON.generate("hud" => text, "stale" => false))

        expect(hud).to eq("")
      end
    end

    it "reads stale whatever the key order" do
      File.write(counts_file, '{"stale":true,"hud":"rv 7+2"}')

      expect(hud).to eq("rv 7+2?")
    end

    it "creates nothing, and is empty, under a state home it cannot write to" do
      locked = File.join(@dir, "locked")
      Dir.mkdir(locked, 0o500)
      readonly = Lain::Paths.new(env: { "HOME" => @dir, "XDG_STATE_HOME" => File.join(locked, "state") })

      expect(described_class.hud(paths: readonly)).to eq("")
      expect(Dir.children(locked)).to be_empty
    ensure
      FileUtils.chmod(0o700, locked) if locked
    end
  end

  it "asks 1 review_requests question" do
    seed
    poll.call

    expect(queries).to eq(["is:open is:pr review-requested:@me archived:false"])
  end

  describe "orgs" do
    let(:orgs) { ["acme"] }

    it "counts only the pull requests of the named organizations" do
      seed
      pulls << pull(30, via: :direct, requested_at: opened_at + 60).with(repo: "other/api")
      poll.call

      expect(counted).to include("total" => 7, "direct" => 3)
    end
  end

  describe "a second poll while the first holds the lock" do
    it "does nothing and sends no notice" do
      seed
      Lain::FileLock.new("#{counts_file}.lock").try { poll.call }

      expect([queries, notices, File.exist?(counts_file)]).to eq([[], [], false])
    end

    it "runs once the lock is free" do
      seed
      poll.call

      expect(queries.size).to eq(1)
    end
  end

  describe "a notice that was not sent" do
    let(:feed) { ->(*) { false } }

    it "is not recorded as notified, so a later poll can still send it" do
      seed
      poll.call

      expect(log.notified?("pr:acme/api#1")).to be(false)
    end
  end

  describe "a failed write" do
    it "raises, and leaves no temporary file behind" do
      seed
      allow(File).to receive(:rename).and_raise(Errno::EIO)

      expect { poll.call }.to raise_error(Errno::EIO)
      expect(Dir.children(@dir).grep(/reviews\.json\./)).to eq(["reviews.json.lock"])
    end

    it "is not mistaken for GitHub being unreachable" do
      seed
      allow(File).to receive(:write).and_call_original
      allow(File).to receive(:write).with(a_string_matching(/reviews\.json\.\d+/), anything).and_raise(Errno::ENOSPC)

      expect { poll.call }.to raise_error(Errno::ENOSPC)
    end
  end

  describe "replacing the count file" do
    it "is replaced by a rename, so a reader sees the old counts or the new, never half" do
      seed
      File.write(counts_file, '{"total":0}')
      before_rename = nil
      allow(File).to receive(:rename).and_wrap_original do |original, *args|
        before_rename = File.read(counts_file)
        original.call(*args)
      end
      poll.call

      expect([before_rename, counted.fetch("total")]).to eq(['{"total":0}', 7])
    end
  end
end
