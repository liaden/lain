# frozen_string_literal: true

# The one repository search three layers ask: the chat's worktree backend,
# `lain worktrees gc`, and `--isolation none` answering for a handback. It used
# to be published from {Lain::CLI::IsolationBackend}, which put the isolation
# layer's dependency on the CLI layer above it; these examples moved here with
# it rather than being rewritten, so the stop rule stays covered where it lives.
RSpec.describe Lain::Project::Repository do
  around do |example|
    Dir.mktmpdir("lain-repository-search") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:search_paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(@dir, "state") }) }

  def nearest_from(dir) = described_class.nearest(dir, paths: search_paths, home: Dir.home)

  describe ".nearest" do
    it "finds the nearest ancestor holding a .git entry" do
      repo = File.join(@dir, "repo")
      FileUtils.mkdir_p(File.join(repo, ".git"))
      FileUtils.mkdir_p(File.join(repo, "a", "b"))

      found = nearest_from(File.join(repo, "a", "b"))

      expect([found.path, found.found?]).to eq([repo, true])
    end

    it "answers an empty path, not nil, outside any repository" do
      found = nearest_from(@dir)

      expect([found.path, found.found?]).to eq(["", false])
    end

    it "refuses a search that cannot be bounded, rather than climbing without a ceiling" do
      expect { described_class.nearest(@dir, paths: search_paths, home: nil) }
        .to raise_error(Lain::Project::Resolver::UnusableHome)
    end
  end

  # Each caller words its own lead-in and keeps its own error class, because the
  # remedy differs per command; only this clause is shared.
  describe "#searched" do
    it "names where the search started and where it stopped" do
      found = nearest_from(@dir)

      expect(found.searched("/from/here"))
        .to eq("/from/here is not inside a git repository up to #{found.boundary} (#{found.reason})")
    end
  end
end
