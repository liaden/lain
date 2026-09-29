# frozen_string_literal: true

require "fileutils"
require "json"
require "neovim"
require "stringio"
require "tmpdir"

# `/survey <path>`: the repl command that puts a human in front of a
# CORPUS inside the cockpit they already have open.
#
# This is the surface a survey is actually read and marked in, so it is not a
# thinner variant of `spec/lain/cli/survey_spec.rb` -- it carries the same two
# flags, and every difference from the one-shot command is a difference in what
# it is wired TO: the chat's own journal, the editor's own surface, and the
# gesture rails a human's `<CR>` arrives on.
#
# Nothing between the command and the filesystem is doubled. The tree, the
# classifier, the walk, the projection, the corpus and the session are all real,
# because what this card ships is the wiring between them and a double anywhere
# in that chain would test the double. `$HOME` is injected at a path nothing here
# creates, so no example can reach the developer's own dotfiles.

# The editor rail. {Lain::Frontend::Neovim::CommandInbox}'s duck, reduced to what
# {Lain::CLI::HumanReplies} asks of one. Its own class rather than the one
# `command/review_spec.rb` declares -- that file is one `parallel_tests` may hand
# to another worker entirely.
class SurveyCommandRail
  def initialize = (@refusals = [])

  attr_reader :refusals

  def push(*) = nil
  def pop(*) = nil
  def review_refused(message) = @refusals << message
  def attached? = true
end

# The surface at the port's own eight messages, recording WHAT THE EDITOR HAD
# ALREADY BEEN BOUND when it was told to present. That recording is the whole of
# the bind-before-draw claim: a command that drew first and bound afterwards
# renders identically and marks identically, and only the order tells them apart.
class SurveyOrderSurface
  def initialize(editor) = (@editor = editor)

  attr_reader :bound_when_drawn, :focused

  def present(_changeset, scope:)
    @bound_when_drawn = @editor.bound
    scope && nil
  end

  # Recorded, not discarded: `focus` must land AFTER the draw, and a stand-in
  # that answered nil could not tell "focused once, last" from "never focused".
  def focus = (@focused = (@focused || 0) + 1)

  def annotate(_anchor, _text, kind:) = kind
  def mark(_hunk_key, _state) = nil
  def thread(_anchor) = nil
  def verdict = nil
  def settle(_verdict) = nil
  def refuse(message) = message
end

# The editor's render inlet at the four rails a review surface posts on, keeping
# every `set_thread` payload. The thread rail is the whole of the assertion in
# the docent examples below: a question's answer arrives there and nowhere else,
# long after the gesture that asked, so a recording of that rail is the only
# thing that can tell an answer that was DRAWN from one that was merely computed.
class SurveyDocentInlet
  def initialize = (@threads = [])

  attr_reader :threads

  def set_review(_lines, _generation, _sides) = nil
  def review_focus = nil
  def review_refused(_message) = nil
  def set_thread(anchor, lines) = @threads << [anchor, lines]
end

# The frontend, reduced to the three messages {Lain::CLI::HumanReplies} asks of
# one. The surface is the REAL text surface and the view the REAL sidebar view,
# for `command/review_spec.rb`'s reason: what is under test is whether the
# command reaches THESE, and a double answering the port would be
# indistinguishable from {Lain::Review::Surface::Null}.
class SurveyCommandEditor
  def initialize(sink, surface: nil)
    @view = Lain::Frontend::Neovim::ReviewView.new
    @surface = surface || Lain::Review::Surface::Text.new(sink:)
  end

  attr_reader :bound

  def review_surface = @surface
  def review_view = @view
  def bind_changeset_review(review) = @bound = review
end

