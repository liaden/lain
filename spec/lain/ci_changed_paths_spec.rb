# frozen_string_literal: true

require "tmpdir"
require "open3"

RSpec.describe "bin/ci/changed-paths", :seam do
  let(:script) { File.expand_path("../../bin/ci/changed-paths", __dir__) }
  let(:zeros) { "0" * 40 }

  around do |example|
    Dir.mktmpdir("lain-changed-paths") do |dir|
      @repo = File.realpath(dir)
      example.run
    end
  end

  def scrubbed_env = Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB.merge("GITHUB_OUTPUT" => nil)

  def git(*args)
    config = %w[-c user.email=a@b.c -c user.name=t -c commit.gpgsign=false]
    out, status = Open3.capture2e(Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB, "git", "-C", @repo, *config, *args)
    raise "git #{args.join(" ")}: #{out}" unless status.success?

    out.strip
  end

  def commit_touching(*paths)
    paths.each do |path|
      full = File.join(@repo, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, "#{SecureRandom.hex(4)}\n")
    end
    git("add", "-A")
    git("commit", "-q", "-m", "change")
    git("rev-parse", "HEAD")
  end

  def report(base, head)
    out, err, status = Open3.capture3(scrubbed_env, script, base, head, chdir: @repo)
    raise "changed-paths failed: #{err}" unless status.success?

    out.lines.map(&:strip).sort
  end

  def base_commit
    git("init", "-q")
    commit_touching("README")
  end

  it "trips mutants only for a change under ext/lain" do
    base = base_commit
    head = commit_touching("ext/lain/src/dag.rs")

    expect(report(base, head)).to eq(%w[mutants=true remote=false])
  end

  it "runs everything when the base is 40 zeros" do
    base_commit
    head = commit_touching("docs/x.md")

    expect(report(zeros, head)).to eq(%w[mutants=true remote=true])
  end

  it "runs everything when the base is empty" do
    base_commit
    head = commit_touching("docs/x.md")

    expect(report("", head)).to eq(%w[mutants=true remote=true])
  end

  it "trips remote only for a change to an extracted remote script" do
    base = base_commit
    head = commit_touching("bin/ci/build-apk")

    expect(report(base, head)).to eq(%w[mutants=false remote=true])
  end

  it "runs everything when the filter itself changes" do
    base = base_commit
    head = commit_touching("bin/ci/changed-paths")

    expect(report(base, head)).to eq(%w[mutants=true remote=true])
  end

  it "reports both false for an unrelated change" do
    base = base_commit
    head = commit_touching("docs/x.md")

    expect(report(base, head)).to eq(%w[mutants=false remote=false])
  end

  it "appends to GITHUB_OUTPUT when it is set" do
    base = base_commit
    head = commit_touching("ext/lain/a.rs")
    output = File.join(@repo, "..", "gh-output-#{Process.pid}")
    _out, _err, status = Open3.capture3(scrubbed_env.merge("GITHUB_OUTPUT" => output), script, base, head,
                                        chdir: @repo)

    expect([status.success?, File.readlines(output).map(&:strip).sort]).to eq([true, %w[mutants=true remote=false]])
  ensure
    FileUtils.rm_f(output)
  end

  it "keeps main.yml free of multi-line run blocks" do
    workflow = File.read(File.expand_path("../../.github/workflows/main.yml", __dir__))

    expect(workflow).not_to match(/^\s*run:\s*[|>]/)
  end
end
