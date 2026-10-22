# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# A filter whose sift blows up: the fail-closed rescue has to answer with an
# error rather than with the listing it could not finish checking. Kept out of
# the RSpec block (Lint/ConstantDefinitionInBlock), the shape
# {RedactSpecSupport} already uses.
module WithholdSpecSupport
  # The message names the listing it was handed, which is exactly what must not
  # reach the model -- so the rescue may report the CLASS and nothing else.
  class RaisingFilter
    def sift(rows, **)
      raise IOError, "sift died on #{rows.inspect}"
    end
  end
end

# The listing side of the secret boundary: a path the classifier does not call
# ordinary is dropped from a `glob`, `list_files` or `grep` result on the way
# OUT of the tool phase, and the drop is always REPORTED.
#
# Every example drives the REAL tool as the downstream app, over a real
# temporary tree, against a real Session and a real classifier. That is not
# thoroughness for its own sake: the claims here are about the tools' own output
# FORMAT -- grep's `file:line:text`, glob's base-relative rows, its cap trailer
# -- and a spec that fabricated those strings would go green against a format
# the tools do not produce.
RSpec.describe Lain::Middleware::WithholdSecretPaths, :seam do
  subject(:middleware) { described_class.new(filter:) }

  let(:filter) { Lain::Sensitivity::Filter.new(sensitivity:) }
  # The home is INSIDE the tmpdir, so the home-anchored half of the tables is
  # exercised against a real tree without the suite naming the runner's own
  # `$HOME`. `cwd:` is required and has no default -- the chunk's ruling.
  let(:sensitivity) { Lain::Sensitivity.new(home:, cwd: dir) }
  let(:home) { File.join(dir, "home") }
  let(:dir) { @dir }
  let(:session) { Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: dir, env: {})) }

  # Literal, never sliced from the classifier's own tables: a fixture built out
  # of the constant it is meant to pin cannot fail when that constant is wrong.
  let(:secret) { "sk-live-9tKq2mR7xT4wL8nB3jH6yD1sA5fG0pE" }

  around do |example|
    Dir.mktmpdir { |made| @dir = made and example.run }
  end

  before do
    write("app.rb", "API_KEY = ENV.fetch(\"API_KEY\")\n")
    write(".env", "API_KEY=#{secret}\n")
    write("notes/README.md", "nothing to see\n")
    write("home/.ssh/id_rsa", "PRIVATE KEY\n")
    write("home/.ssh/id_rsa.pub", "PUBLIC KEY\n")
    write("home/.password-store/work/gh.gpg", "encrypted\n")
  end

  def write(name, content)
    File.join(dir, name).tap do |path|
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end
  end

  # Through a real Stack, so the Env wrapping production does is exercised
  # rather than a bare Hash that happens to answer the same messages.
  def stack = Lain::Middleware::Stack.new([middleware])

  def dispatch(effect, tool, subject_stack: stack)
    subject_stack.call({ effect:, context: session }) do |inner|
      invocation = Lain::Tool::Invocation.new(tool_use_id: inner.fetch(:effect).tool_use_id,
                                              context: inner.fetch(:context))
      inner.merge(result: tool.call(inner.fetch(:effect).input, invocation))
    end
  end

  def effect(name, input) = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name:, input:)

  def run(name, tool, input, **options) = dispatch(effect(name, input), tool, **options)

  def glob(pattern, path: nil, **options)
    run("glob", Lain::Tools::Glob.new, { "pattern" => pattern, "path" => path }.compact, **options)
  end

  def grep(pattern, path: ".", **options)
    run("grep", Lain::Tools::Grep.new, { "pattern" => pattern, "path" => path }, **options)
  end

  def list(path, recursive: false, **options)
    run("list_files", Lain::Tools::ListFiles.new, { "path" => path, "recursive" => recursive }, **options)
  end

  def content(env) = env.fetch(:result).content

  # A grep result this file WRITES rather than one a real grep produced: the row
  # below is a shape the parser has to survive, not output the tool emits.
  def grepping(listing)
    stack.call({ effect: effect("grep", { "pattern" => "x", "path" => "." }), context: session }) do |inner|
      inner.merge(result: Lain::Tool::Result.ok(listing))
    end
  end

  # The same call with no guard in the way: what the tool itself produced, so
  # "untouched" is asserted against the real output rather than a literal.
  def unguarded = Lain::Middleware::Stack.new([])

  describe "a grep whose matches include a gated file" do
    it "prints no line out of it, and says one match was withheld" do
      shown = content(grep("API_KEY"))

      expect(shown).not_to include(secret, ".env:")
      expect(shown).to include("app.rb:1:")
      expect(shown).to include("1 match withheld (credential)")
    end

    # A colon is legal in a path, so `odd:1/.env:1:hit` splits three ways and
    # only one of them names the file grep actually read. Reading the first
    # colon as the separator answers "odd", which is ordinary -- and prints the
    # secret. Every reading is judged instead, and any sensitive one takes the
    # row.
    it "withholds a match whose path is not unambiguously separable" do
      write("odd:1/.env", "API_KEY=#{secret}\n")

      shown = content(grep("API_KEY"))

      expect(shown).not_to include(secret)
      expect(shown).to include("2 matches withheld (credential)")
    end

    it "refuses a search of one gated file before the tool runs, and says how to ask for a release" do
      reached = false
      env = stack.call({ effect: effect("grep", { "pattern" => "API_KEY", "path" => ".env" }),
                         context: session }) do |inner|
        reached = true
        inner
      end

      expect(reached).to be(false)
      expect(env.fetch(:result)).to be_error
      expect(content(env)).to eq("searching a gated file returns nothing; use read_file on it to ask for a release")
    end

    it "refuses a search of one gated file named by a Pathname" do
      reached = false
      env = stack.call({ effect: effect("grep", { "pattern" => "API_KEY", "path" => Pathname(".env") }),
                         context: session }) do |inner|
        reached = true
        inner
      end

      expect([reached, env.fetch(:result)]).to match([false, be_error])
    end

    it "leaves a path the tool must reject to the tool, whatever its shape" do
      ["a\0b", 7].each do |path|
        env = stack.call({ effect: effect("grep", { "pattern" => "x", "path" => path }), context: session }) do |inner|
          inner.merge(result: Lain::Tool::Result.error("tool reached"))
        end

        expect(content(env)).to eq("tool reached")
      end
    end

    it "still withholds the matches of a gated directory searched by name" do
      shown = content(grep("API_KEY", path: "home/.ssh"))

      expect(shown).not_to include("PRIVATE KEY")
    end
  end

  # A single-file grep labels every row with the model's own spelling, so each
  # row is judged as the file that was searched. The policy's filter, as
  # production builds it, because only it judges a path where it lands.
  describe "a grep of one file" do
    let(:filter) { Lain::Sensitivity::Policy.new(sensitivity:, home:, root: dir).filter }

    it "shows the rows of a relative single-file grep" do
      write("gdir/g.txt", "alpha line\nbeta line\n")

      expect(content(grep("beta", path: "gdir/g.txt"))).to eq("gdir/g.txt:2:beta line")
    end

    # The real grep, with the tree changed while it runs: before it reads, and
    # after it has read but before this class sifts its rows.
    def grep_racing(path, before: -> {}, after: -> {})
      stack.call({ effect: effect("grep", { "pattern" => "API_KEY", "path" => path }), context: session }) do |inner|
        before.call
        invocation = Lain::Tool::Invocation.new(tool_use_id: "tu_1", context: inner.fetch(:context))
        result = Lain::Tools::Grep.new.call(inner.fetch(:effect).input, invocation)
        after.call
        inner.merge(result:)
      end
    end

    def relink(name, target)
      File.delete(File.join(dir, name))
      File.symlink(target, File.join(dir, name))
    end

    def refile(name)
      FileUtils.rm_rf(File.join(dir, name))
      write(name, "x\n")
    end

    it "still withholds every row as the gated file's when the file becomes a link to one after the check" do
      write("notes.txt", "API_KEY=ordinary\n")

      expect(content(grep_racing("notes.txt", before: -> { relink("notes.txt", ".env") })))
        .to eq("1 match withheld (credential)")
    end

    # Both the up-front check and the sift judge the file as it stands when
    # each runs, as every listing does; the read between them is not seen. What
    # remains is the content mask, which covers only the values it can
    # recognise: an unkeyed bare line is shown.
    it "judges a file that was a link to a gated one only while grep read it by what it is at the sift" do
      write("notes.txt", "API_KEY=ordinary\n")

      shown = content(grep_racing("notes.txt", before: -> { relink("notes.txt", ".env") },
                                               after: -> { refile("notes.txt") }))

      expect(shown).to eq("notes.txt:1:API_KEY=#{secret}")
    end

    it "judges a file that becomes a directory before grep reads it by what it is at the sift" do
      write("t", "x\n")
      becomes_directory = lambda do
        File.delete(File.join(dir, "t"))
        Dir.mkdir(File.join(dir, "t"))
        File.symlink("../.env", File.join(dir, "t", "t"))
      end

      expect(content(grep_racing("t", before: becomes_directory))).to eq("1 match withheld (credential)")
    end

    it "shows a single-file row whose matched text has digits between colons" do
      write("app.log", "at 12:30:45 started\n")

      expect(content(grep("started", path: "app.log"))).to eq("app.log:1:at 12:30:45 started")
    end

    it "withholds the rows of a directory grep whose directory becomes a file before the sift" do
      write("t/keep.txt", "API_KEY=ordinary\n")
      File.symlink("../.env", File.join(dir, "t", "a"))

      expect(content(grep_racing("t", after: -> { refile("t") }))).to eq("2 matches withheld (malformed)")
    end

    it "withholds a directory grep's row that is spelled like the directory when it becomes a file" do
      write("t/keep.txt", "API_KEY=ordinary\n")
      File.symlink("../.env", File.join(dir, "t", "t"))

      expect(content(grep_racing("t", after: -> { refile("t") }))).to eq("2 matches withheld (malformed)")
    end

    it "shows the rows of a relative single-file ast_search" do
      write("gdir/m.rb", "def beta = 1\n")

      shown = content(run("ast_search", Lain::Tools::AstSearch.new,
                          { "pattern" => "def $NAME = $V", "language" => "ruby", "path" => "gdir/m.rb" }))

      expect(shown).to start_with("gdir/m.rb:1:def beta = 1")
    end

    it "refuses a link to a gated file before the tool runs" do
      File.symlink(".env", File.join(dir, "notes.txt"))

      env = grep("API_KEY", path: "notes.txt")

      expect(content(env)).to eq(described_class::GATED_FILE_SEARCH)
      expect(content(env)).not_to include(secret)
    end

    context "with an exemption at one exact path" do
      let(:sensitivity) do
        Lain::Sensitivity.new(home:, cwd: dir, root: dir,
                              rules: Lain::Sensitivity::Rules.from({ "exempt" => ["/deploy/.env"] }))
      end

      before { write("deploy/.env", "API_KEY=#{secret}\n") }

      it "shows the rows read_file of that path would show" do
        expect(sensitivity.classify(File.join(dir, "deploy", ".env"))).to be_ordinary
        expect(content(grep("API_KEY", path: "deploy/.env"))).to eq("deploy/.env:1:API_KEY=#{secret}")
      end

      it "still refuses the gated file beside it that the exemption does not name" do
        expect(content(grep("API_KEY", path: ".env"))).to eq(described_class::GATED_FILE_SEARCH)
      end
    end
  end

  describe "an ast_search whose rows include a gated path" do
    def ast_search(**options)
      run("ast_search", Lain::Tools::AstSearch.new,
          { "pattern" => "def $NAME", "language" => "ruby", "path" => "." }, **options)
    end

    before do
      write("lib/a.rb", "def alpha; end\n")
      write("id_rsa.rb", "def hidden; end\n")
    end

    it "drops the row under the gated path and says one match was withheld" do
      shown = content(ast_search)

      expect(shown).to include("lib/a.rb:1:")
      expect(shown).not_to include("id_rsa.rb")
      expect(shown).to end_with("1 match withheld (credential)")
    end

    it "still withholds the rows of one gated file searched by name" do
      shown = content(run("ast_search", Lain::Tools::AstSearch.new,
                          { "pattern" => "def $NAME", "language" => "ruby", "path" => "id_rsa.rb" }))

      expect(shown).not_to include("hidden")
      expect(shown).to end_with("1 match withheld (credential)")
    end

    it "returns the tool's own output when nothing is gated" do
      File.delete(File.join(dir, "id_rsa.rb"))

      expect(content(ast_search)).to eq(content(ast_search(subject_stack: unguarded)))
    end

    def captures_search(**options)
      run("ast_search", Lain::Tools::AstSearch.new,
          { "pattern" => "puts($ARG)", "language" => "ruby", "path" => "." }, **options)
    end

    it "keeps a row whose capture holds a line-number-shaped field" do
      write("lib/b.rb", "puts(\"a:5:b\")\n")

      expect(content(captures_search)).to include("lib/b.rb:1:")
    end

    it "withholds a row with captures under a gated path" do
      write("id_rsa.rb", "puts(\"x\")\n")

      shown = content(captures_search)

      expect(shown).not_to include("id_rsa.rb")
      expect(shown).to end_with("1 match withheld (credential)")
    end
  end

  # A trailer is the tool talking about its answer, not a path in it; joined
  # onto a gated base it would read as a sensitive file and take the trailer
  # with it.
  describe "a listing trailer under a gated base" do
    def listing_of(*rows)
      stack.call({ effect: effect("list_files", { "path" => "home/.ssh", "recursive" => true }),
                   context: session }) do |inner|
        inner.merge(result: Lain::Tool::Result.ok(rows.join("\n")))
      end
    end

    it "keeps the skipped-links trailer of a real walk, uncounted" do
      File.symlink("id_rsa.pub", File.join(home, ".ssh", "lnk"))

      shown = content(list("home/.ssh", recursive: true))

      expect(shown.lines.map(&:chomp)).to eq(["id_rsa.pub", "... 1 symlink skipped", "1 path withheld (protected)"])
    end

    [
      "... 2 symlinks skipped",
      "... capped at 500 of 900 paths",
      "... listing stopped at 10 entries; narrow the path or the pattern",
      "... truncated to 3 of 9 paths, withholding 40 bytes over the 100-byte ceiling -- " \
      "instead, narrow the pattern or the path"
    ].each do |trailer|
      it "passes #{trailer.inspect} through, neither counted nor withheld" do
        shown = content(listing_of("id_rsa", "id_rsa.pub", trailer))

        expect(shown.lines.map(&:chomp)).to eq(["id_rsa.pub", trailer, "1 path withheld (protected)"])
      end
    end

    it "still withholds a file whose name only begins like a trailer" do
      write("home/.ssh/... capped at 5 of 9 paths x", "k\n")
      write("home/.ssh/... 1 symlink skipped x", "k\n")

      shown = content(list("home/.ssh", recursive: true))

      expect(shown).not_to include("capped at 5", "skipped x")
    end
  end

  # A walk follows a linked base, so `keys -> ~/.ssh` lists the key under a name
  # no rule matches. The run's filter is the policy's, which judges each row
  # where it lands.
  describe "a listing through a link to a denied directory" do
    let(:filter) { Lain::Sensitivity::Policy.new(sensitivity:, home:).filter }

    before { File.symlink(File.join(home, ".ssh"), File.join(dir, "keys")) }

    it "withholds the denied file from list_files" do
      shown = content(list("keys"))

      expect(shown).not_to match(/id_rsa$/)
      expect(shown).to include("id_rsa.pub", "1 path withheld (protected)")
    end

    it "withholds the denied file's lines from grep" do
      shown = content(grep("KEY", path: "keys"))

      expect(shown).not_to include("PRIVATE KEY")
      expect(shown).to include("PUBLIC KEY", "1 match withheld (protected)")
    end
  end

  # A leased worker's checkout sits outside the root the classifier was built
  # on, so the row is judged below the call's own cwd as well.
  describe "a listing in a checkout outside the root" do
    let(:sensitivity) { Lain::Sensitivity.new(home:, cwd: root, root:) }
    let(:filter) { Lain::Sensitivity::Policy.new(sensitivity:, home:, root:).filter }
    let(:root) { File.join(dir, "app").tap { |made| FileUtils.mkdir_p(made) } }
    let(:checkout) { File.join(dir, "worktrees", "w1") }
    let(:session) { Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: checkout, env: {}, checkout:)) }

    before do
      write("worktrees/w1/secrets/prod.yml", "hunter2\n")
      write("worktrees/w1/README", "plain\n")
    end

    it "withholds a row under a directory that names a secret, and keeps the rest" do
      shown = content(list(checkout, recursive: true))

      expect(shown).not_to include("prod.yml")
      expect(shown).to include("README", "withheld (named)")
    end

    # `/mode plan` started in a subdirectory runs in a spike that mirrors it,
    # so the checkout is the base, not the cwd below it.
    context "with the cwd below the checkout" do
      let(:session) do
        Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: File.join(checkout, "sub"), env: {}, checkout:))
      end

      before { write("worktrees/w1/sub/plain.txt", "hunter2\n") }

      it "withholds the row from list_files and grep alike" do
        listed = content(list(checkout, recursive: true))
        grepped = content(grep("hunter2", path: checkout))

        expect([listed, grepped]).to all(satisfy { |shown| !shown.include?("prod.yml") })
        expect(grepped).to include("plain.txt")
      end
    end
  end

  describe "a glob over a denied directory" do
    it "enumerates nothing under it and reports the count" do
      shown = content(glob(".password-store/**/*", path: home))

      expect(shown).to eq("2 paths withheld (protected)")
    end

    # The exception in the denied table is what makes this a real listing
    # rather than a blanket refusal of the directory: `id_rsa.pub` is a public
    # key and stays.
    it "keeps the ordinary siblings of a denied path" do
      shown = content(glob(".ssh/*", path: home))

      expect(shown.split("\n")).to eq([".ssh/id_rsa.pub", "1 path withheld (protected)"])
    end

    # A home-anchored rule is the one that can tell WHERE a row was resolved
    # from: `Downloads` is gated under the injected home and ordinary anywhere
    # else, so this fails unless the row resolved against the glob's own base
    # rather than against the worker's cwd.
    it "resolves a row against the base the tool used, not the worker's cwd" do
      write("home/Downloads/report.md", "quarterly\n")

      shown = content(glob("Downloads/*", path: home))

      expect(shown).to eq("1 path withheld (out_of_scope)")
    end
  end

  # BLOCKER from review: an empty `list_files`/`glob` result is no longer
  # `content == ""` (each was given a named sentence instead), and this
  # middleware re-reads a guarded tool's WHOLE content as listing rows. A
  # single-row sentence is exactly one row, {Listing#paths_in} reads the
  # whole sentence as a candidate path, and joining it onto a base that is
  # itself under a gated home directory (`~/Downloads` and friends) matches
  # the gated rule on the BASE alone -- the sentence's own words never
  # mattered. The result: an ORDINARY, EMPTY subdirectory of `~/Downloads`
  # comes back "1 path withheld (out_of_scope)", asserting hidden content
  # exists where there is none -- a false statement about the security
  # boundary, worse than the ok("") those sentences replaced.
  describe "an empty result under a gated (but ordinary) directory" do
    def mkdir(name) = File.join(dir, name).tap { |path| FileUtils.mkdir_p(path) }

    it "list_files: says the directory is empty, never that a path was withheld" do
      empty_dir = mkdir("home/Downloads/empty_subdir")

      shown = content(list(empty_dir))

      expect(shown).not_to include("withheld")
      expect(shown).to match(/empty/i)
    end

    it "glob: says nothing matched, never that a path was withheld" do
      empty_dir = mkdir("home/Downloads/empty_subdir")

      shown = content(glob("*", path: empty_dir))

      expect(shown).not_to include("withheld")
      expect(shown).to match(/no match/i)
    end

    # grep's no-match sentence ALSO happens to carry exactly one colon
    # (`Matches#paths_in` finds no line-number-shaped field to extract from
    # it), so this alone would pass even with `no_rows?` deleted -- it is a
    # basic correctness check, not proof the guard is doing the work.
    it "grep: says nothing matched, never that a path was withheld" do
      empty_dir = mkdir("home/Downloads/empty_subdir")

      shown = content(grep("needle", path: empty_dir))

      expect(shown).not_to include("withheld")
      expect(shown).to match(/no match/i)
    end

    # The property the review's mutation check actually demanded: a directory
    # whose NAME manufactures extra colons defeats the "exactly one colon"
    # coincidence above. "oops:42:here" makes grep's sentinel
    # (`grep: no matches for "needle" in .../Downloads/oops:42:here`) split
    # into a "42" field followed by a text field, so WITHOUT `Matches#no_rows?`
    # short-circuiting first, {Matches#paths_in} WOULD extract a reading
    # (everything up to that "42") and {#reading} WOULD join it onto the
    # gated `base`, withholding it. Colons are ordinary bytes in a POSIX
    # filename, so this is not a contrived string -- it is a real directory
    # name. Verified (2026-08-18): forcing `Matches#no_rows?` to always
    # return `false` turns this example red with "1 match withheld
    # (out_of_scope)", where the example above stays green -- so this one,
    # not that one, is what pins `no_rows?` doing the work rather than the
    # colon-count coincidence.
    it "grep: is not fooled by a directory name that manufactures a false line-number field" do
      empty_dir = mkdir("home/Downloads/oops:42:here")

      shown = content(grep("needle", path: empty_dir))

      expect(shown).not_to include("withheld")
      expect(shown).to match(/no match/i)
    end
  end

  describe "a recursive listing of a personal directory" do
    # `list_files` is guarded on the same terms as `glob`, and this is the one
    # listing that withholds for two different reasons at once -- so the report
    # names both, once each, and the ordinary siblings survive.
    it "keeps the ordinary entries and names every reason once" do
      write("home/Downloads/report.md", "quarterly\n")

      shown = content(list("home", recursive: true))

      expect(shown.split("\n")).to eq([".ssh/id_rsa.pub", "7 paths withheld (credential, out_of_scope, protected)"])
    end
  end

  describe "a listing with nothing sensitive in it" do
    it "is byte-identical to the tool's own output" do
      guarded = content(list("notes"))
      plain = content(dispatch(effect("list_files", { "path" => "notes", "recursive" => false }),
                               Lain::Tools::ListFiles.new, subject_stack: unguarded))

      expect(guarded).to eq(plain)
    end

    it "gains no withheld line" do
      expect(content(glob("notes/*"))).not_to include("withheld")
    end
  end

  describe "what the count discloses" do
    it "names no path, only how many and why" do
      shown = content(glob(".password-store/**/*", path: home))

      expect(shown).not_to include("gh.gpg", "work", ".password-store")
      expect(shown).to include("2 paths withheld")
    end
  end

  # The escalation the card exists to force: grep counts a withheld match
  # against its own cap, because the cap ended the SEARCH before this guard ever
  # saw a row. So the two numbers describe two different things -- what the
  # search stopped at, and what the output withheld -- and the arithmetic
  # between them has to close.
  describe "a grep that both caps and withholds" do
    it "reports both facts, and the counts do not contradict" do
      write("many.txt", ([+"API_KEY=x"] * 250).join("\n"))

      shown = content(grep("API_KEY"))
      matches = shown.split("\n").grep(/:\d+:/)

      expect(shown).to include("capped at #{Lain::Tools::Grep::MAX_MATCHES} matches")
      expect(shown).to include("1 match withheld (credential)")
      expect(matches.length).to eq(Lain::Tools::Grep::MAX_MATCHES - 1)
      expect(matches.length + 1).to eq(Lain::Tools::Grep::MAX_MATCHES)
    end
  end

  describe "a grep that stops its walk and withholds" do
    it "keeps the walk-limit trailer while still withholding the secret path" do
      limit = Lain::Tool::Bounds::WalkLimit.new(entries: 3, bytes: 1_000_000)
      write("a.txt", "API_KEY=x\n")
      write("b.txt", "API_KEY=x\n")
      write("c.txt", "API_KEY=x\n")

      shown = content(run("grep", Lain::Tools::Grep.new(walk_limit: limit),
                          { "pattern" => "API_KEY", "path" => "." }))

      expect(shown).to include("listing stopped at 3 entries")
      expect(shown).to include(" withheld (credential)")
      expect(shown).not_to include(".env:")
    end
  end

  # The owed test, and it is owed because the survival is a CLASSIFICATION
  # rather than a structural fact. Grep's trailer survives for a structural
  # reason -- {Matches#paths_in} finds no `path:lineno:text` split in it and so
  # offers the classifier nothing. {Listing#paths_in} is `[row]`, so under
  # `glob` and `list_files` the cap notice IS offered as a candidate path, is
  # joined to the base, and survives only because {Lain::Sensitivity} rules it
  # ordinary. A rule that someday matched it would silently delete the one row
  # that says the answer is partial, leaving a capped listing reading as
  # complete -- the exact failure both this class and {Lain::Tool::Bounds}
  # exist to prevent.
  #
  # The notice is read from the tool's OWN bound rather than written out here,
  # the `no_rows?` rule: one definition, read from both ends.
  describe "a listing that both caps and withholds" do
    # One ordinary file over the cap, plus a gated one that sorts first (so it
    # is inside the surviving prefix and there is really something to withhold).
    let(:total) { Lain::Tools::Glob::BOUND.limit + 2 }
    let(:notice) { Lain::Tools::Glob::BOUND.notice(total) }

    before do
      FileUtils.mkdir_p(File.join(dir, "many"))
      (total - 1).times { |i| File.write(File.join(dir, "many", format("f%05d.txt", i)), "") }
      write("many/credentials.json", "{\"token\":\"#{secret}\"}\n")
    end

    it "keeps glob's cap notice as an ordinary row and counts only the secret as withheld" do
      shown = content(glob("many/*", path: dir))

      expect(shown.split("\n")).to include(notice)
      expect(shown).to end_with("\n1 path withheld (named)")
      expect(shown).not_to include("credentials.json")
      expect(shown).not_to include(secret)
    end

    it "keeps list_files' cap notice as an ordinary row too" do
      shown = content(list(File.join(dir, "many")))

      expect(shown.split("\n")).to include(Lain::Tools::ListFiles::BOUND.notice(total))
      expect(shown).to end_with("\n1 path withheld (named)")
      expect(shown).not_to include("credentials.json")
    end
  end

  # The byte ceiling's notice is a row like the cap notice, and survives for the
  # same two reasons: grep's reader finds no `path:lineno:text` split in it, and
  # the listing reader offers it as a path the classifier rules ordinary.
  describe "a listing held to its byte ceiling, that also withholds" do
    before do
      FileUtils.mkdir_p(File.join(dir, "wide"))
      400.times { |i| write("wide/a_component_with_a_long_descriptive_name_#{i}.tsx", "hit #{"z" * 100}\n") }
      write("wide/credentials.json", "{\"token\":\"#{secret}\"} hit\n")
    end

    it "keeps the truncation line on glob, list_files and grep" do
      shown = { glob: content(glob("wide/*", path: dir)), list_files: content(list(File.join(dir, "wide"))),
                grep: content(grep("hit", path: File.join(dir, "wide"))) }

      shown.each do |tool, text|
        expect(text.lines.map(&:chomp)).to include(a_string_starting_with("... truncated to ")), tool.to_s
        expect(text).not_to include(secret), tool.to_s
      end
    end
  end

  describe "a row this class cannot even join" do
    # A matched line carrying `\0:12:` makes the SECOND reading of the row hold
    # a NUL byte, and `File.join` raises on one before the classifier is ever
    # asked. That fails closed -- but it fails closed over the whole listing,
    # taking every ordinary row with it, where {Lain::Sensitivity::MALFORMED}
    # withholds exactly the row nobody can read. Reachable from grep's matched
    # TEXT, which is a file's bytes and nobody's to constrain.
    it "withholds just that row, and the rest of the listing survives" do
      write("keep.txt", "TOKEN ok\n")
      write("poison.txt", "TOKEN\0:12:x\n")

      env = grep("TOKEN")

      expect(env.fetch(:result)).not_to be_error
      expect(content(env).split("\n")).to eq(["keep.txt:1:TOKEN ok", "1 match withheld (malformed)"])
    end
  end

  # A name whose bytes are not UTF-8 cannot be classified, so it fails closed --
  # but as ONE row. Splitting the listing as text raised on the first such name,
  # and the rescue then withheld every ordinary row beside it, naming only
  # `(ArgumentError)`.
  describe "a name that is not UTF-8" do
    let(:bad_name) { "bad\xFF.rb".b }

    before do
      write("mixed/ok.rb", "zzzmarker\n")
      File.binwrite(File.join(dir, "mixed".b, bad_name), "zzzmarker\n")
    end

    it "withholds exactly that row of a list_files listing" do
      env = list("mixed")

      expect(env.fetch(:result)).not_to be_error
      expect(content(env).split("\n")).to eq(["ok.rb", "1 path withheld (malformed)"])
    end

    it "withholds exactly that row of a glob" do
      env = glob("*", path: File.join(dir, "mixed"))

      expect(env.fetch(:result)).not_to be_error
      expect(content(env).split("\n")).to eq(["ok.rb", "1 path withheld (malformed)"])
    end

    # `Dir.pwd` answers a BINARY string under a C locale, and every byte is
    # valid BINARY -- so a check that asked the string's own encoding would
    # call this name readable and hand it on. The question is whether it is
    # UTF-8, which is what the model reads.
    it "withholds it when the base arrives spelled as BINARY bytes" do
      env = list(File.join(dir, "mixed").b)

      expect(env.fetch(:result)).not_to be_error
      expect(content(env).split("\n")).to eq(["ok.rb", "1 path withheld (malformed)"])
    end

    # A row written here rather than by a real grep, since neither arm emits
    # one: the parser has to survive it anyway, because this class is the
    # boundary and cannot vouch for what every future producer of a row does.
    it "withholds a grep row whose bytes are not UTF-8, and keeps the rest" do
      env = grepping("keep.rb:1:zzzmarker\n#{bad_name}:1:zzzmarker".b.force_encoding(Encoding::UTF_8))

      expect(env.fetch(:result)).not_to be_error
      expect(content(env).split("\n")).to eq(["keep.rb:1:zzzmarker", "1 match withheld (malformed)"])
    end
  end

  describe "a grep match whose line is not UTF-8" do
    before do
      write("latin/utf8.txt", "zzzmarker in UTF-8\n")
      File.binwrite(File.join(dir, "latin", "latin1.txt"), "caf\xE9 zzzmarker\n".b)
    end

    it "returns the line with its byte escaped, and the result commits" do
      env = grep("zzzmarker", path: "latin")
      block = { "type" => "tool_result", "tool_use_id" => "tu_1", "content" => content(env), "is_error" => false }

      expect(env.fetch(:result)).not_to be_error
      expect(content(env).split("\n")).to eq(['latin1.txt:1:caf\xE9 zzzmarker', "utf8.txt:1:zzzmarker in UTF-8"])
      expect { CoreGraph.timeline.commit(role: :user, content: [block]) }.not_to raise_error
    end
  end

  describe "what it does not touch" do
    # The `12:34` boundary the split rule documents: a match row always carries
    # a TEXT field after its line number, so two fields are not one. Without
    # that bound the first field is read as a path, and `.env:34` comes back as
    # `1 path withheld` -- the count lying in the other direction, about a file
    # nothing named.
    it "does not read a row with no text field as a path" do
      env = grepping(".env:34")

      expect(content(env)).to eq(".env:34")
    end

    it "leaves a tool it does not guard alone" do
      path = write("plain.txt", "hello\n")

      shown = content(run("read_file", Lain::Tools::ReadFile.new, { "path" => path }))

      expect(shown).to eq("hello\n")
    end

    # A failed tool carries a message, never a listing -- and the message can
    # NAME the path it failed on, which reads as a row and would otherwise be
    # withheld: the refusal would come back as `1 path withheld`, as an OK
    # result, with the reason the tool failed thrown away.
    it "passes an error result through unchanged, message and flag both" do
      env = list(".env")

      expect(env.fetch(:result)).to be_error
      expect(content(env)).to include("not a directory")
    end
  end

  describe "when it cannot check the result" do
    subject(:middleware) { described_class.new(filter: WithholdSpecSupport::RaisingFilter.new) }

    # The CLASS only. An exception's message can quote the listing that produced
    # it, and that listing is what this class exists to withhold.
    it "answers with an error naming the class and not the listing" do
      env = glob("*")

      expect(env.fetch(:result)).to be_error
      expect(content(env)).to include("IOError")
      expect(content(env)).not_to include("app.rb")
    end
  end

  describe "content it cannot read as a listing" do
    # A tool returning provider content blocks is bytes this class structurally
    # cannot sift, and forwarding the part it understood is the fail-open shape
    # {Lain::Middleware::RedactSecretReads::Scan} refuses for the same reason.
    it "is refused rather than forwarded" do
      blocks = [{ "type" => "text", "text" => ".env" }]
      env = stack.call({ effect: effect("glob", { "pattern" => "*" }), context: session }) do |inner|
        inner.merge(result: Lain::Tool::Result.ok(blocks))
      end

      expect(env.fetch(:result)).to be_error
      # Named, not merely errored: forwarding the blocks and letting the sift
      # die on them fails closed too, and reads identically from outside.
      expect(content(env)).to include("cannot read as a listing")
      expect(content(env)).not_to include(".env")
    end
  end

  describe "a glob that now reaches dotfiles" do
    it "lists .env under a bare star and withholds it" do
      shown = content(glob("*"))

      expect(shown.split("\n")).to include("app.rb", "notes")
      expect(shown).not_to match(/^\.env$/)
      expect(shown).to match(/\d+ paths? withheld/)
    end
  end
end
