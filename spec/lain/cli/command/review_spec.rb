# frozen_string_literal: true

require "async"
require "fileutils"
require "json"
require "mixlib/shellout"
require "neovim"
require "stringio"
require "tmpdir"

# `/review <target>`: the repl command that puts a human in front of a
# pull request inside the cockpit they already have open.
#
# EVERY GESTURE HERE ARRIVES ON THE COMMAND INBOX, and that is the whole point
# of the file rather than a stylistic preference. `spec/lain/cli/review_spec.rb`
# had 28 examples proving {Lain::CLI::Review} correct while nothing in `exe/lain`
# mounted it, and waves 3-5 of this chunk shipped a surface with zero
# construction sites under green specs. Calling {Lain::Review::Handover}
# directly would reproduce exactly that: the object works, and nothing reaches
# it. So the seam group below binds a real {Lain::CLI::HumanReplies}, pushes the
# wire's own `["review_mark", [line, state, generation]]` onto the editor rail,
# runs the real consumer fiber, and asserts what the session recorded.
#
# THE STALE-GENERATION EXAMPLE IS THE COUNTER-EXAMPLE, and without it a stamp
# ignoring implementation passes every other example in this file: a gesture
# that resolves whatever row the line names, whatever rendering it came from,
# marks the same hunks as the good one. The refusal reaching `review_refused` is
# what tells the two apart.

# The editor rail, both directions. {Lain::Frontend::Neovim::CommandInbox}'s
# duck: a non-blocking pop the consumer fiber drains, and the way a refused
# gesture gets back to the human who made it. Its own class rather than the one
# `human_replies_spec.rb` declares -- that file is one `parallel_tests` may hand
# to another worker entirely.
class ReviewCommandRail
  def initialize
    @commands = []
    @refusals = []
  end

  attr_reader :refusals

  def push(command) = @commands.push(command)
  def pop(*) = @commands.shift
  def review_refused(message) = @refusals << message
  def attached? = true
end

# The one message the diff pair sends the editor, recorded rather than sent.
# Its own class for {ReviewCommandRail}'s reason: a class declared in another
# spec file is one `parallel_tests` may hand to another worker entirely.
class ReviewCommandInlet
  attr_reader :posted

  def initialize = (@posted = [])

  def open_changeset(path, old_lines, line, revisions)
    @posted << { path:, old_lines:, line:, revisions: }
    nil
  end
end

# The frontend, reduced to the three messages {Lain::CLI::HumanReplies} asks of
# one. The surface is the REAL text surface, the view the REAL sidebar view and
# its diff surface the REAL {Lain::Frontend::Neovim::ChangesetDiff}, for
# `wiring_spec.rb`'s reason: what is under test is whether the command reaches
# THESE, and a double answering the port would be indistinguishable from
# {Lain::Review::Surface::Null}. Only the INLET is recorded, because its far
# side is an editor and this group has none.
class ReviewCommandEditor
  def initialize(sink, surface: nil)
    @inlet = ReviewCommandInlet.new
    @view = Lain::Frontend::Neovim::ReviewView.new(
      changesets: Lain::Frontend::Neovim::ChangesetDiff.new(rpc: @inlet)
    )
    @surface = surface || Lain::Review::Surface::Text.new(sink:)
  end

  attr_reader :bound, :inlet

  def review_surface = @surface
  def review_view = @view
  def bind_changeset_review(review) = @bound = review
end

# The editor's render inlet at the rails a thread-carrying surface posts on,
# keeping every `set_thread` payload so a spec can read the anchor id back.
class ReviewCommandThreadInlet
  def initialize = (@threads = [])

  attr_reader :threads

  def set_review(_lines, _generation, _sides) = nil
  def review_focus = nil
  def review_refused(_message) = nil
  def set_thread(anchor, lines) = @threads << [anchor, lines]
end

# A journal whose writes park, so a second thread can reach a round's terminal
# guards while the first is still writing -- the only way to make the window
# between a check and its record wide enough to land in on purpose.
class ReviewCommandSlowIO < StringIO
  def write(*)
    sleep 0.3
    super
  end
end

