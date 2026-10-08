# frozen_string_literal: true

require "async"
require "fileutils"
require "tmpdir"

# The differential: the SAME {Lain::Tools::Grep}, once in process and once
# with a {Lain::Core::Client} wired, over one corpus per case. The claim under
# test is NOT that the two paths are interchangeable -- they demonstrably are
# not -- but that every axis where they CAN agree does, and every axis where
# they cannot is pinned here as a witness rather than discovered by a user.
#
# Written out rather than extracted into a shared group: grep rides ONE
# transport (:core), so a shared group would have exactly one host and would
# state nothing mechanically. The discipline that matters is kept anyway -- a
# differential helper that only compares the two arms has no teeth of its own,
# since two arms agreeing proves nothing if neither ran the wire, so every
# parity case below ALSO asserts its bytes literally, and those literals are
# what pin the wire.
#
# The witnesses in the second block are the card's escalations, standing in
# code. Each one goes RED the moment the corresponding product decision lands,
# which is the point: a divergence that stops being true must not stay silent.
#
# They are also the ONLY thing here that can tell whether the wire ran at all,
# and that is not a paradox: a parity example asserts the two arms AGREE, which
# a core arm secretly running the in-process walk satisfies perfectly. Measured
# -- ignoring the injected client entirely (`@search = RubySearch.new`) reddens
# 5 of these 16 examples, and all 5 are witnesses. So the divergences are the
# only proof this block reached the daemon at all: delete them for being "not
# parity" and the file passes green having proved nothing.
#
# The ignore-rules examples below use a fixture repository, because the
# in-process walk only honours a `.gitignore` inside one. The names they use
# avoid `src`, which a developer's own global gitignore may list and the
# daemon would then honour from outside the fixture.
RSpec.describe Lain::Tools::Grep, :core do
  # Both arms of the same tool, across the lain-core boundary.
  around do |example|
    Dir.mktmpdir("lain-grep-parity") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  attr_reader :tmpdir

  let(:runtime_base) { Dir.mktmpdir("lain-grep-parity-runtime") }
  let(:paths) { Lain::Paths.new(env: { "XDG_RUNTIME_DIR" => runtime_base }) }

  after { FileUtils.rm_rf(runtime_base) }

  # binwrite, so a case can put bytes that are not valid UTF-8 into a file
  # without Ruby transcoding them on the way in.
  def write(relative_path, content)
    path = File.join(tmpdir, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
    path
  end

  def with_client
    Sync do
      client = Lain::Core::Client.start(transport: Lain::Core::Child.new(paths:))
      begin
        yield client
      ensure
        client.stop
      end
    end
  end

  # The corpus is the session's cwd, so a case may pass a RELATIVE `path` and
  # exercise the WorkerEnv resolution both paths share -- without Dir.chdir,
  # whose process-wide effect would leak across the parallel spec workers.
  def invocation
    Lain::Tool::Invocation.new(context: Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: tmpdir, env: {})))
  end

  # One search through both paths; the pair of results, the in-process one
  # first. A fresh daemon per case, so no case inherits another's state.
  def differential(pattern, path = tmpdir, **extra)
    input = { pattern:, path:, **extra }
    call = invocation
    [described_class.new.call(input, call),
     with_client { |client| described_class.new(client:).call(input, call) }]
  end

  # Byte-for-byte is the contract, so compare the .b forms: the in-process
  # path's strings come off File.foreach and the wire's off msgpack str, and
  # String#== on differently-encoded non-ASCII strings is false even when
  # every byte agrees.
  def expect_identical(ruby, core)
    expect(core.error?).to eq(ruby.error?)
    expect(core.content.b).to eq(ruby.content.b)
  end

  def differential_including(include, path = tmpdir)
    input = { pattern: "needle", path: }
    ruby = described_class.new(include:).call(input, invocation)
    core = with_client { |client| described_class.new(client:, include:).call(input, invocation) }
    [ruby, core]
  end

  describe "axes where the two paths agree" do
    it "agrees on labels, line numbers and order over a nested tree" do
      write("alpha.txt", "the needle here\n")
      write("beta.txt", "no match\n")
      write("nested/gamma.txt", "one\ntwo\nthe needle again\n")

      ruby, core = differential("needle")

      expect_identical(ruby, core)
      expect(core.content).to eq("alpha.txt:1:the needle here\nnested/gamma.txt:3:the needle again")
    end

    # UTF-8 that is not ASCII, a CRLF line, and a final line with no
    # terminator, in one corpus -- the three ways a line's BYTES can differ
    # between a File.foreach chomp and the wire's own line terminator strip.
    it "agrees on multibyte, CRLF and unterminated lines, and answers UTF-8" do
      write("multi.txt", "naïve needle — em dash 日本語\n")
      write("crlf.txt", "needle over crlf\r\nsecond\r\n")
      write("noeol.txt", "needle with no trailing newline")

      ruby, core = differential("needle")

      expect_identical(ruby, core)
      expect(core.content).to eq("crlf.txt:1:needle over crlf\n" \
                                 "multi.txt:1:naïve needle — em dash 日本語\n" \
                                 "noeol.txt:1:needle with no trailing newline")
      # The Journal is NDJSON and this content goes into it: binary-tagged
      # bytes here would make JSON.generate raise on the turn that carried them.
      expect(core.content.encoding).to eq(Encoding::UTF_8)
    end

    it "agrees on case-insensitive matching, and on its default being off" do
      write("shout.txt", "NEEDLE\n")

      off_ruby, off_core = differential("needle")
      on_ruby, on_core = differential("needle", case_insensitive: true)

      expect_identical(off_ruby, off_core)
      expect_identical(on_ruby, on_core)
      expect(off_core.content).to eq(%(grep: no matches for "needle" in #{tmpdir}))
      expect(on_core.content).to eq("shout.txt:1:NEEDLE")
    end

    # No matches is still an ok Result, but no longer a blank one -- see
    # {Lain::Tools::Grep#no_matches_message}. That formatting runs client-side
    # in #format_matches, downstream of BOTH search arms (the daemon reply
    # carries no message of its own, just `{matches: [], capped: false}`), so
    # this is still a parity fact and not two independently-chosen strings.
    it "agrees that no match is an ok result naming the pattern -- not an error, and not blank" do
      write("quiet.txt", "nothing interesting here\n")

      ruby, core = differential("zzz")

      expect_identical(ruby, core)
      expect(core).to be_ok
      expect(core.content).to eq(%(grep: no matches for "zzz" in #{tmpdir}))
    end

    # Deliberately capped INSIDE one file: that keeps the walk order (which
    # the two paths do not share -- see the witness below) out of the answer,
    # so this case measures the cap boundary and nothing else. Both sides
    # collect one past MAX_MATCHES and report from that, so 200 available is
    # uncapped and 201 is capped.
    it "agrees on the cap, its boundary, and the line that says so" do
      write("many.txt", (["needle"] * 5000).join("\n"))

      capped_ruby, capped_core = differential("needle")
      expect_identical(capped_ruby, capped_core)
      expect(capped_core.content.lines.grep(/^many\.txt:/).size).to eq(described_class::MAX_MATCHES)
      expect(capped_core.content).to end_with("... capped at #{described_class::MAX_MATCHES} matches")

      File.write(File.join(tmpdir, "many.txt"), (["needle"] * described_class::MAX_MATCHES).join("\n"))
      at_cap_ruby, at_cap_core = differential("needle")
      expect_identical(at_cap_ruby, at_cap_core)
      expect(at_cap_core.content).not_to include("capped at")
    end

    # The daemon labels a FILE target with the `path` param verbatim, and that
    # param is the WorkerEnv-resolved absolute locator -- so without the
    # `input.path` substitution in Grep::CoreSearch#call this case leaks an
    # absolute path where the in-process path prints "README.md:1:".
    it "agrees that a single-file target keeps the model's own spelling" do
      write("README.md", "hello world\n")

      ruby, core = differential("hello", "README.md")

      expect_identical(ruby, core)
      expect(core.content).to eq("README.md:1:hello world")
    end

    it "agrees on a missing path, byte for byte, without a round trip" do
      missing = File.join(tmpdir, "nope")

      ruby, core = differential("needle", missing)

      expect_identical(ruby, core)
      expect(core).to be_error
      expect(core.content).to eq("no such file or directory: #{missing}")
    end

    def git_init
      system("git", "init", "-q", tmpdir, exception: true)
    end

    # The daemon walks with ripgrep's `ignore` crate and the in-process walk
    # lists the repository through `git ls-files`; both skip what git ignores.
    it "agrees that a git-ignored file is skipped" do
      git_init
      write(".gitignore", "target/\n")
      write("target/x.txt", "needle ignored\n")
      write("app/y.txt", "needle kept\n")

      ruby, core = differential("needle")

      expect_identical(ruby, core)
      expect(core.content).to eq("app/y.txt:1:needle kept")
    end

    it "agrees that a search include re-includes an ignored file and keeps the rest" do
      git_init
      write(".gitignore", "target/\n")
      write("target/x.txt", "needle ignored\n")
      write("target/other.txt", "needle also ignored\n")
      write("app/y.txt", "needle kept\n")

      ruby, core = differential_including(%w[target/x.txt])

      expect_identical(ruby, core)
      expect(core.content).to eq("app/y.txt:1:needle kept\ntarget/x.txt:1:needle ignored")
    end

    # These fixtures happen to sort re-included files last; the order itself
    # diverges, pinned in the gaps block below.
    it "agrees that a slashless include glob matches at the repository top only" do
      git_init
      write(".gitignore", "*.log\nx.txt\n")
      write("app/y.txt", "needle kept\n")
      write("d/b.log", "needle nested log\n")
      write("sub/x.txt", "needle nested\n")
      write("x.txt", "needle top\n")
      write("z.log", "needle top log\n")

      ruby, core = differential_including(%w[*.log x.txt])

      expect_identical(ruby, core)
      expect(core.content).to eq("app/y.txt:1:needle kept\nx.txt:1:needle top\nz.log:1:needle top log")
    end

    it "agrees that include globs match from the repository top when searching a subdirectory" do
      git_init
      write(".gitignore", "target/\n")
      write("app/target/z.txt", "needle ignored\n")
      write("app/a.txt", "needle kept\n")

      ruby, core = differential_including(%w[app/target/z.txt], File.join(tmpdir, "app"))
      expect_identical(ruby, core)
      expect(core.content).to eq("a.txt:1:needle kept\ntarget/z.txt:1:needle ignored")

      ruby, core = differential_including(%w[target/z.txt], File.join(tmpdir, "app"))
      expect_identical(ruby, core)
      expect(core.content).to eq("a.txt:1:needle kept")
    end

    it "agrees that dotfiles are searched and .git is not" do
      write(".dotfile", "needle in a dotfile\n")
      write(".hidden/deep.txt", "needle under a dot directory\n")
      write(".git/objects/junk", "needle in git's object store\n")

      ruby, core = differential("needle")

      expect_identical(ruby, core)
      expect(core.content).to eq(".dotfile:1:needle in a dotfile\n" \
                                 ".hidden/deep.txt:1:needle under a dot directory")
    end

    # This stood below as a divergence witness until the in-process walk
    # stopped abandoning a file at its first line that is not UTF-8: it reads
    # bytes now, so it searches past that line exactly as the wire's reader
    # does. The invalid line itself matches nothing here, which keeps this a
    # claim about reading PAST it -- how each arm spells a MATCHED invalid line
    # is a separate question this example does not ask.
    it "agrees on reading past a line that is not UTF-8" do
      write("bad.txt", "needle one\nneedle two\n\xFF\xFE invalid\nneedle four\n")

      ruby, core = differential("needle")

      expect_identical(ruby, core)
      expect(core.content).to eq("bad.txt:1:needle one\nbad.txt:2:needle two\nbad.txt:4:needle four")
    end

    # POSTURE parity, not byte parity, and structurally so: the two engines
    # write their own parse errors. What must not differ is what the model
    # gets -- an error Result naming the pattern it sent, never a raise.
    it "agrees on the POSTURE of an uncompilable pattern: an error Result naming it" do
      write("any.txt", "needle\n")

      ruby, core = differential("(unclosed")

      expect(ruby).to be_error
      expect(core).to be_error
      expect(ruby.content).to start_with('invalid pattern "(unclosed"')
      expect(core.content).to start_with('invalid pattern "(unclosed"')
    end
  end

  # Five named gaps in the ignore handling, accepted: a tracked file that
  # .gitignore also names, `**` glob syntax, a .gitignore outside a repository,
  # a bare .ignore file, and the order of re-included files. Each is pinned so a
  # change on either side reddens a test instead of silently altering a search.
  describe "ignore-handling gaps the daemon carries -- pinned, not smoothed over" do
    def git_init
      system("git", "init", "-q", tmpdir, exception: true)
    end

    # `git ls-files --cached` keeps a tracked file that also matches
    # .gitignore, while the `ignore` crate skips it.
    it "DIVERGES on a tracked file that .gitignore also names: git keeps it, the crate skips it" do
      git_init
      write("app/y.txt", "needle kept\n")
      write("target/x.txt", "needle tracked\n")
      system("git", "-C", tmpdir, "add", "-f", "target/x.txt", exception: true)
      write(".gitignore", "target/\n")

      ruby, core = differential("needle")

      expect(ruby.content).to eq("app/y.txt:1:needle kept\ntarget/x.txt:1:needle tracked")
      expect(core.content).to eq("app/y.txt:1:needle kept")
    end

    # File.fnmatch and gitignore syntax differ on `**` edge cases: a trailing
    # `**` crosses directories only in gitignore syntax.
    it "DIVERGES on an include glob ending in **: gitignore syntax crosses directories, fnmatch does not" do
      git_init
      write(".gitignore", "target/\n")
      write("target/deep/z.txt", "needle deep\n")

      ruby, core = differential_including(%w[target/**])

      expect(ruby.content).to eq(%(grep: no matches for "needle" in #{tmpdir}))
      expect(core.content).to eq("target/deep/z.txt:1:needle deep")
    end

    # require_git is off in the daemon, so a .gitignore applies outside a
    # repository, while the in-process walk lists a plain directory whole.
    it "DIVERGES on a .gitignore outside a repository: the crate honours it, the plain walk does not" do
      write(".gitignore", "target/\n")
      write("target/x.txt", "needle ignored\n")
      write("app/y.txt", "needle kept\n")

      ruby, core = differential("needle")

      expect(ruby.content).to eq("app/y.txt:1:needle kept\ntarget/x.txt:1:needle ignored")
      expect(core.content).to eq("app/y.txt:1:needle kept")
    end

    # Ruby sorts the merged list; the daemon appends re-included files after
    # the normal walk.
    it "DIVERGES on the order of re-included files: Ruby sorts the merged list, the daemon appends them" do
      git_init
      write(".gitignore", "aa/\n")
      write("aa/x.txt", "needle ignored\n")
      write("bb/y.txt", "needle kept\n")

      ruby, core = differential_including(%w[aa/x.txt])

      expect(ruby.content).to eq("aa/x.txt:1:needle ignored\nbb/y.txt:1:needle kept")
      expect(core.content).to eq("bb/y.txt:1:needle kept\naa/x.txt:1:needle ignored")
    end

    # A bare .ignore file is honoured by the crate only.
    it "DIVERGES on a bare .ignore file: the crate honours it, git does not" do
      git_init
      write(".ignore", "hidden.txt\n")
      write("hidden.txt", "needle hidden\n")
      write("app/y.txt", "needle kept\n")

      ruby, core = differential("needle")

      expect(ruby.content).to eq("app/y.txt:1:needle kept\nhidden.txt:1:needle hidden")
      expect(core.content).to eq("app/y.txt:1:needle kept")
    end
  end

  # ⚠️ EVERY example below asserts a DIFFERENCE. None of them is a parity
  # claim, and none may be "fixed" by relaxing it -- each is an open product
  # decision escalated during this work, pinned here so that
  # whichever way it is decided, the decision reddens a test instead of
  # silently changing what a user gets back.
  describe "divergences the transport swap carries -- pinned, not smoothed over" do
    # ESCALATION 2. Dir.glob sorts ONE flat list of full paths, where "."
    # (0x2E) sorts before "/" (0x2F); the daemon sorts per directory during a
    # depth-first walk, so it descends into `a/` on reaching it. Two entries
    # are enough to show it -- and under MAX_MATCHES this decides WHICH
    # matches come back, which is a user-visible result change, not a cosmetic
    # ordering one.
    it "DIVERGES on walk order: a sibling directory and file order oppositely" do
      write("a.txt", "needle one\n")
      write("a/b.txt", "needle two\n")

      ruby, core = differential("needle")

      expect(ruby.content).to eq("a.txt:1:needle one\na/b.txt:1:needle two")
      expect(core.content).to eq("a/b.txt:1:needle two\na.txt:1:needle one")
    end

    # The engines are different by design: the daemon's is finite automata,
    # and THAT is what bounds a pathological pattern. Grep#description
    # therefore promises only the subset both accept -- this case is why it
    # may not say "Ruby regex syntax".
    it "DIVERGES on regex dialect: lookaround compiles in process and is refused over the wire" do
      write("hay.txt", "needle in a haystack\n")

      ruby, core = differential('(?=needle)\w+')

      expect(ruby).to be_ok
      expect(ruby.content).to eq("hay.txt:1:needle in a haystack")
      expect(core).to be_error
      expect(core.content).to include("look-around")
    end

    # NOT in the inherited divergence list, and found by measurement here:
    # "binary" means two different things. The daemon quits a file at its
    # first NUL byte (BinaryDetection::quit(0)) and discards the buffer it was
    # in, so a match BEFORE the NUL is lost too; the in-process walk reads
    # every line as bytes and skips none, and a NUL is a byte like any other.
    it "DIVERGES on NUL bytes: the wire drops the whole file, the in-process walk keeps its matches" do
      write("nul.txt", "needle before nul\nplain \x00 byte\nneedle after nul\n")

      ruby, core = differential("needle")

      expect(ruby.content).to eq("nul.txt:1:needle before nul\nnul.txt:3:needle after nul")
      expect(core.content).to eq(%(grep: no matches for "needle" in #{tmpdir}))
    end

    # Also not in that list. Dir.glob's File.file? follows the link, so the
    # in-process walk searches the same bytes twice under two labels; the
    # daemon's walker does not follow symlinks and reports the target once.
    it "DIVERGES on symlinks: the in-process walk follows one and reports the bytes twice" do
      write("sym_target.txt", "needle target\n")
      File.symlink(File.join(tmpdir, "sym_target.txt"), File.join(tmpdir, "link.txt"))

      ruby, core = differential("needle")

      expect(ruby.content).to eq("link.txt:1:needle target\nsym_target.txt:1:needle target")
      expect(core.content).to eq("sym_target.txt:1:needle target")
    end

    # The wire's UTF8 sink refuses a MATCHED line that is not UTF-8 and the
    # daemon abandons the file there; the in-process walk escapes the bytes and reads on.
    it "DIVERGES on a matched line that is not UTF-8: the in-process walk escapes it, the wire abandons the file" do
      write("latin1.txt", "needle one\ncaf\xE9 needle\nneedle three\n")

      ruby, core = differential("needle")

      expect(ruby.content).to eq("latin1.txt:1:needle one\nlatin1.txt:2:caf\\xE9 needle\nlatin1.txt:3:needle three")
      expect(core.content).to eq("latin1.txt:1:needle one")
    end
  end
end
