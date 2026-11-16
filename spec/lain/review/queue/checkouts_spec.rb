# frozen_string_literal: true

require "stringio"
require "tmpdir"

RSpec.describe Lain::Review::Queue::Checkouts, :seam do
  let(:root) { Dir.mktmpdir }
  let(:notes) { StringIO.new }

  after { FileUtils.remove_entry(root) }

  def clone_at(path, origin, at: Time.utc(2026, 11, 1))
    dir = FileUtils.mkdir_p(File.join(root, path)).first
    FileUtils.cp_r("#{SeedRepo.at(SeedRepo::SEED)}/.", dir)
    SeedRepo.git(dir, "remote", "add", "origin", origin)
    stamp = { "GIT_COMMITTER_DATE" => at.iso8601, "GIT_AUTHOR_DATE" => at.iso8601 }
    SeedRepo.git(dir, "commit", "-q", "--allow-empty", "-m", "later", env: stamp)
    dir
  end

  def checkouts = described_class.new(roots: [root], notes:)

  it "maps an ssh origin to its clone" do
    dir = clone_at("api", "git@github.com:fuze/api.git")
    expect(checkouts.for("fuze/api")).to eq(dir)
  end

  it "maps an https origin, two levels down, ignoring case and a missing .git" do
    dir = clone_at("fuze/api", "https://github.com/Fuze/API")
    expect(checkouts.for("fuze/api")).to eq(dir)
  end

  it "answers nil when no clone has that origin" do
    clone_at("api", "git@github.com:fuze/api.git")
    expect(checkouts.for("fuze/other")).to be_nil
  end

  it "returns the clone with the newest HEAD commit and names the other in a note" do
    clone_at("old", "git@github.com:fuze/api.git", at: Time.utc(2026, 1, 1))
    newer = clone_at("new", "https://github.com/fuze/api.git", at: Time.utc(2026, 11, 10))
    expect([checkouts.for("fuze/api"), notes.string]).to match([newer, %r{fuze/api.*old}])
  end

  it "names the extra clones once however often the repo is looked up" do
    clone_at("old", "git@github.com:fuze/api.git", at: Time.utc(2026, 1, 1))
    clone_at("new", "git@github.com:fuze/api.git", at: Time.utc(2026, 11, 10))
    finder = checkouts
    2.times { finder.for("fuze/api") }
    expect(notes.string.lines.size).to eq(1)
  end

  it "does not count a linked worktree as another clone" do
    dir = clone_at("api", "git@github.com:fuze/api.git", at: Time.utc(2026, 1, 1))
    linked = File.join(root, "api-wt")
    SeedRepo.git(dir, "worktree", "add", "-q", "-b", "wt", linked)
    SeedRepo.git(linked, "commit", "-q", "--allow-empty", "-m", "newer",
                 env: { "GIT_COMMITTER_DATE" => Time.utc(2026, 11, 10).iso8601 })
    expect([checkouts.for("fuze/api"), notes.string]).to eq([dir, ""])
  end
end
