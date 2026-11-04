# frozen_string_literal: true

# What a command the verdict leaves to a shell means, read only where a shell
# could not read it another way. Everything it refuses here would otherwise
# reach an approving rule as a term that is not what `sh -c` runs.
RSpec.describe Lain::Shell::Reading do
  def term(*pipelines)
    Lain::Shell::Term.new(pipelines: pipelines.map do |stages|
      Lain::Shell::Term::Pipeline.new(stages: stages.map { |argv| Lain::Shell::Term::Stage.new(argv:, discards: []) })
    end)
  end

  describe ".of" do
    it "reads the trial's grep after a cd, with the cd folded into the cwd" do
      expect(described_class.of('cd .lain-views && grep -c "Given" a.md b.md', nil))
        .to eq([term([%w[grep -c Given a.md b.md]]), "./.lain-views"])
    end

    it "folds each cd onto the call's own cwd, an absolute one replacing it" do
      expect(described_class.of("cd a && cd b && cat x", "sub").last).to eq("sub/a/b")
      expect(described_class.of("cd a && cd /abs && cat x", "sub").last).to eq("/abs")
    end

    it "splits stages into pipelines at &&, and keeps a pipe inside one" do
      expect(described_class.of("cat a | head -2 && wc -l b", nil))
        .to eq([term([%w[cat a], %w[head -2]], [%w[wc -l b]]), nil])
    end

    it "keeps a backslash inside double quotes before anything a shell would not unescape" do
      expect(described_class.of('grep -n "leak\\|ggml" a.md', nil).first)
        .to eq(term([["grep", "-n", "leak\\|ggml", "a.md"]]))
    end

    it "reads single quotes as written and a word joined from quoted and bare spans" do
      expect(described_class.of("git log --format='%h %s' -3", nil).first)
        .to eq(term([["git", "log", "--format=%h %s", "-3"]]))
    end

    it "refuses a cd bound by anything but &&, a cd after the first stage, and a cd it cannot place" do
      commands = ["cd x; cat a", "cd x || cat a", "cd x | cat a", "cat a && cd x", "cat a && cd x && cat b",
                  "cd -P x && cat a", "cd x y && cat a", "cd - && cat a", "cd x", "cd '' && cat a"]

      expect(commands.map { described_class.of(_1, nil) }).to eq([nil] * commands.size)
    end

    # The separator check is what keeps `||` out: the stage count alone would
    # pass, and the term would run both stages as a pipe.
    it "refuses stages joined by ||, ; or &, though the stage count matches" do
      commands = ["sed -n 1p a.md || cat a.md", "git log --oneline -1 || cat a.md", "cat a; cat b", "cat a & cat b"]

      expect(commands.map { described_class.of(_1, nil) }).to eq([nil] * commands.size)
    end

    it "refuses every word a shell would expand or unescape, a redirect, and a newline" do
      commands = ['grep "$HOME" a', "grep x *.md", "cat a > out", "cat a 2>/dev/null", "grep {a,b}.md x",
                  "cat ~/a", "cat a=~/b", "cat a:~/b", "cat 'a'\ncat b", "grep x\\ y a", "grep '' a",
                  "grep `id` a", "cat $(id)", 'grep "a\\$HOME" x', 'grep "a\\"b" x', "grep 'a' # c",
                  "cat !x", "cat <<< a", "(cat a)"]

      expect(commands.map { described_class.of(_1, nil) }).to eq([nil] * commands.size)
    end

    it "refuses what is not a command String at all" do
      expect([nil, 42, ""].map { described_class.of(_1, nil) }).to eq([nil, nil, nil])
    end
  end
end