RSpec.describe Lain::CLI::Command::Review do
  let(:command) do
    described_class.new(root: @repo, outbox:, shell_out_factory: Mixlib::ShellOut.public_method(:new),
                        ledger: Lain::Sensitivity::Ledger.new)
  end

  # The REAL outbox `/review-submit` reads, never a spy: what has to be true is
  # that the round THIS command opened is the round that would be posted, and a
  # recording double could only say `hold` was called with something.
  let(:outbox) { Lain::Review::Submit::Outbox.new }
  let(:sink) { StringIO.new }
  let(:record) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: record) }
  let(:rail) { ReviewCommandRail.new }
  let(:editor) { ReviewCommandEditor.new(sink) }
  let(:questions) { Async::Queue.new }

  # The run's real reply router: the object that owns both the acked-gesture
  # table and `bind_changeset_review`, so nothing between the wire and the
  # session is a double.
  let(:replies) do
    Lain::CLI::HumanReplies.new(tty: instance_double(Lain::Frontend::TTY),
                                conductor: instance_double(Lain::CLI::Conductor),
                                ask_human: instance_double(Lain::Tools::AskHuman::Directory),
                                questions:)
  end

  # `journal_path: nil` is a chat recording to no file, so it resumed nothing.
  let(:chronicle) { instance_double(Lain::CLI::Chronicle, record_journal: journal, journal_path: nil) }
  let(:env) { build_command_env(replies:, chronicle:) }

  # A `main` and a `feature` carrying TWO commits, because `--base`'s default is
  # {Lain::Forge::Landing::BASE} and an example that overrides it has to be able
  # to tell the two apart: against `main` the changeset is README plus
  # `later.rb`, against `HEAD~1` it is `later.rb` alone. Reviewed against one
  # commit, a `--base` this command dropped on the floor would render exactly
  # what the default renders and the example would be green either way.
  around do |example|
    Dir.mktmpdir("lain-command-review") do |dir|
      FileUtils.cp_r(File.join(SeedRepo.at("README" => "seed\n"), "."), dir)
      git(dir, "branch", "-M", "main")
      git(dir, "checkout", "-q", "-b", "feature")
      File.write(File.join(dir, "README"), "seed\nthe line under review\n")
      commit(dir, "the work under review")
      File.write(File.join(dir, "later.rb"), "the second commit\n")
      commit(dir, "and the commit after it")
      @repo = dir
      example.run
    end
  end

  def commit(dir, subject)
    git(dir, "add", "-A")
    git(dir, "commit", "-q", "-m", subject)
  end

  def git(dir, *)
    Mixlib::ShellOut.new("git", "-C", dir, *,
                         environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB).run_command.error!
  end

  # An editor attached, exactly as {Lain::CLI::Repl#run} attaches one.
  def attached
    replies.bind_editor(rail)
    replies.bind_review_editor(editor)
  end

  # The whole round trip, on the rail a real editor uses: push the wire's own
  # message, run the reply surfaces for real, and stop them. Bounded, so a
  # gesture nothing consumes is a failing example naming the condition rather
  # than a hang.
  def gestured(*commands, &settled)
    commands.each { |wire| rail.push(wire) }
    Sync do |task|
      # The CONVERSATION's surfaces, not the ask's. The two were split, and the
      # editor rail moved to the conversation-scoped one -- which is what a
      # gesture arriving while the human sits at `you>` is served by. Spinning
      # only these is therefore the stronger claim: it says a gesture needs no
      # model turn in flight, which is the whole of the defect that split closed.
      surfaces = replies.session_surfaces(task)
      begin
        pumped_until(task, reason: "the gesture was served", &settled)
      ensure
        surfaces.each(&:stop)
      end
    end
  end

  # The rendering the human is looking at, and the stamp it carries -- read off
  # the view the command bound, never rebuilt here, because a stamp is only
  # resolvable by the view that issued it.
  def sidebar = editor.review_view.render(editor.bound.session.marked, scope: :cumulative)

  def row_of(rendering, path) = rendering.lines.index { |line| line.include?(path) } + 1

  # THE LAST LINK, and the one this chunk has now missed twice: a command that
  # works and is registered, against a line a human actually types. `/review
  # 4821` and `/review .../pull/12` both have to survive {Skill::Invocation}'s
  # grammar with their target intact -- a bare number and a URL are the two
  # spellings {Lain::CLI::Review::Target} exists to tell apart, and a dispatcher
  # that swallowed either would hand this command an empty line and get its
  # usage back, looking for all the world like the human mistyped.
  describe "the line a human types, through the registry that dispatches it" do
    let(:registry) { Lain::CLI::Command::Registry.new([command]).bind(env) }

    it "reaches the command with its target intact" do
      attached

      answer = registry.dispatch("/review feature --scope commits") { raise "fallthrough must not run" }

      expect(answer).to include("branch feature").and include("commits")
    end

    it "carries a pull-request spelling through rather than eating it" do
      attached

      # Refused by the RESOLVER, naming the number -- which is proof the digits
      # arrived: a swallowed target answers the usage instead.
      expect { registry.dispatch("/review 4821") { raise "fallthrough must not run" } }
        .to raise_error(Lain::Error, /4821/)
    end
  end

  describe "what it refuses before it opens anything" do
    # Both sides call the same method, so this says the two AGREE and nothing
    # about what either contains -- dropping the `format` ships the raw
    # `[--scope %<scopes>s]` template to a human's chat and still passes. The
    # example below is what closes that.
    it "answers its own usage when no target was named" do
      expect(command.call("", env)).to eq(command.usage)
    end

    # What the sentence actually SAYS, against the registry rather than a
    # literal: every registered strategy is advertised, and the template was
    # filled in rather than shipped raw.
    it "advertises every registered scope, with the template resolved" do
      expect(command.usage).to include(*Lain::Review::Partition::STRATEGIES.keys.map(&:to_s))
      expect(command.usage).not_to include("%<")
    end

    # The one refusal that is about the PROCESS rather than the target, and the
    # reason it comes first: a headless chat that drew a review into
    # {Lain::Review::Surface::Null} would report a review nobody can read, which
    # is the exact failure this chunk exists against.
    it "refuses when no editor is attached, rather than drawing into a null surface" do
      expect { command.call("feature", env) }
        .to raise_error(Lain::Error, /no editor/)
    end

    it "refuses a flag it does not carry, rather than reading it as a branch name" do
      attached

      expect { command.call("feature --squash", env) }.to raise_error(Lain::Error, /--squash/)
    end

    it "refuses a flag whose value is missing, rather than treating it as absent" do
      attached

      expect { command.call("feature --base", env) }.to raise_error(Lain::Error, /--base/)
    end

    # Naming the THING a flag takes (a ref, a scope) rather than the generic
    # "a value" -- a human told only that something is missing has to go read
    # the usage line to learn what.
    it "says exactly what --base takes, not merely that it takes something" do
      attached

      expect do
        command.call("feature --base", env)
      end.to raise_error(Lain::Error, "--base takes a ref -- #{command.usage}")
    end

    # {Command::Survey#refuse_unreadable!}'s guard, which this command lacked
    # until it had a switch for the guard to matter to. A flag FOLLOWED BY A
    # SWITCH has that switch for its value: `--base --permissive` would review
    # against a ref named `--permissive` AND silently enable the escape, then
    # fail late as an unresolvable ref -- two wrong things for one typo, and
    # neither of them the missing word.
    it "refuses a flag whose value is itself a flag, rather than reviewing against a ref named --permissive" do
      attached

      expect { command.call("feature --base --permissive", env) }.to raise_error(Lain::Error, /--base/)
    end

    # This command used to ignore every word past the target, and take the
    # LAST of a duplicated flag, with no word about either.
    it "refuses an extra word after the target, naming it" do
      attached

      expect { command.call("main extra", env) }.to raise_error(Lain::Error, /extra/)
    end

    it "refuses a flag given twice, rather than quietly keeping the last" do
      attached

      expect { command.call("feature --base main --base feature", env) }
        .to raise_error(Lain::Error, /--base was given more than once/)
    end

    # {Lain::CLI::Review::Target}'s own refusals, reached rather than restated:
    # this command resolves through that object unchanged, which is what makes
    # the card cheap, and an unresolvable ref must say so in ITS words.
    it "hands back the target resolver's own refusal for a ref that names nothing" do
      attached

      expect { command.call("no-such-branch", env) }
        .to raise_error(Lain::Review::Source::UnknownRef, /no-such-branch/)
    end

    # Nothing may be bound and nothing journaled by a call that refused: a
    # review the human cannot answer is worse than no review, and a rail still
    # holding the last one would route their next verdict to it.
    it "binds no review and journals nothing when the target does not resolve" do
      attached

      expect { command.call("no-such-branch", env) }.to raise_error(Lain::Review::Source::UnknownRef)
      expect(editor.bound).to be_nil
      expect(record.string).to be_empty
    end
  end

  # `--base`'s default is {Lain::Forge::Landing::BASE} ("main"), and a
  # repository whose trunk is called something else has this fail with no
  # `--base` ever typed -- the one shape only THIS command can tell apart
  # from an ordinary typo'd ref, because only it knows which ref came from a
  # flag and which came from a default nobody asked for.
  describe "a repository with no default base to review a branch against" do
    around do |example|
      git(@repo, "branch", "-D", "main")
      example.run
    end

    it "refuses naming --base <ref>, not a bare unresolved-ref message" do
      attached

      expect { command.call("feature", env) }.to raise_error(Lain::Error, /--base <ref>/)
    end

    it "still carries the target resolver's own explanation of what failed" do
      attached

      expect { command.call("feature", env) }.to raise_error(Lain::Error, /"main".*does not resolve/)
    end

    # An EXPLICIT --base that fails to resolve is the human's own typo, not a
    # missing default -- so it keeps the target resolver's plain words rather
    # than being told to do the very thing they just did.
    it "does not redirect an explicit, merely wrong --base to the same remedy" do
      attached

      expect { command.call("feature --base no-such-ref", env) }
        .to raise_error(Lain::Review::Source::UnknownRef, /no-such-ref/)
    end
  end

  describe "opening a review in the editor the chat already has" do
    it "draws the changeset on the editor's own surface and says what it opened" do
      attached

      answer = command.call("feature", env)

      expect(sink.string).to include("README")
      expect(answer).to include("branch feature").and include("cumulative")
    end

    # The banner used to name `:LainReviewDone`, a PROTOCOL-5 EPIC command
    # whose guard (`runtime/65_review.lua:93-98`) requires
    # `b:lain_review_epic_slug` -- a variable a changeset review never stamps
    # either, so the guard could never pass here any more than it can from a
    # survey. `:LainReviewVerdict {verdict}` (`runtime/46_sidebar.lua:188`,
    # protocol 10) is what a changeset review's hand-back actually reaches, and
    # {Command::Survey}'s own spec carries the matching example -- the two
    # banners are one string and this pins both halves of it.
    it "names the command a changeset review's hand-back actually reaches, not the epic surface's" do
      attached

      answer = command.call("feature", env)

      expect(answer).to include(":LainReviewVerdict #{Lain::Review::VERDICTS.first}")
      expect(answer).not_to include("LainReviewDone")
    end

    # The review is part of the chat's RECORD, not a second journal beside it:
    # `/review` inside a cockpit is one session, and a round opened in another
    # file could never be resumed from the session the human was in.
    it "opens the round in the chat's own journal" do
      attached

      command.call("feature", env)

      expect(record.string).to include("changeset_opened").and include("local_branch")
    end

    # ONE object on both rails is asserted by the seam group below, where a
    # gesture arriving on the ACKED rail is read back off the object the ANSWERED
    # rail was handed. This is the half that can be said without the wire: the
    # editor was handed a real review rather than nothing.
    it "hands the editor's write rail the review it just opened" do
      attached

      command.call("feature", env)

      expect(editor.bound).to be_a(Lain::Review::Handover)
      expect(editor.bound.session.changeset.files.map { |file| file.path.to_s }).to include("README")
    end

    # The round has to be reachable from `/review-submit`, and the object
    # that reaches it is the outbox. Asserted through the SESSION rather than
    # through a `have_received(:hold)`, because what matters is that the round
    # the outbox would post is the round this command drew.
    it "holds the round it opened in the run's outbox, so a finished review can leave the machine" do
      attached

      command.call("feature", env)

      expect(outbox).to be_open
      expect(outbox.target).to eq("branch feature")
    end

    # The branch leg's whole point: a review with nowhere to post is still HELD.
    # Refusing to hold it would tell the human "no changeset review is open"
    # when one plainly is, which is the wrong sentence about the wrong thing.
    it "holds a BRANCH round with no pull request, so the refusal names the branch and not an absent review" do
      attached

      command.call("feature", env)

      expect { outbox.submit(executor: instance_double(Lain::Forge::Gh)) }
        .to raise_error(Lain::Review::Submit::Outbox::Nowhere, /branch feature/)
    end

    # The base is what decides WHICH changeset is drawn, so the assertion is
    # about what fell OUT of it: against `HEAD~1` the first commit's README is
    # not in the range, and a `--base` this command ignored would draw it.
    it "honours --base, so a branch can be reviewed against something other than main" do
      attached

      answer = command.call("feature --base HEAD~1", env)

      expect(answer).to include("branch feature")
      expect(sink.string).to include("later.rb")
      expect(sink.string).not_to include("README")
    end

    it "honours --scope, so the commit walk is reachable without a second command" do
      attached

      answer = command.call("feature --scope commits", env)

      expect(answer).to include("commits")
      expect(sink.string).to include("the work under review")
    end

    it "refuses a scope the vocabulary does not declare" do
      attached

      expect { command.call("feature --scope everything", env) }
        .to raise_error(Lain::Review::Session::UnknownScope, /everything/)
    end

    # The cockpit's half of the same claim {Lain::CLI::Review}'s spec makes:
    # registering a strategy is all it takes to reach it, with no literal to
    # add on either command path.
    it "honours a scope that shipped after the vocabulary was written" do
      attached

      answer = command.call("feature --scope by_directory", env)

      expect(answer).to include("by_directory")
    end

    it "resolves the absent flag to the registry's own default" do
      attached

      expect(command.call("feature", env)).to include(Lain::Review::Partition::DEFAULT_SCOPE)
    end

    # THE PARTIAL-REVIEW REFUSAL NAMES A FLAG, and it is one sentence for both
    # review commands -- so a `/review` that could not read it would name a
    # remedy unreachable from the very round that refused, which is the defect
    # the wording change exists to end, moved one command over. Read off the
    # POLICY that reaches `Session.open`: a survey-shaped end-to-end approve
    # needs a repository this group's source double does not have, and nothing
    # downstream of the policy is what this example is about.
    # The negative is the load-bearing half. `Permissive` reads nothing, so a
    # command that resolved the flag to one would let a typed line forgive an
    # objection -- and it would still pass an assertion phrased "the escape was
    # wired".
    it "opens the round under the blocker-respecting escape when --permissive is on the line" do
      attached
      seen = []
      allow(Lain::Review::Session).to receive(:open).and_wrap_original do |original, **kwargs|
        seen << kwargs.fetch(:policy)
        original.call(**kwargs)
      end

      command.call("feature --permissive", env)

      expect(seen.last).to be_an_instance_of(Lain::Review::Verdict::Policy::BlockersOnly)
      expect(seen.last).not_to be_a(Lain::Review::Verdict::Policy::Permissive)
    end

    it "keeps the strict policy when nobody asked for the escape" do
      attached
      seen = []
      allow(Lain::Review::Session).to receive(:open).and_wrap_original do |original, **kwargs|
        seen << kwargs.fetch(:policy)
        original.call(**kwargs)
      end

      command.call("feature", env)

      expect(seen.last).to be_a(Lain::Review::Verdict::Policy::EveryHunk)
    end

    it "offers the flag in its usage, so the refusal's remedy is discoverable before the refusal" do
      expect(command.usage).to include("--permissive")
    end

    # Driven ON THIS COMMAND, end to end and against the real repository this
    # group already builds -- not the policy object, the VERDICT. An earlier
    # draft of this card claimed the round could not be driven this far here.
    # It can: the `around` hook above is a real git tree.
    it "settles an approve over a changeset nobody marked, when --permissive opened it" do
      attached
      command.call("feature --permissive", env)

      expect(editor.bound.wrote_verdict("approve")).to be_nil
    end

    it "refuses that same approve without the flag, naming it as the way past" do
      attached
      command.call("feature", env)

      expect(editor.bound.wrote_verdict("approve")).to include("--permissive")
    end

    # A `blocker` at the line `feature`'s first commit added, in the shape
    # {Lain::Frontend::Neovim::ReviewWrite} normalizes off the wire. The
    # revision is read off the changeset rather than spelled, because an anchor
    # naming another revision is a different refusal entirely.
    def blocker(handover)
      { "path" => "README", "side" => "new", "line" => 2, "anchor_text" => "the line under review",
        "text" => "this is wrong", "kind" => "blocker", "drifted" => false,
        "revision" => handover.session.changeset.head_ref }
    end

    # THE LINE THE FLAG MUST NOT CROSS, on this command too. `/review` advertises
    # the same word in the same `usage`, so an escape that forgave an objection
    # here would forgive it for every reader of the help text.
    it "still refuses an approve over an unanswered blocker, in the blocker's own words" do
      attached
      command.call("feature --permissive", env)
      handover = editor.bound
      handover.wrote_annotation(blocker(handover))

      expect(handover.wrote_verdict("approve")).to include("README:2").and include("nobody has answered")
    end
  end

  # THE OTHER SURFACE, from this side of the pair. `/survey` and `/review` share
  # one outbox and one set of gesture rails, so a changeset review refuses to
  # draw over a survey that is still LIVE -- and stops refusing the moment a
  # human has judged that survey, because the marks it was protecting have been
  # handed back and there is nothing left to draw over.
  #
  # The survey is a double: this file's `around` builds a git repository and no
  # corpus, and the whole of what the guard reads off a held round is the two
  # questions below. `source_name` is asked of {Lain::CLI::Command::Survey}
  # rather than spelled, because that is the one place the word is derived.
  describe "a survey already open in the same chat" do
    def survey_round(verdict:)
      instance_double(Lain::Review::Session, source: Lain::CLI::Command::Survey.source_name, verdict:)
    end

    # The refusal from this side, and it is the one that shipped: asserted on
    # the guard's own sentence, since a `Lain::Error` alone is satisfied by half
    # the refusals this command can raise.
    it "refuses a changeset review over a LIVE survey, in the guard's own words" do
      attached
      outbox.hold(session: survey_round(verdict: Lain::Review::Verdict::None), number: nil,
                  label: "survey of /tmp/corpus")

      expect { command.call("feature", env) }
        .to raise_error(Lain::Error, a_string_including("survey of /tmp/corpus")
                                       .and(include("the gesture rails")))
      expect(editor.bound).to be_nil
    end

    # End to end against the real repository this file already builds: the
    # review OPENS, and the round it opened is the one the chat now holds.
    it "opens a changeset review over a survey that has been settled by a verdict" do
      attached
      outbox.hold(session: survey_round(verdict: "approve"), number: nil, label: "survey of /tmp/corpus")

      answer = command.call("feature", env)

      expect(answer).to include("branch feature")
      expect(editor.bound).to be_a(Lain::Review::Handover)
    end

    # A note pinned where it bites: `hold` REPLACES, so the settled survey
    # is gone the moment the branch round opens and `/review-submit` names the
    # branch. That is the correct answer, and it is worth an example because the
    # alternative reading -- the settled round lingering behind the live one --
    # is exactly what a "closed" state would have introduced.
    it "replaces the settled survey with the round it just opened, so a submit names the branch" do
      attached
      outbox.hold(session: survey_round(verdict: "approve"), number: nil, label: "survey of /tmp/corpus")

      command.call("feature", env)

      expect(outbox.target).to eq("branch feature")
    end
  end

  # `/review close`: the one way a round leaves the chat short of a verdict.
  describe "closing the round this chat has open" do
    let(:registry) { Lain::CLI::Command::Registry.new([command]).bind(env) }

    def closes = Lain::Journal.records(record.string.lines, type: "changeset_closed").to_a

    it "journals the close as the human's, lets the outbox go and unbinds the rails" do
      attached
      command.call("feature", env)
      digest = editor.bound.session.digest

      answer = registry.dispatch("/review close") { raise "fallthrough must not run" }

      expect(answer).to include("branch feature").and include("closed")
      expect(closes.map { |line| line.values_at("changeset_digest", "closed_by") }).to eq([[digest, "human"]])
      expect(outbox).not_to be_open
      expect(editor.bound).to be_nil
    end

    it "draws the close where the sidebar was" do
      attached
      command.call("feature", env)

      command.call("close", env)

      expect(sink.string.lines.last).to include("closed")
    end

    # The rails were unbound, so the review the editor held is nothing a
    # verdict can reach -- and the round itself refuses one too, for whoever
    # still holds it.
    it "refuses a verdict on the closed round" do
      attached
      command.call("feature --permissive", env)
      closed = editor.bound

      command.call("close", env)

      expect(closed.wrote_verdict("approve")).to include("closed")
      expect(record.string).not_to include("review_verdict")
    end

    it "refuses when no round is open, naming that there is nothing to close" do
      attached

      expect { command.call("close", env) }
        .to raise_error(Lain::Error, Lain::Review::Submit::Outbox::NOTHING_TO_CLOSE)
    end

    # A judged round is the one `/review-submit` posts; closing it would lose
    # the review a human has just finished.
    it "refuses a judged round and goes on holding it, so /review-submit still reaches it" do
      attached
      command.call("feature --permissive", env)
      editor.bound.wrote_verdict("approve")

      expect { command.call("close", env) }.to raise_error(Lain::Review::Session::AlreadySettled)
      expect(outbox).to be_open
      expect(editor.bound).to be_a(Lain::Review::Handover)
    end

    # `/review close` on the chat's thread and `:LainReviewVerdict` on the
    # editor's: exactly one of them ends the round, the other is told so in
    # words, and the outbox holds what the winner left.
    describe "racing a verdict from the editor" do
      let(:record) { ReviewCommandSlowIO.new }

      it "journals exactly one of the close and the verdict, and the outbox matches the one that won" do
        attached
        command.call("feature --permissive", env)
        handover = editor.bound

        closer = Thread.new do
          command.call("close", env)
        rescue Lain::Error => e
          e.message
        end
        sleep 0.05
        verdict = handover.wrote_verdict("approve")
        closed = closer.value

        kinds = Lain::Journal.records(record.string.lines).map { |line| line["type"] }.to_a
        ended = kinds & %w[review_verdict changeset_closed]
        expect(ended.size).to eq(1)
        expect(outbox.open?).to eq(ended == %w[review_verdict])
        expect([verdict, closed].grep(/already (closed|judged)/).size).to eq(1)
      end
    end

    describe "a branch literally named close" do
      before { git(@repo, "branch", "close", "feature") }

      it "names refs/heads/close beside the refusal when nothing is open" do
        attached

        expect { command.call("close", env) }
          .to raise_error(Lain::Error, a_string_including("nothing to close").and(include("refs/heads/close")))
      end

      it "closes the open round and names refs/heads/close beside it" do
        attached
        command.call("feature", env)

        expect(command.call("close", env)).to include("closed").and include("refs/heads/close")
        expect(outbox).not_to be_open
      end
    end

    it "names no branch hint when there is no branch named close" do
      attached
      command.call("feature", env)

      expect(command.call("close", env)).not_to include("refs/heads/close")
    end

    it "refuses a flag after close, rather than reading the line as a branch named close" do
      attached

      expect { command.call("close --base main", env) }.to raise_error(Lain::Error, /close takes nothing/)
    end

    # THE CARD'S FIRST CRITERION, end to end: an unsettled survey used to lock
    # `/review` out of the chat for its whole life, because nothing let go of
    # a round short of a verdict.
    describe "a survey nobody settled" do
      let(:survey) do
        home = File.join(@repo, ".home")
        Lain::CLI::Command::Survey.new(outbox:, cwd: @repo, ledger: Lain::Sensitivity::Ledger.new,
                                       sensitivity: Lain::Sensitivity.new(home:, cwd: @repo))
      end

      before do
        FileUtils.mkdir_p(File.join(@repo, "docs"))
        File.write(File.join(@repo, "docs", "notes.md"), "# Notes\n\nOne line of prose.\n")
      end

      it "is freed by /review close, so /review opens and the journal holds the survey round's close" do
        attached
        survey.call(File.join(@repo, "docs"), env)
        survey_digest = editor.bound.session.digest
        expect { command.call("feature", env) }.to raise_error(Lain::Error, /already open/)

        registry.dispatch("/review close") { raise "fallthrough must not run" }
        answer = registry.dispatch("/review feature") { raise "fallthrough must not run" }

        expect(answer).to include("branch feature")
        expect(closes.map { |line| line.values_at("changeset_digest", "closed_by") })
          .to eq([[survey_digest, "human"]])
      end
    end
  end

  # A resumed chat starts from the session it resumed, and nothing of that
  # session's open review round is carried into it: a round is round-scoped.
  # A `/review` of the same target says so, rather than letting a human believe
  # the notes they left there are on the sidebar they are now reading.
  describe "reopening a target in a resumed chat" do
    # The earlier chat, which opened a review of `earlier` and stopped with it
    # open, written where its session file would be; then the resumed one,
    # whose header names that file.
    def resumed(dir, earlier: "feature")
      prior = StringIO.new
      described_class.new(root: @repo, outbox: Lain::Review::Submit::Outbox.new, ledger: Lain::Sensitivity::Ledger.new)
                     .call(earlier, build_command_env(replies:,
                                                      chronicle: chronicle_on(Lain::Journal.new(io: prior), nil)))
      File.write(File.join(dir, "earlier.ndjson"), prior.string)
      current = File.join(dir, "resumed.ndjson")
      File.write(current, "#{JSON.generate("type" => Lain::SessionRecord::HEADER_TYPE,
                                           "resumed_from" => { "file" => "earlier.ndjson", "head" => "x" })}\n")
      build_command_env(replies:, chronicle: chronicle_on(journal, current))
    end

    def chronicle_on(on, path) = instance_double(Lain::CLI::Chronicle, record_journal: on, journal_path: path)

    it "records the target a round was opened on" do
      attached

      command.call("feature", env)

      expect(Lain::Journal.records(record.string.lines, type: "changeset_opened").first)
        .to include("target" => "branch feature")
    end

    it "opens a new round with a banner saying the earlier notes are not carried over" do
      attached
      Dir.mktmpdir("lain-review-resumed") do |dir|
        answer = command.call("feature", resumed(dir))

        expect(answer).to include("not carried over").and include("branch feature")
      end
    end

    it "says nothing about an earlier round on another target" do
      git(@repo, "branch", "other", "feature")
      attached
      Dir.mktmpdir("lain-review-resumed") do |dir|
        answer = command.call("feature", resumed(dir, earlier: "other"))

        expect(answer).not_to include("not carried over")
      end
    end

    # `refs/heads/feature` is the branch `feature`, and a human reopening it by
    # the other spelling is reopening the same review.
    it "journals a branch by its name, whichever way the ref was spelled" do
      attached

      command.call("refs/heads/feature", env)

      expect(Lain::Journal.records(record.string.lines, type: "changeset_opened").first)
        .to include("target" => "branch feature")
    end

    it "says so when the earlier round was opened as refs/heads/feature" do
      attached
      Dir.mktmpdir("lain-review-resumed") do |dir|
        expect(command.call("feature", resumed(dir, earlier: "refs/heads/feature"))).to include("not carried over")
      end
    end

    # The banner is advice about history, and guards nothing: an earlier file
    # this chat cannot read must never stop a new round opening. It says what it
    # could not read instead, so the failure is still in front of the human.
    describe "an earlier session file it cannot read" do
      def resumed_over(dir, earlier_lines)
        File.write(File.join(dir, "earlier.ndjson"), earlier_lines.join) unless earlier_lines.nil?
        current = File.join(dir, "resumed.ndjson")
        File.write(current, "#{JSON.generate("type" => Lain::SessionRecord::HEADER_TYPE,
                                             "resumed_from" => { "file" => "earlier.ndjson", "head" => "x" })}\n")
        build_command_env(replies:, chronicle: chronicle_on(journal, current))
      end

      it "opens the round over a MISSING earlier file, naming the file it could not read" do
        attached
        Dir.mktmpdir("lain-review-resumed") do |dir|
          answer = command.call("feature", resumed_over(dir, nil))

          expect(answer).to include("branch feature").and include("could not read").and include("earlier.ndjson")
          expect(editor.bound).to be_a(Lain::Review::Handover)
        end
      end

      it "opens the round over a MALFORMED earlier review record, naming the file" do
        attached
        malformed = JSON.generate("type" => "changeset_opened", "source" => "local_branch", "base_ref" => "",
                                  "head_ref" => "x", "digest" => "d", "target" => "branch feature")
        Dir.mktmpdir("lain-review-resumed") do |dir|
          answer = command.call("feature", resumed_over(dir, ["#{malformed}\n"]))

          expect(answer).to include("could not read").and include("earlier.ndjson")
          expect(editor.bound).to be_a(Lain::Review::Handover)
        end
      end

      it "opens the round over a TORN trailing line, which is a killed session and not damage" do
        attached
        Dir.mktmpdir("lain-review-resumed") do |dir|
          answer = command.call("feature", resumed_over(dir, ['{"type":"changeset_opened","sou']))

          expect(answer).to include("branch feature")
          expect(answer).not_to include("could not read")
        end
      end
    end
  end

  # THE REGRESSION THIS GROUP EXISTS FOR. The size guard was originally called
  # from {Lain::CLI::Review#present} and nowhere else -- the TEXT command -- so
  # the editor path had no ceiling at all and `/review` of an
  # 800-file pull request drew every row of it into the sidebar. The guard is on
  # {Lain::Review::Session#present} now, which is what both commands reach the
  # surface through.
  #
  # Nothing is doubled here: `sink` is the editor's own REAL
  # {Lain::Review::Surface::Text}, so "the sidebar drew nothing" is read off the
  # bytes an attached editor would have received rather than off a spy's
  # bookkeeping.
  describe "the size past which it refuses to draw in the editor" do
    # The same real outbox the rest of this file uses: a bounded refusal
    # leaves it holding NOTHING (asserted below), which a spy could not say
    # honestly.
    def bounded(**ceilings)
      described_class.new(root: @repo, outbox:, ledger: Lain::Sensitivity::Ledger.new, bounds: Lain::Review::Bounds.new(**ceilings),
                          shell_out_factory: Mixlib::ShellOut.public_method(:new))
    end

    # A branch off `main` wide enough to meet {Lain::Review::Bounds}' own
    # DEFAULT ceiling, so one example here needs no injection at all: the
    # ceilings a human actually meets are the constructor's defaults, and a
    # command bounded only when a caller hands it a Bounds would pass every
    # other example in this block and still draw an 800-file pull request whole.
    def wide_branch(count)
      git(@repo, "checkout", "-q", "-b", "wide", "main")
      count.times { |index| File.write(File.join(@repo, "wide_#{index}.rb"), "#{index}\n") }
      commit(@repo, "a commit nobody can read whole")
    end

    it "refuses a changeset past the default ceiling with nothing injected at all" do
      attached
      wide_branch(Lain::Review::Bounds::DEFAULT_MAX_FILES + 1)

      expect { command.call("wide", env) }
        .to raise_error(Lain::Review::Bounds::TooLarge,
                        a_string_including("ceiling of #{Lain::Review::Bounds::DEFAULT_MAX_FILES}"))
      expect(sink.string).not_to include("wide_0.rb")
    end

    it "refuses a changeset past a ceiling, in Bounds' own words" do
      attached

      expect { bounded(max_files: 1).call("feature", env) }
        .to raise_error(Lain::Review::Bounds::TooLarge, /2 files.*ceiling of 1.*scope: commits/m)
    end

    it "draws only the refusal where the sidebar was, so no sidebar claims to hold the changeset" do
      attached

      expect { bounded(max_files: 1).call("feature", env) }.to raise_error(Lain::Review::Bounds::TooLarge)

      expect(sink.string).not_to include("README")
      expect(sink.string).to include("refused:").and include("ceiling of 1")
    end

    # The round was bound and held before the draw refused, because a human
    # fast enough to answer between the two needs a rail that routes. Once the
    # draw refuses, nothing is left bound: no outbox a `/critique` or a
    # `/review-submit` would read, and no rail a verdict could land on.
    it "leaves nothing bound when it refuses: the outbox is not open and the rails are unbound" do
      attached

      expect { bounded(max_files: 1).call("feature", env) }.to raise_error(Lain::Review::Bounds::TooLarge)

      expect(outbox).not_to be_open
      expect(editor.bound).to be_nil
    end

    it "journals the refused round as closed by the refusal, with no verdict" do
      attached

      expect { bounded(max_files: 1).call("feature", env) }.to raise_error(Lain::Review::Bounds::TooLarge)

      expect(Lain::Journal.records(record.string.lines, type: "changeset_closed").to_a.map { |line| line["closed_by"] })
        .to eq(["refusal"])
      expect(record.string).not_to include("review_verdict")
    end

    # A refusal of a SECOND round lets go of the first as well: its rails were
    # rebound to the refused round before the draw, so a verdict routed to
    # either would land on a round nobody is looking at.
    # BIND BEFORE DRAW leaves a window a fast human can gesture in, on purpose.
    # A gesture landing there must not turn the refusal into something else:
    # the ceiling is still what the human is told, and nothing is left bound.
    describe "a gesture that lands between the bind and the refusal" do
      # The gesture runs at the start of the round's draw, which is after the
      # bind and before the ceiling can refuse.
      def gesture_during_draw(&gesture)
        landing = gesture
        allow(Lain::Review::Session).to receive(:open).and_wrap_original do |open, **kwargs|
          open.call(**kwargs).tap do |session|
            allow(session).to receive(:present).and_wrap_original do |present, **scope|
              landing.call
              present.call(**scope)
            end
          end
        end
      end

      it "still refuses in the ceiling's words and leaves nothing bound when a verdict settled the round first" do
        attached
        gesture_during_draw { editor.bound.wrote_verdict("approve") }

        expect { bounded(max_files: 1).call("feature --permissive", env) }
          .to raise_error(Lain::Review::Bounds::TooLarge)
        expect(editor.bound).to be_nil
        expect(outbox).not_to be_open
      end

      it "still refuses in the ceiling's words when a close landed first" do
        attached
        gesture_during_draw { editor.bound.wrote_close }

        expect { bounded(max_files: 1).call("feature", env) }.to raise_error(Lain::Review::Bounds::TooLarge)
        expect(editor.bound).to be_nil
        expect(Lain::Journal.records(record.string.lines, type: "changeset_closed").count).to eq(1)
      end
    end

    it "leaves nothing bound when it refuses a second round opened over a first" do
      attached
      command.call("feature", env)

      expect { bounded(max_files: 1).call("feature", env) }.to raise_error(Lain::Review::Bounds::TooLarge)

      expect(outbox).not_to be_open
      expect(editor.bound).to be_nil
    end

    # The remedy the refusal names, taken: two commits of one file each fit a
    # ceiling of one where the cumulative view of both does not. Without this
    # the advice could be wrong in exactly the way {Lain::Review::Bounds}'
    # NO_PRESENTABLE_SCOPE exists to prevent.
    it "still draws the commit walk its refusal recommends" do
      attached

      bounded(max_files: 1).call("feature --scope commits", env)

      expect(sink.string).to include("the work under review")
    end
  end

  # THE SEAM THIS CARD EXISTS FOR. Every example drives the wire, never the
  # object: the command opens the review, the editor sends a gesture, the real
  # consumer fiber serves it, and the assertion is about what the session holds.
  describe "the gestures a human makes, arriving on the command inbox", :seam do
    it "records a mark against the session the command opened" do
      attached
      command.call("feature", env)
      rendering = sidebar
      row = row_of(rendering, "README")

      gestured(["review_mark", [row, "reviewed", rendering.generation]]) do
        editor.bound.session.marks.to_h.any?
      end

      expect(editor.bound.session.marks.to_h.values).to all(eq("reviewed"))
      # NOT `be_empty`: a landed mark now says so, once, naming the row. The
      # collection is called `refusals` because the rail is -- it carries every
      # sentence the review surface sends, acknowledgements among them, which is
      # why the assertion has to name what it expects rather than assert silence.
      expect(rail.refusals).to eq(["marked reviewed: 1 hunk(s) of README"])
    end

    # THE COUNTER-EXAMPLE. A stamp the view no longer holds names a row in a
    # buffer whose rows have moved, and the refusal has to reach the editor the
    # gesture came from -- a mark that silently lands on whatever that line
    # names now is a wrong-hunk write, not an error.
    it "refuses a gesture stamped with a rendering the view no longer holds, and says so on the rail" do
      attached
      command.call("feature", env)
      rendering = sidebar
      row = row_of(rendering, "README")
      stale = rendering.generation + Lain::Frontend::Neovim::ReviewView::HELD + 1

      gestured(["review_mark", [row, "reviewed", stale]]) { rail.refusals.any? }

      expect(rail.refusals.first).to include("lain://review")
      expect(editor.bound.session.marks.to_h).to be_empty
    end

    # A stamp is not merely PRESENT-or-absent: a buffer nothing ever rendered
    # into carries none at all, and telling that apart from a stale one is what
    # {Lain::Frontend::Neovim::ReviewView}'s three sentences exist for.
    it "refuses an unstamped gesture with the sentence about an unrendered buffer" do
      attached
      command.call("feature", env)

      gestured(["review_mark", [1, "reviewed", nil]]) { rail.refusals.any? }

      expect(rail.refusals.first).to include("no rendering stamp")
    end

    # THE FIRST LINK OF THE WHOLE GESTURE CHAIN, and the one this rail
    # was missing: `<CR>` -> `review_open` -> {Lain::Review::Handover#open} ->
    # the view -> the diff surface -> the editor. It used to end at
    # {Lain::Frontend::Neovim::ReviewView::Unwired}'s refusal, which meant no
    # diff buffer was ever created -- and since `47_diff.lua`'s `pair()` is what
    # stamps those buffers, `:LainNote` had nowhere to place a note either.
    #
    # The OLD SIDE is what the assertion is about, not that a post happened: the
    # changeset here is a real one over a real repository, `README` genuinely
    # read `seed` at the base and reads `seed` plus a line now, so an
    # implementation posting the new side, the working tree, or nothing at all
    # is a different value rather than the same green.
    it "opens the row's file as a diff pair, old side and both revisions, with nothing refused" do
      attached
      command.call("feature", env)
      rendering = sidebar

      gestured(["review_open", [row_of(rendering, "README"), rendering.generation]]) do
        editor.inlet.posted.any?
      end

      session = editor.bound.session
      expect(editor.inlet.posted)
        .to eq([{ path: "README", old_lines: ["seed"], line: 1,
                  revisions: { "old" => session.changeset.base_ref, "new" => session.changeset.head_ref } }])
      expect(rail.refusals).to be_empty
    end

    # The card's other half: a review whose diff surface nobody wired still says
    # so rather than dropping the gesture. Same command, same rail, an editor
    # built the way every one in this tree was before the diff opener was wired.
    it "refuses an open gesture in words when the editor has no diff surface at all" do
      unwired = Lain::Frontend::Neovim::ReviewView.new
      editor.define_singleton_method(:review_view) { unwired }
      attached
      command.call("feature", env)
      rendering = sidebar

      gestured(["review_open", [row_of(rendering, "README"), rendering.generation]]) { rail.refusals.any? }

      expect(rail.refusals.first).to include("no diff surface is wired")
      expect(editor.inlet.posted).to be_empty
    end

    # RE-AIMED, and deliberately rather than deleted. It used to read "no docent
    # is wired to this review yet", which was true of every review in the tree
    # and is the defect that was filed; the command wires one off the editor's
    # surface now. What this pins is the case that KEEPS the refusal: the editor
    # here draws on {Lain::Review::Surface::Text}, which has no thread pane, and
    # a docent that spent a provider call and drew nowhere is worse than one
    # that refuses. The sentence is unchanged because the human's situation is.
    it "refuses an ask gesture in words where the surface has no thread pane to draw an answer in" do
      attached
      command.call("feature", env)

      gestured(["review_ask", %w[anchor-1 why?]]) { rail.refusals.any? }

      expect(rail.refusals.first).to include("no docent is wired")
    end

    # A second `/review` REBINDS: the rails hold the review the human is
    # actually looking at, or a gesture over the new sidebar records against the
    # old changeset.
    it "rebinds both rails when a second review is opened over the first" do
      attached
      command.call("feature", env)
      first = editor.bound
      command.call("feature", env)
      rendering = sidebar

      gestured(["review_mark", [row_of(rendering, "README"), "reviewed", rendering.generation]]) do
        editor.bound.session.marks.to_h.any?
      end

      expect(editor.bound).not_to equal(first)
      expect(first.session.marks.to_h).to be_empty
    end
  end

  # A docent the command wires is one `/stop` can reach: the supervisor it hands
  # the docent is the run's own, so a dropped pass would leave the answer
  # running with nothing in the fleet to stop.
  describe "the docent this command registers with the run's supervisor" do
    let(:thread_inlet) { ReviewCommandThreadInlet.new }
    let(:editor) { ReviewCommandEditor.new(sink, surface: Lain::Review::Surface::Neovim.new(rpc: thread_inlet)) }

    it "is stopped by /stop, which names it, and its abandonment is journaled" do
      stopped = nil

      Sync do |task|
        supervisor = Lain::Supervisor.new.run(task)
        parked = build_command_env(replies:, chronicle:, supervisor:,
                                   role_spawn: ->(*) { Async::Notification.new.wait })
        attached
        command.call("feature", parked)
        handover = editor.bound
        handover.wrote_annotation({ "path" => "README", "side" => "new", "line" => 2, "kind" => "note",
                                    "anchor_text" => "the line under review", "text" => "why?", "drifted" => false,
                                    "revision" => handover.session.changeset.head_ref })
        handover.ask(thread_inlet.threads.last.first["id"], "why this way?")

        stopped = Lain::CLI::Command::Stop.new.call("", parked)
      ensure
        supervisor.stop
      end

      expect(stopped).to include("diff_docent")
      expect(record.string.lines.map { |line| JSON.parse(line)["type"] }).to include("docent_abandoned")
    end
  end

  # THE RENDERING, READ BACK OUT OF A REAL EDITOR. A nil answer from
  # {Lain::Review::Session#present} means "the surface took it", which for an
  # editor means "queued" and never "drawn" -- so the only assertion worth
  # making about the nvim leg is one that reads the buffer nvim actually holds.
  describe "the sidebar a real nvim draws", :nvim, :seam do
    around { |example| headless_editor("lain-review-cmd") { example.run } }

    def sidebar_lines
      inspector.exec_lua(<<~LUA, [])
        local buf = vim.fn.bufnr("lain://review")
        if buf == -1 then return {} end
        return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      LUA
    end

    it "renders the changeset into lain://review, in the editor the chat is already attached to" do
      frontend = Lain::Frontend::Neovim.new(channel: Lain::Channel.new, socket_path: @socket)

      frontend.run do
        replies.bind_editor(frontend.command_inbox)
        replies.bind_review_editor(frontend)

        command.call("feature", env)

        wait_until(reason: "lain://review carried the changeset") { sidebar_lines.grep(/README/).any? }
      end
    end
  end
end
