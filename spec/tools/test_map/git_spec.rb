# frozen_string_literal: true

require "open3"
require "tmpdir"
require "rbconfig"
require_relative "../../../tools/test_map/git"

RSpec.describe TestMap::Git do
  let(:identity) do
    { "GIT_AUTHOR_NAME" => "t", "GIT_AUTHOR_EMAIL" => "t@t", "GIT_COMMITTER_NAME" => "t",
      "GIT_COMMITTER_EMAIL" => "t@t" }
  end

  def init_repo(dir, file)
    File.write(File.join(dir, file), "x")
    [%w[init -q], ["add", file]].each do |args|
      _, err, st = Open3.capture3(identity.merge(SeedRepo::SCRUB), "git", "-C", dir, *args)
      raise err unless st.success?
    end
  end

  describe ".run" do
    it "lists the repo's own index when GIT_INDEX_FILE names another" do
      Dir.mktmpdir do |other|
        Dir.mktmpdir do |dir|
          init_repo(other, "foreign.txt")
          init_repo(dir, "own.txt")
          saved = ENV.fetch("GIT_INDEX_FILE", nil)
          ENV["GIT_INDEX_FILE"] = File.join(other, ".git", "index")
          begin
            expect(described_class.run("ls-files", repo: dir)).to eq("own.txt\n")
          ensure
            ENV["GIT_INDEX_FILE"] = saved
          end
        end
      end
    end

    it "keeps the caller's context with scrub: false" do
      Dir.mktmpdir do |other|
        Dir.mktmpdir do |dir|
          init_repo(other, "foreign.txt")
          init_repo(dir, "own.txt")
          saved = ENV.fetch("GIT_INDEX_FILE", nil)
          ENV["GIT_INDEX_FILE"] = File.join(other, ".git", "index")
          begin
            expect(described_class.run("ls-files", repo: dir, scrub: false)).to eq("foreign.txt\n")
          ensure
            ENV["GIT_INDEX_FILE"] = saved
          end
        end
      end
    end

    it "returns UTF-8 text when the process encoding is not UTF-8" do
      Dir.mktmpdir do |dir|
        init_repo(dir, "\u00e9.txt")
        saved = Encoding.default_external
        Encoding.default_external = Encoding::US_ASCII
        begin
          out = described_class.run("-c", "core.quotepath=false", "ls-files", repo: dir)
          expect([out.encoding, out]).to eq([Encoding::UTF_8, "\u00e9.txt\n"])
        ensure
          Encoding.default_external = saved
        end
      end
    end

    it "raises with stderr on a non-zero exit" do
      Dir.mktmpdir do |dir|
        expect do
          described_class.run("rev-parse", "HEAD", repo: dir)
        end.to raise_error(RuntimeError, /not a git repository|fatal/)
      end
    end
  end

  it "scrubs the keys lain's own worktree scrubs" do
    expect(described_class::SCRUB).to match_array(Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB.keys)
  end

  it "loads in a Ruby with no lain on the load path" do
    path = File.expand_path("../../../tools/test_map/git.rb", __dir__)
    out, st = Open3.capture2e({ "RUBYOPT" => nil, "RUBYLIB" => nil }, RbConfig.ruby, "--disable-gems", "-e",
                              "require ARGV[0]; print defined?(Lain).inspect", path)
    expect([st.success?, out]).to eq([true, "nil"])
  end
end
