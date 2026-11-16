# frozen_string_literal: true

require "open3"
require "tmpdir"

# bin/qa-lain, like exe/lain, ends in a guarded `.start`, so this `load` defines
# the Thor class without parsing rspec's ARGV.
load File.expand_path("../../bin/qa-lain", __dir__)

RSpec.describe QALain do
  let(:root) { File.expand_path("../..", __dir__) }

  it "declares review and survey, each routing a bare target through `open`" do
    expect([described_class.subcommand_classes["review"], described_class.subcommand_classes["survey"]])
      .to eq([QALain::Review, QALain::Survey])
    expect([QALain::Review, QALain::Survey].map(&:default_command)).to eq(%w[open open])
  end

  it "refuses an unknown switch on review, naming it" do
    expect { described_class.start(%w[review open feature/x --nope], debug: true) }
      .to raise_error(Thor::UnknownArgumentError, /--nope/)
  end

  it "hands review's scope and base to the lib as a Symbol and a String" do
    review = instance_double(Lain::CLI::Review, present: "drawn")
    allow(Lain::CLI::Review).to receive(:new).and_return(review)

    expect { described_class.start(%w[review feature/x --scope by_directory --base main], debug: true) }
      .to output(/drawn/).to_stdout
    expect(review).to have_received(:present).with("feature/x", scope: :by_directory, base: "main")
  end

  it "offers every registered strategy on review's --scope" do
    scope = QALain::Review.commands.fetch("open").options.fetch(:scope)

    expect(scope.enum).to match_array(Lain::Review::Partition::STRATEGIES.values.map(&:name))
  end

  describe "the executables", :seam do
    def run_exe(*argv, chdir: root, env: {})
      Open3.capture3({ "BUNDLE_GEMFILE" => nil, "RUBYOPT" => nil, "BUNDLER_SETUP" => nil }.merge(env),
                     RbConfig.ruby, *argv, chdir:)
    end

    def git(dir, *args)
      out, status = Open3.capture2e(SeedRepo::SCRUB, "git", "-C", dir, *args)
      raise out unless status.success?
    end

    it "reviews a branch as text" do
      Dir.mktmpdir("qa-lain-review") do |dir|
        git(dir, "init", "-q", "-b", "main")
        File.write(File.join(dir, "a.rb"), "a\n")
        git(dir, "add", ".")
        git(dir, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "-m", "base")
        git(dir, "checkout", "-q", "-b", "feature/x")
        File.write(File.join(dir, "a.rb"), "a\nb\n")
        git(dir, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-qam", "change")

        env = { "HOME" => dir, "XDG_STATE_HOME" => File.join(dir, "state"),
                "XDG_CACHE_HOME" => File.join(dir, "cache") }
        out, err, status = run_exe(File.join(root, "bin/qa-lain"), "review", "feature/x", chdir: dir, env:)

        expect([status.success?, out, err]).to match([true, %r{feature/x.*a\.rb}m, ""])
      end
    end

    it "lists review and survey under qa-lain and neither under lain" do
      qa, = run_exe(File.join(root, "bin/qa-lain"), "help")
      lain, = run_exe(File.join(root, "exe/lain"), "help")

      expect(qa).to match(/qa-lain review.*qa-lain survey/m)
      expect(lain).not_to match(/lain (review|survey)/)
    end

    it "boots both through Lain::Boot::Launch, which itself writes nothing to stderr" do
      sources = %w[exe/lain bin/qa-lain].map { File.read(File.join(root, _1)) }
      launch = File.read(File.join(root, "lib/lain/boot/launch.rb"))

      expect(sources).to all(include("Lain::Boot::Launch.call"))
      expect(launch).not_to match(/\b(?:abort|warn)\b|\$stderr|STDERR/)
    end
  end

  describe "the QA sandbox shims", :seam do
    it "writes a lain and a qa-lain shim, each under ruby 4.0.9" do
      Dir.mktmpdir("qa-shim") do |home|
        script = File.join(root, ".claude/skills/manual-qa/scripts/qa-sandbox.sh")
        _, err, status = Open3.capture3({ "HOME" => home }, "bash", script, "shimtag", root)
        shims = %w[lain qa-lain].map { File.read(File.join(home, "tmp/lain-qa-shimtag/shim", _1)) }

        expect(status.success?).to be(true), err
        expect(shims.map { _1[/ruby@[\d.]+/] }).to eq(["ruby@4.0.9"] * 2)
        expect(shims.map { _1[%r{exec "[^"]+/(exe/lain|bin/qa-lain)"}, 1] }).to eq(%w[exe/lain bin/qa-lain])
      end
    end
  end
end
