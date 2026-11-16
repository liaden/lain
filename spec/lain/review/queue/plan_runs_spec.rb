# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require "json"

RSpec.describe Lain::Review::Queue::PlanRuns, :seam do
  let(:dir) { Dir.mktmpdir }
  let(:checkout) { Lain::Isolation::Checkout.new(dir) }
  let(:notes) { StringIO.new }
  let(:rows) { described_class.new(checkout:, notes:).call }

  after { FileUtils.remove_entry(dir) }

  def git(*args) = SeedRepo.git(dir, *args).stdout.strip

  def commit(message)
    git("commit", "-q", "--allow-empty", "-m", message)
    git("rev-parse", "HEAD")
  end

  def plan(name, status:, base: nil, head: nil, title: "Plan #{name}", under: "planning")
    FileUtils.mkdir_p(File.join(dir, under))
    lines = ["# #{title}", "", "status: #{status}", ("base: #{base}" if base), ("head: #{head}" if head), ""]
    File.write(File.join(dir, under, "#{name}.md"), lines.compact.join("\n"))
  end

  before do
    SeedRepo.derived("plan runs", into: dir) { nil }
    git("branch", "-M", "trunk")
  end

  it "lists a finished run with its range" do
    a = git("rev-parse", "HEAD")
    c = commit("work")
    plan("done-run", status: "done", base: a, head: c, title: "Ship it")
    commit("later work")

    expect(rows.map { |r| [r.id, r.rank, r.reason, r.head_sha, r.request.to_h] }).to eq(
      [["plan:planning/done-run.md", :plan_run, "plan done: Ship it", c,
        { "kind" => "range", "base" => a, "head" => c, "repo_root" => File.realpath(dir) }]]
    )
    expect(rows.first.request.review_line).to eq("/review #{c} --base #{a}")
  end

  it "reviews a run in flight up to the head of the checkout" do
    a = git("rev-parse", "HEAD")
    d = commit("work")
    plan("live-run", status: "in-progress", base: a, title: "Doing it")

    expect(rows.map { |r| [r.reason, r.request.to_h.values_at("base", "head")] }).to eq(
      [["plan in progress: Doing it", [a, d]]]
    )
  end

  it "takes the first word of a status that carries prose" do
    a = git("rev-parse", "HEAD")
    c = commit("work")
    plan("prose", status: "done (landed 2026-11-16)", base: a, head: c)

    expect(rows.size).to eq(1)
  end

  it "ignores plans with no base line and ignored files that have one" do
    a = git("rev-parse", "HEAD")
    c = commit("work")
    60.times { |i| plan("nobase#{i}", status: "done") }
    File.write(File.join(dir, ".gitignore"), "hidden.md\n")
    plan("hidden", status: "done", base: a, head: c)

    expect(rows).to eq([])
  end

  it "ignores a plan whose status is neither done nor in-progress" do
    a = git("rev-parse", "HEAD")
    plan("draft", status: "draft", base: a)

    expect(rows).to eq([])
  end

  it "gives no row for a done plan with no head line" do
    a = git("rev-parse", "HEAD")
    plan("headless", status: "done", base: a)

    expect(rows).to eq([])
  end

  it "gives no row for a tracked plan deleted from the working tree" do
    a = git("rev-parse", "HEAD")
    plan("gone", status: "in-progress", base: a)
    git("add", "-A")
    commit("track the plan")
    FileUtils.rm(File.join(dir, "planning/gone.md"))

    expect(rows).to eq([])
  end

  it "lists a run in a repository under a non-ASCII path" do
    accented = File.join(dir, "caf\u00e9")
    SeedRepo.derived("plan runs", into: accented) { nil }
    base = SeedRepo.git(accented, "rev-parse", "HEAD").stdout.strip
    FileUtils.mkdir_p(File.join(accented, "planning"))
    File.write(File.join(accented, "planning", "p.md"), "# P\n\nstatus: in-progress\nbase: #{base}\n")

    listed = described_class.new(checkout: Lain::Isolation::Checkout.new(accented), notes:).call

    expect(listed.map { |r| r.request.repo_root }).to eq([File.realpath(accented)])
  end

  it "skips a plan whose recorded base is not a full sha, with 1 note, and lists the rest" do
    a = git("rev-parse", "HEAD")
    c = commit("work")
    plan("good", status: "done", base: a, head: c)
    plan("short", status: "done", base: a[0, 12], head: c)

    expect([rows.map(&:id), notes.string])
      .to eq([["plan:planning/good.md"],
              "skipped plan:planning/short.md: queued review request refused: base is not of its shape\n"])
  end

  it "lists a plan whose file name is not ASCII beside a plain one" do
    a = git("rev-parse", "HEAD")
    c = commit("work")
    plan("good", status: "done", base: a, head: c)
    plan("\u00e9t\u00e9", status: "done", base: a, head: c)

    expect(rows.map(&:id).sort).to eq(["plan:planning/good.md", "plan:planning/\u00e9t\u00e9.md"])
  end

  it "skips a plan whose file name is not UTF-8, with 1 note, and lists the rest" do
    a = git("rev-parse", "HEAD")
    c = commit("work")
    plan("good", status: "done", base: a, head: c)
    File.write(File.join(dir, "planning", "\xE9t\xE9.md".b), "# P\n\nstatus: done\nbase: #{a}\nhead: #{c}\n")

    expect([JSON.parse(JSON.generate(rows.map(&:id))), notes.string.lines.size]).to eq([["plan:planning/good.md"], 1])
  end

  it "lists a run from a subdirectory of the work tree, rooted at its top" do
    a = git("rev-parse", "HEAD")
    c = commit("work")
    plan("nested", status: "done", base: a, head: c, under: "sub/planning")

    listed = described_class.new(checkout: Lain::Isolation::Checkout.new(File.join(dir, "sub")), notes:).call

    expect(listed.map { |r| r.request.repo_root }).to eq([File.realpath(dir)])
  end

  it "skips a plan it cannot read, with 1 note, and lists the rest" do
    a = git("rev-parse", "HEAD")
    c = commit("work")
    plan("good", status: "done", base: a, head: c)
    plan("locked", status: "done", base: a, head: c)
    allow(File).to receive(:read).and_call_original
    allow(File).to receive(:read).with(%r{planning/locked\.md\z}).and_raise(Errno::EACCES)

    expect([rows.map(&:id), notes.string.lines.grep(/locked/).size]).to eq([["plan:planning/good.md"], 1])
  end

  it "reads only plans under planning/, so a doc quoting the base format gives no row" do
    a = git("rev-parse", "HEAD")
    plan("format-doc", status: "done", base: a, head: a, under: "docs")

    expect(rows).to eq([])
  end
end
