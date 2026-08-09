# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# The exe half of this card, `load`ed the way `spec/lain/cli_spec.rb` loads it:
# the script ends in `LainCLI.start(ARGV)` guarded by `$PROGRAM_NAME ==
# __FILE__`, so this defines the Thor classes without parsing rspec's ARGV.
# Needed here because Thor validates an `enum:` BEFORE it dispatches, so the
# `--scope` list is a scope vocabulary of its own and the one most easily left
# behind -- `lain review --scope by_directory` was exactly that failure.
load File.expand_path("../../../exe/lain", __dir__)

# `lain survey PATH`: the third source reached from a command line.
#
# Nothing is doubled. The filesystem, the classifier, the walk, the projection,
# the corpus, the session and the journal are all real, because what this card
# ships is the wiring BETWEEN them -- a double anywhere in that chain would test
# the double. The one thing arranged rather than found is `$HOME`, which is
# injected at a path nothing here creates so no example can reach the
# developer's own dotfiles.
RSpec.describe Lain::CLI::Survey, :seam do
  around do |example|
    Dir.mktmpdir("lain-survey-cli") do |made|
      @tmp = File.realpath(made)
      @root = File.join(@tmp, "corpus")
      @home = File.join(@tmp, "home")
      @state = File.join(@tmp, "state")
      FileUtils.mkdir_p([@root, @home, @state])
      example.run
    end
  end

  # XDG and HOME injected rather than exported: the round journals a
  # `changeset_opened`, and it must land in a directory this example owns.
  def paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => @state, "HOME" => @home })

  # `cwd:` is the surveyed tree rather than the process's own directory, so the
  # `[sensitivity]` table this reads is one no example can be surprised by.
  def command(**overrides) = described_class.new(paths:, cwd: @root, **overrides)

  def write(relative, body)
    File.join(@root, relative).tap do |path|
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, body)
    end
  end

  def document(*lines) = "#{lines.join("\n")}\n"

  # Two ordinary prose files, which is the shape a survey is FOR.
  def two_documents
    write("notes.md", document("# Notes", "", "One line of prose.", "Another line of prose."))
    write("guide.md", document("# Guide", "", "A guide to the notes.", "With a second line."))
  end

  # What the round left in the experiment record: `source` names WHICH source
  # produced the changeset, so it is how an example reads the wiring back
  # without asking the command what it built.
  def opened_records
    lines = Dir.glob(File.join(@state, "**", "*.ndjson")).flat_map { |file| File.readlines(file) }
    Lain::Journal.records(lines, type: Lain::Review::ChangesetOpened::JOURNAL_TYPE).to_a
  end

  def sources_journaled = opened_records.map { |record| record["source"] }

  describe "a directory surveyed as it stands" do
    before { two_documents }

    it "names every file with its review state" do
      rendered = command.present(@root)

      expect(rendered).to include("[ ] notes.md", "[ ] guide.md")
    end

    it "names the tree, the scope and how many files it listed" do
      rendered = command.present(@root)

      expect(rendered).to include(@root, "cumulative", "2 files")
    end

    it "journals the round under the corpus source" do
      command.present(@root)

      expect(sources_journaled).to eq(["corpus"])
    end

    # The output-discipline half, checked at the seam CLAUDE.md names: this
    # command RETURNS Strings and only the frontend prints.
    it "answers a String and writes nothing to stdout" do
      rendered = nil

      expect { rendered = command.present(@root) }.not_to output.to_stdout
      expect(rendered).to be_a(String)
    end

    # Its own example rather than a second matcher on the one above: each
    # `expect {}.not_to output` runs the block, so one example asserting both
    # would open two rounds and name only one of them if it failed.
    it "writes nothing to stderr either" do
      expect { command.present(@root) }.not_to output.to_stderr
    end
  end

  # The disclosure a survey owes a human, and the reason it lives here rather
  # than on a surface: `Source::Corpus#withheld` is forwarded from the walk and
  # NOTHING in `lib/` renders it yet -- a survey that quietly listed two of four
  # files would be the silent narrowing the whole boundary is written against.
  describe "the paths the walk would not hand over" do
    let(:private_key) do
      "-----BEGIN OPENSSH PRIVATE KEY-----\n" \
        "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAM0ZBS0U\n" \
        "-----END OPENSSH PRIVATE KEY-----\n"
    end

    before { two_documents }

    it "names a denied path and why it was withheld, without listing it as a file" do
      write(".netrc", "machine example.com login sam password hunter2\n")

      rendered = command.present(@root)

      expect(rendered).to include(".netrc")
      expect(rendered).not_to include("[ ] .netrc")
    end

    it "carries the classifier's own explanation rather than a paraphrase of it" do
      write(".ssh/id_rsa", private_key)
      verdict = Lain::Sensitivity.new(home: @home, cwd: @root).classify(File.join(@root, ".ssh/id_rsa"))

      expect(command.present(@root)).to include(verdict.explanation)
    end

    it "names a binary file and says that is why" do
      write("logo.png", "\x89PNG\r\n\x1A\n\x00\x00\x00\rIHDR")

      expect(command.present(@root)).to include("logo.png", Lain::Survey::Withheld::BINARY)
    end

    it "counts what it withheld, so a short listing is never silent" do
      write(".netrc", "machine example.com login sam password hunter2\n")
      write("logo.png", "\x00\x01\x02")

      expect(command.present(@root)).to include("withheld 2 paths")
    end

    it "says nothing at all about withholding when nothing was withheld" do
      expect(command.present(@root)).not_to include("withheld")
    end
  end

  describe "a path that names nothing" do
    it "refuses as a Lain::Error, naming the path" do
      missing = File.join(@tmp, "no-such-tree")

      expect { command.present(missing) }.to raise_error(Lain::Error, /#{Regexp.escape(missing)}/)
    end

    # `Boundary#render` in the exe turns a Lain::Error into a clean Thor::Error
    # and lets everything else through as a backtrace, so WHICH class it is is
    # the whole of what a human sees.
    it "refuses a file rather than surveying it, because a survey is of a tree" do
      file = write("notes.md", document("# Notes"))

      expect { command.present(file) }.to raise_error(Lain::Survey::Walk::Refused, /#{Regexp.escape(file)}/)
    end

    it "journals no round for a path it refused" do
      expect { command.present(File.join(@tmp, "no-such-tree")) }.to raise_error(Lain::Error)
      expect(opened_records).to be_empty
    end
  end

  describe "the size past which it refuses" do
    before { two_documents }

    def bounded(**ceilings) = command(bounds: Lain::Review::Bounds.new(**ceilings))

    # From the WALK, before a byte is read -- the corpus checks its file ceiling
    # in `#initialize`, so this refusal costs nothing it then throws away.
    it "refuses a tree over the file ceiling, naming the count, the ceiling and what to narrow to" do
      expect { bounded(max_files: 1).present(@root) }
        .to raise_error(Lain::Review::Bounds::TooLarge, /2 files.*ceiling of 1.*survey a subdirectory/m)
    end

    it "refuses a tree over the line ceiling too, which is the other shape" do
      expect { bounded(max_lines: 1).present(@root) }
        .to raise_error(Lain::Review::Bounds::TooLarge, /lines/)
    end

    it "journals no round when the file ceiling refuses, since the corpus never opened" do
      expect { bounded(max_files: 1).present(@root) }.to raise_error(Lain::Review::Bounds::TooLarge)

      expect(opened_records).to be_empty
    end
  end

  describe "the unbounded flag" do
    before { two_documents }

    def bounded(**ceilings) = command(bounds: Lain::Review::Bounds.new(**ceilings))

    it "presents what the FILE ceiling would have refused" do
      rendered = bounded(max_files: 1).present(@root, unbounded: true)

      expect(rendered).to include("[ ] notes.md", "[ ] guide.md")
    end

    it "presents what the LINE ceiling would have refused, so both are lifted" do
      rendered = bounded(max_lines: 1).present(@root, unbounded: true)

      expect(rendered).to include("[ ] notes.md", "[ ] guide.md")
    end

    # `/critique` chunking keeps its ceiling regardless of what a human is
    # willing to scroll, so the flag lifts two of the three and carries the
    # third through untouched. Asserted on the transformation itself, because
    # nothing on the presentation path reads it and an example that could not
    # tell a lifted ceiling from a kept one would pass either way.
    describe ".unbounded" do
      let(:kept) { Lain::Review::Bounds.new(max_critique_lines: 4242) }

      it "lifts the file ceiling" do
        expect(described_class.unbounded(kept).max_files).to be(Lain::Review::Bounds::UNBOUNDED)
      end

      it "lifts the line ceiling" do
        expect(described_class.unbounded(kept).max_lines).to be(Lain::Review::Bounds::UNBOUNDED)
      end

      it "leaves the critique ceiling exactly as it was given" do
        expect(described_class.unbounded(kept).max_critique_lines).to eq(4242)
      end
    end
  end

  describe "the scope the flag picks" do
    before { two_documents }

    it "presents one flat table by default" do
      expect(command.present(@root)).to include("[ ] notes.md")
    end

    # The absent flag goes through the SAME resolution an explicit one does, so
    # the default is named by the registry rather than by a literal here.
    it "resolves the absent flag to the registry's own default" do
      expect(command.present(@root)).to include(Lain::Review::Partition::DEFAULT_SCOPE)
    end

    it "renders the absent flag exactly as the registry's default rendered explicitly" do
      expect(command.present(@root)).to eq(command.present(@root, scope: Lain::Review::Partition::DEFAULT_SCOPE))
    end

    # THE AC, proved by construction rather than merely observed. The two
    # examples above compare against the registry's default and pass just as
    # well against `def default_scope = :cumulative` -- a restated literal that
    # happens to agree today, which is exactly what the card forbids. MOVING the
    # constant is the only question that separates the two, and a survey that
    # follows it cannot be reading a literal.
    #
    # A panel mutant proved the gap rather than argued it: the same-VALUE
    # literal survived all forty examples, because the earlier canary changed
    # the value (`:by_directory`) and so was killed by any value assertion.
    it "follows the registry's default WHEREVER it moves, so the word is never restated here" do
      stub_const("Lain::Review::Partition::DEFAULT_SCOPE", "by_directory")

      expect(command.present(@root)).to eq(command.present(@root, scope: "by_directory"))
    end

    it "presents the directory grouping when it is asked for" do
      write("deep/inner.md", document("# Inner", "", "A file one directory down."))

      expect(command.present(@root, scope: "by_directory")).to include("by_directory", "deep")
    end

    it "refuses a scope the registry does not declare, naming what it was given" do
      expect { command.present(@root, scope: "cumulatve") }
        .to raise_error(Lain::Review::Session::UnknownScope, /cumulatve/)
    end

    # Applicability is a SEPARATE, later refusal than "is this a scope at all":
    # `ByCommit#supports?` asks the source, and a corpus has no walk to group by.
    it "refuses the commit walk over a corpus, naming the scope and the source" do
      expect { command.present(@root, scope: "commits") }
        .to raise_error(Lain::Review::Session::UnsupportedScope, /commits.*corpus/m)
    end

    it "names the scopes a corpus DOES present, so the refusal is actionable" do
      expect { command.present(@root, scope: "commits") }
        .to raise_error(Lain::Review::Session::UnsupportedScope, /cumulative/)
    end

    it "resolves a typo'd scope before the round is journaled, so a refusal opens nothing" do
      expect { command.present(@root, scope: "cumulatve") }.to raise_error(Lain::Review::Session::UnknownScope)

      expect(opened_records).to be_empty
    end

    # BEFORE THE WALK, which is a stronger claim than the one above and needs a
    # tree the walk itself would refuse to separate them: `Corpus#initialize`
    # consults the walk, so resolving the scope one line later still journals
    # nothing and still passes that example -- while the human with a typo is
    # told to narrow their tree.
    #
    # SUBJECT  UnknownScope: scope must be one of [...], got "cumulatve"
    # MUTANT   TooLarge: this corpus is 2 files, over the ceiling of 1 -- survey a subdirectory...
    it "resolves a typo'd scope before it walks, so the refusal is the typo and not the tree" do
      oversized = command(bounds: Lain::Review::Bounds.new(max_files: 1))

      expect { oversized.present(@root, scope: "cumulatve") }
        .to raise_error(Lain::Review::Session::UnknownScope, /cumulatve/)
    end
  end

  describe "the surface it presents through" do
    before { two_documents }

    # Six messages at the port's own shapes, because `Surface.check!` refuses
    # anything else -- an `instance_spy` included.
    def refusing_surface(refusal)
      Class.new do
        define_method(:present) { |_changeset, scope:| "#{refusal} (#{scope})" }
        def annotate(_anchor, _text, kind:) = kind
        def mark(_hunk_key, _state) = nil
        def thread(_anchor) = nil
        def verdict = nil
        def refuse(message) = message
      end.new
    end

    it "hands an injected surface's own refusal back rather than a rendering of its own" do
      rendered = command(surface: refusing_surface("the editor is detached")).present(@root)

      expect(rendered).to include("the editor is detached (cumulative)")
    end

    it "still names the survey above an injected surface's refusal" do
      expect(command(surface: refusing_surface("detached")).present(@root)).to include(@root)
    end

    it "refuses a surface that does not answer the port, before anything is journaled" do
      expect { command(surface: Object.new).present(@root) }
        .to raise_error(Lain::Review::Surface::Incomplete, /present/)
      expect(opened_records).to be_empty
    end
  end

  # The escalation trigger, discharged rather than asserted once: `Boundary#render`
  # turns ONLY a Lain::Error into a clean Thor::Error, and anything else reaches
  # the user as a backtrace. So every refusal this command can emit is driven
  # here, in one place, and asked what it is.
  describe "every refusal it can emit" do
    def refusal_from
      yield
      raise "expected a refusal, and nothing was raised"
    rescue StandardError => e
      e
    end

    it "raises only Lain::Errors, whatever the human got wrong" do
      two_documents
      refusals = [
        -> { command.present(File.join(@tmp, "absent")) },
        -> { command.present(@root, scope: "cumulatve") },
        -> { command.present(@root, scope: "commits") },
        -> { command(bounds: Lain::Review::Bounds.new(max_files: 1)).present(@root) },
        -> { command(surface: Object.new).present(@root) }
      ].map { |attempt| refusal_from(&attempt) }

      expect(refusals).to all(be_a(Lain::Error))
      expect(refusals.map(&:message)).to all(satisfy { |message| !message.strip.empty? })
    end
  end

  # A survey does not need a repository, and this is the half that says so. Every
  # fixture here is a plain `mktmpdir` -- `git ls-files` has no answer in one, so
  # the walk globs -- and the round still journals: `Paths#sessions_dir` keys on
  # a digest of the process directory and does not care whether it is a
  # repository.
  describe "a tree that is not a repository" do
    before { two_documents }

    it "surveys it all the same, from the glob rather than from git" do
      expect(command.present(@root)).to include("[ ] notes.md")
    end

    it "journals the round into this project's sessions directory all the same" do
      command.present(@root)

      expect(Dir.glob(File.join(paths.sessions_dir, "*.ndjson"))).not_to be_empty
    end
  end
end

# The exe half. Thor owns the first word, so `lain survey ./docs` only reaches
# the lib at all through `default_command`, and Thor validates an `enum:` before
# it dispatches -- both are wiring nothing in `lib/` can pin.
#
# The BODY is driven too, and not only the metadata: `options[:scope]&.to_sym`
# and `options[:unbounded]` are the two coercions between argv and the lib, and
# a body hardcoding the wrong thing passes every metadata assertion there is.
# `.start` with `debug: true` throughout -- Thor renders a refusal as `exit(1)`,
# RSpec does not rescue SystemExit inside an example, and a truncated run
# reports what had already passed as a pass.
RSpec.describe LainCLI, "the survey subcommand" do
  def survey_command = LainCLI::Survey.commands.fetch("open")

  it "routes a bare PATH through the default command, so a path is never read as a command name" do
    expect(LainCLI::Survey.default_command).to eq("open")
  end

  it "offers every registered strategy on --scope, so shipping one is all it takes to reach it" do
    expect(survey_command.options.fetch(:scope).enum)
      .to match_array(Lain::Review::Partition::STRATEGIES.values.map(&:name))
  end

  it "offers nothing on --scope the registry would then refuse" do
    expect { survey_command.options.fetch(:scope).enum.each { Lain::Review::Session.scope!(_1) } }
      .not_to raise_error
  end

  it "declares --unbounded as a boolean, so it is a word a human says and not a number" do
    expect(survey_command.options.fetch(:unbounded).type).to eq(:boolean)
  end

  it "is reachable as a subcommand of the executable" do
    expect(described_class.subcommand_classes["survey"]).to be(LainCLI::Survey)
  end

  # What argv MEANS by the time the lib sees it. Doubled at the command class
  # rather than at the filesystem, because the two coercions are the whole
  # subject here and a real survey would answer the same String whichever
  # arguments reached it.
  describe "what the command body hands the lib" do
    let(:survey) { instance_double(Lain::CLI::Survey, present: "drawn") }

    before { allow(Lain::CLI::Survey).to receive(:new).and_return(survey) }

    def start(*argv) = expect { described_class.start(argv, debug: true) }.to output(/drawn/).to_stdout

    it "hands the scope over as a Symbol, which is what Session.scope! and every surface dispatch on" do
      start("survey", "/some/tree", "--scope", "by_directory")

      expect(survey).to have_received(:present).with("/some/tree", scope: :by_directory, unbounded: false)
    end

    it "hands over a nil scope when the flag is absent, so the LIB resolves the default" do
      start("survey", "/some/tree")

      expect(survey).to have_received(:present).with("/some/tree", scope: nil, unbounded: false)
    end

    it "hands the unbounded flag over as true when a human says the word" do
      start("survey", "/some/tree", "--unbounded")

      expect(survey).to have_received(:present).with("/some/tree", scope: nil, unbounded: true)
    end
  end

  # The whole path, undoubled, once: argv in, a rendering on stdout. `render`
  # is the only thing between the lib's String and the terminal, and nothing
  # above pins that it says anything at all.
  describe "a real survey through the executable" do
    around do |example|
      Dir.mktmpdir("lain-survey-exe") do |made|
        @tree = File.realpath(made)
        File.write(File.join(@tree, "notes.md"), "# Notes\n\nOne line of prose.\n")
        # HOME and XDG injected for the round this really journals: the exe
        # builds its own `Paths`, and a spec must not write into the developer's
        # own sessions directory.
        with_env("HOME" => File.join(@tree, "home"), "XDG_STATE_HOME" => File.join(@tree, "state")) { example.run }
      end
    end

    it "says what the lib drew, from argv all the way to stdout" do
      expect { described_class.start(["survey", @tree], debug: true) }
        .to output(/\[ \] notes\.md/).to_stdout
    end

    it "takes the scope from argv, so --scope reaches the grouping and not just the enum" do
      expect { described_class.start(["survey", @tree, "--scope", "by_directory"], debug: true) }
        .to output(/by_directory/).to_stdout
    end
  end
end
