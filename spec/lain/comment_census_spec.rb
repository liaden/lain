# frozen_string_literal: true

require "open3"
require "pathname"

# `load`, not `require_relative`: the subject lives at `bin/comment-census` with
# no `.rb` extension (matching `bin/lint-price-freshness`), and Ruby's `require`
# family resolves a feature by trying known suffixes -- it does not fall back to
# the literal path, so `require_relative` raises LoadError on an extensionless
# script. `load` takes the path as-is; the file only defines a module and a CLI
# block guarded by `$PROGRAM_NAME == __FILE__`, which is false under rspec.
load File.expand_path("../../bin/comment-census", __dir__)

# The census is the instrument the comment sweep is measured with, so its own
# claims have to be mechanical. Two properties carry the weight:
#
#   1. The stripper's output is what proves "the sweep changed no code". If a
#      `#` inside a heredoc were read as a comment, the proof would be a
#      tautology over corrupted text. Every stripper example here is paired
#      with `verify`, which re-lexes both sides and compares the significant
#      token streams -- a claim about the parse, not about the characters.
#   2. The ticket classifier decides ~2,400 rewrites. A false positive there
#      deletes a reader's only pointer into somebody else's documentation, so
#      the classifier refuses to guess: a shape it cannot place is reported as
#      unknown rather than swept.
RSpec.describe CommentCensus do
  let(:repo_root) { Pathname.new(File.expand_path("../..", __dir__)) }

  def run_cli(*args, dir: repo_root)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, (repo_root / "bin/comment-census").to_s, *args,
                                            chdir: dir.to_s)
    [stdout, stderr, status]
  end

  describe "the prose/YARD split" do
    let(:source) do
      <<~RUBY
        # frozen_string_literal: true

        # Prose about why this exists.
        class Widget
          # @param name [String] the widget's name
          # @return [Widget]
          def initialize(name) = @name = name
        end
      RUBY
    end

    it "counts code, YARD tag lines and prose comment lines as three separate figures" do
      tally = described_class.tally(source, language: :ruby)

      expect(tally.code).to eq(3)
      expect(tally.yard).to eq(2)
      expect(tally.prose).to eq(2)
    end

    # Two real files through the real binary rather than the whole tree: the
    # claim is about the report's shape, and walking 1,400 files to make it
    # would put seven seconds on the suite's critical path for no extra signal.
    it "prints the three figures separately when run through the binary" do
      stdout, _stderr, status = Dir.mktmpdir do |dir|
        File.write(File.join(dir, "sample.rb"), source)
        File.write(File.join(dir, "sample.lua"), "-- a note\nlocal x = 1\n")
        run_cli(File.join(dir, "sample.rb"), File.join(dir, "sample.lua"))
      end

      expect(status).to be_success
      expect(stdout).to match(/^\s*code lines\s+\d+$/)
      expect(stdout).to match(/^\s*YARD tag lines\s+\d+$/)
      expect(stdout).to match(/^\s*prose comment lines\s+\d+$/)
    end
  end

  describe "stripping Ruby" do
    # Every `#` below is inside a literal. None of them is a comment, and a
    # stripper that reads the raw text rather than the parse deletes all four.
    let(:source) do
      <<~RUBY
        # a comment-only line
        DOC = <<~TEXT
          # not a comment: a heredoc body line

          still the heredoc, after a blank line that must survive
        TEXT
        PATTERN = /a#b/
        LABEL = "colour #ff0000"
        SIGIL = :"#anchor"
        x = 1 # a trailing comment
      RUBY
    end

    it "keeps a # that lives in a heredoc, a regex, a string or a symbol" do
      stripped = described_class.strip(source, language: :ruby)

      expect(stripped).to include("# not a comment: a heredoc body line")
      expect(stripped).to include("/a#b/")
      expect(stripped).to include('"colour #ff0000"')
      expect(stripped).to include(':"#anchor"')
    end

    it "removes the comment-only line and the trailing comment, leaving the code" do
      stripped = described_class.strip(source, language: :ruby)

      expect(stripped).not_to include("a comment-only line")
      expect(stripped).not_to include("a trailing comment")
      expect(stripped).to include("x = 1\n")
    end

    it "keeps a blank line that is inside a heredoc body" do
      stripped = described_class.strip(source, language: :ruby)

      expect(stripped).to include("body line\n\n  still the heredoc")
    end

    it "leaves the significant token stream identical, which is the no-code-changed claim" do
      expect(described_class.verify(source, language: :ruby)).to be_ok
    end

    it "reports a mismatch when the stripped text would not re-lex the same" do
      result = described_class.verify_pair(source, "#{source}\nSNEAKY = 2\n", language: :ruby)

      expect(result).not_to be_ok
      expect(result.reason).to include("token")
    end
  end

  describe "stripping Lua" do
    let(:source) do
      <<~LUA
        -- a comment-only line
        local doc = [[
        -- not a comment: a long-bracket string

        still the long string
        ]]
        local dash = "a -- b"
        local lvl = [==[ ]] still inside ]==]
        --[[ a long
             comment ]]
        local x = 1 -- a trailing comment
      LUA
    end

    it "keeps a -- that lives in a long bracket, a quoted string or a nested level" do
      stripped = described_class.strip(source, language: :lua)

      expect(stripped).to include("-- not a comment: a long-bracket string")
      expect(stripped).to include('"a -- b"')
      expect(stripped).to include("[==[ ]] still inside ]==]")
    end

    it "removes the short comment, the long comment and the trailing comment" do
      stripped = described_class.strip(source, language: :lua)

      expect(stripped).not_to include("a comment-only line")
      expect(stripped).not_to include("a trailing comment")
      expect(stripped).not_to include("a long\n")
      expect(stripped).to include("local x = 1\n")
    end

    it "keeps a blank line that is inside a long-bracket string" do
      stripped = described_class.strip(source, language: :lua)

      expect(stripped).to include("long-bracket string\n\nstill the long string")
    end

    it "compiles to the same bytecode after stripping, which is the no-code-changed claim", :seam do
      result = described_class.verify(source, language: :lua)

      expect(result).to be_ok
      expect(result.checked_with).to eq("luac") if described_class::Verifier::LUAC
    end
  end

  describe "the ticket classifier" do
    let(:source) do
      <<~RUBY
        # The plan ticket T15 asked for this.
        # F31 and B12 were the findings; E4 was the enhancement note.
        # OM-6 is the roadmap entry.
        x = 1
      RUBY
    end

    it "lists every project-internal scheme, finding numbers included" do
      tokens = described_class.tickets(source, language: :ruby).map(&:token)

      expect(tokens).to include("T15", "F31", "B12", "E4", "OM-6")
    end

    it "reports each site with its line and the comment text, so a sweeper can act on it" do
      site = described_class.tickets(source, language: :ruby).find { |t| t.token == "OM-6" }

      expect(site.line).to eq(3)
      expect(site.text).to include("roadmap entry")
    end

    it "finds them through the CLI" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "sample.rb"), source)
        stdout, _stderr, = run_cli("--tickets", File.join(dir, "sample.rb"))

        %w[T15 F31 B12 E4 OM-6].each { |token| expect(stdout).to include(token) }
      end
    end
  end

  describe "third-party identifiers" do
    let(:source) do
      <<~RUBY
        # `nofile` refuses `:write` with E382 before any autocommand runs.
        # The digest is SHA-256 and the timestamp is RFC 3339.
        # Unicode C0 and C1 controls are stripped; an H2 heading is a section.
        # N stages against N-1 pipes, and -U3 is the diff context window.
        # E4 is ours, in the same file.
        x = 1
      RUBY
    end

    it "does not call an nvim error code, a hash name or an RFC a ticket" do
      tokens = described_class.tickets(source, language: :ruby).map(&:token)

      expect(tokens).not_to include("E382", "SHA-256", "RFC 3339", "C0", "C1", "H2", "N-1", "U3")
    end

    it "still calls E4 a ticket in that same file" do
      expect(described_class.tickets(source, language: :ruby).map(&:token)).to include("E4")
    end

    # Read out of the banned section alone. The report quotes each site's whole
    # comment, so a third-party token can legitimately appear in the AMBIGUOUS
    # listing's echoed text -- what must not happen is its being LISTED.
    it "leaves the third-party sites alone through the CLI" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "sample.rb"), source)
        stdout, _stderr, = run_cli("--tickets", File.join(dir, "sample.rb"))
        banned = stdout[/^PROJECT SCHEMES.*?(?=\n\n)/m].to_s

        expect(banned).to include("E4")
        %w[E382 SHA-256 C0 H2 U3].each { |token| expect(banned.scan(/: #{token} --/)).to be_empty }
      end
    end

    # The tree itself, not a fixture. Every example above proves the classifier
    # can TELL a ticket from a third-party token; none of them proved the tree
    # is clean, so six `AC n` citations landed across two commits while this
    # file stayed green. CLAUDE.md gives the ban no exempt tier, so the honest
    # assertion is that the banned section is empty -- and it names the sites,
    # because a bare count tells whoever reddens this nothing about where.
    it "carries no project-scheme citation anywhere the checker scans" do
      stdout, _stderr, = run_cli("--check-tickets")
      sites = stdout.lines.drop_while { |line| !line.start_with?("PROJECT SCHEMES") }
                          .drop(1).take_while { |line| line.start_with?("  ") }

      expect(sites).to be_empty, "project-scheme citations are banned in comments:\n#{sites.join}"
    end

    it "refuses to guess: a shape in neither list is reported as unknown, not as a ticket" do
      unknown = "# QQ7 is a scheme nobody has classified yet.\n"

      expect(described_class.tickets(unknown, language: :ruby)).to be_empty
      expect(described_class.unknowns(unknown, language: :ruby).map(&:token)).to eq(["QQ7"])
    end

    it "lets an exact third-party token beat its own project prefix" do
      expect(described_class::Classifier.classify("E382")).to eq(:third_party)
      expect(described_class::Classifier.classify("E4")).to eq(:project)
    end

    it "declares C1 ambiguous rather than sweeping it, because this tree uses it both ways" do
      expect(described_class::Classifier.classify("C1")).to eq(:ambiguous)
    end
  end

  # The manifest is gone and the comments that explained it were not swept with
  # it -- three hand sweeps each missed a different subset, which is why this
  # classifier exists at all. What it must get right is the boundary: a retired
  # claim is caught, a live order is not deleted for looking like one, and a
  # shape nobody has taught it stops the gate rather than being guessed at.
  describe "the load-order classifier" do
    def verdict(sentence) = described_class::LoadOrder.verdict(sentence)

    it "catches a claim that orders two units by the manifest that no longer does it" do
      expect(verdict("`lain.rb` loads `lain/cli` before `lain/shell`.")).to eq(:retired)
    end

    it "catches the CONSEQUENCE on its own, which is the shape a vocabulary sweep walks past" do
      expect(verdict("this unit loads before `lain/forge`, so the class body is a NameError at boot."))
        .to eq(:retired)
    end

    it "leaves an order that still exists alone" do
      expect(verdict("`vcr_configuration.rb` loads first because the support glob is `Dir[]`'s sorted order."))
        .to eq(:live)
    end

    # What keeps the UNCLASSIFIED tier small enough to be a worklist rather
    # than a wall: an ordering claim naming no unit of this library is not a
    # claim about this library, whatever verbs it uses.
    it "ignores an ordering claim that names no unit of this library" do
      expect(verdict("The gate runs LAST, after every rung above it has answered.")).to be_nil
    end

    it "reports a load-order claim it cannot place rather than calling it either way" do
      expect(verdict("{Widget} loads after {Gadget}, so naming it first is a NameError at boot."))
        .to eq(:unknown)
    end

    it "says nothing about a sentence making no ordering claim at all" do
      expect(verdict("`lain.rb` holds the loader and three inflections.")).to be_nil
    end

    # Sentence-scoped, not block-scoped: an ordering claim in one paragraph and
    # a `lain/foo` path three sentences later are not one claim, and pairing
    # them turned ten findings into twenty-three on this tree.
    it "does not pair an ordering claim with a unit named in a different sentence" do
      source = <<~RUBY
        # The rungs run in order, lowest first. A path under `lain/arm` is one.
        x = 1
      RUBY

      expect(described_class.load_order_claims(source, language: :ruby)).to be_empty
    end

    it "joins the comment lines a claim wraps across, so an eighty-column sentence is still one" do
      source = <<~RUBY
        # Resolved at CALL time, because `lain.rb` loads
        # `lain/cli` before `lain/shell`.
        x = 1
      RUBY

      expect(described_class.load_order_claims(source, language: :ruby).map(&:verdict)).to eq([:retired])
    end

    it "fails the check on a retired claim, through the CLI" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "sample.rb"), "# `lain.rb` loads `lain/cli` before `lain/shell`.\nx = 1\n")
        stdout, _stderr, status = run_cli("--check-load-order", File.join(dir, "sample.rb"))

        expect(stdout).to include("RETIRED MANIFEST")
        expect(status).not_to be_success
      end
    end
  end

  describe "the checker's scope" do
    # Not decoration. A rule whose stated scope and enforced scope differ is the
    # defect this whole sweep exists to remove, so the two are compared
    # mechanically rather than by a reader remembering to keep them in step.
    let(:claude_md) { (repo_root / "CLAUDE.md").read }

    it "scans exactly the directories CLAUDE.md's ticket rule names" do
      documented = described_class.documented_scope(claude_md)

      expect(documented).to eq(described_class::SCAN_PATHS)
    end

    it "names Rust nowhere in that scope, because a doc attribute cannot be deleted" do
      expect(described_class::SCAN_PATHS.grep(%r{\A(ext|crates)/})).to be_empty
      expect(described_class.scan_files(repo_root).grep(/\.rs\z/)).to be_empty
    end

    it "covers the runtime Lua, which is inside lib/ but carries its own comment syntax" do
      files = described_class.scan_files(repo_root)

      expect(files).to include(a_string_matching(%r{lib/lain/frontend/neovim/runtime/.*\.lua\z}))
    end
  end
end
