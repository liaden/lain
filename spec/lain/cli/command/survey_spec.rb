# frozen_string_literal: true

require "fileutils"
require "neovim"
require "stringio"
require "timeout"
require "tmpdir"

# `/survey <path>` (B14): the repl command that puts a human in front of a
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
  let(:command) { described_class.new(root: @root, cwd: @root, outbox:, paths:, ledger:) }

  # The run's ONE region ledger, injected because {Lain::Sensitivity::Ledger}'s
  # own class doc makes that rule 1 of three and "a raise rather than a note": a
  # defaulted ledger lets a forgotten injection become a SECOND one whose
  # releases nobody ever sees, so a released region would still render
  # `<redacted:N>` in the survey with every object present and nothing wrong to
  # look at.
  let(:ledger) { Lain::Sensitivity::Ledger.new }

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

  let(:chronicle) { instance_double(Lain::CLI::Chronicle, record_journal: journal) }
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

  # HOME injected rather than exported: the classifier anchors its home-relative
  # rules against it, and no example may reach the developer's own dotfiles. The
  # ROUND is journaled into the chat's own journal, so no sessions directory is
  # touched at all.
  def paths = Lain::Paths.new(env: { "HOME" => @home })

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
      expect { described_class.new(root: @root, outbox:, paths:) }
        .to raise_error(ArgumentError, /ledger/)
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

    # F4: the banner used to name `:LainReviewDone`, a PROTOCOL-5 EPIC command
    # whose guard (`runtime/65_review.lua:93-98`) requires
    # `b:lain_review_epic_slug` -- a variable a survey never stamps, so the
    # guard could never pass. This is the command a survey's own hand-back
    # actually reaches: `:LainReviewVerdict {verdict}`
    # (`runtime/46_sidebar.lua:188`, protocol 10). Pinned by NAME and not just
    # by "does not say LainReviewDone", because a banner that dropped the
    # hand-back gesture entirely would pass a merely negative assertion.
    # {Lain::Review::OpenedBanner} owns the wording now (T5 fix round); this
    # example is what proves {Command::Survey} actually reads it.
    it "names the command a survey's hand-back actually reaches, not the epic surface's" do
      attached

      answer = command.call(@root, env)

      expect(answer).to include(":LainReviewVerdict #{Lain::Review::VERDICTS.first}")
      expect(answer).not_to include("LainReviewDone")
    end

    # The other half of the same sentence (T5's third clause): ":LainNote
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
      defaulted = Dir.chdir(@root) { described_class.new(root: @tmp, outbox:, paths:, ledger:) }

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
      bounded = described_class.new(outbox:, root: @root, cwd: @root, ledger:,
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
    # B11's panel killed a `:by_directory` canary with exactly such an assertion
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
      oversized = described_class.new(root: @root, outbox:, paths:, ledger:,
                                      bounds: Lain::Review::Bounds.new(max_files: 1))

      expect { oversized.call("#{@root} --scope cumulatve", env) }
        .to raise_error(Lain::Review::Session::UnknownScope, /cumulatve/)
    end
  end

  describe "the ceilings, and the flag that lifts them" do
    before { two_documents }

    def bounded(**ceilings)
      described_class.new(root: @root, outbox:, paths:, ledger:, bounds: Lain::Review::Bounds.new(**ceilings))
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

    # B11's panel finding, checked where it can actually be wrong: `/critique`
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
    let(:changeset_round) { instance_double(Lain::Review::Session, source: "local_branch") }

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

      expect { Lain::CLI::Command::Review.new(root: @root, outbox:).call("feature", env) }
        .to raise_error(Lain::Error, /is already open in this chat/)
    end

    # The `@root` match alone is the vacuous assertion above, so it carries the
    # guard's own words too: this example is about WHICH surface is named, and
    # it must not be satisfiable by the resolver's refusal naming the same tree.
    it "names the survey itself in that refusal, so the human knows which surface is in the way" do
      attached
      command.call(@root, env)

      expect { Lain::CLI::Command::Review.new(root: @root, outbox:).call("feature", env) }
        .to raise_error(Lain::Error, a_string_including(@root).and(include("is already open in this chat")))
    end

    # THE STRANDING PAIR, and the defect this guard would otherwise CREATE.
    # Nothing in a chat closes a round -- `Outbox` answers `hold`, `open?`,
    # `submit`, `held_source` and `target`, and none of them lets go -- so a
    # refusal that held a round while drawing NOTHING locks `/review` out of
    # that cockpit for the rest of the session, over a survey the human never
    # saw. That is this card's own stated failure ("an opened review that
    # nothing drew and no gesture could reach") reached through the guard the
    # card added.
    #
    # Two refusals raise from `Session#present`, which is AFTER the round is
    # open -- the LINE ceiling and `UnsupportedScope`. The file ceiling is not
    # one of them: `Corpus#initialize` refuses it before a session exists.
    it "holds nothing when the LINE ceiling refuses, so a later /review is not locked out" do
      attached
      bounded = described_class.new(root: @root, outbox:, paths:, ledger:,
                                    bounds: Lain::Review::Bounds.new(max_lines: 1))

      expect { bounded.call(@root, env) }.to raise_error(Lain::Review::Bounds::TooLarge)

      expect(outbox).not_to be_open
      expect { Lain::CLI::Command::Review.new(root: @root, outbox:).call("feature", env) }
        .to raise_error(Lain::Review::Source::UnknownRef)
    end

    it "holds nothing when the scope is one a corpus cannot answer, for the same reason" do
      attached

      expect { command.call("#{@root} --scope commits", env) }
        .to raise_error(Lain::Review::Session::UnsupportedScope)

      expect(outbox).not_to be_open
      expect { Lain::CLI::Command::Review.new(root: @root, outbox:).call("feature", env) }
        .to raise_error(Lain::Review::Source::UnknownRef)
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

  # T5's third clause and its AC5, driven against a REAL editor: the banner's
  # own claims, checked rather than argued for. `changeset_diff_spec.rb`'s
  # pattern -- a real {Lain::Frontend::Neovim::RenderInlet}, `.drain` sent over
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
      socket = File.join(Dir.tmpdir, "lain-survey-cmd-#{Process.pid}-#{rand(1_000_000)}.sock")
      # `chdir: @root`, `47_diff.lua`'s ROOT: paths land relative to the
      # SURVEYED tree, and `Lain::Frontend::Neovim::ChangesetDiff` posts them
      # exactly as {Lain::Review::Source::Corpus} named them -- repository-
      # relative to the corpus, never to this process's own cwd.
      pid = spawn("nvim", "--headless", "--clean", "-n", "--listen", socket, chdir: @root,
                                                                             out: File::NULL, err: File::NULL)
      Timeout.timeout(10) { sleep 0.02 until File.exist?(socket) }
      @nvim = Neovim.attach_unix(socket)
      @nvim.exec_lua(Lain::Frontend::Neovim::RuntimeLoader.new.source,
                     [Lain::VERSION, Lain::Frontend::Neovim::PROTOCOL, @nvim.channel_id])
      example.run
    ensure
      @nvim = nil
      if pid
        begin
          Process.kill("TERM", pid)
          Process.wait(pid)
        rescue Errno::ESRCH, Errno::ECHILD
          nil
        end
      end
      FileUtils.rm_f(socket)
    end

    def messages
      @nvim.exec_lua("return vim.api.nvim_exec2('messages', { output = true }).output", [])
    end

    # AC4 and AC5 in one example: opening a survey row is what puts the human
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
