# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Lain::Review::Queue::PlanRuns, :seam do
  let(:dir) { Dir.mktmpdir }
  let(:checkout) { Lain::Isolation::Checkout.new(dir) }
  let(:rows) { described_class.new(checkout:).call }

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

    expect(rows.map { |r| [r.id, r.rank, r.reason, r.head_sha, r.request] }).to eq(
      [["plan:planning/done-run.md", :plan_run, "plan done: Ship it", c,
        { "kind" => "range", "base" => a, "head" => c, "repo_root" => File.realpath(dir) }]]
    )
  end

  it "reviews a run in flight up to the head of the checkout" do
    a = git("rev-parse", "HEAD")
    d = commit("work")
    plan("live-run", status: "in-progress", base: a, title: "Doing it")

    expect(rows.map { |r| [r.reason, r.request.values_at("base", "head")] }).to eq(
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

  it "reads only plans under planning/, so a doc quoting the base format gives no row" do
    a = git("rev-parse", "HEAD")
    plan("format-doc", status: "done", base: a, head: a, under: "docs")

    expect(rows).to eq([])
  end
end