RSpec.describe Lain::CLI::Command::Survey do
  # `cwd:` is stated rather than defaulted, and it is the corpus tree because
  # THIS chat is standing in the tree it surveys. It is a separate question from
  # `root:` ({Lain::Project} splits them) and it decides what a surveyed file is
  # NAMED -- the editor resolves a row against the directory it was started in,
  # so a name is only openable if it is relative to where the chat stands. Left
  # to its `Dir.pwd` default the fixture would name every file by a `..` climb
  # out of the repository and into a tmpdir, which is correct and unreadable.
  let(:command) { described_class.new(cwd: @root, outbox:, ledger:, sensitivity:) }

  # The run's ONE region ledger, injected because {Lain::Sensitivity::Ledger}'s
  # own class doc makes that rule 1 of three and "a raise rather than a note": a
  # defaulted ledger lets a forgotten injection become a SECOND one whose
  # releases nobody ever sees, so a released region would still render
  # `<redacted:N>` in the survey with every object present and nothing wrong to
  # look at.
  let(:ledger) { Lain::Sensitivity::Ledger.new }

  # The run's ONE path classifier, injected for the ledger's reason one
  # boundary over: the chat's board compiles the `[sensitivity]` table once and
  # every reader of it holds THAT object, so a survey cannot list a path the
  # gate beside it refuses. A real one over the real tree, never a double --
  # what the walk asks it is the whole of what a withheld path means. HOME is
  # injected at a path nothing here creates, so its home-anchored rules cannot
  # reach the developer's own dotfiles.
  let(:sensitivity) { Lain::Sensitivity.new(home: @home, cwd: @root) }

  # The REAL outbox the chat's other review command reads, never a spy: what has
  # to be true is that the round THIS command opened is the round the rest of the
  # chat can see, and a recording double could only say `hold` was called.
  let(:outbox) { Lain::Review::Submit::Outbox.new }
  let(:sink) { StringIO.new }
  let(:record) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: record) }
  let(:rail) { SurveyCommandRail.new }
  let(:editor) { SurveyCommandEditor.new(sink) }
  let(:questions) { Async::Queue.new }

  # The run's real reply router: the object that owns both the acked-gesture
  # table and `bind_changeset_review`, so nothing between the command and the
  # rails is a double.
  let(:replies) do
    Lain::CLI::HumanReplies.new(tty: instance_double(Lain::Frontend::TTY),
                                conductor: instance_double(Lain::CLI::Conductor),
                                ask_human: instance_double(Lain::Tools::AskHuman::Directory),
                                questions:)
  end

  # `journal_path: nil` is a chat recording to no file, so it resumed nothing.
  let(:chronicle) { instance_double(Lain::CLI::Chronicle, record_journal: journal, journal_path: nil) }
  let(:env) { build_command_env(replies:, chronicle:) }

  around do |example|
    Dir.mktmpdir("lain-command-survey") do |made|
      @tmp = File.realpath(made)
      @root = File.join(@tmp, "corpus")
      @home = File.join(@tmp, "home")
      FileUtils.mkdir_p([@root, @home])
      example.run
    end
  end

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

  # An editor attached, exactly as {Lain::CLI::Repl#run} attaches one.
  def attached
    replies.bind_editor(rail)
    replies.bind_review_editor(editor)
  end

  # THE LAST LINK, and the one this chunk has missed before: a command that works
  # and is registered, against a line a human actually types. A path with a
  # leading `./` and a flag after it both have to survive {Skill::Invocation}'s
  # grammar with the path intact -- a dispatcher that swallowed either would hand
  # this command an empty line and get its usage back, looking for all the world
  # like the human mistyped.
  describe "the line a human types, through the registry that dispatches it" do
    let(:registry) { Lain::CLI::Command::Registry.new([command]).bind(env) }

    it "reaches the command with its path and its flags intact" do
      two_documents
      attached

      answer = registry.dispatch("/survey #{@root} --scope by_directory") { raise "fallthrough must not run" }

      expect(answer).to include(@root).and include("by_directory")
    end
  end

  describe "what it refuses before it opens anything" do
    # Both sides call the same method, so this says the two AGREE and nothing
    # about what either contains -- dropping the `format` ships the raw
    # `[--scope %<scopes>s]` template to a human's chat and still passes. The
    # example below is what closes that.
    it "answers its own usage when no path was named" do
      expect(command.call("", env)).to eq(command.usage)
    end

    # What the sentence actually SAYS, against the registry rather than a
    # literal: every registered strategy is advertised, and the template was
    # filled in rather than shipped raw.
    it "advertises every registered scope, with the template resolved" do
      expect(command.usage).to include(*Lain::Review::Partition::STRATEGIES.keys.map(&:to_s))
      expect(command.usage).not_to include("%<")
    end

    it "advertises the unbounded flag, so the parity with the one-shot command is discoverable" do
      expect(command.usage).to include("--unbounded")
    end

    # The one refusal that is about the PROCESS rather than the tree, and the
    # reason it comes first: a headless chat that drew a survey into
    # {Lain::Review::Surface::Null} would report a survey nobody can read.
    it "refuses when no editor is attached, rather than drawing into a null surface" do
      two_documents

      expect { command.call(@root, env) }.to raise_error(Lain::Error, /no editor/)
    end

    it "names the flag that attaches an editor, because that is what the human can do about it" do
      two_documents

      expect { command.call(@root, env) }.to raise_error(Lain::Error, /--nvim/)
    end

    # {Lain::Sensitivity::Ledger}'s rule 1, stated there as "a raise rather than
    # a note": a forgotten injection must be an ArgumentError at wiring time,
    # because the alternative is a SECOND ledger holding releases nobody ever
    # sees -- a released region still rendering `<redacted:N>` with every object
    # present and nothing about the wiring looking wrong.
    it "refuses to construct without the run's region ledger, rather than minting one of its own" do
      expect { described_class.new(outbox:, sensitivity:) }
        .to raise_error(ArgumentError, /ledger/)
    end

    # The same rule for the other collaborator the run has exactly one of, and
    # the failure it keeps out is worse than a duplicate: a survey that built
    # its own classifier would re-read `.lain/config.toml` LATER than the board
    # did, so a config edited mid-session would have the listing enumerating
    # paths the gate beside it still refuses -- both halves working, neither
    # wrong to look at, and the boundary narrowed in silence.
    it "refuses to construct without the run's classifier, rather than compiling a second table" do
      expect { described_class.new(outbox:, ledger:) }
        .to raise_error(ArgumentError, /sensitivity/)
    end

    it "refuses a flag it does not carry, rather than reading it as a path" do
      attached

      expect { command.call("#{@root} --squash", env) }
        .to raise_error(Lain::Error, /--squash is not a flag/)
    end

    # A DECLARED flag with an unreadable value is not an unreadable flag, and
    # the difference is what the human does next: told "--scope is not a flag
    # /survey can read", they delete the one word they got right.
    it "says a declared flag was given no value, rather than calling it a flag it cannot read" do
      attached

      expect { command.call("#{@root} --scope", env) }
        .to raise_error(Lain::Error, /--scope takes a value/)
    end

    it "keeps that wording off a flag it genuinely does not declare" do
      attached

      expect { command.call("#{@root} --squash", env) }
        .to raise_error(Lain::Error) { |refusal| expect(refusal.message).not_to include("takes a value") }
    end

    # The switch is what makes this more than pedantry: `--scope --unbounded`
    # reads as "scope is --unbounded" under any parse that takes the next word
    # whatever it is, and that resolves to an UnknownScope naming a flag the
    # human spelled correctly.
    it "refuses a flag whose value is itself a flag, rather than surveying at scope --unbounded" do
      attached

      expect { command.call("#{@root} --scope --unbounded", env) }
        .to raise_error(Lain::Error, /--scope takes a value/)
    end

    # {Lain::Survey::Walk}'s own refusal, reached rather than restated.
    it "hands back the walk's own refusal for a path that names nothing" do
      attached
      missing = File.join(@tmp, "no-such-tree")

      expect { command.call(missing, env) }
        .to raise_error(Lain::Survey::Walk::Refused, /#{Regexp.escape(missing)}/)
    end

    # An extra word past the path used to vanish with no refusal at all,
    # silently surveying the path alone.
    it "refuses an extra word after the path, naming it" do
      two_documents
      attached

      expect { command.call("#{@root} something", env) }
        .to raise_error(Lain::Error, /something/)
    end

    # {Command::Survey} shares {Lain::CLI::Command::Args} with `/review`: a
    # Hash keyed by flag name silently kept the last of two, so a human who
    # retyped `--scope` reading a typo never learned the first one was thrown
    # away.
    it "refuses a flag given twice, rather than quietly keeping the last" do
      two_documents
      attached

      expect { command.call("#{@root} --scope by_directory --scope by_extension", env) }
        .to raise_error(Lain::Error, /--scope was given more than once/)
    end

    # A directory whose name has a space could not be surveyed at all before
    # {Lain::CLI::Command::Args} started splitting with {Shellwords}.
    it "surveys a directory whose name has a space when the line quotes it" do
      spaced = write("my notes/page.md", document("# Notes", "", "One line of prose."))
      attached

      answer = command.call(%("#{File.dirname(spaced)}"), env)

      expect(answer).to include("1 file")
    end

    # Nothing may be bound and nothing journaled by a call that refused: a review
    # the human cannot answer is worse than no review, and a rail still holding
    # the last one would route their next verdict to it.
    it "binds no review and journals nothing when the path does not resolve" do
      attached

      expect { command.call(File.join(@tmp, "no-such-tree"), env) }.to raise_error(Lain::Error)
      expect(editor.bound).to be_nil
      expect(record.string).to be_empty
      expect(outbox).not_to be_open
    end
  end

  describe "opening a survey in the editor the chat already has" do
    before { two_documents }

    it "draws the tree on the editor's own surface and says what it opened" do
      attached

      answer = command.call(@root, env)

      expect(sink.string).to include("notes.md", "guide.md")
      expect(answer).to include(@root).and include("2 files")
    end

    it "says where the human reads it and which gestures reach it" do
      attached

      expect(command.call(@root, env)).to include("lain://review")
    end

    # The banner used to name `:LainReviewDone`, a PROTOCOL-5 EPIC command
    # whose guard (`runtime/65_review.lua:93-98`) requires
    # `b:lain_review_epic_slug` -- a variable a survey never stamps, so the
    # guard could never pass. This is the command a survey's own hand-back
    # actually reaches: `:LainReviewVerdict {verdict}`
    # (`runtime/46_sidebar.lua:188`, protocol 10). Pinned by NAME and not just
    # by "does not say LainReviewDone", because a banner that dropped the
    # hand-back gesture entirely would pass a merely negative assertion.
    # {Lain::Review::OpenedBanner} owns the wording now; this example is what
    # proves {Command::Survey} actually reads it.
    it "names the command a survey's hand-back actually reaches, not the epic surface's" do
      attached

      answer = command.call(@root, env)

      expect(answer).to include(":LainReviewVerdict #{Lain::Review::VERDICTS.first}")
      expect(answer).not_to include("LainReviewDone")
    end

    # The other half of the same sentence: ":LainNote
    # annotates" is unchanged, because `:LainNote` is what a `<CR>` on a survey
    # row actually opens into -- {Lain::Frontend::Neovim::ChangesetDiff} draws
    # every corpus file as a diff whose old side is `[]` (an ADDED file, never
    # `nil`, {Lain::Review::Changeset#old_side}'s documented distinction), so
    # `open_changeset` still stamps the buffer `:LainNote` reads
    # (`runtime/47_diff.lua`'s `review_diff.stamp`). Proved end to end against
    # a real editor in "the survey banner's commands, against a real editor"
    # below, rather than assumed here.
    it "still names :LainNote, unlike the hand-back verb beside it" do
      attached

      expect(command.call(@root, env)).to include(":LainNote annotates")
    end

    # {Lain::Review::OpenedBanner} owns how many motions a round's banner
    # teaches; this is what proves THIS command hands it the round to decide
    # from. A survey draws `sidebar | file`, so the second `<C-w>l` the two-hop
    # motion carries would take a human out of the layout -- and the banner is
    # the documented way in (`planning/survey-dogfood-2026-08-25.md:68`), so
    # the overshoot is a human following instructions into nothing.
    #
    # The NEGATIVE is the load-bearing half: `<C-w>l<C-w>l` contains `<C-w>l`,
    # so the positive assertion alone passes on the unchanged two-hop string.
    it "teaches the one-window motion a survey's own layout has, not the changeset review's two" do
      attached

      answer = command.call(@root, env)

      expect(answer).to include("<C-w>l reaches the file where :LainNote annotates")
      expect(answer).not_to include("<C-w>l<C-w>l")
    end

    # The survey is part of the chat's RECORD, not a second journal beside it:
    # `/survey` inside a cockpit is one session, and a round opened in another
    # file could never be resumed from the session the human was in.
    it "opens the round in the chat's own journal, under the corpus source" do
      attached

      command.call(@root, env)

      expect(record.string).to include("changeset_opened").and include("corpus")
    end

    it "hands the editor's write rail the review it just opened" do
      attached

      command.call(@root, env)

      expect(editor.bound).to be_a(Lain::Review::Handover)
      expect(editor.bound.session.changeset.files.map { |file| file.path.to_s }).to include("notes.md")
    end

    # The DEFAULTED `cwd:`, which every other example here states and which a
    # caller building this command by hand gets. It has to be the working
    # directory and not `root:`, because it decides what a surveyed file is
    # NAMED and the editor resolves that name against the directory it was
    # started in. Built inside the `chdir` because the default is evaluated at
    # construction ({Lain::CLI::EpicMount}'s spec drives its own the same way),
    # and `root:` deliberately points somewhere else so the two cannot be
    # confused: defaulted to the root, every name here would begin `corpus/`.
    it "names files from the working directory when nobody says where the chat stands" do
      two_documents
      attached
      defaulted = Dir.chdir(@root) { described_class.new(outbox:, ledger:, sensitivity:) }

      defaulted.call(@root, env)

      expect(editor.bound.session.changeset.files.map { |file| file.path.to_s }).to eq(%w[guide.md notes.md])
    end

    # THE ORDERING AC. The bind must be complete before the surface is told
    # anything, {Lain::Tools::RequestReview::Implementation#tell}'s rule: a human
    # fast enough to press `<CR>` between the two would otherwise send a gesture
    # nothing could route.
    it "binds the gesture rails BEFORE the surface is told to draw" do
      surface = SurveyOrderSurface.new(nil)
      recording = SurveyCommandEditor.new(sink, surface:)
      surface.instance_variable_set(:@editor, recording)
      replies.bind_editor(rail)
      replies.bind_review_editor(recording)

      command.call(@root, env)

      expect(surface.bound_when_drawn).to be_a(Lain::Review::Handover)
    end

    # `41_layout.lua` builds the review tabpage and draws into it without ever
    # going there, because the ONE entry point that takes focus was reachable
    # from Lua and called by nothing in Ruby. So a `/survey` drew a survey the
    # human then had to go and find.
    it "puts the human in front of the survey it drew" do
      surface = SurveyOrderSurface.new(nil)
      recording = SurveyCommandEditor.new(sink, surface:)
      surface.instance_variable_set(:@editor, recording)
      replies.bind_editor(rail)
      replies.bind_review_editor(recording)

      command.call(@root, env)

      expect(surface.focused).to eq(1)
    end

    # ONCE, and only for a survey that DREW. A ceiling refusal raises out of
    # `Session#present`, and a human yanked into a tabpage holding nothing is
    # worse off than one left where they were reading the refusal.
    it "does not focus a survey that refused before it drew" do
      surface = SurveyOrderSurface.new(nil)
      recording = SurveyCommandEditor.new(sink, surface:)
      surface.instance_variable_set(:@editor, recording)
      replies.bind_editor(rail)
      replies.bind_review_editor(recording)
      bounded = described_class.new(outbox:, cwd: @root, ledger:, sensitivity:,
                                    bounds: Lain::Review::Bounds.new(max_files: 1))

      expect { bounded.call(@root, env) }.to raise_error(Lain::Error)

      expect(surface.focused).to be_nil
    end

    # A survey is a round with nowhere to post, which is not the same as no round
    # at all -- so it is HELD, and `/review-submit` says what is wrong rather
    # than "no changeset review is open" about one that plainly is.
    it "holds the round in the run's outbox, named as a survey" do
      attached

      command.call(@root, env)

      expect(outbox).to be_open
      expect(outbox.target).to include(@root)
    end

    it "answers Nowhere rather than NotOpen when a human tries to post a survey" do
      attached

      command.call(@root, env)

      expect { outbox.submit(executor: instance_double(Lain::Forge::Gh)) }
        .to raise_error(Lain::Review::Submit::Outbox::Nowhere, /#{Regexp.escape(@root)}/)
    end

    # The whole sentence, not a fragment: a survey is not a branch, and the
    # refusal must not call it one. The label already names the
    # survey and its path, so the sentence adds no second noun.
    it "names the survey and its path, never calls it a branch, and still points at the remedy" do
      attached

      command.call(@root, env)
      label = outbox.target

      expect(label).to include("survey of", @root)

      expect { outbox.submit(executor: instance_double(Lain::Forge::Gh)) }.to raise_error(
        Lain::Review::Submit::Outbox::Nowhere,
        "this review was opened on #{label}, which has no pull request to post a review " \
        "to -- the annotations and the verdict are on the journal either way. Run `/review <pull-request>` " \
        "against the pull request itself to post one."
      )
    end

    # The disclosure `lain survey` owes a human, owed identically here: a listing
    # short by one file with no word about why is the silent narrowing the whole
    # secret boundary is written against, and a cockpit that discloses less than
    # the one-shot command is the parity bug this card exists against.
    it "names what the walk would not hand over, and counts it" do
      attached
      write(".netrc", "machine example.com login sam password hunter2\n")

      answer = command.call(@root, env)

      expect(answer).to include(".netrc").and include("withheld 1 path")
      expect(sink.string).not_to include(".netrc")
    end

    it "says nothing at all about withholding when nothing was withheld" do
      attached

      expect(command.call(@root, env)).not_to include("withheld")
    end
  end

  describe "the scope the flag picks" do
    before { two_documents }

    it "presents the directory grouping when it is asked for" do
      attached
      write("deep/inner.md", document("# Inner", "", "A file one directory down."))

      answer = command.call("#{@root} --scope by_directory", env)

      expect(answer).to include("by_directory")
      expect(sink.string).to include("deep")
    end

    it "refuses a scope the registry does not declare, naming what it was given" do
      attached

      expect { command.call("#{@root} --scope cumulatve", env) }
        .to raise_error(Lain::Review::Session::UnknownScope, /cumulatve/)
    end

    # Applicability is a SEPARATE, later refusal than "is this a scope at all":
    # `ByCommit#supports?` asks the source, and a corpus has no commit walk.
    it "refuses the commit walk over a corpus, naming the scope and the source" do
      attached

      expect { command.call("#{@root} --scope commits", env) }
        .to raise_error(Lain::Review::Session::UnsupportedScope, /commits.*corpus/m)
    end

    # THE AC, proved by construction rather than merely observed. A restated
    # literal that happens to agree today passes any assertion about the VALUE --
    # a review panel killed a `:by_directory` canary with exactly such an assertion
    # and learned nothing. MOVING the constant is the only question that
    # separates a command reading the registry from one reading a literal.
    it "follows the registry's default WHEREVER it moves, so the word is never restated here" do
      attached
      stub_const("Lain::Review::Partition::DEFAULT_SCOPE", "by_directory")

      expect(command.call(@root, env)).to include("by_directory")
    end

    # BEFORE THE WALK, and it takes a tree the WALK ITSELF refuses to say so: a
    # canary that merely moved the resolution past `Walk.new` survived every
    # other example in this file, because the ceiling that refuses a big tree is
    # checked later still, in `Corpus#initialize`. A human who typed a path
    # wrong AND a scope wrong must be told about the scope they typed, not sent
    # hunting a directory.
    #
    # SUBJECT  UnknownScope: scope must be one of [...], got "cumulatve"
    # MUTANT   Walk::Refused: /tmp/.../no-such-tree is not a directory ...
    it "resolves a typo'd scope before it walks, so the refusal is the typo and not the path" do
      attached

      expect { command.call("#{File.join(@tmp, "no-such-tree")} --scope cumulatve", env) }
        .to raise_error(Lain::Review::Session::UnknownScope, /cumulatve/)
    end

    # And before the tree is MEASURED, which is the second half of the same
    # ordering: `Corpus#initialize` checks the file ceiling from the walk alone,
    # so a resolution one line further down tells a human with a typo to narrow
    # their tree.
    #
    # SUBJECT  UnknownScope: scope must be one of [...], got "cumulatve"
    # MUTANT   TooLarge: this corpus is 2 files, over the ceiling of 1 -- ...
    it "resolves a typo'd scope before the tree is measured, so the refusal is the typo and not the size" do
      attached
      oversized = described_class.new(outbox:, ledger:, sensitivity:,
                                      bounds: Lain::Review::Bounds.new(max_files: 1))

      expect { oversized.call("#{@root} --scope cumulatve", env) }
        .to raise_error(Lain::Review::Session::UnknownScope, /cumulatve/)
    end
  end

  describe "the ceilings, and the flag that lifts them" do
    before { two_documents }

    def bounded(**ceilings)
      described_class.new(outbox:, ledger:, sensitivity:,
                          bounds: Lain::Review::Bounds.new(**ceilings))
    end

    it "refuses a tree past the file ceiling, in Bounds' own words" do
      attached

      expect { bounded(max_files: 1).call(@root, env) }
        .to raise_error(Lain::Review::Bounds::TooLarge, /2 files.*ceiling of 1/m)
    end

    it "draws nothing into the editor when it refuses, so no sidebar claims to hold the corpus" do
      attached

      expect { bounded(max_files: 1).call(@root, env) }.to raise_error(Lain::Review::Bounds::TooLarge)

      expect(sink.string).to be_empty
    end

    it "presents what the file ceiling would have refused when a human says --unbounded" do
      attached

      bounded(max_files: 1).call("#{@root} --unbounded", env)

      expect(sink.string).to include("notes.md", "guide.md")
    end

    it "lifts the LINE ceiling too, so both of the two are lifted and not just the first" do
      attached

      bounded(max_lines: 1).call("#{@root} --unbounded", env)

      expect(sink.string).to include("notes.md", "guide.md")
    end

    # A review panel finding, checked where it can actually be wrong: `/critique`
    # packs against a context WINDOW, so a human saying they will scroll anything
    # has said nothing about how large a prompt may be. Read off the Bounds that
    # REACH `Session.open` rather than off the source, because nothing on the
    # presentation path consults that ceiling and an example that could not tell
    # a lifted one from a kept one would pass either way.
    it "carries the critique ceiling through untouched, whatever a human is willing to scroll" do
      attached
      seen = []
      allow(Lain::Review::Session).to receive(:open).and_wrap_original do |original, **kwargs|
        seen << kwargs.fetch(:bounds)
        original.call(**kwargs)
      end

      bounded(max_critique_lines: 4242).call("#{@root} --unbounded", env)

      expect(seen.last.max_critique_lines).to eq(4242)
      expect(seen.last.max_files).to be(Lain::Review::Bounds::UNBOUNDED)
    end
  end

  # THE REMEDY A REFUSAL OFFERS HAS TO BE ONE THE READER CAN PERFORM. The
  # partial-review refusal used to end "open the session with
  # Lain::Review::Verdict::Policy::Permissive.new" -- a Ruby constructor, in a
  # sentence echoed to a human holding an editor. It now names a flag, and a
  # flag no command declares would be the same defect wearing different words,
  # so the sentence and the switch are pinned against each other HERE, on a
  # command that offers it.
  describe "the flag the partial-review refusal names" do
    before { two_documents }

    it "offers it in its usage, beside the switch it already had" do
      expect(command.usage).to include("--permissive", "--unbounded")
    end

    # Nothing marked, so the default policy refuses -- and what it refuses WITH
    # has to be reachable from the same line the human just typed.
    it "refuses an approve over an unreviewed survey without it, naming it as the way past" do
      attached
      command.call(@root, env)

      expect(editor.bound.wrote_verdict("approve")).to include("--permissive")
    end

    it "admits that same approve when the survey was opened with it" do
      attached
      command.call("#{@root} --permissive", env)

      expect(editor.bound.wrote_verdict("approve")).to be_nil
    end

    # `wrote_verdict` answering nil is "nothing refused it", which a verdict
    # that quietly went nowhere would also satisfy. The record is the claim.
    it "journals the verdict it admitted, rather than merely not refusing it" do
      attached
      command.call("#{@root} --permissive", env)
      editor.bound.wrote_verdict("approve")

      expect(record.string.lines.map { |line| JSON.parse(line)["type"] }).to include("review_verdict")
    end

    # A `blocker` in the shape {Lain::Frontend::Neovim::ReviewWrite} normalizes
    # off the wire, at a line `notes.md` actually has.
    def blocker
      { "path" => "notes.md", "side" => "new", "line" => 3, "anchor_text" => "One line of prose.",
        "text" => "this is wrong", "kind" => "blocker", "revision" => "corpus", "drifted" => false }
    end

    # THE LINE THE FLAG MUST NOT CROSS. Its own sentence offers it as a way past
    # ROWS nobody read; an unanswered blocker is somebody who read the work and
    # said no, and no flag advertised in `usage` may forgive one. Driven from
    # the human's end -- a typed `/survey ... --permissive`, a blocker placed on
    # the rail, then approve -- because the whole defect is that the escape
    # became TYPEABLE.
    it "still refuses an approve over an unanswered blocker, in the blocker's own words" do
      attached
      command.call("#{@root} --permissive", env)
      handover = editor.bound
      handover.wrote_annotation(blocker)

      expect(handover.wrote_verdict("approve")).to include("notes.md:3").and include("nobody has answered")
    end

    it "leaves that review unsettled, so the flag cost the verdict and not the round" do
      attached
      command.call("#{@root} --permissive", env)
      handover = editor.bound
      handover.wrote_annotation(blocker)
      handover.wrote_verdict("approve")

      expect(handover.session.verdict).to be(Lain::Review::Verdict::None)
      expect(record.string.lines.map { |line| JSON.parse(line)["type"] }).not_to include("review_verdict")
    end

    # The escape still escapes: a plain note claims nothing about
    # admissibility, so the flag does what its sentence promises.
    it "admits over an unreviewed changeset carrying only a plain note" do
      attached
      command.call("#{@root} --permissive", env)
      handover = editor.bound
      handover.wrote_annotation(blocker.merge("kind" => "note"))

      expect(handover.wrote_verdict("approve")).to be_nil
    end

    # BOTH SWITCHES COME OFF ONE LIST, so neither can turn the other on. The
    # parse read `words.intersect?(SWITCHES)` for `unbounded`, which answers
    # "any switch present" and was correct only while the list held one member
    # -- adding a second is exactly what arms it, and the ceiling is what
    # notices.
    it "does not lift the ceilings that the other switch lifts" do
      bounded = described_class.new(cwd: @root, outbox:, ledger:, sensitivity:,
                                    bounds: Lain::Review::Bounds.new(max_files: 1))
      attached

      expect { bounded.call("#{@root} --permissive", env) }.to raise_error(Lain::Review::Bounds::TooLarge)
    end
  end

  # ONE OPEN REVIEW PER CHAT (the plan's Open decisions). The chat holds one
  # `outbox:` across both review commands, and one set of gesture rails: a second
  # SURFACE opened over the first would rebind those rails to a sidebar the first
  # review's marks cannot reach. Reopening the SAME kind still rebinds, which is
  # the documented recovery from a bounded refusal and has its own example in
  # `command/review_spec.rb`.
  describe "a second review surface in one chat" do
    before { two_documents }

    # The held round's SOURCE is the whole of what tells the two apart, and it is
    # the value `/review` journals -- so a double answering it is the honest
    # stand-in for a changeset review this tree has no repository for.
    #
    # The VERDICT is the second thing the guard reads, and this one is a round
    # nobody has judged: `Verdict::None` is what a live session answers, and the
    # real null object is used rather than a stubbed nil for the reason its own
    # doc gives -- a nil would let a guard pass by nil-checking instead.
    let(:changeset_round) do
      instance_double(Lain::Review::Session, source: "local_branch", verdict: Lain::Review::Verdict::None)
    end

    # The same round after a human judged it. A judged round is held exactly as
    # a live one is -- nothing in a chat lets go -- so the only difference
    # between this double and the one above is the word, which is the point.
    let(:settled_changeset_round) do
      instance_double(Lain::Review::Session, source: "local_branch", verdict: "approve")
    end

    it "refuses a survey over an open changeset review, naming the review already open" do
      attached
      outbox.hold(session: changeset_round, number: 12, label: "pull request 12")

      expect { command.call(@root, env) }.to raise_error(Lain::Error, /pull request 12/)
    end

    it "leaves the open review exactly where it was, since the refusal opened nothing" do
      attached
      outbox.hold(session: changeset_round, number: 12, label: "pull request 12")

      expect { command.call(@root, env) }.to raise_error(Lain::Error)
      expect(outbox.target).to eq("pull request 12")
      expect(editor.bound).to be_nil
    end

    # THE MIRROR, and the half that makes this a rule rather than a courtesy
    # `/survey` pays `/review`. Refused before the target is resolved, so this
    # tree needs no repository for the example to be about the guard.
    #
    # ASSERTED ON THE GUARD'S OWN WORDS, and a panel mutant is why: matching the
    # tmpdir alone passes with the guard DELETED. `Source::UnknownRef` is a
    # `Lain::Error` too, and because this tree is not a repository its message
    # names the very same path -- "head ref "feature" does not resolve to a
    # commit in /tmp/.../corpus". The two refusals are only distinguishable by
    # what they SAY.
    it "refuses a changeset review over an open survey, naming the survey already open" do
      attached
      command.call(@root, env)

      expect { Lain::CLI::Command::Review.new(root: @root, outbox:, ledger: Lain::Sensitivity::Ledger.new).call("feature", env) }
        .to raise_error(Lain::Error, /is already open in this chat/)
    end

    # The `@root` match alone is the vacuous assertion above, so it carries the
    # guard's own words too: this example is about WHICH surface is named, and
    # it must not be satisfiable by the resolver's refusal naming the same tree.
    it "names the survey itself in that refusal, so the human knows which surface is in the way" do
      attached
      command.call(@root, env)

      expect { Lain::CLI::Command::Review.new(root: @root, outbox:, ledger: Lain::Sensitivity::Ledger.new).call("feature", env) }
        .to raise_error(Lain::Error, a_string_including(@root).and(include("is already open in this chat")))
    end

    # THE STRANDING PAIR, and the defect this guard would otherwise CREATE.
    # Only a verdict or a human's `/review close` lets a round go, so a refusal
    # that held a round while drawing NOTHING would lock `/review` out of that
    # cockpit over a survey the human never saw. That is this card's own stated failure ("an opened review that
    # nothing drew and no gesture could reach") reached through the guard the
    # card added.
    #
    # Two refusals raise from `Session#present`, which is AFTER the round is
    # open -- the LINE ceiling and `UnsupportedScope`. The file ceiling is not
    # one of them: `Corpus#initialize` refuses it before a session exists.
    it "holds nothing when the LINE ceiling refuses, so a later /review is not locked out" do
      attached
      bounded = described_class.new(outbox:, ledger:, sensitivity:,
                                    bounds: Lain::Review::Bounds.new(max_lines: 1))

      expect { bounded.call(@root, env) }.to raise_error(Lain::Review::Bounds::TooLarge)

      expect(outbox).not_to be_open
      expect { Lain::CLI::Command::Review.new(root: @root, outbox:, ledger: Lain::Sensitivity::Ledger.new).call("feature", env) }
        .to raise_error(Lain::Review::Source::UnknownRef)
    end

    # The rails half of the same refusal. They were bound before the draw, for
    # the human fast enough to gesture between the two, and a verdict landing
    # on a survey nobody saw -- `--permissive` would even admit one -- is what
    # is left if the refusal does not let them go.
    it "leaves the rails unbound and draws the refusal where the sidebar was when the LINE ceiling refuses" do
      attached
      bounded = described_class.new(outbox:, ledger:, sensitivity:, cwd: @root,
                                    bounds: Lain::Review::Bounds.new(max_lines: 1))

      expect { bounded.call(@root, env) }.to raise_error(Lain::Review::Bounds::TooLarge)

      expect(editor.bound).to be_nil
      expect(sink.string).to include("refused:").and include("lines")
      expect(sink.string).not_to include("notes.md")
      expect(Lain::Journal.records(record.string.lines, type: "changeset_closed").to_a.map { |line| line["closed_by"] })
        .to eq(["refusal"])
    end

    it "keeps holding a settled changeset review when a survey opened over it refuses" do
      attached
      outbox.hold(session: settled_changeset_round, number: 12, label: "pull request 12")
      bounded = described_class.new(outbox:, ledger:, sensitivity:, cwd: @root,
                                    bounds: Lain::Review::Bounds.new(max_lines: 1))

      expect { bounded.call(@root, env) }.to raise_error(Lain::Review::Bounds::TooLarge)

      expect(outbox.target).to eq("pull request 12")
    end

    it "holds nothing when the scope is one a corpus cannot answer, for the same reason" do
      attached

      expect { command.call("#{@root} --scope commits", env) }
        .to raise_error(Lain::Review::Session::UnsupportedScope)

      expect(outbox).not_to be_open
      expect(editor.bound).to be_nil
      expect { Lain::CLI::Command::Review.new(root: @root, outbox:, ledger: Lain::Sensitivity::Ledger.new).call("feature", env) }
        .to raise_error(Lain::Review::Source::UnknownRef)
    end

    # ONCE THE ROUND IS SETTLED the rule stops applying, and the whole of the
    # reason is in the guard's own rationale: "a sidebar the survey's marks
    # cannot reach". Marks handed back and judged have nowhere left to reach. A
    # chat that surveyed once could otherwise never review a branch again for
    # the rest of its life.
    #
    # The survey is settled through the HAND-BACK a human's own `<CR>` reaches
    # (`Handover#wrote_verdict` -> `Session#submit`) rather than by stubbing a
    # reader: what has to be true is that the verdict a human writes is the one
    # the other command sees, and `Session#submit` touches no outbox at all.
    # `--permissive` is on the line because the default policy refuses an
    # approve over rows nobody marked, and this example is about the guard.
    it "lets a changeset review open once the survey has been settled by a verdict" do
      attached
      command.call("#{@root} --permissive", env)

      expect(editor.bound.wrote_verdict("approve")).to be_nil
      expect { Lain::CLI::Command::Review.new(root: @root, outbox:, ledger: Lain::Sensitivity::Ledger.new).call("feature", env) }
        .to raise_error(Lain::Review::Source::UnknownRef)
    end

    # Where a chat can see it: settling is not closing. Between the verdict
    # and whatever round replaces it the survey is still held, so
    # `/review-submit` names it rather than answering "no changeset review is
    # open" about the round the human has only just judged.
    it "still holds the settled survey, so the round a human just judged is still the one held" do
      attached
      command.call("#{@root} --permissive", env)
      editor.bound.wrote_verdict("approve")

      expect(outbox).to be_open
      expect(outbox.target).to eq("survey of #{@root}")
    end

    # THE MIRROR of the pair above, and the direction `/survey` owns: a
    # changeset review that has been judged is not a surface in the way either.
    it "opens a survey over a changeset review that has already been settled" do
      attached
      outbox.hold(session: settled_changeset_round, number: 12, label: "pull request 12")

      command.call(@root, env)

      expect(editor.bound).to be_a(Lain::Review::Handover)
      expect(outbox.target).to eq("survey of #{@root}")
    end

    # THE COUNTER-EXAMPLE to a guard written as `outbox.open?`. Reopening the
    # same kind is how a human gets a second look at a tree they have already
    # surveyed, and refusing it would be a rule about the wrong thing.
    it "rebinds when a survey is reopened over a survey, rather than refusing" do
      attached
      command.call(@root, env)
      first = editor.bound

      command.call(@root, env)

      expect(editor.bound).to be_a(Lain::Review::Handover)
      expect(editor.bound).not_to equal(first)
    end
  end

  # A resumed chat carries none of the review round the session it resumed
  # left open -- a round is round-scoped -- so a survey of the same TARGET says
  # so. The target is the tree a human named, not its content: a survey of
  # `big/` whose files changed since is still the survey of `big/`.
  describe "reopening a survey in a resumed chat" do
    before { two_documents }

    def chronicle_on(on, path) = instance_double(Lain::CLI::Chronicle, record_journal: on, journal_path: path)

    # The earlier chat's session file, and whatever it did before stopping --
    # in its own outbox, since it was its own chat.
    def earlier(dir)
      prior = StringIO.new
      held = Lain::Review::Submit::Outbox.new
      yield described_class.new(cwd: @root, outbox: held, ledger:, sensitivity:),
            build_command_env(replies:, chronicle: chronicle_on(Lain::Journal.new(io: prior), nil)), held
      File.write(File.join(dir, "earlier.ndjson"), prior.string)
    end

    # The resumed chat: a header naming the earlier file, as `--resume` writes it.
    def resumed(dir)
      current = File.join(dir, "resumed.ndjson")
      File.write(current, "#{JSON.generate("type" => Lain::SessionRecord::HEADER_TYPE,
                                           "resumed_from" => { "file" => "earlier.ndjson", "head" => "x" })}\n")
      build_command_env(replies:, chronicle: chronicle_on(journal, current))
    end

    def in_session_dir(&) = Dir.mktmpdir("lain-survey-resumed", &)

    it "opens a new round with the not-carried-over banner" do
      attached
      in_session_dir do |dir|
        earlier(dir) { |survey, earlier_env| survey.call(@root, earlier_env) }

        answer = command.call(@root, resumed(dir))

        expect(answer).to include("not carried over").and include(@root)
        expect(editor.bound).to be_a(Lain::Review::Handover)
      end
    end

    it "still says so when the tree changed between the two sessions" do
      attached
      in_session_dir do |dir|
        earlier(dir) { |survey, earlier_env| survey.call(@root, earlier_env) }
        write("notes.md", document("# Notes", "", "A line written after the earlier chat stopped."))
        write("added.md", document("# Added", "", "A file the earlier survey never saw."))

        expect(command.call(@root, resumed(dir))).to include("not carried over")
      end
    end

    it "says so for the same tree named another way" do
      attached
      in_session_dir do |dir|
        earlier(dir) { |survey, earlier_env| survey.call("#{@root}/", earlier_env) }

        expect(command.call(File.join(@root, "."), resumed(dir))).to include("not carried over")
      end
    end

    # The tree, not the spelling of the way to it: a link to the directory the
    # earlier chat surveyed reaches the same files.
    it "says so for the same tree reached through a symlink" do
      File.symlink(@root, File.join(@tmp, "linked"))
      attached
      in_session_dir do |dir|
        earlier(dir) { |survey, earlier_env| survey.call(@root, earlier_env) }

        expect(command.call(File.join(@tmp, "linked"), resumed(dir))).to include("not carried over")
      end
    end

    it "says nothing when the earlier chat closed that survey" do
      attached
      in_session_dir do |dir|
        earlier(dir) do |survey, earlier_env, held|
          survey.call(@root, earlier_env)
          Lain::CLI::Command::Review.new(root: @root, outbox: held, ledger: Lain::Sensitivity::Ledger.new).call(
            "close", earlier_env
          )
        end

        expect(command.call(@root, resumed(dir))).not_to include("not carried over")
      end
    end

    it "says nothing about an earlier survey of another tree" do
      write("sub/inner.md", document("# Inner", "", "Prose below the root."))
      attached
      in_session_dir do |dir|
        earlier(dir) { |survey, earlier_env| survey.call(File.join(@root, "sub"), earlier_env) }

        expect(command.call(@root, resumed(dir))).not_to include("not carried over")
      end
    end

    it "says nothing in a chat that resumed nothing" do
      attached

      expect(command.call(@root, env)).not_to include("not carried over")
    end
  end

  # The thread pane's model half, which no shipped path constructed. The
  # examples here are deliberately NOT "a docent was built" -- `Docent.new` with
  # only a changeset and a view is a fully constructed docent whose answerer is
  # `Unanswerable` and whose journal is `Channel::Null`, and it refuses every
  # question while satisfying any assertion about construction. So each one below
  # drives the human's own route -- `/survey`, a note, a question typed into the
  # pane that note opened -- and asserts an ANSWER came back, was DRAWN, and is
  # ON THE RECORD.
  describe "the docent a survey wires, and the question that reaches it" do
    let(:inlet) { SurveyDocentInlet.new }
    let(:surface) { Lain::Review::Surface::Neovim.new(rpc: inlet) }
    let(:editor) { SurveyCommandEditor.new(sink, surface:) }
    let(:asks) { [] }
    let(:answer) { "the last unit is real, so the range is inclusive" }
    let(:result) { Lain::Tool::Result.ok(answer) }
    let(:env) { build_command_env(replies:, chronicle:, role_spawn: recording_spawn) }

    before { two_documents }

    # The run's role spawn, at the arity {Lain::Review::Docent::Answerer} sends:
    # `(role, context_mode, prompt)`. A recorder rather than a double, because
    # what has to be true is that the docent's OWN role and mode reach it -- an
    # `instance_double` that accepted anything would pass on a docent wired to
    # the wrong arm.
    def recording_spawn
      lambda do |role, mode, brief|
        asks << [role, mode, brief]
        result
      end
    end

    # A note at line 3 of `notes.md`, in the shape
    # {Lain::Frontend::Neovim::ReviewWrite} normalizes off the wire. It is what
    # OPENS the thread: the pane is keyed by anchor id, and the id only exists
    # once something has posted one.
    def note(**overrides)
      { "path" => "notes.md", "side" => "new", "line" => 3, "anchor_text" => "One line of prose.",
        "text" => "why this way?", "kind" => "note", "revision" => "corpus",
        "drifted" => false }.merge(overrides.transform_keys(&:to_s))
    end

    # The id the editor would cite back, read off the rail the editor reads it
    # off: `set_thread`'s own payload. Nothing here invents one.
    def anchor_id = inlet.threads.last.first["id"]

    def records = record.string.lines.map { |line| JSON.parse(line) }

    def records_at(id) = records.select { |entry| entry["anchor_id"] == id }

    # `/survey`, drawn, with the gesture rails bound -- the state every example
    # below starts from.
    def opened_survey
      attached
      command.call(@root, env)
      editor.bound
    end

    # The whole human route, in the order a human takes it, and the await is
    # part of it: a docent RETURNS from the gesture and answers on a task of its
    # own, so a spec that did not wait would assert over a pending marker.
    def asked(question)
      handover = opened_survey
      handover.wrote_annotation(note)
      Sync { handover.ask(anchor_id, question).tap { |outcome| outcome.task&.wait } }
    end

    it "reaches the run's role spawn with the docent's own role and mode" do
      asked("why is the range inclusive?")

      expect(asks.map { |ask| ask.first(2) })
        .to eq([[Lain::Review::Docent::ROLE, Lain::Review::Docent::MODE]])
    end

    # The brief is the whole of what the child sees, so the question and the
    # hunk it is about both have to be in it -- a spawn reached with an empty
    # prompt is a docent that cost money and read nothing.
    it "hands it a brief carrying the question and the hunk it is about" do
      asked("why is the range inclusive?")

      expect(asks.first.last).to include("why is the range inclusive?").and include("One line of prose.")
    end

    it "takes the question rather than refusing it" do
      outcome = asked("why is the range inclusive?")
      taken = format(Lain::Review::Docent::TAKEN, "why is the range inclusive?")

      expect([outcome.asked?, outcome.report]).to eq([true, taken])
    end

    # THE ANSWER IS DRAWN, which is the half a construction assertion cannot
    # see: it arrives on the thread rail, at the anchor the question was asked
    # against, and it is the docent speaking rather than lain refusing.
    it "draws the answer into the thread pane, on the anchor the question was asked at" do
      asked("why is the range inclusive?")
      anchor, lines = inlet.threads.last

      expect(anchor["id"]).to eq(anchor_id)
      expect(lines.join("\n")).to include(answer).and include(Lain::Review::Docent::SPEAKER_DOCENT)
    end

    # AND IT IS ON THE RECORD. Both records, because an ask with no terminal
    # record after it is a question a bench counts as outstanding forever.
    it "journals the ask and the answer against that anchor" do
      asked("why is the range inclusive?")

      expect(records_at(anchor_id).map { |entry| entry["type"] })
        .to eq(%w[docent_asked docent_answered])
    end

    it "journals what was asked and what came back, not merely that something happened" do
      asked("why is the range inclusive?")
      answered = records_at(anchor_id).find { |entry| entry["type"] == "docent_answered" }

      expect(answered).to include("question" => "why is the range inclusive?", "answer" => answer)
    end

    # The arm names itself on the record, which is what makes two docents
    # comparable at all -- a run that journaled the shipped role for every arm
    # answers one bucket for every arm.
    it "records which arm answered" do
      asked("why is the range inclusive?")
      recorded = records_at(anchor_id).find { |entry| entry["type"] == "docent_asked" }

      expect(recorded["role"]).to eq(Lain::Review::Docent::ROLE.to_s)
    end

    # A survey opened, then the tree moved under it -- ordinary, because a
    # corpus is read from disk and a human goes on working in the tree they are
    # surveying. Locating the hunk an anchor sits in walks the changeset LAZILY,
    # so it reaches the filesystem at the moment the note arrives.
    #
    # THE NOTE MUST STILL LAND. This rail's own rule is that it refuses
    # uniformly or not at all (`Lain::Review::Surface::Neovim`'s class doc), and
    # its rescue catches this project's own refusals -- never an Errno. So a
    # docent that let one out would lose the human's note, and take the editor's
    # reply loop down with it.
    it "records a note whose surveyed file has since been deleted, instead of losing it to a raise" do
      handover = opened_survey
      FileUtils.rm(File.join(@root, "notes.md"))

      expect(handover.wrote_annotation(note)).to be_nil
      expect(records.select { |entry| entry["type"] == "annotation_placed" }.map { |entry| entry["anchor_text"] })
        .to eq([nil])
    end

    # THE PANE MAY NOT ASSERT A THREAD THE RECORD DENIES. `nitpick` is not one
    # of `Review::ANNOTATION_KINDS`, so the session refuses the note and journals
    # nothing -- and a thread opened anyway would invite a question at an anchor
    # no note ever landed at, which the docent would answer with a real provider
    # call.
    it "opens no thread for a note the session refused" do
      handover = opened_survey

      refusal = handover.wrote_annotation(note(kind: "nitpick"))

      expect(refusal).to be_a(String)
      expect(inlet.threads).to be_empty
      expect(records.map { |entry| entry["type"] }).not_to include("annotation_placed")
    end

    # ONE payload per note. The thread rail carries a single payload per anchor,
    # so a docent that rendered its own empty conversation beside the note would
    # post twice and let write order decide which the human sees. Holding the
    # thread WITHOUT drawing it is what makes the note win by construction.
    it "posts the thread pane once for a note that landed, not once per owner of the rail" do
      handover = opened_survey

      handover.wrote_annotation(note)

      expect(inlet.threads.size).to eq(1)
      expect(inlet.threads.last.last.join("\n")).to include("why this way?")
    end

    # THE ACCEPTED LOSS, pinned so it cannot move in silence. A second note on a
    # line whose thread has already been answered mints a SECOND anchor -- an id
    # belongs to an {Lain::Review::Anchor}, not to a position -- so the pane the
    # cursor finds on that line becomes the note's, and the answered thread is no
    # longer the one on screen.
    #
    # ACCEPTED rather than preserved or refused, and measured rather than
    # assumed. Refusing a legitimate note because a docent once answered nearby
    # is plainly wrong. Preserving means rendering the exchange instead, which
    # loses the NOTE from the pane -- trading one loss for the other, over the
    # single payload this rail carries per anchor. What makes accepting bearable
    # is the two assertions below: nothing is destroyed. The exchange is still
    # held under its own id and still answers there, and `docent_answered` is on
    # the record for {Lain::Review::Docent#replay}. The human reopens it; they do
    # not lose what they paid for.
    #
    # The real fix is an anchor identified by its POSITION rather than by a fresh
    # uuid, which is a change to {Lain::Review::Anchor}'s identity and not a line
    # of wiring.
    it "displaces an answered thread when a second note lands on its line, without destroying it" do
      asked("why is the range inclusive?")
      first = anchor_id

      editor.bound.wrote_annotation(note(text: "second thought"))

      expect(anchor_id).not_to eq(first)
      displaced = inlet.threads.last.last.join("\n")
      expect(displaced).to include("second thought")
      expect(displaced).not_to include(answer)
      expect(records_at(first).map { |entry| entry["type"] }).to include("docent_answered")
    end

    it "goes on answering in the displaced thread, so reopening it is all the human has to do" do
      asked("why is the range inclusive?")
      first = anchor_id
      editor.bound.wrote_annotation(note(text: "second thought"))

      Sync { editor.bound.ask(first, "and why not the other way?").tap { |asked| asked.task&.wait } }

      expect(inlet.threads.last.first["id"]).to eq(first)
      expect(inlet.threads.last.last.join("\n")).to include("and why not the other way?")
    end
  end

  # The other half of the same wiring, and it must stay honest: a docent draws
  # every answer itself, on its own task, long after the gesture that asked --
  # so a surface with no thread pane has nowhere to put one, and a docent that
  # spent a provider call and drew nowhere is worse than one that refuses.
  describe "a survey drawn on a surface with no thread pane" do
    it "keeps refusing by name rather than wiring a docent that cannot render" do
      two_documents
      attached
      command.call(@root, env)

      outcome = editor.bound.ask("anchor-nobody-minted", "why this way?")

      expect([outcome.asked?, outcome.report])
        .to eq([false, Lain::Review::Handover::Unattended::NO_DOCENT])
    end
  end

  # The banner's own claims, driven against a REAL editor and checked rather
  # than argued for. `changeset_diff_spec.rb`'s pattern -- a real
  # {Lain::Frontend::Neovim::RenderInlet}, `.drain` sent over
  # one connection and read back over the SAME one, so message order is the
  # only ordering this needs -- rather than the full RPC-thread/async gesture
  # loop, which is a second object's seam to cover.
  #
  # The CHANGESET driven through {Lain::Frontend::Neovim::ChangesetDiff} is the
  # REAL one this command's own `round` built -- `editor.bound.session.changeset`
  # -- so what gets opened is exactly what a survey's `<CR>` would resolve to,
  # not a stand-in.
  describe "the survey banner's commands, against a real editor", :nvim, :seam do
    around do |example|
      two_documents
      # `chdir: @root`, `47_diff.lua`'s ROOT: paths land relative to the
      # SURVEYED tree, and `Lain::Frontend::Neovim::ChangesetDiff` posts them
      # exactly as {Lain::Review::Source::Corpus} named them -- repository-
      # relative to the corpus, never to this process's own cwd.
      headless_editor("lain-survey-cmd", chdir: @root) do |editor|
        @nvim = editor.with_runtime
        example.run
      end
    end

    def messages
      @nvim.exec_lua("return vim.api.nvim_exec2('messages', { output = true }).output", [])
    end

    # Two criteria in one example: opening a survey row is what puts the human
    # in the buffer the banner's two commands are about, so both are checked
    # against the ONE buffer a real `<CR>` would have opened.
    it "reaches :LainNote from a row it opened, and refuses :LainReviewDone with a named surface, not a traceback" do
      attached
      command.call(@root, env)
      changeset = editor.bound.session.changeset

      real_inlet = Lain::Frontend::Neovim::RenderInlet.new(waker: -> {})
      diff = Lain::Frontend::Neovim::ChangesetDiff.new(rpc: real_inlet)
      diff.reviewing(changeset)
      refusal = diff.open("guide.md", 1)
      real_inlet.drain(@nvim)

      expect(refusal).to be_nil, "opening a survey's own row refused: #{refusal}"

      # STOOD ON EXPLICITLY, because opening no longer leaves the cursor here:
      # `open_changeset` draws the pair and then lands the human in the SIDEBAR
      # (`runtime/47_diff.lua`'s `landing`), so that the review's own keys are
      # under the cursor and the `x` its banner teaches cannot reach the real
      # file on disk. The banner's claim below is about the BUFFER the row
      # opened, not about where `<CR>` parks the cursor, so this finds that
      # buffer by its stamp rather than inheriting whatever focus the open
      # happened to leave.
      #
      # BY THE STAMP and deliberately not by counting `<C-w>l`s: how many
      # motions the banner teaches is per-round now
      # ({Lain::Review::OpenedBanner} reads the round's sides), and an example
      # that re-derived the count here would be a second answer to that
      # question, free to disagree with the sentence it is checking. The unit
      # example above pins the motion; this one pins where it has to land.
      #
      # The stamp is returned and CHECKED, because both commands below read
      # `nvim_get_current_buf`: arriving in the wrong window would test them
      # against a buffer this example never opened, and `:LainNote`'s refusal
      # there reads exactly like the one this example exists to rule out.
      opened = @nvim.exec_lua(<<~LUA, [])
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          local buf = vim.api.nvim_win_get_buf(win)
          if vim.b[buf].lain_review_side == "new" then
            vim.api.nvim_set_current_win(win)
            return vim.b[buf].lain_review_path
          end
        end
        return nil
      LUA
      expect(opened).to eq("guide.md"), "the walk to the opened row landed on #{opened.inspect}"

      # THE FIRST HALF OF THE BANNER'S CLAIM: the row `<CR>` opened is a
      # buffer `:LainNote` accepts, because `open_changeset` stamped it
      # (`runtime/47_diff.lua`'s `review_diff.stamp`) whether or not the file
      # has an old side -- an ADDED file's is `[]`, never `nil`
      # ({Lain::Review::Changeset#old_side}'s documented distinction), so this
      # never took the {Lain::Frontend::Neovim::ChangesetDiff::NO_OLD_SIDE}
      # refusal above.
      note = @nvim.exec_lua(<<~LUA, [])
        local ok, err = pcall(vim.cmd, "LainNote note a survey note")
        return { ok = ok, err = tostring(err) }
      LUA
      expect(note["ok"]).to be(true), "LainNote refused a survey's own row: #{note["err"]}"

      # THE SECOND HALF: the banner no longer names this command, and the
      # reason is checkable now -- it refuses THIS buffer (no EPIC generation
      # or slug was ever stamped on it), and does so as a lain sentence naming
      # the surface, never as an escaped Lua error.
      done = @nvim.exec_lua(<<~LUA, [])
        local ok, err = pcall(vim.cmd, "LainReviewDone")
        return { ok = ok, err = tostring(err) }
      LUA
      expect(done["ok"]).to be(true),
                            "LainReviewDone escaped this survey's row as a raw error: #{done["err"]}"
      text = messages
      expect(text).to include("lain:").and include(":LainReviewVerdict")
      expect(text).not_to include("stack traceback")
    end
  end
end
