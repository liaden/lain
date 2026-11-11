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
    it "refuses stages joined by || or &, though the stage count matches" do
      commands = ["sed -n 1p a.md || cat a.md", "git log --oneline -1 || cat a.md", "cat a & cat b"]

      expect(commands.map { described_class.of(_1, nil) }).to eq([nil] * commands.size)
    end

    it "refuses every word a shell would expand or unescape, a redirect, and a newline" do
      commands = ['grep "$HOME" a', "grep x *.md", "cat a > out", "grep {a,b}.md x",
                  "cat ~/a", "cat a=~/b", "cat a:~/b", "cat 'a'\ncat b", "grep x\\ y a", "grep '' a",
                  "grep `id` a", "cat $(id)", 'grep "a\\$HOME" x', 'grep "a\\"b" x', "grep 'a' # c",
                  "cat !x", "cat <<< a", "(cat a)"]

      expect(commands.map { described_class.of(_1, nil) }).to eq([nil] * commands.size)
    end

    it "reads a merged stderr and a /dev/null discard after a stage as that stage alone" do
      expect(described_class.of("cargo clippy --workspace 2>&1 | tail -2", nil).first)
        .to eq(term([%w[cargo clippy --workspace], %w[tail -2]]))
      redirects = ["2>/dev/null", ">/dev/null", ">/dev/null 2>&1"]

      expect(redirects.map { described_class.of("cargo build #{_1} && ls", nil).first })
        .to eq([term([%w[cargo build]], [%w[ls]])] * redirects.size)
    end

    # `&>` is bash's: a dash `sh` backgrounds the stage and truncates the file.
    it "refuses a redirect to a file, &>, any other spelling, and one not spaced after its stage" do
      commands = ["ls > out.txt", "ls 2>&1 > out.txt", "ls &>/dev/null", "ls >> /dev/null", "ls 1>/dev/null",
                  "ls 2>&2", "ls >&2", "ls 2>&1- | cat", "ls >/dev/null a", ">/dev/null ls", "ls 2>&1>/dev/null",
                  "cat < a", "ls 2>'/dev/null'"]

      expect(commands.map { described_class.of(_1, nil) }).to eq([nil] * commands.size)
    end

    it "reads ';' as a boundary between pipelines, as && is" do
      expect(described_class.of("git status --short; ls -a", nil))
        .to eq([term([%w[git status --short]], [%w[ls -a]]), nil])
    end

    it "refuses ';' anywhere after a cd, and a trailing ';'" do
      commands = ["cd nonexist && true ; cat secret.txt", "cd x && cat a; cat b", "cat a;", "cat a; cat b;"]

      expect(commands.map { described_class.of(_1, nil) }).to eq([nil] * commands.size)
    end

    it "refuses what is not a command String at all" do
      expect([nil, 42, ""].map { described_class.of(_1, nil) }).to eq([nil, nil, nil])
    end
  end

  describe ".from" do
    it "reads a parse a caller already holds as .of reads the command" do
      command = "cd a && cat x | head -2"

      expect(described_class.from(Lain::Shell::Parse.new.call(command), "sub"))
        .to eq(described_class.of(command, "sub"))
    end
  end

  # Stub programs log their argv, so a real shell's own run says what the
  # reading claims runs. Pipeline stages run concurrently, hence the sort, and
  # each stub writes its line in 1 append, which no other stage's can split.
  describe "against a real shell", :seam do
    shells = %w[/bin/sh /bin/bash /bin/dash /usr/bin/dash].select { File.executable?(_1) }.uniq { File.realpath(_1) }

    def stub(status) = <<~SH
      #!/bin/sh
      line="${0##*/}"; for word; do line="$line$(printf '\\037')$word"; done; printf '%s\\n' "$line" >> "$LOG"
      exit #{status}
    SH

    def ran(shell, command, programs, failing: [])
      Dir.mktmpdir("reading_spec") do |dir|
        programs.each do |name|
          File.write(File.join(dir, name), stub(failing.include?(name) ? 1 : 0))
          File.chmod(0o755, File.join(dir, name))
        end
        log = File.join(dir, "log")
        Open3.capture2e({ "PATH" => dir, "LOG" => log }, shell, "-c", command, chdir: dir)
        File.readlines(log, chomp: true).map { _1.split("\x1f") }.sort
      end
    end

    def read_argvs(command) = described_class.of(command, nil).first.stages.map(&:argv).sort

    shells.each do |shell|
      it "runs what the reading reads for 2>&1, 2>/dev/null and >/dev/null under #{shell}" do
        commands = ["cargo clippy --workspace 2>&1 | tail -2", "cargo build 2>/dev/null && tail -2",
                    "cargo build >/dev/null && tail -2", "cargo build >/dev/null 2>&1 && tail -2"]

        expect(commands.map { ran(shell, _1, %w[cargo tail]) }).to eq(commands.map { read_argvs(_1) })
      end

      it "runs every pipeline after ';' whatever the one before returned under #{shell}" do
        command = "git status --short; ls -a"

        expect(ran(shell, command, %w[git ls], failing: %w[git])).to eq(read_argvs(command))
      end
    end
  end
end
