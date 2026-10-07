# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Review::Source::Diffed do
  RSpec::Matchers.define_negated_matcher :not_include, :include

  let(:repo_root) { "/repo" }
  let(:secret_file) { "API_KEY=sk-live-0000000000000000\nplain line\n" }

  let(:host_class) do
    Class.new do
      include Lain::Review::Source::Diffed

      def initialize(repo_root, held)
        @repo_root = repo_root
        @held = held
      end

      def file_at(_revision, path) = @held[path]
    end
  end

  let(:source) { host_class.new(repo_root, "app.env" => secret_file.b) }

  describe "#line_at" do
    it "masks an unreleased region on the line it answers" do
      expect(source.line_at("head", "app.env", 1)).to include("<redacted:1>").and(not_include("sk-live-"))
    end

    it "answers a line holding no region as it is" do
      expect(source.line_at("head", "app.env", 2)).to eq("plain line")
    end

    it "answers the released text once the run's ledger holds the release" do
      ledger = Lain::Sensitivity::Ledger.new
      ledger.release("/repo/app.env", Lain::Sensitivity::Regions.detect(secret_file.b))
      source.projection = Lain::Survey::Projection.new(ledger:)

      expect(source.line_at("head", "app.env", 1)).to eq("API_KEY=sk-live-0000000000000000")
    end

    it "answers nil for a path or a line the revision does not hold" do
      expect([source.line_at("head", "absent.rb", 1), source.line_at("head", "app.env", 9)]).to eq([nil, nil])
    end
  end

  describe "#files, when a side's revision holds no file" do
    let(:source) do
      Class.new(host_class) do
        def diff
          "diff --git a/creds.rb b/creds.rb\nnew file mode 100644\nindex 0000000..1111111\n" \
          "--- /dev/null\n+++ b/creds.rb\n@@ -0,0 +1,2 @@\n+x = 1\n+API_KEY=sk-live-0000000000000000\n".b
        end

        def base_ref = "b" * 40

        def head_ref = "h" * 40
      end.new(repo_root, {})
    end

    # Masked rather than refused: the hunk's own lines are projected, so a
    # source whose file_at misbehaves never hands a raw line on.
    it "masks the hunk's own lines and never hands them on raw" do
      expect(source.files.first.hunks.first.lines).to eq(["+x = 1", "+API_KEY=<redacted:1>"])
    end
  end

  describe "#files over a real branch", :seam do
    let(:token) { "API_KEY=sk-live-1111111111111111" }
    let(:pem) do
      body = (1..28).map { |i| format("line%02d", i) * 8 }
      "#{["-----BEGIN PRIVATE KEY-----", *body, "-----END PRIVATE KEY-----"].join("\n")}\n"
    end

    around do |example|
      Dir.mktmpdir("lain-diffed-files") do |root|
        @repo = File.join(File.realpath(root), "repo")
        FileUtils.cp_r(SeedRepo.at({ "README.md" => "seed\n" }), @repo)
        example.run
      end
    end

    def git(*) = SeedRepo.git(@repo, *).stdout

    def write(path, text)
      FileUtils.mkdir_p(File.dirname(File.join(@repo, path)))
      File.write(File.join(@repo, path), text)
    end

    def commit(message)
      git("add", "-A")
      git("commit", "-q", "-m", message)
    end

    def branch(base = {})
      base.each { |path, text| write(path, text) }
      commit("base") unless base.empty?
      @base = git("rev-parse", "HEAD").strip
      git("checkout", "-q", "-b", "feature")
      yield
      commit("head")
    end

    def source(ledger: Lain::Sensitivity::Ledger.new, head: "HEAD")
      Lain::Review::Source::LocalBranch.new(base: @base, head:, repo_root: @repo)
                                       .tap { |built| built.projection = Lain::Survey::Projection.new(ledger:) }
    end

    def files(ledger: Lain::Sensitivity::Ledger.new) = source(ledger:).files

    def keys(built = source) = Lain::Review::Hunk.keys(built.files.flat_map(&:hunks))

    def released(text)
      Lain::Sensitivity::Ledger.new.release(File.join(@repo, "creds.rb"), Lain::Sensitivity::Regions.detect(text))
    end

    def lines(file, marker) = file.hunks.flat_map(&:lines).select { |line| line.start_with?(marker) }

    def sided(hunk, marker) = hunk.lines.count { |line| line.start_with?(" ", marker) }

    it "masks an added token on its hunk line" do
      branch { write("creds.rb", "x = 1\n#{token}\n") }

      expect(lines(files.first, "+")).to eq(["+x = 1", "+API_KEY=<redacted:1>"])
    end

    it "keeps each hunk's line counts and masks every line of an added key block" do
      branch({ "keys.txt" => "head\n" }) { write("keys.txt", "head\n#{pem}tail\n") }
      hunks = files.first.hunks

      expect(hunks.map { |hunk| [sided(hunk, "-"), sided(hunk, "+")] })
        .to eq(hunks.map { |hunk| [hunk.old_count, hunk.new_count] })
      expect(lines(files.first, "+").first(30)).to all(match(/\A\+<redacted:\d+>\z/))
    end

    it "keeps a head-side release through the base side, before and after" do
      branch({ "creds.rb" => "x = 1\nAPI_KEY=sk-live-0000000000000000\n" }) do
        write("creds.rb", "x = 1\n#{token}\n")
      end
      ledger = released("x = 1\n#{token}\n")

      before = files(ledger:).first
      after = files(ledger:).first

      expect([lines(before, "+"), lines(after, "+")]).to all(eq(["+#{token}"]))
      expect(lines(before, "-")).to eq(["-API_KEY=<redacted:1>"])
    end

    # The changed line sits mid-block, where its hunk shows neither armour line,
    # so only the whole old file at the base names it a key.
    it "projects a rename's old side from the old path at the base" do
      branch({ "creds.rb" => pem }) do
        git("mv", "creds.rb", "config.rb")
        write("config.rb", pem.sub("line15" * 8, "edited" * 8))
      end
      file = files.first

      expect(file.status).to eq(:renamed)
      expect(lines(file, "-")).to eq(["-<redacted:2>"])
      expect(file.hunks.flat_map(&:lines).join).not_to include("line15")
    end

    it "keeps a release on an uncommitted edit through opening a review" do
      branch { write("creds.rb", "x = 1\n#{token}\n") }
      edited = "x = 1\nAPI_KEY=sk-live-3333333333333333\n"
      write("creds.rb", edited)
      ledger = released(edited)

      files(ledger:)

      expect(ledger.released(File.join(@repo, "creds.rb"))).not_to be_empty
    end

    it "numbers a hunk's placeholders across both its sides" do
      branch({ "creds.rb" => "x = 1\nAPI_KEY=sk-live-0000000000000000\n" }) { write("creds.rb", "x = 1\n#{token}\n") }

      expect(files.first.hunks.first.lines).to eq([" x = 1", "-API_KEY=<redacted:1>", "+API_KEY=<redacted:2>"])
    end

    it "keys and addresses a changeset the same across a release" do
      branch { write("creds.rb", "x = 1\n#{token}\n") }
      ledger = released("x = 1\n#{token}\n")

      expect([keys(source(ledger:)), source(ledger:).identity]).to eq([keys, source.identity])
    end

    it "keys a hunk the same when a secret lands in another hunk" do
      body = (1..40).map { |i| "line #{i}\n" }
      branch({ "app.rb" => body.join }) do
        edits = { 2 => "changed 3\n", 35 => "#{token}\n" }
        write("app.rb", body.each_with_index.map { |line, i| edits.fetch(i, line) }.join)
      end
      first = git("rev-parse", "HEAD").strip
      write("app.rb", File.read(File.join(@repo, "app.rb")).sub("changed 3", "API_KEY=sk-live-2222222222222222"))
      commit("a secret in the first hunk")

      expect(keys.last).to eq(keys(source(head: first)).last)
    end

    # The key is over the masked text, so the secret's own bytes never reach a
    # journaled digest: two values in the same place key alike.
    it "keys a hunk by its masked text, never by the secret's bytes" do
      branch { write("creds.rb", "x = 1\n#{token}\n") }
      first = git("rev-parse", "HEAD").strip
      write("creds.rb", "x = 1\nAPI_KEY=sk-live-4444444444444444\n")
      commit("rotate")

      expect(keys(source(head: first))).to eq(keys)
    end
  end
end
