# frozen_string_literal: true

require "stringio"
require "fileutils"

RSpec.describe Lain::Review::Queue::PullRequests, :seam do
  let(:dir) { Dir.mktmpdir }
  let(:notes) { StringIO.new }
  let(:checkouts) { instance_double(Lain::Review::Queue::Checkouts) }
  let(:config) { Lain::Config::Github.resolve(project: github, user: Lain::Config::Github.empty, env: {}) }
  let(:github) { Lain::Config::Github.empty }
  let(:requests) { [] }
  let(:found) { [] }
  let(:queries) { [] }
  let(:sinks_seen) { [] }
  let(:reads) do
    asked = requests
    matched = found
    log = queries
    sinks = sinks_seen
    Class.new do
      define_method(:review_requests) { |query:| (log << query) && asked }
      define_method(:matches) do |query:, notes: nil|
        sinks << notes
        (log << query) && matched
      end
    end.new
  end
  let(:clock) { -> { Time.utc(2026, 11, 16, 12) } }
  let(:scope) { :mine }
  let(:with_matches) { false }
  let(:rows) do
    described_class.new(reads:, config:, checkouts:, scope:, matches: with_matches, notes:, clock:).call
  end

  after { FileUtils.remove_entry(dir) }

  def git(*args) = SeedRepo.git(dir, *args).stdout.strip

  def commit(message)
    git("commit", "-q", "--allow-empty", "-m", message)
    git("rev-parse", "HEAD")
  end

  def asking(number, via: :direct, repo: "fuze/api", head: "a" * 40, paths: [], mine: nil, truncated: false)
    Lain::Forge::Gh::ReviewRequest.new(
      repo:, number:, title: "PR #{number}", url: "https://github.com/#{repo}/pull/#{number}", head_sha: head,
      author: "alice", paths: paths.freeze, paths_truncated: truncated, requested_at: nil, via:,
      team: (via == :team ? "fuze/platform" : nil), my_last_review: mine
    )
  end

  before do
    SeedRepo.derived("pull requests", into: dir) { nil }
    allow(checkouts).to receive(:for).and_return(nil)
  end

  describe ".id_for" do
    it "names a pull request the way its row is named" do
      expect(described_class.id_for(asking(7, repo: "fuze/web"))).to eq("pr:fuze/web#7")
    end
  end

  describe "a direct and a team request" do
    let(:requests) { [asking(2, via: :team), asking(1)] }

    it "yields the direct row only for scope mine" do
      expect(rows.map { |r| [r.id, r.rank] }).to eq([["pr:fuze/api#1", :direct]])
    end

    context "with scope all" do
      let(:scope) { :all }

      it "yields both, direct first, each with its reason" do
        expect(rows.map { |r| [r.id, r.rank, r.reason] })
          .to eq([["pr:fuze/api#1", :direct, "direct, no local checkout"],
                  ["pr:fuze/api#2", :team, "team: fuze/platform, no local checkout"]])
      end
    end
  end

  describe "requests of 1 rank" do
    let(:requests) { (1..12).map { |number| asking(number) } }

    it "keep the order GitHub gave them" do
      expect(rows.map { |r| r.request.to_h["url"][/\d+\z/].to_i }).to eq((1..12).to_a)
    end
  end

  describe "a request I reviewed before" do
    let(:old) { git("rev-parse", "HEAD") }
    let(:head) { commit("one") && commit("two") }
    let(:requests) { [asking(12, head:, mine: old)] }

    before { allow(checkouts).to receive(:for).with("fuze/api").and_return(dir) }

    it "asks for the PR since that commit, naming the commits added" do
      old
      row = rows.first

      expect([row.rank, row.reason, row.request.to_h])
        .to eq([:re_review, "direct, re-review: 2 commits",
                { "kind" => "pr", "url" => "https://github.com/fuze/api/pull/12", "since" => old }])
    end

    it "shows the whole PR when that commit is not an ancestor of the head" do
      requests.replace([asking(12, head:, mine: "f" * 40)])

      expect(rows.first).to have_attributes(rank: :direct, reason: "direct")
      expect(rows.first.request.to_h).not_to include("since")
    end

    it "shows the whole PR when nothing came after my review" do
      requests.replace([asking(12, head: old, mine: old)])

      expect(rows.first.rank).to eq(:direct)
    end
  end

  describe "the checkout" do
    let(:requests) { [asking(1)] }

    it "holds the clone the repo maps to" do
      allow(checkouts).to receive(:for).with("fuze/api").and_return(dir)

      expect(rows.first).to have_attributes(reason: "direct")
      expect(rows.first.request.repo_root).to eq(git("rev-parse", "--show-toplevel"))
    end

    it "says there is none when the repo has no clone" do
      expect([rows.first.reason, rows.first.request.repo_root]).to eq(["direct, no local checkout", nil])
    end
  end

  describe "matches" do
    let(:github) do
      Lain::Config::Github.from({ "orgs" => ["fuze"], "keywords" => ["billing"], "paths" => [%r{\Adb/}] }, path: nil)
    end
    let(:found) { [asking(7, via: :match, paths: %w[db/x.sql]), asking(8, via: :match, paths: %w[app/y.rb])] }

    it "runs no keyword or path query while matches are off" do
      rows

      expect(queries).to eq(["is:open is:pr review-requested:@me archived:false"])
    end

    context "with matches on" do
      let(:with_matches) { true }
      let(:requests) { [asking(1)] }

      it "adds a path row, below every request, for an unrequested PR touching a configured path" do
        expect(rows.map { |r| [r.id, r.rank, r.reason] })
          .to include(["pr:fuze/api#7", :path, "path: db/x.sql, no local checkout"])
        expect(rows.first.id).to eq("pr:fuze/api#1")
      end

      it "adds a keyword row for a PR the keyword search found, and a PR once" do
        found << asking(7, via: :match, paths: %w[db/x.sql])
        reasons = rows.select { |r| r.id.end_with?("#7", "#8") }.map(&:reason)

        expect(reasons.size).to eq(2)
        expect(reasons).to include("keyword: billing, no local checkout")
      end

      it "hands every search the notes sink" do
        rows

        expect(sinks_seen).to eq([notes, notes])
      end

      it "scopes each search to the org and the days window" do
        rows
        window = "is:open is:pr archived:false -author:@me org:fuze updated:>=2026-11-02"

        expect(queries.drop(1)).to include(
          "#{window} sort:updated-desc",
          "#{window} sort:updated-desc billing in:title,body"
        )
      end

      it "skips a PR that is already a request row" do
        found << asking(1, via: :match, paths: %w[db/z.sql])

        expect(rows.count { |r| r.id == "pr:fuze/api#1" }).to eq(1)
      end

      context "with paths only" do
        let(:github) { Lain::Config::Github.from({ "orgs" => ["fuze"], "paths" => [%r{\Adb/}] }, path: nil) }

        it "keeps a truncated PR with no match in its first files, as an unconfirmed path row" do
          found.replace([asking(9, via: :match, paths: %w[app/z.rb], truncated: true)])
          row = rows.find { |r| r.id == "pr:fuze/api#9" }

          expect([row.rank, row.reason]).to eq([:path, "path: /\\Adb\\//?, file list truncated, no local checkout"])
        end

        it "confirms a truncated PR whose first files do match" do
          found.replace([asking(9, via: :match, paths: %w[db/z.sql], truncated: true)])

          expect(rows.find { |r| r.id == "pr:fuze/api#9" }.reason).to eq("path: db/z.sql, no local checkout")
        end
      end

      it "quotes a keyword of several words" do
        github_words = Lain::Config::Github.from({ "orgs" => ["fuze"], "keywords" => ["data model"] }, path: nil)
        described_class.new(reads:, config: Lain::Config::Github.resolve(project: github_words,
                                                                         user: Lain::Config::Github.empty, env: {}),
                            checkouts:, matches: true, clock:).call

        expect(queries.last).to end_with('sort:updated-desc "data model" in:title,body')
      end

      it "leaves a team request that scope hides out of the match rows" do
        requests.replace([asking(1), asking(7, via: :team)])

        expect(rows.map(&:id)).not_to include("pr:fuze/api#7")
      end

      context "with no org configured" do
        let(:github) { Lain::Config::Github.from({ "keywords" => ["billing"] }, path: nil) }

        it "says why nothing was searched" do
          rows

          expect(notes.string).to match(/matches.*no org/)
        end
      end
    end
  end

  describe "orgs" do
    let(:github) { Lain::Config::Github.from({ "orgs" => ["fuze"] }, path: nil) }
    let(:requests) { [asking(1, repo: "other/api"), asking(2)] }

    it "drops a request in an org the config does not name" do
      expect(rows.map(&:id)).to eq(["pr:fuze/api#2"])
    end
  end
end
