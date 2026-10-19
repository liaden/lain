# frozen_string_literal: true

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
      expect(resolved("cd x && cat a | grep b && cat c")).to eq(%w[/p/x /p/x/a /p/x/b /p/x/c])
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

    it "makes a shell given -c, or reading its commands from stdin, opaque" do
      ["sh -c 'cat x'", "bash -lc x", "zsh -c x", "echo x | bash"].each do |command|
        expect(named(command)).to be_opaque, command
      end
    end

    it "makes an interpreter running inline code or a module opaque" do
      ["ruby -e x", "python3 -c x", "perl -pe x f", "node -e x", "node --eval x", "python -m http.server",
       "awk '{print}' f", "echo 1 | ruby"].each do |command|
        expect(named(command)).to be_opaque, command
      end
    end

    it "names a script a shell or an interpreter runs from a file" do
      ["bash script.sh", "ruby script.rb", "awk -f prog.awk f"].each do |command|
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
       "git whatchanged", "git range-diff A...B", "git cat-file -p HEAD", "git notes show", "git commit -m x",
       "git annotate f", "git"]
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

    it "names --git-dir as written on a subcommand that writes, and diff's --output" do
      expect(named("git --git-dir=/etc/.git commit -m x").written.map(&:resolved)).to include("/etc/.git")
      expect(named("git --git-dir=/etc/.git log").written).to be_empty
      expect(named("git diff --output=/etc/x").written.map(&:resolved)).to eq(%w[/etc/x])
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
    it "makes its stage opaque" do
      expect(named("git -C ../other commit -m x")).to be_opaque
    end

    describe "of a read-only git" do
      def directories(command) = named(command).paths.select(&:directory).map(&:resolved)

      it "names its directory instead of turning opaque" do
        ["git -C sibling log 2>&1", "git -Csibling log", "git -C sibling status"].each do |command|
          result = named(command)
          expect(result).not_to be_opaque, command
          expect(directories(command)).to eq(%w[/p/sibling]), command
        end
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

      it "stays opaque for a writing subcommand" do
        ["git -C sibling commit -m x", "git -C sibling checkout .", "git -C sibling add -A",
         "git -C sibling clone url", "git -C sibling"].each { expect(named(_1)).to be_opaque, _1 }
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

    it "names sed -i's files as written, and its script as read" do
      result = named("sed -i 's/a/b/' f g")
      expect(result.written.map(&:resolved)).to eq(%w[/p/f /p/g])
      expect(result.paths.map(&:resolved)).to include("/p/s/a/b")
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
      expect(resolved("echo hi 2>&1")).to eq(%w[/p/hi])
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
      expect(resolved('git commit -m "fix bug"')).to include("/p/fix bug")
      expect(named('git commit -m "fix bug"')).not_to be_opaque
    end

    it "unquotes a word made of quoted and bare pieces" do
      expect(resolved('cat a"b c"d')).to eq(["/p/ab cd"])
    end

    it "makes the command opaque when a double-quoted span holds $, a backtick, a backslash or !" do
      ['cat "$HOME/.ssh/id_rsa"', 'cat "a`id`"', 'cat "a\\"b"', 'cat "a!b"'].each do |command|
        expect(named(command)).to be_opaque, command
      end
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

    it "makes an assignment before the program opaque" do
      expect(named("LD_PRELOAD=/tmp/x.so cat f")).to be_opaque
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

  describe ".directories" do
    def directories(command, cwd: "/p")
      described_class.directories(Lain::Shell::Parse.new.call(command), cwd:, home: nil)
    end

    it "names the directory each stage runs in, a cd's own stage included" do
      expect(directories("cd x && cat a | grep b")).to eq(%w[/p /p/x /p/x])
    end

    it "names a repeated cd's directory as many times as it runs" do
      expect(directories("cd /a && cd /b && cd /a && ls")).to eq(%w[/p /a /b /a])
    end

    it "knows no directory past a join after which a stage may run where the cd failed to leave" do
      expect(directories("cd x && ls\ncargo")).to eq(["/p", "/p/x", nil])
      expect(directories("cd x && ls ; cargo")).to eq(["/p", "/p/x", nil])
    end

    it "knows no directory after a cd it cannot bind" do
      expect(directories("ls && cd - && ls")).to eq(["/p", "/p", nil])
    end

    it "keeps the call's directory across any join when nothing changes it" do
      expect(directories("ls ; pwd")).to eq(%w[/p /p])
    end

    it "knows none for a command it cannot read, or a relative cwd" do
      expect(directories("echo $(id) && ls")).to eq([nil, nil])
      expect(directories("ls", cwd: "p")).to eq([nil])
    end
  end
end
