# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Shell::Named do
  def named(command, cwd: "/p", home: "/home/u") = described_class.of(command, cwd:, home:)

  def resolved(command, **) = named(command, **).paths.map(&:resolved)

  describe "a sequence joined by &&" do
    it "names each stage's paths against the directory it runs in" do
      result = named("cd x && cat .env")
      expect(result.paths.map(&:resolved)).to eq(%w[/p/x /p/x/.env])
      expect(result).not_to be_opaque
    end

    it "keeps the cd's directory across a later && or pipe" do
      expect(resolved("cd x && cat a | wc b && cat c")).to eq(%w[/p/x /p/x/a /p/x/b /p/x/c])
    end

    it "counts a stage's redirect as part of the stage, not of the join" do
      expect(resolved("cd x && cat a > o && cat b")).to eq(%w[/p/x /p/x/a /p/x/o /p/x/b])
    end
  end

  describe "the cd rule" do
    it "makes the rest opaque when a cd is joined by anything but &&" do
      ["cd x || cat .env", "cd x; cat .env", "cd x | cat .env", "cd x & cat .env", "(cd x); cat .env"].each do |command|
        expect(named(command)).to be_opaque, command
      end
    end

    it "makes the rest opaque when a cd names no literal directory" do
      ["cd && cat .env", "cd - && cat .env", "pushd x && cat .env", "popd && cat .env"].each do |command|
        expect(named(command)).to be_opaque, command
      end
    end

    it "makes the rest opaque when a cd's directory is an expansion" do
      expect(named("cd $D && cat .env")).to be_opaque
    end

    it "makes the rest opaque when a join after a bound cd is not && or a pipe" do
      result = named("cd x && cat a; cat b")
      expect(result).to be_opaque
      expect(result.paths.map(&:resolved)).not_to include("/p/b", "/p/x/b")
    end

    it "reads a quoted cd as the cd bash runs" do
      expect(resolved("'cd' x && cat .env")).to eq(%w[/p/x /p/x/.env])
    end

    it "makes the rest opaque across a newline, which the grammar reports as no separator" do
      expect(named("cd x\ncat .env")).to be_opaque
    end

    it "binds across a newline or a comment after the &&, where bash continues the list" do
      expect(resolved("cd x &&\ncat .env")).to eq(%w[/p/x /p/x/.env])
      expect(resolved("cd x && # c\ncat .env")).to eq(%w[/p/x /p/x/.env])
    end

    it "binds only when the cd is first or joined to the stage before it by &&" do
      ["cat a || cd x && cat .env", "true | cd x && cat .env", "cd x && cat a | cd y && cat .env",
       "cat a; cd x && cat .env", "cat a & cd x && cat .env"].each do |command|
        result = named(command)
        expect(result).to be_opaque, command
        expect(result.paths.map(&:resolved)).not_to include("/p/x/.env", "/p/x/y/.env"), command
      end
    end

    it "binds after a stage joined to it by &&" do
      result = named("true && cd x && cat .env")
      expect(result.paths.map(&:resolved)).to include("/p/x/.env")
      expect(result).not_to be_opaque
    end

    it "makes the rest opaque when a cd's directory globs" do
      expect(named("cd x* && cat .env")).to be_opaque
    end

    it "marks the cd's directory, and only it, as a directory the stages after it run in" do
      result = named("cd x && cat a")
      expect(result.paths.to_h { [_1.resolved, _1.directory] }).to eq("/p/x" => true, "/p/x/a" => false)
    end
  end

  describe "a program that runs other programs" do
    def runners
      programs = Lain::Shell::Programs
      programs::TAKES_A_COMMAND - %w[find] + programs::WRAPPERS + programs::PRIVILEGE
    end

    it "makes its stage opaque, from the list the verdict reads" do
      runners.each { |program| expect(named("#{program} cat .env")).to be_opaque, program }
    end

    it "is matched by its last segment when written as a path" do
      expect(named("/usr/bin/env cat /etc/shadow")).to be_opaque
    end

    it "is any program reached through a process's own entry or descriptor, wherever the word starts" do
      commands = ["/proc/self/exe -c '$X'", "/proc/1/exe cat a", "/dev/fd/3 3<x.py", "./fd/3 a",
                  "~/../../proc/self/exe -c id"]

      expect(commands.map { named(_1, cwd: "/dev").opaque? }).to all(be(true))
      expect(named("/usr/bin/cat a")).not_to be_opaque
    end

    it "makes a shell given -c, or reading its commands from stdin, opaque" do
      ["sh -c 'cat x'", "bash -lc x", "zsh -c x", "echo x | bash"].each do |command|
        expect(named(command)).to be_opaque, command
      end
    end

    it "makes an interpreter running inline code or a module opaque" do
      ["ruby -e x", "python3 -c x", "perl -pe x f", "node -e x", "node --eval x", "python -m http.server",
       "echo 1 | ruby"].each do |command|
        expect(named(command)).to be_opaque, command
      end
    end

    it "names a script a shell or an interpreter runs from a file" do
      ["bash script.sh", "ruby script.rb"].each do |command|
        expect(named(command)).not_to be_opaque, command
      end
      expect(resolved("ruby script.rb")).to eq(%w[/p/script.rb])
    end

    it "makes find opaque only with an action that runs or deletes" do
      expect(named("find . -name x")).not_to be_opaque
      %w[-exec -execdir -ok -okdir -delete].each do |action|
        expect(named("find . #{action} rm x ';'")).to be_opaque, action
      end
    end

    it "marks a find's search root as reaching everything under it" do
      root = named("find src -name x").paths.find { _1.resolved == "/p/src" }
      expect(root.pattern).to eq("/p/src/**")
    end

    it "makes a shell or interpreter reading code from stdin opaque" do
      ["bash -s", "bash -s x", "sh -", "ruby -", "python3 -", "bash /dev/stdin", "ruby /dev/fd/0",
       "python /proc/self/fd/0"].each do |command|
        expect(named(command)).to be_opaque, command
      end
    end

    it "makes awk opaque on inline code from -e, --source or -E" do
      ["awk -f p -e x f", "awk --source=x -f p f", "gawk -E p f", "awk -f - f", "awk -f /dev/stdin f"].each do |command|
        expect(named(command)).to be_opaque, command
      end
    end

    it "reads a versioned or aliased interpreter as the interpreter" do
      ["python3.14 -c x", "ruby3.3 -e x", "nodejs -e x", "luajit -e x", "pypy3 -c x"].each do |command|
        expect(named(command)).to be_opaque, command
      end
      expect(named("python3.14 x.py")).not_to be_opaque
    end

    it "reads an interpreter's value-taking options, so a value is not taken for inline code" do
      ["ruby -Ilib -Ispec x.rb", "perl -Ilib x.pl", "python -W ignore x.py"].each do |command|
        expect(named(command)).not_to be_opaque, command
      end
      expect(resolved("ruby -Ilib -Ispec x.rb")).to include("/p/x.rb")
      expect(named("perl -Iexe x.pl")).not_to be_opaque
      expect(named("python -W ignore")).to be_opaque
    end

    it "does not take a version or help request for code on stdin" do
      ["ruby --version", "ruby -v", "python3 --help", "bash --version"].each do |command|
        expect(named(command)).not_to be_opaque, command
      end
    end

    it "reads ruby's -W as a flag, so the script after it is the script" do
      expect(resolved("ruby -W x.rb")).to eq(%w[/p/x.rb])
      expect(named("ruby -W x.rb")).not_to be_opaque
    end

    it "makes ruby's -C and -x directory options opaque" do
      expect(named("ruby -Cdir x.rb")).to be_opaque
      expect(named("ruby -xdir x.rb")).to be_opaque
    end

    it "makes every program with a shell escape opaque" do
      Lain::Shell::Programs::SHELL_ESCAPES.each { |program| expect(named("#{program} f")).to be_opaque, program }
    end

    it "makes git, tar, rsync and sort opaque on an option that names a program" do
      ["git -c core.pager=x log", "git --config-env=a=b log", "git --exec-path=/x log",
       "tar --to-command=sh -xf a.tar", "tar -I zstd -cf a.tar x", "tar --use-compress-program=x -cf a x",
       "tar --checkpoint-action=exec=x -cf a x", "tar -F x -cf a x", "tar --info-script=x -cf a x",
       "rsync -e ssh a b", "rsync --rsh=ssh a b", "rsync --rsync-path=x a b",
       "sort --compress-program=x f"].each do |command|
        expect(named(command)).to be_opaque, command
      end
      ["git log", "rsync -av a b", "tar -xf a.tar"].each { expect(named(_1)).not_to be_opaque, _1 }
    end
  end

  describe "an extraction that may write outside the directory" do
    it "is opaque for tar or bsdtar keeping absolute names, cpio extracting, git apply --unsafe-paths and unzip -:" do
      ["tar -xPf e.tar", "tar --absolute-names -xf e.tar", "tar xPf e.tar", "bsdtar -xPf e.tar", "cpio -idm",
       "cpio --extract", "git apply --unsafe-paths x.diff", "unzip -: e.zip"].each do |command|
        expect(named(command)).to be_opaque, command
      end
    end

    it "is named when the extraction keeps names relative" do
      ["tar -xf e.tar", "cpio -idm --no-absolute-filenames", "cpio -o", "git apply x.diff",
       "unzip e.zip"].each { expect(named(_1)).not_to be_opaque, _1 }
    end
  end

  describe "git" do
    def patterns(command) = named(command).paths.filter_map(&:pattern)

    it "names the path of a <rev>:<path> operand anywhere in the tree" do
      expect(patterns("git show HEAD:.env")).to include("/p/**/.env")
      expect(patterns("git show :.env")).to include("/p/**/.env")
      expect(patterns("git cat-file -p HEAD:.env")).to include("/p/**/.env")
    end

    it "is opaque on a <rev>:<path> that leaves the tree" do
      ["git show HEAD:../x", "git show HEAD:/etc/x"].each { expect(named(_1)).to be_opaque, _1 }
    end

    it "reads the whole tree for diff, log, show, grep, stash, blame and add -A" do
      ["git diff", "git log -p", "git show HEAD", "git grep KEY", "git stash show -p", "git blame f",
       "git add -A", "git add --all", "git add ."].each do |command|
        expect(patterns(command)).to include("/p/**"), command
      end
      expect(patterns("git status")).to be_empty
    end

    it "marks a git read of the whole tree as git's and read only, and a recursive grep's as neither" do
      reads = ["git log", "git diff HEAD~1 -- crates/store", "git branch -a", "grep -rn x ."]
      whole_tree = ->(command) { named(command).paths.select { _1.pattern == "/p/**" }.map { [_1.git, _1.written] } }

      expect(reads.to_h { [_1, whole_tree.call(_1)] }).to eq(reads.to_h { [_1, [[!_1.start_with?("grep"), false]]] })
    end

    it "reads the whole tree for log only when it prints file contents or commit bodies" do
      ["git log -p", "git log --patch", "git log -u", "git log -Skey", "git log -Gkey", "git log --follow -p f",
       "git log --format=%B", "git log --pretty=format:%h%b", "git log --format=%+b", "git log --format=%-B",
       "git log '--format=% b'", "git log --oneline -p"]
        .each { expect(patterns(_1)).to include("/p/**"), _1 }
      ["git log --oneline -5", "git log --format=%s", "git log --pretty=oneline", "git log --pretty=short",
       "git log --oneline --stat", "git log --format=%B --oneline", "git log --format=%x25b"]
        .each { expect(patterns(_1)).not_to include("/p/**"), _1 }
    end

    it "reads the whole tree for every subcommand but the few that print no file contents" do
      ["git stash show", "git stash list", "git archive HEAD", "git format-patch -1 --stdout", "git reflog -p",
       "git whatchanged", "git range-diff A...B", "git cat-file -p HEAD", "git notes show", "git annotate f", "git"]
        .each { expect(patterns(_1)).to include("/p/**"), _1 }
      ["git status", "git ls-files", "git ls-tree -r HEAD", "git rev-parse HEAD", "git shortlog"]
        .each { expect(patterns(_1)).to be_empty, _1 }
    end

    it "reads the whole tree for a log whose format prints commit bodies, the default included" do
      ["git log", "git log -5", "git log --stat", "git log --name-only", "git log --pretty", "git log --pretty=fuller",
       "git log --format=email", "git log --oneline --format=%B"]
        .each { expect(patterns(_1)).to include("/p/**"), _1 }
    end

    it "scopes -c to before the subcommand" do
      expect(named("git log -c")).not_to be_opaque
      expect(named("git -ccore.pager=less log")).to be_opaque
    end

    describe "a checkout-local write" do
      def dotgit(command) = named(command).paths.select { _1.resolved == "/p/.git" }.map(&:written)

      def whole_tree(command) = named(command).paths.select { _1.pattern == "/p/**" }.map { [_1.written, _1.git] }

      def written_besides_dotgit(command) = named(command).written.map(&:resolved) - ["/p/.git"]

      it "names its paths and the .git directory as written, never the whole tree" do
        {
          "git add lib/x.rb spec/x_spec.rb" => %w[/p/lib/x.rb /p/spec/x_spec.rb], "git commit -m msg" => [],
          "git commit -m msg lib/x.rb" => %w[/p/lib/x.rb], "git restore f" => %w[/p/f],
          "git reset HEAD -- f" => %w[/p/f], "git rm f" => %w[/p/f], "git mv a b" => %w[/p/a /p/b],
          "git checkout -- f" => %w[/p/f], "git commit --amend --no-edit" => [], "git commit -F msg.txt" => [],
          "git commit --reuse-message=HEAD" => []
        }.each do |command, pathspecs|
          expect([dotgit(command), whole_tree(command), pathspecs - resolved(command)]).to eq([[true], [], []]), command
        end
      end

      it "writes the paths rm, restore, mv and checkout name, and only reads those add, commit and reset name" do
        expected = { "git rm f" => %w[/p/f], "git restore f" => %w[/p/f], "git mv a b" => %w[/p/a /p/b],
                     "git checkout -- f" => %w[/p/f], "git add f" => [], "git commit -m x f" => [],
                     "git reset HEAD -- f" => [] }

        expect(expected.to_h { |command, _| [command, written_besides_dotgit(command)] }).to eq(expected)
      end

      it "keeps a commit's message and message file out of its pathspecs" do
        ["git commit -m lib", "git commit --message lib", "git commit -F lib", "git commit -t lib",
         "git commit --file lib"].each { expect(patterns(_1)).not_to include("/p/lib/**"), _1 }
      end

      it "names a commit's message file however its value is attached" do
        ["git commit -F.env", "git commit -aF.env", "git commit -F .env", "git commit --file=.env",
         "git commit -t.env -m x", "git commit --template=.env -m x"].each do |command|
          expect(resolved(command)).to include("/p/.env"), command
        end
      end

      it "reads the whole tree, as git, for every file it may take: a root, glob or magic pathspec, or -A" do
        reads = ["git add .", "git add ./", "git add -f '*'", "git add '*.pem'", "git add 'lib/?.rb'",
                 "git add '[a-z]*'", "git add :/", "git add ':(top)'", "git add ':!x'", "git add ':(glob)**'",
                 "git add -A", "git add --all", "git add -u", "git commit -a -m x", "git commit -am x",
                 "git commit --al -m x", "git reset -- '*'", "git commit -m x -o '*'", "git commit -m x -o ':/'"]

        expect(reads.to_h { [_1, whole_tree(_1)] }).to eq(reads.to_h { [_1, [[false, true]]] })
        expect(patterns("git add lib")).to include("/p/lib/**")
        expect(patterns("git commit -qm x -o lib")).to include("/p/lib/**")
      end

      it "writes the whole tree, as git, for a hard reset, a detach, or a root, glob or magic pathspec it writes" do
        writes = ["git reset --hard", "git reset --hard HEAD~1", "git switch --detach v1", "git switch -d v1",
                  "git checkout --detach v1", "git restore '*'", "git restore .", "git checkout -- '*'",
                  "git checkout -- .", "git rm -r ':/'", "git rm '*.rb'", "git mv ':(top)a' b", "git restore -m '*'",
                  "git restore -m ':/'"]

        expect(writes.to_h { [_1, whole_tree(_1)] }).to eq(writes.to_h { [_1, [[true, true]]] })
      end

      it "keeps in the class the forms each subcommand reads as it says" do
        ["git add lib/x.rb", "git commit -m msg", "git commit --amend -m x", "git commit --squash=HEAD -m x",
         "git reset main~0", "git reset --soft HEAD~1", "git rm --cached f", "git commit -m x -i lib",
         "git restore -s base lib", "git checkout -m -- lib/x.rb", "git add lib", "git commit -qm x -o lib"]
          .each { expect(dotgit(_1)).to eq([true]), _1 }
      end

      it "leaves out a short option cluster holding a letter its subcommand does not know" do
        ["git commit -Xm x", "git add -o f", "git restore -t '*'", "git rm -m '*'", "git reset -m '*'",
         "git mv -r a b"].each { expect(dotgit(_1)).to be_empty, _1 }
      end

      it "leaves out a write that opens an editor or prompts, which a headless run would wait on forever" do
        ["git commit", "git commit -a", "git commit --amend", "git commit -e -m x", "git commit --edit -m x",
         "git commit -c HEAD", "git commit -p -m x", "git commit --interactive -m x", "git add -e", "git add --edit",
         "git add -p", "git add --patch", "git add -i", "git restore -p", "git reset -p", "git checkout -p -- f"]
          .each { expect(dotgit(_1)).to be_empty, _1 }
      end

      it "leaves out a write to the shared store, a skipped hook and a pathspec read from a file" do
        ["git stash clear", "git tag -d v1", "git branch -D feature", "git switch -c topic", "git switch topic",
         "git checkout topic", "git push", "git commit --no-verify -m x", "git commit -n -m x",
         "git commit --no-verif -m x", "git add --pathspec-from-file=list", "git --git-dir=/x/.git add .",
         "git --namespace=n commit -m x", "git --no-pager commit -m x"].each do |command|
          expect([dotgit(command), patterns(command).include?("/p/**")]).to eq([[], true]), command
        end
      end

      it "leaves out a write naming a path outside the tree, as source or destination" do
        ["git mv lib/x.rb ../moved.rb", "git mv lib/x.rb /tmp/moved.rb", "git mv /tmp/x lib/x.rb", "git add ../other/f",
         "git rm lib/../../f", "git restore ~/f", "git checkout -- ../f", "git commit -m x -- /etc/f"]
          .each { expect(dotgit(_1)).to be_empty, _1 }
      end

      it "reads a `--` that is an option's value as that value, not as the end of its options" do
        expect(%w[-m --message -F].to_h { [_1, whole_tree("git commit #{_1} -- -a")] })
          .to eq(%w[-m --message -F].to_h { [_1, [[false, true]]] })
        expect(["git commit -m -- --no-verify", "git checkout --conflict -- -f lib/x.rb"].map { dotgit(_1) })
          .to eq([[], []])
        expect([dotgit("git commit -m x -- -a"), whole_tree("git commit -m x -- -a")]).to eq([[true], []])
        expect(resolved("git commit -m x -- -a")).to include("/p/-a")
      end

      it "stays opaque where git points elsewhere or runs code it was handed" do
        ["git --work-tree=/y commit", "GIT_DIR=/z git commit",
         "git -c core.fsmonitor=cmd status", "git -c alias.x=!sh x", "git --exec-path=/x commit -m x"]
          .each { expect(named(_1)).to be_opaque, _1 }
      end
    end

    it "names --git-dir as written on a subcommand that writes, and diff's --output" do
      expect(named("git --git-dir=/etc/.git commit -m x").written.map(&:resolved)).to include("/etc/.git")
      expect(named("git --git-dir=/etc/.git log").written).to be_empty
      expect(named("git diff --output=/etc/x").written.map(&:resolved)).to eq(%w[/etc/x])
    end
  end

  describe "an operand that names no file" do
    it "reads echo's words as text" do
      result = named('echo "exit=$?"')
      expect(result.paths).to be_empty
      expect(result).not_to be_opaque
    end

    it "still names where echo's output is written" do
      result = named("echo x > out")
      expect(result.paths.map(&:resolved)).to eq(%w[/p/out])
      expect(result.written.map(&:resolved)).to eq(%w[/p/out])
    end

    it "reads a searcher's first operand as its pattern" do
      expect(resolved("grep -E 'abc|def' notes.txt")).to eq(%w[/p/notes.txt])
      expect(resolved("rg secret src")).to eq(%w[/p/src])
    end

    it "names every operand once an option gave the pattern" do
      expect(resolved("grep -e abc notes.txt")).to include("/p/notes.txt")
      expect(resolved("grep -f patterns.txt x")).to eq(%w[/p/patterns.txt /p/x])
      expect(resolved("grep --file=patterns.txt x")).to eq(%w[/p/patterns.txt /p/x])
      expect(resolved("grep -if patterns.txt x")).to eq(%w[/p/patterns.txt /p/x])
      expect(resolved("rg -f patterns.txt x")).to eq(%w[/p/patterns.txt /p/x])
    end

    it "names every operand when an abbreviated long option gave the pattern" do
      %w[--regex=x --reg=x --rege=x].each do |option|
        expect(resolved("grep #{option} f")).to include("/p/f"), option
      end
      expect(resolved("egrep --reg=x f")).to include("/p/f")
    end

    it "searches under every operand when an abbreviated long option gave the pattern" do
      expect(named("grep -r --reg=x dir").paths.map(&:pattern)).to include("/p/dir/**")
    end

    it "names a file an rg option reads before the pattern" do
      expect(resolved("rg --ignore-file .secret pat .")).to include("/p/.secret", "/p")
    end

    it "reads rg's encoding and depth options as taking a value, so the pattern after them is not named" do
      expect(resolved("rg -E utf8 secret f")).to eq(%w[/p/utf8 /p/f])
      expect(resolved("rg -d 2 secret f")).to eq(%w[/p/2 /p/f])
    end

    it "searches under every ack operand when it lists files or an option gave the pattern" do
      expect(named("ack -f dir").paths.map(&:pattern)).to include("/p/dir/**")
      expect(named("ack --match x dir").paths.map(&:pattern)).to include("/p/dir/**")
    end

    it "names every operand of rg --files, which takes no pattern" do
      expect(resolved("rg --files .env")).to eq(%w[/p/.env])
    end

    it "reads a sed script and a jq filter as program text" do
      expect(resolved("sed -n '5,9p' a.c")).to eq(%w[/p/a.c])
      expect(resolved("jq '.x' b.json")).to eq(%w[/p/b.json])
      expect(resolved("sed -e 's/a/b/' a.c")).to include("/p/a.c")
    end

    it "names a sandboxed sed script read from a file" do
      expect(resolved("sed --sandbox -f script.sed a.c")).to eq(%w[/p/script.sed /p/a.c])
      expect(named("sed -f script.sed a.c")).to be_opaque
    end

    it "is opaque on a jq filter that loads a module, inline or from a file" do
      expect(named(%(jq -n 'import "./creds" as $c; $c'))).to be_opaque
      expect(named(%(jq 'include "x"; .' b.json))).to be_opaque
      expect(named(%(jq '"x" | modulemeta' b.json))).to be_opaque
      expect(named("jq --from-file f.jq b.json")).to be_opaque
      expect(named("jq -rf f.jq b.json")).to be_opaque
    end

    it "names every jq operand when an option's value could sit before the filter" do
      expect(resolved("jq -L lib '.x' b.json")).to include("/p/lib", "/p/b.json")
      expect(resolved("jq --slurpfile n s.json '.x' b.json")).to include("/p/s.json", "/p/b.json")
      expect(resolved("jq --rawfile n s.txt '.x' b.json")).to include("/p/s.txt", "/p/b.json")
    end

    it "reads an inline awk program as program text, and keeps a program file opaque" do
      expect(resolved("awk '{print}' b")).to eq(%w[/p/b])
      expect(named("awk -f prog.awk b")).to be_opaque
    end

    it "reads printf's format as text and names the words after it" do
      expect(resolved("printf '%s' a")).to eq(%w[/p/a])
    end

    it "names every word of a program it does not list" do
      expect(resolved("frobnicate alpha beta")).to eq(%w[/p/alpha /p/beta])
    end

    it "names the pattern of a program bundle exec may not run as named" do
      expect(resolved("bundle exec grep pat f")).to include("/p/pat", "/p/f")
    end

    it "stays opaque on a pattern it cannot read" do
      expect(named("grep $x f")).to be_opaque
    end
  end

  describe "sed" do
    it "is opaque when a script runs a command, reads a file in or writes one" do
      ["sed 's/a/b/e' f", "sed 's/a/b/w out' f", "sed -e 'w out' f", "sed '1r /etc/shadow' f", "sed 'R x' f",
       "sed 'W x' f", "sed e f", "sed 's/a/b/i;w out' f", "sed -n '/x/w out' f", "sed --expression=e f",
       "sed -f script f"].each do |command|
        expect(named(command)).to be_opaque, command
      end
    end

    it "reads a script whose letters sit inside an s command, a regex or a label" do
      ["sed 's/a/b/g' f", "sed -n '/^#/p' f", "sed -n '/error/p' f", "sed -i 's/re/we/' f", "sed 'b end; :end' f",
       "sed 's|/etc|/w|' f"].each do |command|
        expect(named(command)).not_to be_opaque, command
      end
    end

    it "reads a script given as an option's value, attached or after =" do
      ["sed -es/a/b/ f", "sed --expression=p f"].each { expect(named(_1)).not_to be_opaque, _1 }
    end

    it "trusts --sandbox, which refuses those commands" do
      expect(named("sed --sandbox -e 'w out' f")).not_to be_opaque
    end
  end

  describe "bundle" do
    it "names what bundle exec runs as a plain program, with none of its own readings" do
      result = named("bundle exec cat .env")
      expect(result.paths.map(&:resolved)).to eq(%w[/p/.env])
      expect(result).not_to be_opaque
      expect(named("bundle exec cat .env").written.map(&:resolved)).to eq(%w[/p/.env])
    end

    it "keeps every rule that makes what bundle exec runs opaque" do
      ["bundle exec sh -c 'cat /etc/shadow'", "bundle exec ruby -e x", "bundle exec env cat x",
       "bundle exec find . -delete", "bundle exec sed 'w out' f", "bundle exec git -c a=b log",
       "bundle exec vim f", "bundle exec grep -C 3 x f"].each do |command|
        expect(named(command)).to be_opaque, command
      end
    end

    it "marks every path under bundle exec as possibly written" do
      expect(named("bundle exec cp .env /etc/x").written.map(&:resolved)).to eq(%w[/p/.env /etc/x])
    end

    it "names bundle install's --path as written" do
      expect(named("bundle install --path /etc/v").written.map(&:resolved)).to include("/etc/v")
    end

    it "names a script runner under bundle exec" do
      result = named("bundle exec rspec spec/x_spec.rb")
      expect(result.paths.map(&:resolved)).to eq(%w[/p/spec/x_spec.rb])
      expect(result).not_to be_opaque
    end

    it "makes bundle exec opaque on an option of its own, and other subcommands opaque" do
      ["bundle exec --gemfile=/x rake", "bundle exec", "bundle update", "bundle config set x y"].each do |command|
        expect(named(command)).to be_opaque, command
      end
    end

    it "names bundle install's project as written" do
      result = named("bundle install --quiet")
      expect(result).not_to be_opaque
      expect(result.written.map(&:pattern)).to eq(["/p/**"])
    end
  end

  describe "a recursive reader" do
    def patterns(command) = named(command).paths.filter_map(&:pattern)

    it "marks its roots, or the directory it runs in when none is named" do
      expect(patterns("grep -r x src")).to eq(%w[/p/src/**])
      expect(patterns("grep -R x")).to eq(%w[/p/**])
      expect(patterns("grep -e x -r lib")).to eq(%w[/p/lib/**])
      expect(patterns("rg x")).to eq(%w[/p/**])
      expect(patterns("rg x lib")).to eq(%w[/p/lib/**])
      expect(patterns("ag x lib")).to eq(%w[/p/lib/**])
      expect(patterns("ack x lib")).to eq(%w[/p/lib/**])
      expect(patterns("find -name x")).to eq(%w[/p/**])
    end

    it "marks the sources of a recursive copy or archive" do
      expect(patterns("cp -r src dst")).to eq(%w[/p/src/**])
      expect(patterns("cp -a src dst")).to eq(%w[/p/src/**])
      expect(patterns("tar czf a.tgz src")).to eq(%w[/p/src/**])
      expect(patterns("zip -r a.zip src")).to eq(%w[/p/src/**])
    end

    it "marks the sources of a recursive rsync or scp" do
      ["rsync -r src dst", "rsync -a src dst", "rsync -av src dst", "rsync --recursive src dst",
       "rsync --archive src dst", "scp -r src host:dst"].each { expect(patterns(_1)).to eq(%w[/p/src/**]), _1 }
      expect(patterns("rsync src dst")).to be_empty
    end

    it "marks every operand of a recursive diff" do
      expect(patterns("diff -r a b")).to eq(%w[/p/a/** /p/b/**])
      expect(patterns("diff a b")).to be_empty
    end

    it "marks nothing for a grep that does not recurse" do
      expect(patterns("grep x f")).to be_empty
    end
  end

  describe "a -C option" do
    describe "of git, before its subcommand" do
      def directories(command) = named(command).paths.select(&:directory).map(&:resolved)

      it "names its directory instead of turning opaque" do
        ["git -C sibling log 2>&1", "git -Csibling log", "git -C sibling status"].each do |command|
          result = named(command)
          expect(result).not_to be_opaque, command
          expect(directories(command)).to eq(%w[/p/sibling]), command
        end
      end

      it "names its directory for merge-base, a read-only subcommand" do
        expect(directories("git --no-pager -C sibling merge-base main HEAD")).to eq(%w[/p/sibling])
      end

      it "names a directory outside the working one as the directory it runs in" do
        expect(directories("git -C /outside log")).to eq(%w[/outside])
        expect(directories("git -C ../other log")).to eq(%w[/other])
      end

      it "resolves the rest of the command against that directory" do
        expect(resolved("git -C sibling grep x -- .env")).to include("/p/sibling/.env")
        expect(resolved("git -C sibling grep x -- .env")).not_to include("/p/.env")
        expect(named("git -C sibling diff").paths.filter_map(&:pattern)).to eq(%w[/p/sibling/**])
        expect(named("git -C sibling show HEAD:.env").paths.filter_map(&:pattern)).to include("/p/sibling/**/.env")
      end

      it "reads a global option before it as a path, not as the subcommand" do
        result = named("git --git-dir=/etc -C a log")
        expect(result).not_to be_opaque
        expect(result.paths.map(&:resolved)).to include("/etc", "/p/a")
      end

      it "keeps a redirect in the directory the command was given" do
        expect(resolved("git -C sibling log > out")).to include("/p/out")
      end

      it "reads a writing subcommand in that directory, whatever the subcommand" do
        ["git -C sibling commit -m x", "git -C sibling checkout .", "git -C sibling add -A",
         "git -C sibling clone url", "git -C sibling remote -v", "git -C sibling branch"].each do |command|
          expect(named(command)).not_to be_opaque, command
          expect(directories(command)).to eq(%w[/p/sibling]), command
        end
        expect(named("git -C sibling commit -m x").written.map(&:resolved)).to eq(%w[/p/sibling/.git])
        expect(named("git -C sibling add -A").written.map(&:resolved)).to eq(%w[/p/sibling/.git])
      end

      it "stays opaque with no subcommand after it" do
        expect(named("git -C sibling")).to be_opaque
      end

      it "stays opaque when the directory is not one literal, or another option also moves" do
        ["git -C $D log", "git -C sibling -C other log", "git -C a --work-tree=/etc log",
         "git -C sibling -c core.pager=x log", "git -c core.pager=x -C sibling log",
         "git -C sibling log -C", "git log -C sibling"].each { expect(named(_1)).to be_opaque, _1 }
      end
    end

    it "makes an attached -C opaque too" do
      expect(named("make -C../other")).to be_opaque
    end

    it "makes a -C inside a cluster of short options opaque" do
      expect(named("tar -xzC out -f a.tar")).to be_opaque
    end

    it "stays opaque for a program it does not know, where -C may change directory" do
      expect(named("ninja -C build")).to be_opaque
    end

    it "is read as context lines, not a directory, for the programs where it means that" do
      ["grep -C 3 x f", "rg -C3 x f", "diff -C 3 a f", "ls -C f"].each do |command|
        result = named(command)
        expect(result).not_to be_opaque, command
        expect(result.paths.map(&:resolved)).to include("/p/f"), command
      end
    end
  end

  describe "a directory option" do
    it "reads an old-style tar cluster as short options" do
      expect(named("tar xzfC a.tar /tmp")).to be_opaque
      expect(named("tar xf a.tar")).not_to be_opaque
    end

    it "makes git --work-tree opaque" do
      ["git --work-tree=/etc checkout .", "git --work-tree /etc status"].each do |command|
        expect(named(command)).to be_opaque, command
      end
    end

    it "makes -d opaque for patch and unzip" do
      ["patch -p1 -d /etc", "patch -d/etc", "unzip a.zip -d /etc", "unzip -d/etc a.zip"].each do |command|
        expect(named(command)).to be_opaque, command
      end
    end
  end

  describe "a --directory or --chdir option" do
    it "makes its stage opaque, with its value attached or apart" do
      ["make --directory=../other", "tar -xf a.tar --directory out", "env --chdir=/tmp cat f"].each do |command|
        expect(named(command)).to be_opaque, command
      end
    end

    it "is ls's own flag, not a directory change, under ls" do
      expect(named("ls --directory f")).not_to be_opaque
    end
  end

  describe "a program that writes its file arguments" do
    def written(command) = named(command).written.map(&:resolved)

    it "names every file argument as written for tee, touch, mkdir, rm, rmdir, mv and truncate" do
      expect(written("echo hi | tee -a log out")).to eq(%w[/p/log /p/out])
      expect(written("touch a b")).to eq(%w[/p/a /p/b])
      expect(written("mkdir -p d")).to eq(%w[/p/d])
      expect(written("rm -rf d")).to eq(%w[/p/d])
      expect(written("rmdir d")).to eq(%w[/p/d])
      expect(written("mv a b")).to eq(%w[/p/a /p/b])
      expect(written("truncate -s 0 f")).to eq(%w[/p/0 /p/f])
    end

    it "names the program written as a path by its last segment" do
      expect(written("/bin/rm f")).to eq(%w[/p/f])
    end

    it "names only cp's destination as written" do
      result = named("cp /etc/hosts out")
      expect(result.written.map(&:resolved)).to eq(%w[/p/out])
      expect(result.paths.map(&:resolved)).to include("/etc/hosts")
    end

    it "names cp's target-directory as written, and its operands as read" do
      expect(written("cp -t d a")).to eq(%w[/p/d])
      expect(written("cp -rt d a")).to eq(%w[/p/d])
      expect(written("cp --target-directory=d a")).to eq(%w[/p/d])
      expect(written("cp -tdst a")).to eq(%w[/p/dst])
    end

    it "names ln's and install's destination or target directory as written" do
      expect(written("ln -s /etc/shadow link")).to eq(%w[/p/link])
      expect(written("install -m 755 a /usr/local/bin/a")).to eq(%w[/usr/local/bin/a])
      expect(written("ln -t /etc a")).to eq(%w[/etc])
      expect(written("install -t /etc a")).to eq(%w[/etc])
    end

    it "names mv's target directory as written" do
      expect(written("mv --target-directory=/etc a")).to include("/etc")
    end

    it "names every operand of chmod, chown and chgrp as written" do
      expect(written("chmod 777 /etc/shadow")).to include("/etc/shadow")
      expect(written("chown me /etc/shadow")).to include("/etc/shadow")
      expect(written("chgrp g /etc/shadow")).to include("/etc/shadow")
    end

    it "names dd's of= as written and its if= as read" do
      result = named("dd if=/etc/shadow of=out")
      expect(result.written.map(&:resolved)).to include("/p/out")
      expect(result.written.map(&:resolved)).not_to include("/etc/shadow")
      expect(result.paths.map(&:resolved)).to include("/etc/shadow")
    end

    it "names an output option's value as written, attached or apart" do
      expect(written("sort -o /etc/x a")).to eq(%w[/etc/x])
      expect(written("sort -o/o/out a")).to eq(%w[/o/out])
      expect(written("gcc -o/etc/x a.c")).to eq(%w[/etc/x])
      expect(written("curl -o /etc/x http://h")).to eq(%w[/etc/x])
      expect(written("curl --output=/etc/x http://h")).to eq(%w[/etc/x])
    end

    it "names every sed -i operand as written when the script came from an option" do
      expect(written("sed -e s/a/b/ -i f")).to eq(%w[/p/f])
      expect(written("sed -i --expression=s/a/b/ f g")).to eq(%w[/p/f /p/g])
      result = named("sed --sandbox -f script -i f")
      expect(result.written.map(&:resolved)).to eq(%w[/p/f])
      expect(result.paths.map(&:resolved)).to include("/p/script")
    end

    it "names sed -i's files as written, and not its script" do
      result = named("sed -i 's/a/b/' f g")
      expect(result.written.map(&:resolved)).to eq(%w[/p/f /p/g])
      expect(result.paths.map(&:resolved)).not_to include("/p/s/a/b")
    end

    it "names every sed -i operand as written when an abbreviated long option gave the script" do
      expect(written("sed -i --expr=s/a/b/ f")).to eq(%w[/p/f])
    end

    it "names nothing written for sed without -i" do
      expect(written("sed 's/a/b/' f")).to be_empty
    end

    it "names the destination of rsync, scp and git clone as written" do
      expect(written("rsync -av src /etc/")).to eq(%w[/etc])
      expect(written("scp a host:x")).to eq(%w[/p/host:x])
      expect(written("git clone url /etc/x")).to eq(%w[/etc/x])
    end

    it "names the directory it runs in as written for a git clone or init with no directory" do
      expect(named("git clone url").written.map(&:pattern)).to eq(%w[/p/**])
      expect(named("git init").written.map(&:pattern)).to eq(%w[/p/**])
      expect(written("git init d")).to eq(%w[/p/d])
    end

    it "names git worktree add's path, and git archive's and format-patch's output, as written" do
      expect(written("git worktree add ../wt")).to eq(%w[/wt])
      expect(written("git archive -o /tmp/a.tar HEAD")).to eq(%w[/tmp/a.tar])
      expect(written("git format-patch -o out HEAD")).to eq(%w[/p/out])
    end

    it "names tar's archive as written when it creates, appends or updates" do
      expect(written("tar -cf /tmp/a.tar src")).to eq(%w[/tmp/a.tar])
      expect(written("tar czf out.tgz src")).to eq(%w[/p/out.tgz])
      expect(written("tar -rf a.tar x")).to eq(%w[/p/a.tar])
      expect(written("tar cfT out.tar list")).to eq(%w[/p/out.tar])
      expect(written("tar -xf a.tar")).to be_empty
    end

    it "names tar's --one-top-level as written" do
      expect(written("tar -xf a.tar --one-top-level=/etc")).to eq(%w[/etc])
    end

    it "names wget's directory prefix, zip's archive and install -d's operands as written" do
      expect(written("wget -P /tmp u")).to eq(%w[/tmp])
      expect(written("wget --directory-prefix=/tmp u")).to eq(%w[/tmp])
      expect(written("zip -r out.zip src")).to eq(%w[/p/out.zip])
      expect(written("install -d a b")).to eq(%w[/p/a /p/b])
      expect(named("install --directory a b")).not_to be_opaque
      expect(written("install --directory a b")).to eq(%w[/p/a /p/b])
    end

    it "reads the cc family's -D, -I and -L as values, not as a cluster holding -C" do
      expect(named("gcc -DCONFIG a.c")).not_to be_opaque
      expect(named("gcc -I/usr/C -LC a.c")).not_to be_opaque
    end
  end

  describe "the program" do
    it "is named when written as a path, and not when bare" do
      expect(resolved("/tmp/evil/cat f")).to eq(%w[/tmp/evil/cat /p/f])
      expect(resolved("cat f")).to eq(%w[/p/f])
    end
  end

  describe "redirects" do
    it "names an output target as written" do
      path = named("echo hi > out.txt").paths.find { _1.resolved == "/p/out.txt" }
      expect(path.written).to be(true)
      expect(named("echo hi > out.txt").written.map(&:resolved)).to eq(%w[/p/out.txt])
    end

    it "names an input target as read" do
      path = named("cat < /etc/shadow").paths.find { _1.resolved == "/etc/shadow" }
      expect(path.written).to be(false)
    end

    it "does not name a descriptor duplication" do
      expect(resolved("cat hi 2>&1")).to eq(%w[/p/hi])
    end

    it "names a word the grammar folds into a redirect, which bash passes to the program" do
      expect(resolved("cat >/dev/null /etc/shadow")).to eq(%w[/etc/shadow])
      expect(named("tee >/dev/null out").written.map(&:resolved)).to eq(%w[/p/out])
    end

    it "does not name /dev/null" do
      result = named("make 2>/dev/null")
      expect(result.paths).to be_empty
      expect(result).not_to be_opaque
    end
  end

  describe "words" do
    it "unquotes a single-quoted word and names an option's value, not the option" do
      paths = resolved("head --file=/etc/shadow 'a b.txt'")
      expect(paths).to include("/etc/shadow", "/p/a b.txt")
      expect(paths.grep(/--file/)).to be_empty
    end

    it "keeps the word as the model wrote it" do
      expect(named("cat 'a b.txt'").paths.map(&:word)).to eq(["'a b.txt'"])
    end

    it "unquotes a double-quoted word that holds nothing a shell would interpret" do
      expect(resolved('cat "fix bug"')).to eq(["/p/fix bug"])
      expect(named('cat "fix bug"')).not_to be_opaque
    end

    it "unquotes a word made of quoted and bare pieces" do
      expect(resolved('cat a"b c"d')).to eq(["/p/ab cd"])
    end

    it "makes the command opaque when a double-quoted span holds $, a backtick or an escaping backslash" do
      ['cat "$HOME/.ssh/id_rsa"', 'cat "a`id`"', 'cat "a\\"b"', 'cat "a\\$b"', 'cat "a\\\\b"',
       'echo "$!"'].each do |command|
        expect(named(command)).to be_opaque, command
      end
    end

    it "reads a bang, and a backslash bash keeps, inside double quotes" do
      result = named('sed -i "s/a!/b\\./" notes.txt')

      expect(result).not_to be_opaque
      expect(result.written.map(&:resolved)).to eq(["/p/notes.txt"])
      expect(resolved('cat "a!b" "c\\.d"')).to eq(["/p/a!b", "/p/c\\.d"])
    end

    it "makes the command opaque on a backslash outside quotes" do
      expect(named("cat a\\ b")).to be_opaque
    end

    it "takes $ inside single quotes as written" do
      expect(resolved("cat '$x'")).to eq(["/p/$x"])
    end

    it "does not name the end-of-options marker or a lone dash" do
      expect(resolved("ls -- -")).to be_empty
    end

    it "names a word after the end-of-options marker even when it starts with a dash" do
      expect(resolved("cat -- -x")).to eq(%w[/p/-x])
      expect(named("rm -- -rf").written.map(&:resolved)).to eq(%w[/p/-rf])
    end

    it "names a short option's attached value" do
      expect(resolved("grep -f.env x")).to include("/p/.env")
    end

    it "names every place an attached value could start when the program's options are not known" do
      expect(resolved("pack -xzf/x")).to include("/x", "/p/f/x")
    end

    it "names none of find's expression words as paths" do
      result = named("find . -name foo")
      expect(result.paths.map(&:resolved)).to include("/p")
      expect(result.paths.map(&:resolved)).not_to include("/p/ame", "/p/me", "/p/e", "/p/-name")
    end

    it "names only the value of a dd operand" do
      result = named("dd if=/etc/shadow of=x")
      expect(result.paths.map(&:resolved)).to contain_exactly("/etc/shadow", "/p/x")
    end

    it "marks the places an unknown program's attached value could start as guesses" do
      guesses = named("tool -xzf/x").paths
      expect(guesses.map(&:resolved)).to include("/p/zf/x", "/p/f/x", "/x")
      expect(guesses).to all(have_attributes(guess: true))
    end

    it "does not mark a path the argv names outright as a guess" do
      expect(named("cat a.txt").paths).to all(have_attributes(guess: false))
    end

    it "keeps a guessed path in the lists every gate reads" do
      result = named("tool -xzf/x > out")
      expect(result.paths.map(&:resolved)).to include("/x", "/p/out")
      expect(result.written.map(&:resolved)).to eq(%w[/p/out])
    end

    it "makes a ~ after a colon in a name=value operand opaque, since bash may expand it" do
      expect(named("cat x=a:~/y")).to be_opaque
    end

    it "names a name=value operand's value, with a leading ~ under home" do
      expect(resolved("make PREFIX=/opt/x")).to include("/opt/x")
      expect(resolved("dd if=~/.env")).to include("/home/u/.env")
    end

    it "names an option's value starting with ~ both as written and under home" do
      result = named("cat --file=~/y")
      expect(result.paths.map(&:resolved)).to include("/p/~/y", "/home/u/y")
      expect(result).not_to be_opaque
    end

    it "makes an unquoted brace opaque" do
      ["cat {/etc/shadow,x}", "cat /etc/{shadow,passwd}"].each do |command|
        expect(named(command)).to be_opaque, command
      end
    end

    it "makes a .. after a named segment opaque, since a symlink decides where it lands" do
      ["cat lnk/../.env", "cd lnk && cat ../.env", "cd x/.. && cat a", "cat x*/../../other/.env"].each do |command|
        expect(named(command)).to be_opaque, command
      end
    end

    it "resolves a leading .. against the directory the call runs in" do
      expect(resolved("cat ../x")).to eq(%w[/x])
    end

    it "names a repeated word once" do
      expect(resolved("cat a a")).to eq(%w[/p/a])
    end

    it "names nothing for an empty word" do
      result = named("cat ''")
      expect(result.paths).to be_empty
      expect(result).not_to be_opaque
    end
  end

  describe "a tilde" do
    it "resolves under home" do
      expect(resolved("cat ~/.ssh/id_rsa")).to eq(%w[/home/u/.ssh/id_rsa])
    end

    it "makes the command opaque with no home" do
      expect(named("cat ~/.ssh/id_rsa", home: nil)).to be_opaque
    end

    it "treats a relative home as none" do
      expect(named("cat ~/.ssh/id_rsa", home: "u")).to be_opaque
    end

    it "makes the command opaque for another user's home" do
      expect(named("cat ~root/.ssh/id_rsa")).to be_opaque
    end

    it "is taken as written when quoted" do
      expect(resolved("cat '~/x'")).to eq(["/p/~/x"])
    end
  end

  describe "a glob" do
    it "names its fixed directory" do
      expect(resolved("ls ~/.cargo/registry/cache/*/")).to eq(%w[/home/u/.cargo/registry/cache])
    end

    it "carries the pattern, absolute, with a quoted glob character escaped" do
      expect(named("ls ~/.cargo/registry/cache/*/").paths.map(&:pattern)).to eq(["/home/u/.cargo/registry/cache/*/"])
      expect(named("cat '*'x*").paths.map(&:pattern)).to eq(["/p/\\*x*"])
    end

    it "carries no pattern for a word with no glob" do
      expect(named("cat a").paths.map(&:pattern)).to eq([nil])
    end

    it "names the directory it runs in when the first segment globs" do
      expect(resolved("cat *.key")).to eq(%w[/p])
    end
  end

  describe "the probes a session runs to look around" do
    it "reads each one, naming its paths" do
      probes = {
        'ls src; echo "exit=$?"' => "/p/src",
        "git -C /p/n remote -v" => "/p/n",
        "awk '/Blocked/ {print FILENAME}' issues/a.md" => "/p/issues/a.md",
        "for f in a.md b.md; do cat $f; done" => "/p/b.md"
      }

      expect(probes.keys.to_h { [_1, [named(_1).opaque?, resolved(_1).include?(probes[_1])]] })
        .to eq(probes.keys.to_h { [_1, [false, true]] })
      expect(named("env | grep XDG")).to have_attributes(opaque: false, paths: [])
    end

    it "reads $?, $$ and $# inside double quotes as digits, so the word names its fixed directory and a pattern" do
      result = named('cat "x$?" "$$" "logs/$#.txt"')
      expect(result).not_to be_opaque
      expect(result.paths.map { [_1.resolved, _1.pattern] })
        .to eq([%w[/p /p/x*], %w[/p /p/*], %w[/p/logs /p/logs/*.txt]])
    end

    it "matches adjacent fills, or a fill beside a bare *, as one wildcard, never a recursive **" do
      expect(['cat "$?$?"', 'cat "$?"*', 'cat *"$$"', 'cat "a$?$#b"'].map { named(_1).paths.sole.pattern })
        .to eq(%w[/p/* /p/* /p/* /p/a*b])
    end

    it "hands no argv for a word the shell finishes, since none is known before it runs" do
      expect(described_class.stages(Lain::Shell::Parse.new.call('echo "exit=$?"'), cwd: "/p", home: nil)).to be_nil
    end

    it "reads a git -C before the subcommand as git's own, naming a write at its directory" do
      result = named("git -C /outside commit -m x")
      expect(result).not_to be_opaque
      expect(result.written.map(&:resolved)).to eq(%w[/outside/.git])
    end

    it "reads a bare env as a reader naming nothing" do
      expect([named("env").opaque?, resolved("env")]).to eq([false, []])
    end

    it "reads only the word env as a bare env, not a program of that name elsewhere" do
      ["./env", "bin/env", "/usr/bin/env"].each { expect(named(_1)).to be_opaque, _1 }
    end

    it "reads an awk program that only reads, as filters and reports" do
      ["awk '{print}' f", "awk -F: '$3 > 100 {print $1}' f", "awk -v n=2 'NR == n || /x/' f",
       "gawk '{ printf \"%s\\n\", $1 }' f", "awk 'END {print NR}' f"].each do |command|
        expect(named(command)).not_to be_opaque, command
        expect(resolved(command)).to include("/p/f"), command
      end
    end

    it "unrolls a for loop over literal paths, reading its body once per word" do
      expect(resolved("for f in a.md b.md; do cat $f; done")).to eq(%w[/p/a.md /p/b.md])
      expect(resolved("for f in a b\ndo\n  wc -l \"$f\" ${f}.txt\ndone")).to eq(%w[/p/a /p/a.txt /p/b /p/b.txt])
      expect(named("for f in a b; do sed -n 1p $f > $f.out; done").written.map(&:resolved))
        .to eq(%w[/p/a.out /p/b.out])
      expect(resolved("for f in a; do cat '$f'; done")).to eq(%w[/p/$f])
    end
  end

  describe "a data option" do
    it "names no path for a curl body, method or header" do
      result = named(%(curl -X POST 127.0.0.1:11434/api/chat -d '{"model":"x"}'))
      expect(result.paths.map(&:resolved)).to eq(%w[/p/127.0.0.1:11434/api/chat])
      expect(result).not_to be_opaque
      expect(resolved("curl -sS -H 'Accept: x' -A agent -u me:pw -e ref --data-raw b u")).to eq(%w[/p/u])
      expect(resolved("curl --data-ascii x --request PUT --user-agent a --referer r u")).to eq(%w[/p/u])
    end

    it "names every file curl reads at an @ as a read path" do
      { "curl -d @a.json u" => "/p/a.json", "curl --data-binary @a u" => "/p/a", "curl --json @a u" => "/p/a",
        "curl -H @h u" => "/p/h", "curl -F x=@a u" => "/p/a", "curl --data-urlencode n@a u" => "/p/a",
        "curl -d@a u" => "/p/a", "curl --data=@a u" => "/p/a", "curl -sSd @a u" => "/p/a",
        "curl --data-urlencode @a u" => "/p/a", "curl -d @/etc/shadow u" => "/etc/shadow" }.each do |command, file|
        result = named(command)
        expect(result.paths.map(&:resolved)).to include(file), command
        expect(result.paths.map(&:resolved)).not_to include("/p/@a", "/p/x=@a", "/p/n@a"), command
        expect(result.written).to be_empty, command
        expect(result).not_to be_opaque, command
      end
    end

    it "reads a value-holding letter as the end of a curl cluster, so -dfoo writes nothing" do
      expect(named("curl -dfoo u").written).to be_empty
    end

    it "reads a curl URL-encoded field's = before its @ as content, not a file" do
      expect(resolved("curl --data-urlencode n=a@b u")).not_to include("/p/b")
    end

    it "names no path for a commit's message or a gh api field" do
      expect(resolved('git commit -m "fix bug"')).not_to include("/p/fix bug")
      expect(resolved("git commit --message=msg")).not_to include("/p/msg")
      expect(resolved("git commit --mess=msg x")).not_to include("/p/msg")
      expect(resolved("gh api -f body=hi repos/x")).not_to include("/p/body=hi", "/p/hi")
    end

    it "keeps git's -m a flag before the subcommand and in log" do
      expect(resolved("git log -m lib")).to include("/p/lib")
    end

    it "keeps a data value bash would glob opaque" do
      expect(named("curl -H Accept:*/* u")).to be_opaque
    end

    it "reads a data value holding only a fill as data" do
      expect(named('curl -d "code=$?" u')).not_to be_opaque
      expect(resolved('curl -d "code=$?" u')).to eq(%w[/p/u])
    end

    it "keeps a data value opaque where a glob sits beside a fill" do
      ['git commit -m "$?"*', 'curl -d "$?"* u'].each { expect(named(_1)).to be_opaque, _1 }
    end

    it "reads a commit's cluster as git does, so a letter after -F, -t or -S is not its message" do
      named_files = {
        "git commit -Fm.secret" => "/p/m.secret", "git commit -Fm .env" => "/p/.env",
        "git commit -tm .env" => "/p/.env", "git commit -qFmsg" => "/p/msg",
        "git commit -Sm msg .env" => "/p/msg", "git commit -cm .env" => "/p/.env",
        "git -C sub commit -cm .env" => "/p/sub/.env", "git commit --pathspec-from-file -m msg" => "/p/msg"
      }
      named_files.each { |command, file| expect(resolved(command)).to include(file), command }
    end

    it "names each file a curl form field reads" do
      expect(resolved("curl -F 'x=@.env;type=text/plain' u")).to eq(%w[/p/.env /p/u])
      expect(resolved("curl -F 'x=<.env' u")).to eq(%w[/p/.env /p/u])
      expect(resolved('curl -F "x=y;headers=@.env" u')).to eq(%w[/p/.env /p/u])
      expect(resolved("curl --form x=@a u")).to eq(%w[/p/a /p/u])
      expect(resolved("curl -F x=@a,b u")).to eq(%w[/p/a /p/b /p/u])
      expect(resolved("curl -F x=y,b u")).to eq(%w[/p/u])
      expect(resolved(%(curl -F 'x=@"a;b"' u))).to eq(["/p/a;b", "/p/u"])
    end

    it "reads a form field's files where curl's own parser reads them" do
      { "x=y; headers=@.env" => %w[/p/.env], "x=y;HEADERS=@.env" => %w[/p/.env],
        "x=y;headers=@ .env" => %w[/p/.env], "x=@.env ;type=text/plain" => %w[/p/.env],
        "x=@ .env" => %w[/p/.env], "x=@a, .env" => %w[/p/a /p/.env], "x=<.env,b" => %w[/p/.env,b],
        "x=y;headers=@.env,b" => %w[/p/.env,b], 'x=@".env"b' => %w[/p/.env],
        "x=@a;type=text/plain; charset=utf-8;headers=@.env" => %w[/p/a /p/.env],
        "x=@a;filename=.env" => %w[/p/a], 'x=@"a"z,b' => %w[/p/a /p/b],
        'x=<"a",b;headers=@h' => %w[/p/a /p/h] }.each do |field, files|
        expect(resolved("curl -F '#{field}' u")).to eq([*files, "/p/u"]), field
      end
    end

    it "names a header file and no file for an @ inside a body" do
      expect(resolved("curl --header @h u")).to eq(%w[/p/h /p/u])
      expect(resolved("curl -d a@b u")).to eq(%w[/p/u])
    end

    it "reads the ~ after an @ as a name, since bash does not expand it there" do
      expect(resolved("curl -d @~/x u")).to eq(%w[/p/~/x /p/u])
    end

    it "splits a curl cluster at the file-taking letters curl splits it at" do
      expect(resolved("curl -T.env https://e")).to include("/p/.env")
      expect(resolved("curl -Kd .env u")).to include("/p/d")
      expect(named("curl -do out u").written).to be_empty
    end

    it "reads no data option for a program bundle exec may not run as named" do
      expect(named("bundle exec curl -d x u").written.map(&:resolved)).to eq(%w[/p/x /p/u])
    end

    it "names no path for a gh api --raw-field" do
      expect(resolved("gh api --raw-field k=v repos/x")).to eq(%w[/p/api /p/repos/x])
    end

    it "names the glob after an @ as a pattern" do
      expect(named("curl -d @*.json u").paths.filter_map(&:pattern)).to include("/p/*.json")
    end
  end

  describe "a compound statement" do
    def read(command) = named(command).paths.map { [_1.resolved, _1.written] }

    it "names a while loop's input file, and stays opaque on the operand read from it" do
      result = named(%(while read f; do wc -l "$f"; done < list.txt))
      expect(result.paths.map(&:resolved)).to include("/p/list.txt")
      expect(result).to be_opaque
    end

    it "reads a while or until loop whose body names only literal words" do
      expect(read("while true; do cat a.txt; done < list.txt")).to eq([["/p/list.txt", false], ["/p/a.txt", false]])
      expect(named("until false; do cat a.txt; done")).not_to be_opaque
    end

    it "makes a cd inside a loop opaque, since each pass starts where the last one left" do
      expect(named("while true; do cat x && cd sub && cat a; done")).to be_opaque
    end

    it "keeps a cd inside a subshell from moving the stages after it" do
      result = named("(cd sub && ls) ; cat a.txt")
      expect(result.paths.map(&:resolved)).to eq(%w[/p/sub /p/a.txt])
      expect(result).not_to be_opaque
      expect(resolved("(cd x) && cat b")).to eq(%w[/p/x /p/b])
    end

    it "keeps a cd bound before a subshell for the stages inside it and after it" do
      expect(resolved("cd x && (cat a) && cat b")).to eq(%w[/p/x /p/x/a /p/x/b])
    end

    it "reads a brace group and every branch of an if" do
      expect(read("{ cat a; cat b; }")).to eq([["/p/a", false], ["/p/b", false]])
      expect(read("if test -f a; then cat b; elif true; then cat c; else touch d; fi"))
        .to eq([["/p/a", false], ["/p/b", false], ["/p/c", false], ["/p/d", true]])
    end

    it "names a write inside an if, a brace group or a subshell, and one redirected from the whole of it" do
      expect(read("if true; then echo x > out; fi")).to eq([["/p/out", true]])
      expect(read("if true; then echo x; fi > out")).to eq([["/p/out", true]])
      expect(read("{ echo x; } >> out")).to eq([["/p/out", true]])
      expect(read("(echo x) > out")).to eq([["/p/out", true]])
    end

    it "makes a redirect after a compound opaque when a cd may have moved where bash opens it" do
      ["cd x && { cat a; } > o", "(cd x && cat a) > o"].each { expect(named(_1)).to be_opaque, _1 }
    end

    it "keeps a case statement opaque" do
      expect(named("case x in a) cat b;; esac")).to be_opaque
    end

    it "places each stage of a subshell where it runs" do
      placed = described_class.stages(Lain::Shell::Parse.new.call("(cd x && ls) ; cat a"), cwd: "/p", home: nil)
      expect(placed).to eq([[%w[cd x], "/p"], [%w[ls], "/p/x"], [%w[cat a], "/p"]])
    end
  end

  describe "redirects that follow compounds" do
    let(:compounds) { described_class::Compounds }

    counted = Class.new(SimpleDelegator) do
      def initialize(item, reads)
        super(item)
        @reads = reads
      end

      def byte_range
        @reads << 1
        __getobj__.byte_range
      end
    end

    # The method this replaced, kept so a corpus can pin the bisection to it.
    def rescanned?(result)
      marks = [*result.stages, *result.separators]
      (result.redirects - result.stages.flat_map(&:redirects)).all? do |redirect|
        at = redirect.byte_range.begin
        result.compounds.any? do |compound|
          from = compound.byte_range.end
          from <= at && marks.none? { _1.byte_range.begin.between?(from, at) }
        end
      end
    end

    it "reads each stage and separator a bounded number of times, however many compounds and redirects" do
      result = Lain::Shell::Parse.new.call("(cd a && cat b) >o; " * 50)
      reads = []
      wrapped = result.with(stages: result.stages.map { counted.new(_1, reads) },
                            separators: result.separators.map { counted.new(_1, reads) })
      marks = result.stages.size + result.separators.size

      expect(compounds.new(wrapped)).to be_readable
      expect(reads.size).to be <= 2 * marks
    end

    it "answers as the rescan did over a generated corpus", :aggregate_failures do
      pieces = ["(cd a && cat b)", "{ cat a; }", "(echo x)", "while true; do cat x; done", "if true; then echo y; fi",
                "cat c", "> o", ">> p", "2> e", "&&", "|", ";", "\n", "&& > o", "(a)>o", "(a);>o b", "{ a; }>o",
                ">o", "(a)", ";"]
      random = Random.new(7)
      # Some commands join with no space, so a redirect or separator touches the compound's last byte.
      results = Array.new(600) do
        words = Array.new(random.rand(1..8)) { pieces.sample(random:) }
        Lain::Shell::Parse.new.call(words.join([" ", ""].sample(random:)))
      end
      answers = results.map { compounds.new(_1).readable? }

      expect(answers).to eq(results.map { rescanned?(_1) })
      expect(answers.uniq).to contain_exactly(true, false)
      expect(results.count { (_1.redirects - _1.stages.flat_map(&:redirects)).any? }).to be > 100
    end
  end

  describe "an operand fed by a command substitution" do
    it "is opaque whatever runs inside it, quoted or not" do
      ["cat $(echo .env)", 'cat "$(printf %s .env)"', "cat x$(git ls-files)", "cat $(git ls-files > out)",
       "cat $(git ls-files ../x)", "cat $(git ls-files; id)", "cat --file=$(git ls-files)", "$(git ls-files) a",
       %(wc -l "$(git ls-files '*.rb')"), "cat $(git ls-files --full-name '*.rb')", "sort $(git ls-files)"]
        .each { expect(named(_1)).to be_opaque, _1 }
    end

    it "stays opaque over a tracked name that word splitting turns into a path outside the pattern" do
      Dir.mktmpdir do |dir|
        carrier = File.join(dir, "d/x /home/alice/.ssh/id_ed25519 y.rb")
        FileUtils.mkdir_p(File.dirname(carrier))
        File.write(carrier, "")
        expect(named("cat $(git ls-files -o '*.rb')", cwd: dir)).to be_opaque
      end
    end
  end

  describe "an interpreter reading its program from stdin" do
    it "stays opaque" do
      expect(named("python3 - <<'EOF'\nprint(1)\nEOF")).to be_opaque
    end
  end

  describe "what stays opaque" do
    it "keeps an option word a fill finishes opaque, since its letters are not known until bash runs it" do
      ['rsync -"$?"e "sh -c id" a h:b', 'curl -"$?"o /tmp/x https://e', 'false; grep -"$?"r TOKEN ~',
       'false; ls -"$?"R ~', 'tar -x"$?"Cf /outside a.tar', 'sh -"$?"c id', 'make -"$?"C /x',
       'sed -"$?"i s/a/b/ f', 'cat --"$#"x=y f'].each { expect(named(_1)).to be_opaque, _1 }
    end

    it "keeps a git -C opaque for a writing subcommand when another global option sits between or before them" do
      ["git -C /outside --no-pager commit -m x", "git --no-pager -C /outside commit -m x",
       "git --no-pager -C/outside commit -m x", "git -C a --git-dir=/z/.git commit -m x"]
        .each { expect(named(_1)).to be_opaque, _1 }
    end

    it "keeps every other expansion opaque, quoted or not" do
      ['echo "$(id)"', 'echo "$x"', 'echo "$1"', 'echo "${?}"', "echo $?", 'echo "$$$x"', 'echo "$?`id`"',
       'echo "$!"', 'echo "$@"', 'echo "$-"'].each { expect(named(_1)).to be_opaque, _1 }
    end

    it "keeps a git -C opaque that another option moves, that names no literal directory, or that runs code" do
      ["git -C a -C b commit -m x", "git -C $D commit -m x", "git -C a --work-tree=/y commit -m x",
       "git -C a -c core.fsmonitor=id status", "git -c alias.x=!sh -C a x",
       "git -C a* commit -m x"].each { expect(named(_1)).to be_opaque, _1 }
    end

    it "keeps an env opaque that runs, changes or splits anything" do
      ["env sh -c id", "env cat .env", "env FOO=1 cat f", "env -i cat f", "env -S 'cat f'", "env -u X sh",
       "env --chdir=/tmp", "/usr/bin/env sh"].each { expect(named(_1)).to be_opaque, _1 }
    end

    it "keeps an awk opaque that runs, reads or writes beyond its operands, or loads code" do
      ["awk 'BEGIN{system(\"id\")}'", "awk -f prog.awk a.md", "gawk '@load \"x\"; {print}' a.md",
       "gawk '@include \"x\"'", "awk '{print > \"out\"}' f", "awk '{printf \"%s\", $0 > \"/tmp/x\"}' f",
       "awk '{print >> \"out\"}' f", "awk '{print | \"sh\"}' f", "awk '{print |& \"sh\"}' f",
       "awk '{\"date\" | getline d}' f", "awk 'BEGIN{while ((getline l < \"/etc/shadow\") > 0) print l}'",
       "awk 'BEGIN{ARGV[1]=\"/etc/shadow\"; ARGC=2} {print}' f", "gawk '{@f()}' f",
       "gawk -l filefuncs '{print}' f", "gawk --load=x '{print}' f", "gawk -i inc '{print}' f",
       "gawk --include=inc '{print}' f", "gawk -o out '{print}' f", "gawk --pretty-print=out '{print}' f",
       "gawk -p prof '{print}' f", "gawk --dump-variables=d '{print}' f", "gawk -D '{print}' f",
       "awk -E p f", "awk"].each do |command|
        expect(named(command)).to be_opaque, command
      end
    end

    it "keeps a for loop opaque unless it is the whole command, over plain literal words, into a readable body" do
      ["for f in $(ls); do cat $f; done", "for f in *.md; do cat $f; done", "for f in \"a b\"; do cat $f; done",
       "for f in ~/x; do cat $f; done", "for f in a; do cat $f; done; rm x", "for f in a; do cat $f; done | sh",
       "for f in a; do cat $f; done > out", "for f in a; do sh -c $f; done", "for f; do cat $f; done",
       "for PATH in /tmp/bin; do ls; done", "for f in a; do cat $f; done; rm -rf /x;\ndone",
       "for f in a; do cat ${f%.md}; done", "for f in a; do cat $f; done & cat .env",
       "for f in a; do for g in b; do cat $g; done; done", "time for f in a; do cat $f; done",
       "for f in a; do cat $f; done; done", "for f in a\\; b; do cat $f; done",
       "for f in x; do cat \"'\" '$f'; done", "for f in p/src/a; do touch \"'\" '/home/u/$f'; done",
       "for f in x; do cat $f # it's\ndone", "for f in x; do cat $f # c\ndone",
       "for f in a; do cat $f; done>out; rm -rf /x;\ndone", "for f in a; do cat $f; done<in; rm -rf /x;\ndone"]
        .each do |command|
        expect(named(command)).to be_opaque, command
      end
    end
  end

  describe "what cannot be read" do
    it "makes an uncovered or broken parse opaque, naming nothing" do
      result = named("for f in *.key; do cat $f; done")
      expect(result).to be_opaque
      expect(result.paths).to be_empty
    end

    it "makes a shopt or set stage, and everything after it, opaque" do
      ["shopt -s dotglob; cat *", "shopt -s globstar && cat **/.env", "set -f; cat *", "shopt -s nocaseglob",
       "cat a && set +f && cat b"].each { expect(named(_1)).to be_opaque, _1 }
    end

    it "answers one shared unreadable value" do
      expect(described_class.of("cat $x", cwd: "relative", home: nil)).to equal(described_class::UNREADABLE)
    end

    it "makes an assignment before the program opaque when it could change what runs or what it opens" do
      ["LD_PRELOAD=/tmp/x.so cat f", "LD_PRELOAD=x.so ls", "PATH=/tmp cat f", "LANG=C BASH_ENV=x cat f",
       "LANG+=x cat f", "LANG=$x cat f"].each { expect(named(_1)).to be_opaque, _1 }
    end

    it "makes an assignment no program follows opaque, with whatever comes after it" do
      ["PATH=/tmp && cat f", "LANG=C; cat f", "LANG=C"].each { expect(named(_1)).to be_opaque, _1 }
    end

    it "reads past an assignment that changes only how the program reports" do
      result = named("RUST_BACKTRACE=1 LC_ALL=C cat a > o")

      expect(result).not_to be_opaque
      expect(result.paths.map { [_1.resolved, _1.written] }).to eq([["/p/a", false], ["/p/o", true]])
    end

    it "reads a cd after an assignment that changes only how it reports" do
      expect(resolved("LANG=C cd x && cat a")).to eq(%w[/p/x /p/x/a])
    end

    it "makes any other builtin after an assignment opaque, since a declaration there outlives the stage" do
      ["LANG=C export PATH=/tmp/evil && touch b", "LANG=C declare -x PATH=/tmp && touch b",
       "LANG=C typeset -x PATH=/tmp && touch b", "LANG=C local PATH=/tmp && touch b",
       "LANG=C readonly PATH=/tmp && touch b", "LANG=C unset PATH && touch b", "LANG=C export -n PATH && touch b",
       "LANG=C let x=1 && touch b", "LANG=C hash -p /tmp/evil touch && touch b", "LANG=C exec touch b",
       "LANG=C command touch b", "LANG=C builtin cd /tmp && touch b", "LANG=C eval touch b",
       "LANG=C source x && touch b", "LANG=C . x && touch b", "LANG=C trap 'touch c' EXIT && touch b"]
        .each { expect(named(_1)).to be_opaque, _1 }
    end

    it "makes an unquoted heredoc opaque, since bash expands its body" do
      expect(named("cat > crates/a/build.rs <<E\nfn main() {}\nE\n")).to be_opaque
    end

    it "makes a quoted heredoc opaque when more of the command shares its line" do
      ["cat > a <<'E' && rm -rf b\nbody\nE\n", "cat <<'E' b\nbody\nE\n", "cat <<'E' | sh\nbody\nE\n"]
        .each { expect(named(_1)).to be_opaque, _1 }
    end

    it "makes a parse with only readable kinds but uncovered bytes opaque" do
      expect(named("cat <<<x")).to be_opaque
    end

    it "makes a redirect no stage owns opaque" do
      expect(named("cat a && > /etc/passwd")).to be_opaque
    end

    it "makes a program it cannot unquote opaque" do
      expect(named("\\rm -rf /etc")).to be_opaque
    end

    it "is deeply frozen when opaque" do
      expect(named("cat $x")).to be_deeply_frozen
    end
  end

  describe ".from" do
    it "reads a parse already made, as .of does" do
      parse = Lain::Shell::Parse.new.call("cd x && cat .env")
      expect(described_class.from(parse, cwd: "/p", home: nil)).to eq(named("cd x && cat .env", home: nil))
    end
  end

  it "is opaque for a relative or missing cwd" do
    expect(named("cat a", cwd: "p")).to be_opaque
    expect(named("cat a", cwd: nil)).to be_opaque
  end

  it "is deeply frozen" do
    expect(named("cd x && cat 'a b' > o")).to be_deeply_frozen
  end

  describe "a quoted heredoc" do
    it "is opaque when its end line is one bash would not end it on" do
      [" EOF", "\tEOF", "EOF ", "EOF;x", "EOF&&x", "EOF # c"].each do |ending|
        command = "cat > t.txt <<'EOF'\n#{ending}\ncat > u.txt <<'X'\nEOF\nhidden after\nX\n"

        expect(named(command)).to be_opaque, command.inspect
      end
    end

    it "is opaque when a body line nearly ends it" do
      ["EOF ", " EOF", "EOF;", "EOF&", "EOF|x", "EOF#"].each do |near|
        command = "cat > a <<'EOF'\n#{near}\nEOF\n"

        expect(named(command)).to be_opaque, command.inspect
      end
    end

    it "is opaque when the grammar runs past an exact end line, as it does after a lone backslash line" do
      expect(named("cat > t.txt <<'EOF'\n\\\nEOF\nhidden after\nEOF\n")).to be_opaque
    end

    it "is opaque for a delimiter it cannot unquote for certain" do
      expect(named("cat > a <<'E'\"F\"\nbody\nEF\n")).to be_opaque
    end

    it "names the file the command writes from it" do
      ["cat > crates/a/build.rs <<'E'\nfn $(main)() {}\nE\n", "cat > crates/a/build.rs <<\"E\"\nbody\nE\n",
       "cat > crates/a/build.rs <<\\E\nbody\nE\n", "cat > crates/a/build.rs <<-'E'\n\tbody\n\tE\n"].each do |command|
        result = named(command)

        expect(result).not_to be_opaque, command
        expect(result.written.map(&:resolved)).to eq(["/p/crates/a/build.rs"]), command
      end
    end

    it "reads the stage after the heredoc's end" do
      expect(resolved("cat > a <<'E'\nbody\nE\ncat b\n")).to eq(%w[/p/a /p/b])
    end
  end

  describe ".stages" do
    def stages(command, cwd: "/p", home: nil)
      described_class.stages(Lain::Shell::Parse.new.call(command), cwd:, home:)
    end

    it "hands each stage's words as bash passes them, with the directory it runs in" do
      expect(stages(%(bash "a b.sh" 'c' d # note))).to eq([[["bash", "a b.sh", "c", "d"], "/p"]])
      expect(stages("ruby 'evil.rb' '*'")).to eq([[%w[ruby evil.rb *], "/p"]])
    end

    it "places each stage where a bound cd leaves it, and knows no directory past one it cannot bind" do
      expect(stages("cd x && ls a")).to eq([[%w[cd x], "/p"], [%w[ls a], "/p/x"]])
      expect(stages("cd x && ls\ncargo")).to eq([[%w[cd x], "/p"], [%w[ls], "/p/x"], [%w[cargo], nil]])
    end

    it "keeps a word written after a redirect, as bash does" do
      expect(stages("echo a > o b")).to eq([[%w[echo a b], "/p"]])
    end

    it "reads a leading tilde as the home it is given" do
      expect(stages("cat ~/notes.txt", home: "/home/u")).to eq([[%w[cat /home/u/notes.txt], "/p"]])
    end

    it "hands a stage's assignments to env, which the resolver reads as a wrapper" do
      expect(stages(%(X="a b" Y=1 ls))).to eq([[["env", "X=a b", "Y=1", "ls"], "/p"]])
    end

    it "cannot tell for a recursive glob, a brace, an expansion, an escape, a lone assignment or a homeless tilde" do
      ["ls **/*.rb", "ls lib/**", "cat $X", "cat a\\ b", "X=1 && ls", "X=$Y ls", "PATH=~/fakebin:/usr/bin ls",
       "X=a:~/b ls", "LANG=C exec ls", "LANG=C eval ls", "LANG=C command ls", "echo $(id)", "cat ~/x", "cat {a,b}"]
        .each { |command| expect(stages(command)).to be_nil, command }
    end

    context "with a glob" do
      around do |example|
        Dir.mktmpdir do |made|
          @dir = File.realpath(made)
          %w[b.rb a.rb c.txt .d.rb].each { File.write(File.join(@dir, _1), "") }
          example.run
        end
      end

      it "expands it to the sorted names it matches where its stage runs" do
        expect(stages("ls *.rb x?.txt", cwd: @dir)).to eq([[%w[ls a.rb b.rb x?.txt], @dir]])
        expect(stages("ls #{@dir}/[ab].rb", cwd: "/p")).to eq([[["ls", "#{@dir}/a.rb", "#{@dir}/b.rb"], "/p"]])
      end

      it "keeps a quoted glob character as a name" do
        expect(stages("ls '*'.rb a'?'.rb", cwd: @dir)).to eq([[%w[ls *.rb a?.rb], @dir]])
      end

      it "cannot tell a glob in a stage it cannot place" do
        expect(stages("cd x && ls ; ls *.rb", cwd: @dir)).to be_nil
      end
    end
  end

  describe ".for_call" do
    let(:context) { Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: "/p", env: {})) }

    def call_of(input) = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input:)

    def for_call(input, **) = described_class.for_call(call_of(input), context, home: "/home/u", **)

    it "runs the command where the session stands when the call names no directory" do
      expect(for_call({ "command" => "cat a" }).paths.map(&:resolved)).to eq(%w[/p/a])
    end

    it "resolves a relative cwd field against the session's directory" do
      expect(for_call({ "command" => "cat a", "cwd" => "sub" }).paths.map(&:resolved)).to eq(%w[/p/sub/a])
    end

    it "reads a ~ in the cwd field as the home it is given" do
      expect(for_call({ "command" => "cat a", "cwd" => "~/x" }).paths.map(&:resolved)).to eq(%w[/home/u/x/a])
    end

    it "reads symbol keys as the tool does" do
      expect(for_call({ command: "cat a", cwd: "sub" }).paths.map(&:resolved)).to eq(%w[/p/sub/a])
    end

    it "is unreadable when the call names no command" do
      expect(for_call({})).to equal(described_class::UNREADABLE)
    end

    it "names an absolute word and leaves the command opaque when the cwd cannot be resolved" do
      [3, "bad\0dir"].each do |cwd|
        result = for_call({ "command" => "cat /etc/passwd notes", "cwd" => cwd })

        expect(result).to be_opaque
        expect(result.paths.map(&:resolved)).to eq(%w[/etc/passwd])
      end
    end

    it "keeps only the words written as absolute when the cwd cannot be resolved" do
      result = for_call({ "command" => "cat ../../etc/x /etc/y notes", "cwd" => "bad\0dir" })

      expect(result).to be_opaque
      expect(result.paths.map(&:resolved)).to eq(%w[/etc/y])
    end

    it "is unreadable when the session's own directory is not absolute" do
      relative = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: "wt", env: {}))

      expect(described_class.for_call(call_of({ "command" => "ls" }), relative, home: nil))
        .to equal(described_class::UNREADABLE)
    end
  end
end
