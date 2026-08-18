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
    def sift(rows)
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

    # A single-FILE grep labels its hits with the model's own spelling rather
    # than relative to a walked root, so the row resolves against the file the
    # tool opened. Nothing here stats to find that out.
    it "withholds the matches of a gated file searched by name" do
      shown = content(grep("API_KEY", path: ".env"))

      expect(shown).to eq("1 match withheld (credential)")
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

  # BLOCKER from the T7 review: an empty `list_files`/`glob` result is no
  # longer `content == ""` (T7 gave each a named sentence instead), and this
  # middleware re-reads a guarded tool's WHOLE content as listing rows. A
  # single-row sentence is exactly one row, {Listing#paths_in} reads the
  # whole sentence as a candidate path, and joining it onto a base that is
  # itself under a gated home directory (`~/Downloads` and friends) matches
  # the gated rule on the BASE alone -- the sentence's own words never
  # mattered. The result: an ORDINARY, EMPTY subdirectory of `~/Downloads`
  # comes back "1 path withheld (out_of_scope)", asserting hidden content
  # exists where there is none -- a false statement about the security
  # boundary, worse than the ok("") T7 replaced.
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

      expect(shown.split("\n")).to eq([".ssh", ".ssh/id_rsa.pub", "6 paths withheld (out_of_scope, protected)"])
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
end
