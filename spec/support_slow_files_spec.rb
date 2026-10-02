# frozen_string_literal: true

# Outside spec/support/ for the reason spec/support_matchers_spec.rb gives: a `_spec.rb`
# under the support glob would load twice.

require "open3"
require "rbconfig"

RSpec.describe SlowFiles do
  let(:root) { File.expand_path("..", __dir__) }
  let(:slow_dir) { "spec/lain/cli/command" }
  let(:slow_file) { "spec/lain/cli/command/review_spec.rb" }

  def dry_run(*args, slow: nil)
    env = { "LAIN_SLOW" => slow }
    out, status = Open3.capture2e(env, "bundle", "exec", "rspec", "--dry-run", "--format", "progress", *args,
                                  chdir: root)
    raise "dry run failed:\n#{out}" unless status.success?

    out
  end

  def example_count(out) = out[/^(\d+) examples,/, 1].to_i

  describe "the list" do
    it "names only files that exist" do
      expect(described_class.missing(root:)).to eq([])
    end

    it "is frozen and holds only spec paths" do
      expect(described_class::PATHS).to be_frozen.and(all(match(%r{\Aspec/.+_spec\.rb\z})))
    end
  end

  describe ".verify!" do
    it "fails naming a listed path that no longer exists" do
      expect { described_class.verify!(root:, paths: ["spec/gone_spec.rb"]) }
        .to raise_error(RuntimeError, %r{spec/gone_spec\.rb})
    end

    it "passes when every listed path exists" do
      expect { described_class.verify!(root:, paths: [slow_file]) }.not_to raise_error
    end
  end

  describe ".named" do
    it "resolves path arguments and ignores flags" do
      expect(described_class.named(["--dry-run", slow_file, slow_dir], root:)).to eq([File.join(root, slow_file)])
    end
  end

  describe "a bare local run", :seam do
    it "excludes the listed files and says how many were skipped and how to run them" do
      out, = Open3.capture2e({ "LAIN_SLOW" => nil }, "bundle", "exec", "rspec", slow_dir, "-e", "no such example",
                             chdir: root)

      expect(out).to match(/Skipping \d+ :slow files.*LAIN_SLOW=1/)
    end

    it "runs fewer examples than a run with LAIN_SLOW=1" do
      expect(example_count(dry_run(slow_dir))).to be < example_count(dry_run(slow_dir, slow: "1"))
    end

    it "runs a listed file named on the command line" do
      count = example_count(dry_run(slow_file))

      expect(count).to be_positive.and(eq(example_count(dry_run(slow_file, slow: "1"))))
    end

    it "keeps a listed file's examples when it is named by example id" do
      expect(example_count(dry_run("#{slow_file}[1:1]"))).to be_positive
    end

    it "selects the slow files under LAIN_SLOW=1 and --tag slow" do
      expect(example_count(dry_run("--tag", "slow", slow_dir, slow: "1"))).to be_positive
    end
  end

  describe "the pspec task", :seam do
    it "hands LAIN_SLOW=1 to its workers" do
      Dir.mktmpdir do |bin|
        fake = File.join(bin, "bundle")
        File.write(fake, "#!/bin/sh\necho \"workers saw LAIN_SLOW=$LAIN_SLOW\"\n")
        File.chmod(0o755, fake)
        env = { "LAIN_SLOW" => nil, "PATH" => "#{bin}:#{ENV.fetch("PATH")}" }
        out, = Open3.capture2e(env, RbConfig.ruby, "-S", "rake", "pspec", chdir: root)

        expect(out).to include("workers saw LAIN_SLOW=1")
      end
    end
  end
end
