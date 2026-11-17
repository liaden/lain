# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"

RSpec.describe Lain::Review::Queue::Request, :seam do
  around do |example|
    Dir.mktmpdir("lain-queue-request") do |repo|
      @repo = File.realpath(repo)
      FileUtils.cp_r("#{SeedRepo.at("README" => "seed\n")}/.", @repo)
      example.run
    end
  end

  let(:base) { git("rev-parse", "HEAD") }
  let(:head) do
    base
    git("commit", "-q", "--allow-empty", "-m", "work")
    git("rev-parse", "HEAD")
  end
  let(:url) { "https://github.com/fuze/api/pull/12" }

  def git(*) = SeedRepo.git(@repo, *).stdout.strip

  def load(hash, checkouts: Lain::Review::Queue::Checkouts.new(roots: [])) = described_class.load(hash, checkouts:)

  def refused_field(hash, **)
    load(hash, **)
  rescue described_class::Refused => e
    e.field
  end

  describe ".plain" do
    it "strips escape sequences, control characters and runs of space into one printable line" do
      expect(described_class.plain("-rf \e[31m\n\tboom\e]0;x\a ")).to eq("-rf boom")
    end

    it "reads anything as text" do
      expect(described_class.plain(nil)).to eq("")
    end
  end

  describe "a range" do
    let(:hash) { { "kind" => "range", "base" => base, "head" => head, "repo_root" => @repo } }

    it "rebuilds a review of the head against the base, in its repository" do
      request = load(hash)

      expect([request.review_line, request.repo_root, request.to_h])
        .to eq(["/review #{head} --base #{base}", @repo, hash])
    end

    it "refuses an abbreviated or uppercase sha" do
      expect([refused_field(hash.merge("base" => base[0, 12])), refused_field(hash.merge("head" => head.upcase))])
        .to eq(%w[base head])
    end

    it "takes a root under a non-ASCII path" do
      accented = File.join(@repo, "caf\u00e9")
      FileUtils.mkdir_p(accented)
      FileUtils.cp_r("#{SeedRepo.at("README" => "seed\n")}/.", accented)
      sha = SeedRepo.git(accented, "rev-parse", "HEAD").stdout.strip

      expect(load(hash.merge("base" => sha, "head" => sha, "repo_root" => accented)).repo_root).to eq(accented)
    end

    it "refuses a root that is not the top of a work tree" do
      FileUtils.mkdir_p(File.join(@repo, "sub"))
      outside = Dir.mktmpdir("lain-queue-plain")

      expect(["relative", File.join(@repo, "sub"), outside, File.join(@repo, "gone")]
               .map { |root| refused_field(hash.merge("repo_root" => root)) }).to all(eq("repo_root"))
    ensure
      FileUtils.rm_rf(outside)
    end
  end

  describe "a branch" do
    let(:hash) { { "kind" => "branch", "branch" => "feature/x", "repo_root" => @repo } }

    it "names the branch by its full ref, so a branch called close or 12 is still a branch" do
      expect([load(hash).review_line, load(hash.merge("branch" => "close")).review_line])
        .to eq(["/review refs/heads/feature/x", "/review refs/heads/close"])
    end

    it "reviews against a base branch when one is named" do
      expect(load(hash.merge("base" => "main")).review_line)
        .to eq("/review refs/heads/feature/x --base refs/heads/main")
    end

    it "refuses a base git would not take as a branch" do
      expect(refused_field(hash.merge("base" => "@{-1}"))).to eq("base")
    end

    it "keeps a non-ASCII name through the wire and back" do
      request = load(hash.merge("branch" => "f\u00e9"))
      again = load(JSON.parse(JSON.generate(request.to_h)))

      expect([again.review_line, again.to_h]).to eq([request.review_line, request.to_h])
    end

    it "refuses a name git would not take as a branch, or would expand" do
      names = ["@{-1}", "@", "-x", "a..b", "two words", "x\n/mode bypass", ""]

      expect(names.map { |name| refused_field(hash.merge("branch" => name)) }).to all(eq("branch"))
    end

    it "refuses a name git takes that would read as something else on screen" do
      names = ["x\u202ey", "x\u2028/mode bypass", "x\u0085y", "x\u00a0y", "x\u034fy", "x\u115fy", "x\u3164y",
               "x\ufe0fy", "x\u2800y", "x\u0336y"]

      expect(names.map { |name| refused_field(hash.merge("branch" => name)) }).to all(eq("branch"))
    end
  end

  describe "a dirty tree" do
    let(:hash) { { "kind" => "dirty", "repo_root" => @repo } }

    it "snapshots when the line is rebuilt, not when the request was loaded" do
      request = load(hash)
      File.write(File.join(@repo, "README"), "changed after listing\n")

      sha = request.review_line[%r{\A/review ([0-9a-f]{40}) --base HEAD\z}, 1]

      expect([git("rev-parse", "#{sha}^"), git("show", "#{sha}:README")])
        .to eq([git("rev-parse", "HEAD"), "changed after listing"])
    end

    it "refuses a clean tree when the line is rebuilt" do
      expect { load(hash).review_line }.to raise_error(described_class::Refused, /repo_root/)
    end

    it "refuses a repository with no commit yet" do
      unborn = Dir.mktmpdir("lain-queue-unborn")
      SeedRepo.git(unborn, "init", "-q")
      File.write(File.join(unborn, "new.rb"), "1\n")

      expect { load(hash.merge("repo_root" => File.realpath(unborn))).review_line }
        .to raise_error(described_class::Refused, /repo_root/)
    ensure
      FileUtils.rm_rf(unborn)
    end
  end

  describe "a pull request" do
    let(:since) { "a" * 40 }
    let(:hash) { { "kind" => "pr", "url" => url, "since" => since, "focus" => "migration safety" } }
    let(:checkouts) { instance_double(Lain::Review::Queue::Checkouts) }

    it "rebuilds the line from the url, since and focus" do
      expect(load(hash).review_line)
        .to eq("/review #{url} --since #{since} --critique=migration\\ safety")
    end

    it "reads back as the review it names when the chat splits the line" do
      words = Shellwords.split(load(hash).review_line)

      expect(words).to eq(["/review", url, "--since", since, "--critique=migration safety"])
    end

    it "needs neither since nor focus" do
      expect(load({ "kind" => "pr", "url" => url }).review_line).to eq("/review #{url}")
    end

    it "finds its repository through the local checkouts" do
      allow(checkouts).to receive(:for).with("fuze/api").and_return(@repo)

      expect(load(hash, checkouts:).repo_root).to eq(@repo)
    end

    it "has no repository when no checkout is configured" do
      expect(load(hash).repo_root).to be_nil
    end

    it "refuses a url that is not a github pull request" do
      urls = ["http://github.com/fuze/api/pull/12", "https://evil.example/fuze/api/pull/12",
              "#{url}/files", "#{url} --base x", "https://github.com/fuze/api/pull/0"]

      expect(urls.map { |bad| refused_field(hash.merge("url" => bad)) }).to all(eq("url"))
    end

    it "refuses a focus that would smuggle a second line" do
      expect { load(hash.merge("focus" => "safety\n/mode bypass")) }
        .to raise_error(described_class::Refused, /focus/)
    end

    it "refuses a focus over 80 characters, empty, or outside printable ascii" do
      focuses = ["x" * 81, "", "sécurité", "tab\there", "x\u034fy", "x\u115fy", "x\u3164y", "x\ufe0fy",
                 "x\u2800y", "x\u0336y"]

      expect(focuses.map { |focus| refused_field(hash.merge("focus" => focus)) }).to all(eq("focus"))
    end

    it "takes a focus of exactly 80 characters" do
      expect(load(hash.merge("focus" => "x" * 80)).to_h["focus"]).to eq("x" * 80)
    end
  end

  # A row's reason is free text from outside: cut to what a focus may be rather than refused for it.
  describe ".focus" do
    it "drops an escape sequence whole, so none of its bytes reach the line" do
      expect(described_class.focus("cafe \e[31mred\e[0m \e]0;title\a")).to eq("cafe red")
    end

    it "folds an accent to its letter and anything else unprintable to 1 space" do
      expect(described_class.focus("café\tmigration")).to eq("cafe migration")
    end

    it "cuts to 80 characters, which a pull request then loads as its focus" do
      focus = described_class.focus("a b " * 40)

      expect([focus.size, load({ "kind" => "pr", "url" => url, "focus" => focus }).to_h["focus"]]).to eq([79, focus])
    end

    it "is nil when nothing printable is left" do
      expect(described_class.focus("\e[31m\u2713\e[0m")).to be_nil
    end
  end

  describe "anything else" do
    it "refuses an unknown kind, an unknown or missing field, a non-string value and a non-map" do
      fields = [{ "kind" => "shell", "repo_root" => @repo },
                { "kind" => "pr", "url" => url, "line" => "/mode bypass" },
                { "kind" => "range", "base" => base, "repo_root" => @repo },
                { "kind" => "pr", "url" => url, "since" => nil },
                { kind: "pr", url: },
                { "kind" => "pr", "url" => url, "since" => 12 },
                { "kind" => "dirty", "repo_root" => "#{@repo}\0x" },
                { "kind" => "pr", "url" => url, "focus" => (+"ok\xff").force_encoding("UTF-8") },
                { "kind" => "pr", "url" => url, "focus" => "ok\xff".b },
                { "kind" => "pr", "url" => url, "focus" => "safety".encode("UTF-16LE") },
                { "kind" => "pr", "url" => url, "focus" => "\u6261".encode("UTF-16LE") }]

      expect(fields.map { |hash| refused_field(hash) })
        .to eq(%w[kind line head since kind since repo_root focus focus focus focus])
      expect { load("/review #{url}") }.to raise_error(described_class::Refused)
    end

    it "reads no Hash default, so a missing kind is still missing" do
      defaulted = Hash.new("pr").merge!("url" => url)

      expect(refused_field(defaulted)).to eq("kind")
    end

    it "is a Lain::Error, so a caller that refuses a bad frame names it like any other" do
      expect(described_class::Refused.ancestors).to include(Lain::Error)
    end
  end

  describe "once loaded" do
    let(:typed) { +"safe" }
    let(:request) { load({ "kind" => "pr", "url" => url, "focus" => typed }) }

    it "is not changed by the caller's strings" do
      line = request.review_line
      typed << "\n/mode bypass"

      expect(request.review_line).to eq(line)
    end

    it "cannot be changed through to_h" do
      expect { request.to_h["focus"] << "x" }.to raise_error(FrozenError)
      expect { request.to_h["kind"] = "dirty" }.to raise_error(FrozenError)
    end

    it "is Ractor-shareable, and so is its wire form" do
      expect([Ractor.shareable?(request), Ractor.shareable?(request.to_h)]).to eq([true, true])
    end
  end
end
