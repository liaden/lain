# frozen_string_literal: true

require "async"
require "fileutils"
require "tmpdir"

# T13's differential: the SAME {Lain::Tools::Grep}, once in process and once
# with a {Lain::Core::Client} wired, over one corpus per case. The claim under
# test is NOT that the two paths are interchangeable -- they demonstrably are
# not -- but that every axis where they CAN agree does, and every axis where
# they cannot is pinned here as a witness rather than discovered by a user.
#
# Modelled on spec/support/shared_examples/exec_boundary_parity.rb, but written
# out rather than extracted into a shared group: grep rides ONE transport
# (:core), so a shared group would have exactly one host and would state
# nothing mechanically. The discipline that carries over is the one that
# matters -- #expect_identical has no teeth of its own (see the measurement
# note on CoreExecSpecSupport::Differential), so every parity case below ALSO
# asserts its bytes literally, and those literals are what pin the wire.
#
# The witnesses in the second block are the card's escalations, standing in
# code. Each one goes RED the moment the corresponding product decision lands,
# which is the point: a divergence that stops being true must not stay silent.
#
# They are also the ONLY thing here that can tell whether the wire ran at all,
# and that is not a paradox: a parity example asserts the two arms AGREE, which
# a core arm secretly running the in-process walk satisfies perfectly. Measured
# -- ignoring the injected client entirely (`@search = RubySearch.new`) reddens
# 5 of these 15 examples, and all 5 are witnesses. So the divergences are this
# block's #expect_attached_to (see core_exec_spec's :vsock note): delete them
# for being "not parity" and the file passes green having proved nothing.
#
# The same limit applies to the ignore-rules parity example above, and it is
# worth naming because it looks like it is pinned here and is not: dropping
# `respect_ignores` from the wire params reddens ZERO examples in this file,
# because the daemon's own default is off too. What pins that the flag is sent
# is the wire assertion in spec/lain/tools/grep_spec.rb, which reddens 2. An
# agreement between two defaults is not the same fact as an intent stated on
# the wire, and only one of the two files can hold the second.
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
  # first. A fresh daemon per case, matching core_exec_spec's :core block.
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

    # T7: no matches is still an ok Result, but no longer a blank one -- see
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

    # RESOLVED, and it did not start out that way. The daemon walks with
    # ripgrep's `ignore` crate and CAN apply .gitignore/.ignore rules; Dir.glob
    # has no idea what a .gitignore is and cannot get one without the
    # subprocess this tier-1 tool exists to avoid. So the in-process semantics
    # win: Grep::CoreSearch sends `respect_ignores: false` and the daemon's
    # walker switches all five ignore sources off.
    #
    # This example lived in the block below as a DIVERGENCE witness until
    # 2026-07-29, and it went red the moment the daemon grew the param -- which
    # is exactly what a witness is for. Do not weaken it back to "the wire
    # returns a subset": the claim now is equality.
    #
    # What this example CANNOT show, and where to look instead. The two arms
    # here agree partly because the daemon's own default is off too, so a build
    # that dropped `respect_ignores` from the wire entirely would still pass.
    # Two other places carry the halves this one cannot:
    #
    # - that the flag is SENT, and sent false on purpose -- the wire-params
    #   example in spec/lain/tools/grep_spec.rb, which reddens if it is dropped.
    # - that the daemon genuinely HONOURS it, so this agreement is a decision
    #   and not an incapacity -- `respect_ignores_rides_the_wire_and_decides_
    #   what_comes_back` in crates/lain-core/src/grep.rs, which drives a real
    #   daemon over a real socket in both directions.
    #
    # Deliberately not re-proved here with a raw `respect_ignores: true` call:
    # no Lain code sends true, so that would exercise a path production never
    # takes, in a file whose every other example means "the two arms agree".
    it "agrees that .gitignore'd files are still searched -- the wire is told to skip no one" do
      write(".gitignore", "ignored.txt\nvendor/\n")
      write("kept.txt", "needle kept\n")
      write("ignored.txt", "needle ignored\n")
      write("vendor/dep.txt", "needle vendored\n")

      ruby, core = differential("needle")

      expect_identical(ruby, core)
      expect(core.content).to eq("ignored.txt:1:needle ignored\n" \
                                 "kept.txt:1:needle kept\n" \
                                 "vendor/dep.txt:1:needle vendored")
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

  # ⚠️ EVERY example below asserts a DIFFERENCE. None of them is a parity
  # claim, and none may be "fixed" by relaxing it -- each is an open product
  # decision escalated by T13 (see .handback-T13.md), pinned here so that
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

    # NOT in T12's inherited divergence list, and found by measurement here:
    # "binary" means two different things. The daemon quits a file at its
    # first NUL byte (BinaryDetection::quit(0)) and discards the buffer it was
    # in, so a match BEFORE the NUL is lost too; the in-process walk only ever
    # skips a line it cannot decode, and a NUL decodes fine.
    it "DIVERGES on NUL bytes: the wire drops the whole file, the in-process walk keeps its matches" do
      write("nul.txt", "needle before nul\nplain \x00 byte\nneedle after nul\n")

      ruby, core = differential("needle")

      expect(ruby.content).to eq("nul.txt:1:needle before nul\nnul.txt:3:needle after nul")
      expect(core.content).to eq(%(grep: no matches for "needle" in #{tmpdir}))
    end

    # The mirror image of the case above, and the correction to T12's struck
    # divergence #4: that measurement had no match AFTER the invalid line, so
    # it read as agreement. With one, the paths part -- File.foreach raises on
    # the undecodable line and the rescue ends the FILE, while the wire's
    # reader transcodes lossily and searches straight through it.
    it "DIVERGES on invalid UTF-8: the in-process walk abandons the file, the wire reads past it" do
      write("bad.txt", "needle one\nneedle two\n\xFF\xFE invalid\nneedle four\n")

      ruby, core = differential("needle")

      expect(ruby.content).to eq("bad.txt:1:needle one\nbad.txt:2:needle two")
      expect(core.content).to eq("bad.txt:1:needle one\nbad.txt:2:needle two\nbad.txt:4:needle four")
    end

    # Also not in T12's list. Dir.glob's File.file? follows the link, so the
    # in-process walk searches the same bytes twice under two labels; the
    # daemon's walker does not follow symlinks and reports the target once.
    it "DIVERGES on symlinks: the in-process walk follows one and reports the bytes twice" do
      write("sym_target.txt", "needle target\n")
      File.symlink(File.join(tmpdir, "sym_target.txt"), File.join(tmpdir, "link.txt"))

      ruby, core = differential("needle")

      expect(ruby.content).to eq("link.txt:1:needle target\nsym_target.txt:1:needle target")
      expect(core.content).to eq("sym_target.txt:1:needle target")
    end
  end
end
