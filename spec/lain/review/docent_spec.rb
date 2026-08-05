# frozen_string_literal: true

require "async"
require "stringio"
require "tmpdir"

# T18's thread pane, recorded at the ONE message the docent sends it:
# `#show(anchor, entries)`, answering the notice that says the render did not
# land, or nil.
#
# ⚠️ It is a RECORDING VIEW and not the real pane, and that is a considered
# trade rather than a shortcut. T18's own deletability spec asserts that nothing
# outside its three files names it -- so a spec that constructed the real pane
# here would couple two capabilities that are each supposed to be removable
# alone. What that costs is that the docent's half of the contract (which
# entries, in which order, at which moment) is pinned here and the pane's half
# (entries to buffer lines) is pinned in T18's own file; what binds them is
# `#speaker`/`#text`, and "posts entries the pane's contract can render" below
# is the example that pins those two names.
class RecordingThreadPane
  def initialize(refusal: nil)
    @refusal = refusal
    @posts = []
  end

  attr_reader :posts

  def show(anchor, entries = [])
    @posts << [anchor, entries]
    @refusal
  end

  def last_entries = @posts.last&.last || []

  # THIS FILE'S own rendering, not a claim about the pane's: it exists so an
  # example can say "the marker is in the thread" in one readable assertion.
  def text = last_entries.map { |entry| "## #{entry.speaker}\n#{entry.text}" }.join("\n\n")
end

# The gesture adapter `bind_changeset_review` is handed is a later wiring card's
# object ({Lain::Review::Surface::Neovim}'s own doc says so). This is the one
# message of it the docent answers, which is exactly the point: {Docent::Asked}
# has to satisfy the `#asked?`/`#report` duck
# {Lain::CLI::HumanReplies::Gestures} asks of it.
class DocentGestureRail
  def initialize(docent) = @docent = docent
  def open(_line, **) = raise(NotImplementedError)
  def mark(_line, _state, **) = raise(NotImplementedError)
  def ask(anchor_id, question) = @docent.ask(anchor_id, question)
end

# {Lain::CLI::HumanReplies}' inbound rail, recorded: it hands the serving loop
# one queued command per pop and collects what the loop tried to tell the human.
# `refusals` being EMPTY is the assertion that a failed docent stayed in the
# thread rather than coming back as a refused gesture.
class DocentEditorRail
  def initialize = @commands = []

  attr_reader :commands

  def push(command) = @commands.push(command)
  def pop(*) = @commands.shift
  def review_refused(message) = refusals << message
  def refusals = @refusals ||= []
  def attached? = true
end

# The docent: a question about one hunk, answered by a fresh role-scoped child
# and rendered back into T18's thread pane.
#
# Two things in here are deliberately NOT doubled, because doubling either would
# have made the property vacuous:
#
# * the ANSWERER genuinely takes two seconds (`Async::Task.current.sleep(2)`).
#   A mock that resolves synchronously proves nothing about blocking -- the
#   ordering it produces is the ordering a blocking implementation produces too.
# * the DUPLICATE case is driven twice, once with the first answer already in
#   and once with it still outstanding, because the window a re-sent `:w`
#   actually arrives in is the second one and a guard that closed only after an
#   answer would pass the first case alone.
RSpec.describe Lain::Review::Docent do
  # Three files; app.rb has TWO hunks, and the second one is the discriminator
  # for "the prompt carries THIS hunk". New-side numbering: hunk one covers 40,
  # 41 and 42, hunk two covers 81 and 82, and 60 is in the file and in no hunk.
  # (The first two borrowed verbatim from `submit_spec.rb`, which needs the same
  # shape.)
  #
  # The THIRD file is a rename whose two sides are numbered differently -- old
  # 10..11, new 20..21 -- because it is the only shape in which the locator's
  # old-side path and the old-side line numbers are both falsifiable. With every
  # anchor on the new side of an unrenamed file, an implementation that indexed
  # on `new_path` and one that always spanned with new-side numbers were both
  # green.
  def diff
    <<~DIFF
      diff --git a/app.rb b/app.rb
      index 1111111..2222222 100644
      --- a/app.rb
      +++ b/app.rb
      @@ -40,2 +40,3 @@ def alpha
       forty
      -forty one
      +FORTY ONE
      +forty two
      @@ -80,2 +81,2 @@ def beta
       eighty
      -eighty one
      +EIGHTY ONE
      diff --git a/lib/other.rb b/lib/other.rb
      index 3333333..4444444 100644
      --- a/lib/other.rb
      +++ b/lib/other.rb
      @@ -1,2 +1,2 @@ def gamma
       x
      -y
      +Y
      diff --git a/lib/was_here.rb b/lib/is_here.rb
      similarity index 88%
      rename from lib/was_here.rb
      rename to lib/is_here.rb
      index 5555555..6666666 100644
      --- a/lib/was_here.rb
      +++ b/lib/is_here.rb
      @@ -10,2 +20,2 @@ def delta
       ten
      -eleven
      +ELEVEN
    DIFF
  end

  def base_sha = -("b" * 40)

  def head_sha = -("h" * 40)

  def commits
    numstat = %w[app.rb lib/other.rb lib/is_here.rb].map do |path|
      Lain::Review::Source::FileStat.new(path: -path, added: 2, deleted: 1)
    end
    [Lain::Review::Source::Commit.new(sha: -("c" * 40), subject: "the work", body: "", numstat: numstat.freeze)]
  end

  let(:changeset) do
    Lain::Review::Changeset.new(
      source: instance_double(Lain::Review::Source::LocalBranch, diff: diff.b, commits: commits.freeze,
                                                                 base_ref: base_sha, head_ref: head_sha)
    )
  end
  let(:view) { RecordingThreadPane.new }
  let(:journal) { [] }
  let(:output) { StringIO.new }
  let(:editor) { DocentEditorRail.new }

  def anchor(path: "app.rb", side: :new, line: 42, anchor_text: "forty two", revision: head_sha, id: "a-42")
    Lain::Review::Anchor.new(path:, side:, line:, anchor_text:, revision:, id:)
  end

  # An answerer is `#call(prompt) -> Tool::Result`, which is the whole of the
  # bench arm: the DEFAULT spawns the `diff_docent` role over a fresh root, and
  # any object answering that one message can stand in its place.
  def recording_answerer(text = "because beta needed the same shape")
    prompts = []
    answerer = ->(prompt) { prompts << prompt and Lain::Tool::Result.ok(text) }
    [answerer, prompts]
  end

  def docent(answerer:, dossier: {}, runner: Lain::Review::Docent::Reactor, role: nil)
    described_class.new(changeset:, view:, answerer:, journal:, dossier:, runner:, role:)
  end

  # The only journal type a bench query joins on, and every example below that
  # reads the record reads it through here.
  def asked_records = journal.select { |record| record.journal_type == "docent_asked" }

  describe "asking does not block the editor" do
    # THE anti-vacuity example of this file. The answerer really does take two
    # seconds, on the same reactor, so an implementation that awaited the answer
    # inside #ask would measure ~2s here rather than ~0s. A synchronous mock
    # would pass against BOTH implementations, which is why there isn't one.
    it "returns before a two-second answer arrives, and renders a pending marker" do
      slow = lambda do |_prompt|
        Async::Task.current.sleep(2)
        Lain::Tool::Result.ok("the late answer")
      end

      Sync do
        subject = docent(answerer: slow)
        subject.open(anchor)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        asked = subject.ask("a-42", "why this way?")
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        expect(asked).to be_asked
        expect(elapsed).to be < 0.5
        expect(view.text).to include("why this way?").and include(described_class::PENDING)
        expect(view.text).not_to include("the late answer")
        asked.task.stop
      end
    end

    # The other half: the same non-blocking ask DOES land, and the pending marker
    # is REPLACED rather than left above the answer.
    it "renders the answer into the same thread once it arrives, in place of the marker" do
      answerer, = recording_answerer

      Sync do
        subject = docent(answerer:)
        subject.open(anchor)
        subject.ask("a-42", "why this way?").task.wait

        expect(view.text).to include("why this way?").and include("because beta needed the same shape")
        expect(view.text).not_to include(described_class::PENDING)
      end
    end
  end

  # What binds this object to the pane on the other side of the seam is the
  # PORT's own value ({Lain::Review::Surface::Message}) -- neither side's, so
  # neither side names the other and neither takes the other with it when it is
  # deleted. This is where the docent's half of that is pinned: it posts the
  # port's value, and the port's value is what a thread conversation is made of.
  describe "what it posts to the thread pane" do
    it "posts the port's own messages, the human's words above the reply, oldest first" do
      answerer, = recording_answerer

      Sync do
        subject = docent(answerer:)
        subject.open(anchor)
        subject.ask("a-42", "why this way?").task.wait
        subject.ask("a-42", "and the second?").task.wait
      end

      expect(view.last_entries).to all(be_a(Lain::Review::Surface::Message))
      expect(view.last_entries.map { |entry| [entry.speaker, entry.text] })
        .to eq([[described_class::SPEAKER_HUMAN, "why this way?"],
                [described_class::SPEAKER_DOCENT, "because beta needed the same shape"],
                [described_class::SPEAKER_HUMAN, "and the second?"],
                [described_class::SPEAKER_DOCENT, "because beta needed the same shape"]])
    end

    # The anchor rides WHOLE, which is T18's rule: the pane is cursor-driven and
    # no other entry point on that rail carries an anchor's position.
    it "posts the anchor itself, not its id" do
      answerer, = recording_answerer
      placed = anchor

      Sync { docent(answerer:).open(placed) }

      expect(view.posts.last.first).to be(placed)
    end

    # An answer nobody can see is not worth a provider call, and a question left
    # in an unrendered thread would make the human's retry look like a duplicate.
    it "takes the question back and spends nothing when the render did not land" do
      answerer, prompts = recording_answerer
      detached = RecordingThreadPane.new(refusal: "showing a review thread needs an attached editor")
      subject = described_class.new(changeset:, view: detached, answerer:, journal:)

      Sync do
        subject.open(anchor)
        asked = subject.ask("a-42", "why this way?")

        expect(asked).not_to be_asked
        expect(asked.report).to include("attached editor")
      end

      expect(prompts).to be_empty
      expect(journal).to be_empty
      expect(subject.conversation("a-42").entries).to be_empty
    end
  end

  describe "the answer carries the hunk as context" do
    # A prompt carrying the WHOLE diff would satisfy "contains that hunk's
    # lines" and be useless, so the fixture has a second hunk in the same file
    # and the assertion is two-sided: hunk one's lines are there and hunk two's
    # are not.
    it "gives the spawned role the enclosing hunk and not its neighbour" do
      answerer, prompts = recording_answerer

      Sync do
        subject = docent(answerer:)
        subject.open(anchor)
        subject.ask("a-42", "why this way?").task.wait
      end

      expect(prompts.size).to eq(1)
      expect(prompts.first).to include("-forty one").and include("+FORTY ONE").and include("+forty two")
      expect(prompts.first).not_to include("EIGHTY ONE")
      expect(prompts.first).not_to include("eighty")
    end

    it "gives it both revisions of the enclosing function, under its heading" do
      answerer, prompts = recording_answerer

      Sync do
        subject = docent(answerer:)
        subject.open(anchor(line: 82, anchor_text: "EIGHTY ONE", id: "a-82"))
        subject.ask("a-82", "and this?").task.wait
      end

      expect(prompts.first).to include("def beta")
      old_heading = Regexp.escape(described_class::Brief::BEFORE % base_sha)
      new_heading = Regexp.escape(described_class::Brief::AFTER % head_sha)
      expect(prompts.first).to match(/#{old_heading}\n+eighty\neighty one\b/)
      expect(prompts.first).to match(/#{new_heading}\n+eighty\nEIGHTY ONE\b/)
    end

    it "carries the question, the task card, the hand-back and the panel's findings it was given" do
      answerer, prompts = recording_answerer
      dossier = { "The task card" => "T24 -- answer a question about a hunk",
                  "The hand-back" => "the enclosing function moved for the tests' sake",
                  "The panel's findings" => "JMK: review_ask carries no stamp" }

      Sync do
        subject = docent(answerer:, dossier:)
        subject.open(anchor)
        subject.ask("a-42", "why this way?").task.wait
      end

      expect(prompts.first).to include("why this way?")
      dossier.each { |title, body| expect(prompts.first).to include(title).and include(body) }
    end

    # The second-order property the card names: a docent that cannot say why is
    # reporting on the hand-back, so the hand-back's ABSENCE has to be visible in
    # the prompt rather than silently rendered as nothing.
    it "says so in the prompt when it was given no dossier at all" do
      answerer, prompts = recording_answerer

      Sync do
        subject = docent(answerer:)
        subject.open(anchor)
        subject.ask("a-42", "why this way?").task.wait
      end

      expect(prompts.first).to include(described_class::Brief::NO_DOSSIER)
    end
  end

  # The locator's OLD side was dead in every example: with every anchor on the
  # new side of an unrenamed file, indexing on the file's new path and spanning
  # with the new side's line numbers both survived as mutants. The comment at
  # the locator states a rule about renamed files that nothing held.
  describe "which hunk an anchor sits in" do
    def moved(line:, id:)
      anchor(path: "lib/was_here.rb", side: :old, line:, anchor_text: "eleven", revision: base_sha, id:)
    end

    it "finds an old-side anchor by its old path and its old line numbers" do
      answerer, prompts = recording_answerer
      subject = docent(answerer:)

      expect(subject.open(moved(line: 11, id: "a-old"))).not_to be_nil

      Sync { subject.ask("a-old", "why did this move?").task.wait }

      expect(prompts.first).to include("-eleven").and include("+ELEVEN")
      expect(journal.first.to_journal)
        .to include("path" => "lib/was_here.rb", "side" => "old", "line" => 11)
    end

    # The same file, at a line that is only in the NEW side's numbering: an
    # old-side anchor there sits in no hunk, and a locator spanning with new
    # numbers would answer one.
    it "reports no thread on an old-side line the old numbering does not cover" do
      answerer, = recording_answerer

      expect(docent(answerer:).open(moved(line: 20, id: "a-new-numbers"))).to be_nil
    end
  end

  describe "the exchange is journaled for replay" do
    it "records the question and the answer as two joinable records" do
      answerer, = recording_answerer

      Sync do
        subject = docent(answerer:)
        subject.open(anchor)
        subject.ask("a-42", "why this way?").task.wait
      end

      types = journal.map(&:journal_type)
      expect(types).to eq(%w[docent_asked docent_answered])
      expect(journal.first.to_journal).to include("anchor_id" => "a-42", "question" => "why this way?",
                                                  "path" => "app.rb", "side" => "new", "line" => 42)
      expect(journal.last.to_journal).to include("anchor_id" => "a-42", "question" => "why this way?",
                                                 "answer" => "because beta needed the same shape")
    end

    # The absence of the provider call is ASSERTED, not merely unobserved: the
    # replaying docent holds an answerer that raises the moment anything calls
    # it. A docent wired to nothing could not be called either, which is not
    # evidence of anything.
    it "reproduces the exchange from the journal with no provider call" do
      answerer, = recording_answerer
      live = nil

      Sync do
        subject = docent(answerer:)
        subject.open(anchor)
        subject.ask("a-42", "why this way?").task.wait
        live = view.text
      end

      forbidden = ->(_prompt) { raise "the docent must not be asked again on replay" }
      replayed_pane = RecordingThreadPane.new
      replayed = described_class.new(changeset:, view: replayed_pane, answerer: forbidden, journal: [])
      replayed.replay(journal.map(&:to_journal))
      replayed.open(anchor)

      expect(replayed_pane.text).to eq(live)
    end

    # Compared with `eq` against the WHOLE live rendering, exactly as its
    # sibling above is, and for a reason `include` cannot carry: the provider's
    # own words appear in a refusal, in an answer that merely quoted them, and
    # in a refusal spoken by the wrong speaker, so an `include` on them holds
    # against every implementation that loses the distinction the example is
    # named for. Two minimal mutants -- replaying the refusal as the docent, and
    # dropping the FAILED wrapper so the provider's words come back as if the
    # docent had said them -- both survived it.
    it "replays a refusal as the refusal, not as an answer" do
      live = nil

      Sync do
        subject = docent(answerer: ->(_prompt) { raise "the provider fell over" })
        subject.open(anchor)
        subject.ask("a-42", "why this way?").task.wait
        live = view.text
      end

      forbidden = ->(_prompt) { raise "the docent must not be asked again on replay" }
      replayed_pane = RecordingThreadPane.new
      replayed = described_class.new(changeset:, view: replayed_pane, answerer: forbidden, journal: [])
      replayed.replay(journal.map(&:to_journal))
      replayed.open(anchor)

      expect(journal.map(&:journal_type)).to eq(%w[docent_asked docent_refused])
      expect(live).to include(described_class::SPEAKER_LAIN).and include("the provider fell over")
      expect(replayed_pane.text).to eq(live)
    end

    # Strictly stronger than the text comparison above, and it costs nothing:
    # a replay that DID reach for the provider would raise inside the answer
    # task, where `deliver`'s rescue would swallow it into a refusal -- so the
    # text comparison catches it as a mismatch rather than as the raise it is.
    # This counts the calls instead.
    it "asks no answerer at all while replaying" do
      answerer, prompts = recording_answerer

      Sync do
        subject = docent(answerer:)
        subject.open(anchor)
        subject.ask("a-42", "why this way?").task.wait
      end

      replays = 0
      counted = ->(prompt) { replays += 1 and answerer.call(prompt) }
      replayed = described_class.new(changeset:, view: RecordingThreadPane.new, answerer: counted, journal: [])
      replayed.replay(journal.map(&:to_journal))
      replayed.open(anchor)
      replayed.conversation("a-42").entries

      expect(prompts.size).to eq(1)
      expect(replays).to eq(0)
    end
  end

  describe "a repeated question is not a repeated spawn" do
    # `review_ask` carries no stamp and T18's editor half re-sends the identical
    # payload on a second `:w`, so the SAME question arrives twice. A spawn is a
    # provider round trip and real money, so the second one must not happen --
    # and it must not happen here, in Ruby, whether or not the editor is ever
    # fixed.
    it "refuses the second of two identical asks and spawns nothing for it" do
      answerer, prompts = recording_answerer
      second = nil

      Sync do
        subject = docent(answerer:)
        subject.open(anchor)
        subject.ask("a-42", "why this way?").task.wait
        second = subject.ask("a-42", "why this way?")
      end

      expect(prompts.size).to eq(1)
      expect(second).not_to be_asked
      expect(second.report).to include("already asked")
      expect(second.task).to be_nil
      expect(journal.map(&:journal_type)).to eq(%w[docent_asked docent_answered])
    end

    # The window the duplicate actually arrives in is one round trip wide, so the
    # guard has to hold while the FIRST answer is still outstanding -- a check
    # against journaled answers alone would let both spawns through.
    it "refuses a duplicate that arrives while the first is still in flight" do
      slow = lambda do |_prompt|
        Async::Task.current.sleep(2)
        Lain::Tool::Result.ok("the late answer")
      end
      spawns = 0
      counting = ->(prompt) { spawns += 1 and slow.call(prompt) }

      Sync do |task|
        subject = docent(answerer: counting)
        subject.open(anchor)
        first = subject.ask("a-42", "why this way?")
        second = subject.ask("a-42", "why this way?")

        expect(second).not_to be_asked
        expect(second.task).to be_nil
        # The first answer has not STARTED yet -- nothing of the answerer runs
        # on the fiber #ask was called on -- so the count is only meaningful
        # once the reactor has been given the chance to run it.
        task.with_timeout(3) { task.sleep(0.01) until spawns.positive? }
        first.task.stop
      end

      expect(spawns).to eq(1)
    end

    # A DIFFERENT question on the same thread is a different ask, or the guard
    # would swallow the human's follow-up.
    it "asks again when the question is not the same one" do
      answerer, prompts = recording_answerer

      Sync do
        subject = docent(answerer:)
        subject.open(anchor)
        subject.ask("a-42", "why this way?").task.wait
        subject.ask("a-42", "and what breaks if I change it?").task.wait
      end

      expect(prompts.size).to eq(2)
    end
  end

  describe "a failed docent refuses in the thread" do
    it "shows a refusal naming the failure rather than an answer" do
      Sync do
        subject = docent(answerer: ->(_prompt) { raise "the provider fell over" })
        subject.open(anchor)
        subject.ask("a-42", "why this way?").task.wait
      end

      expect(view.text).to include(described_class::SPEAKER_LAIN)
      expect(view.text).to include("the provider fell over")
      expect(view.text).not_to include(described_class::PENDING)
    end

    # A tool result carrying `is_error` is the OTHER failure shape, and it does
    # not raise -- so a rescue alone would render the provider's error text as
    # if the docent had said it.
    it "shows a refusal when the answerer reports its own failure" do
      failed = ->(_prompt) { Lain::Tool::Result.error("the child hit its depth ceiling") }

      Sync do
        subject = docent(answerer: failed)
        subject.open(anchor)
        subject.ask("a-42", "why this way?").task.wait
      end

      expect(view.text).to include(described_class::SPEAKER_LAIN)
      expect(view.text).to include("the child hit its depth ceiling")
    end

    # A ScriptError is not a StandardError, and it is the shape that walked past
    # this guard's sibling on the editor rail once -- `deliver`'s rescue names
    # it for that reason and nothing held it. Without the clause the answering
    # task dies with the raise and the thread keeps a marker forever.
    it "shows a refusal when the answerer raises something that is not a StandardError" do
      Sync do
        subject = docent(answerer: ->(_prompt) { raise NotImplementedError, "no arm is wired here" })
        subject.open(anchor)
        subject.ask("a-42", "why this way?").task.wait
      end

      expect(view.text).to include(described_class::SPEAKER_LAIN).and include("no arm is wired here")
      expect(view.text).not_to include(described_class::PENDING)
      expect(journal.map(&:journal_type)).to eq(%w[docent_asked docent_refused])
    end

    # An arm that answers with nothing at all trips the record's own guard, and
    # the human was shown the guard's sentence -- true, and written for a
    # programmer.
    it "refuses in the docent's own words when the answer is empty" do
      Sync do
        subject = docent(answerer: ->(_prompt) { Lain::Tool::Result.ok("   ") })
        subject.open(anchor)
        subject.ask("a-42", "why this way?").task.wait
      end

      expect(view.text).to include(format(described_class::FAILED, described_class::SAID_NOTHING))
      expect(view.text).not_to include("must carry what the docent said")
      expect(journal.map(&:journal_type)).to eq(%w[docent_asked docent_refused])
    end

    it "refuses by name, in the thread, when the anchor sits in no hunk of this changeset" do
      answerer, prompts = recording_answerer
      subject = docent(answerer:)

      opened = subject.open(anchor(line: 60, anchor_text: "sixty", id: "a-60"))

      expect(opened).to be_nil
      expect(subject.ask("a-60", "why?")).not_to be_asked
      expect(subject.ask("a-60", "why?").report).to include("no hunk")
      expect(prompts).to be_empty
    end
  end

  # The fiber this rides on is {Lain::CLI::HumanReplies#editor_reply_loop}, the
  # SOLE consumer of every editor verb -- so a docent that raised into it, or
  # blocked it, would take :LainReply and every review gesture down with it.
  # Asserted by driving a SECOND request through the same fiber, never by
  # reading a flag off it.
  describe "the serving fiber survives", :seam do
    around do |example|
      Dir.mktmpdir do |dir|
        @dir = dir
        example.run
      end
    end

    def replies
      @replies ||= Lain::CLI::HumanReplies.new(
        tty: Lain::Frontend::TTY.new(channel: Lain::Channel.new, output:, input: StringIO.new,
                                     history_path: File.join(@dir, "history")),
        conductor: instance_double(Lain::CLI::Conductor), ask_human: instance_double(Lain::Tools::AskHuman),
        questions: Async::Queue.new
      )
    end

    it "serves a second question after the first one's docent raised" do
      answers = ["fell over", "the second answer"]
      answerer = lambda do |_prompt|
        head = answers.shift
        raise head if head == "fell over"

        Lain::Tool::Result.ok(head)
      end

      Sync do |task|
        subject = docent(answerer:)
        subject.open(anchor)
        replies.bind_editor(editor)
        replies.bind_changeset_review(DocentGestureRail.new(subject))
        # T33: the editor's consumer is the SESSION's surface, not an ask's --
        # a docent question is asked while reading a diff, between turns.
        surfaces = replies.session_surfaces(task)
        begin
          editor.push(["review_ask", ["a-42", "why this way?"]])
          editor.push(["review_ask", ["a-42", "and the second?"]])
          task.with_timeout(3) do
            task.sleep(0.01) until view.text.include?("the second answer")
          end
        ensure
          surfaces.each(&:stop)
        end
      end

      expect(view.text).to include("fell over").and include("the second answer")
      expect(editor.refusals).to be_empty
    end
  end

  # The record exists to make two arms comparable, and it named a CONSTANT: two
  # docents differing only in their role journaled byte-identical records, a
  # bare lambda was filed under the shipped role's name, and the field a bench
  # comparison queries answered one bucket for every arm -- green throughout.
  # These are the experiment the field claims to support, run as a test.
  describe "the record names the arm that answered" do
    def journal_of(answerer, role: nil)
      records = []
      Sync do
        subject = described_class.new(changeset:, view: RecordingThreadPane.new, answerer:, journal: records,
                                      role:)
        subject.open(anchor)
        subject.ask("a-42", "why this way?").task.wait
      end
      records.map(&:to_journal)
    end

    it "journals two arms as two arms, so an arm comparison is a query and not a guess" do
      spawn = ->(_role, _mode, _brief) { Lain::Tool::Result.ok("said") }
      asked = %i[diff_docent researcher].map do |role|
        journal_of(described_class::Answerer.new(spawn:, role:)).first
      end

      expect(asked.map { |record| record["role"] }).to eq(%w[diff_docent researcher])
      expect(asked.first).not_to eq(asked.last)
    end

    it "records an arm that cannot name itself as anonymous, never as the shipped role" do
      answerer, = recording_answerer

      asked = journal_of(answerer).first

      expect(asked["role"]).to eq(described_class::ANONYMOUS_ARM.to_s)
      expect(asked["role"]).not_to eq(described_class::ROLE.to_s)
    end

    it "lets a bench arm name a lambda on the record" do
      answerer, = recording_answerer

      asked = journal_of(answerer, role: :recorded_oracle).first

      expect(asked["role"]).to eq("recorded_oracle")
    end

    # The other half of "comparable byte for byte": the record addresses the
    # PROMPT, so two arms handed different evidence are told apart without the
    # record carrying the diff, the dossier and both revisions. Before this, a
    # docent given a 428-line hand-back and one given nothing at all journaled
    # identical records -- the NO_DOSSIER distinction survived in the prompt and
    # was lost in the record.
    it "journals the address of the exact prompt the arm was handed" do
      answerer, prompts = recording_answerer
      keys = [{}, { "The hand-back" => "the enclosing function moved for the tests' sake" }, {}].map do |dossier|
        records = []
        Sync do
          subject = described_class.new(changeset:, view: RecordingThreadPane.new, answerer:, journal: records,
                                        dossier:)
          subject.open(anchor)
          subject.ask("a-42", "why this way?").task.wait
        end
        records.first.to_journal["brief_key"]
      end

      expect(keys.first).to eq(keys.last)
      expect(keys.first).not_to eq(keys[1])
      expect(keys.first).to eq(Lain::Review::Keying.digest(described_class::Brief::KEY_SCHEME, [prompts.first]))
    end
  end

  # Everything that mutates a thread happens between `conversation.ask` and the
  # scheduled task, and a raise anywhere in that window used to refuse the human
  # WITHOUT taking the question back: a permanent "(thinking...)" marker, an
  # empty or half-written record, and every retry refused as a duplicate of a
  # question that was never asked. The question became unaskable forever.
  describe "a question that did not make it onto a task is taken back" do
    it "takes it back when there is no reactor to answer on, and lets it be asked again" do
      answerer, prompts = recording_answerer
      subject = docent(answerer:, runner: described_class::Reactor)

      subject.open(anchor)
      refused = subject.ask("a-42", "why this way?")

      expect(refused).not_to be_asked
      expect(refused.report).to include("no reactor")
      expect(subject.conversation("a-42").entries).to be_empty
      expect(view.text).not_to include(described_class::PENDING)
      expect(journal.map(&:journal_type)).to eq(%w[docent_asked docent_refused])
      expect(prompts).to be_empty

      # The point of all of the above: the human can ask it again.
      Sync { subject.ask("a-42", "why this way?").task.wait }
      expect(prompts.size).to eq(1)
      expect(view.text).to include("because beta needed the same shape")
    end

    # Reachable through the shipped pane, which raises on an anchor with a blank
    # id -- and a ScriptError rather than a StandardError, because that is the
    # shape that walked past this guard's sibling on the editor rail once.
    it "takes it back when the pane raises, and leaves nothing on the record" do
      answerer, prompts = recording_answerer
      raising = Class.new do
        def show(_anchor, _entries = []) = raise(NotImplementedError, "the pane is half-built")
      end.new
      subject = described_class.new(changeset:, view: raising, answerer:, journal:)

      Sync do
        subject.open(anchor(id: "a-42"))
      rescue NotImplementedError
        nil
      end

      Sync do
        refused = subject.ask("a-42", "why this way?")

        expect(refused).not_to be_asked
        expect(refused.report).to include("half-built")
      end

      expect(prompts).to be_empty
      expect(journal).to be_empty
      expect(subject.conversation("a-42").entries).to be_empty
    end
  end

  describe "one question gets one terminal record" do
    # `docent_answered` used to be written BEFORE the render, so a render that
    # failed left an answer AND a refusal on one question: an answer rate
    # counted over the two types double-counted that arm in both buckets, and
    # replay -- last writer wins -- rendered only the refusal, so an answer that
    # was on the record could not be got back out of it.
    it "does not journal an answer and a refusal for the same question" do
      answerer, = recording_answerer
      failing = Class.new do
        def initialize = @shown = 0

        def show(_anchor, entries = [])
          @shown += 1
          raise "the pane died mid-answer" if entries.any? { |entry| entry.text.include?("because beta") }

          nil
        end
      end.new
      subject = described_class.new(changeset:, view: failing, answerer:, journal:)

      Sync do
        subject.open(anchor)
        subject.ask("a-42", "why this way?").task.wait
      end

      expect(journal.map(&:journal_type)).to eq(%w[docent_asked docent_refused])
      expect(journal.map(&:journal_type).tally.values).to all(eq(1))
    end

    # A session ending mid-answer raises Async::Stop, which must NOT be caught
    # -- so nothing settled and nothing was journaled, and a fresh docent
    # replaying that record rendered a thread that was permanently thinking and
    # refused the re-ask as a duplicate of it.
    it "closes the record when the session ends before the answer does, and stays askable" do
      slow = lambda do |_prompt|
        Async::Task.current.sleep(2)
        Lain::Tool::Result.ok("the late answer")
      end

      Sync do |task|
        subject = docent(answerer: slow)
        subject.open(anchor)
        asked = subject.ask("a-42", "why this way?")
        task.yield
        asked.task.stop
      end

      expect(journal.map(&:journal_type)).to eq(%w[docent_asked docent_abandoned])

      answerer, prompts = recording_answerer
      replayed_pane = RecordingThreadPane.new
      replayed = described_class.new(changeset:, view: replayed_pane, answerer:, journal: [])
      replayed.replay(journal.map(&:to_journal))
      replayed.open(anchor)

      expect(replayed_pane.text).to include(described_class::ABANDONED)
      expect(replayed_pane.text).not_to include(described_class::PENDING)

      Sync { replayed.ask("a-42", "why this way?").task.wait }
      expect(prompts.size).to eq(1)
    end

    # The duplicate refusal says the answer is in the pane. After a provider
    # fell over the pane holds a refusal, not an answer, and a retry then is
    # exactly the case where a repeat is a genuinely different ask -- it was
    # refused forever.
    it "asks again after a failure, because the pane holds no answer to the question" do
      answers = [-> { raise "provider 503" }, -> { Lain::Tool::Result.ok("because beta needed the same shape") }]
      prompts = []
      flaky = ->(prompt) { prompts << prompt and answers.shift.call }

      Sync do
        subject = docent(answerer: flaky)
        subject.open(anchor)
        subject.ask("a-42", "why this way?").task.wait
        second = subject.ask("a-42", "why this way?")

        expect(second).to be_asked
        second.task.wait
      end

      expect(prompts.size).to eq(2)
      expect(view.text).to include("because beta needed the same shape")
      expect(journal.map(&:journal_type)).to eq(%w[docent_asked docent_refused docent_asked docent_answered])
    end

    # And the guard still holds where it has to: an ANSWERED question is a
    # duplicate, so this is not "refuse nothing".
    it "still refuses a repeat of a question that was answered" do
      answerer, prompts = recording_answerer

      Sync do
        subject = docent(answerer:)
        subject.open(anchor)
        subject.ask("a-42", "why this way?").task.wait
        expect(subject.ask("a-42", "why this way?")).not_to be_asked
      end

      expect(prompts.size).to eq(1)
    end
  end

  describe "the vocabulary the pane and the guards are written against" do
    # Standing rule 11 says the oracle reuses the subject's constants, which
    # leaves their VALUES free: a mutant setting SPEAKER_LAIN to "docent" made
    # lain's refusal indistinguishable from the docent's answer and survived
    # every example in this file, because the refusal examples assert
    # `include(SPEAKER_LAIN)` and it was then a substring of every answer.
    it "keeps three distinct speakers and a marker that renders as something" do
      expect(described_class::SPEAKER_HUMAN).to eq("you")
      expect(described_class::SPEAKER_DOCENT).to eq("docent")
      expect(described_class::SPEAKER_LAIN).to eq("lain")
      expect([described_class::SPEAKER_HUMAN, described_class::SPEAKER_DOCENT,
              described_class::SPEAKER_LAIN].uniq.size).to eq(3)
      expect(described_class::SPEAKER_DOCENT).not_to include(described_class::SPEAKER_LAIN)
      expect(described_class::PENDING).not_to be_empty
    end

    # A whitespace-only question would spawn a child and spend money. The
    # defence was a comment saying the editor half refuses it first.
    it "refuses a question that is nothing but whitespace, and spends nothing on it" do
      answerer, prompts = recording_answerer
      subject = docent(answerer:)
      subject.open(anchor)

      refused = subject.ask("a-42", " \t\n ")

      expect(refused).not_to be_asked
      expect(refused.report).to eq(described_class::BLANK)
      expect(prompts).to be_empty
      expect(journal).to be_empty
      expect(subject.conversation("a-42").entries).to be_empty
    end

    # The ordering the code claims: the most SPECIFIC fact first. A blank
    # question at an id nothing opened is a missing thread, not a blank
    # question, because opening one is what the human has to do first.
    it "names the missing thread before the blank question when both are true" do
      answerer, = recording_answerer

      refused = docent(answerer:).ask("a-99", "  ")

      expect(refused.report).to include("no thread is open")
    end
  end

  describe "where the answer is computed is a seam, not a fact" do
    # No shipped example passes anything but the default Reactor, and "the
    # runner is swappable" is half of this card's premise. An INLINE runner is
    # the arm that proves the seam is real: it computes the answer on the
    # calling fiber, with no reactor anywhere, and everything else still holds.
    it "computes the answer wherever the runner says, with no reactor at all" do
      answerer, prompts = recording_answerer
      inline = ->(&block) { block.call }

      subject = docent(answerer:, runner: inline)
      subject.open(anchor)
      asked = subject.ask("a-42", "why this way?")

      expect(asked).to be_asked
      expect(prompts.size).to eq(1)
      expect(view.text).to include("because beta needed the same shape")
      expect(journal.map(&:journal_type)).to eq(%w[docent_asked docent_answered])
    end

    # `transient: true` is why an answer in flight never holds a session open --
    # a docent's answer is worth having and is never worth waiting for. A
    # non-transient task would make the reactor's own shutdown wait out a
    # provider round trip nobody is left to read, and the reasoning for it was
    # in a comment with nothing under it.
    it "lets the session close on an answer nobody is waiting for" do
      slow = lambda do |_prompt|
        Async::Task.current.sleep(2)
        Lain::Tool::Result.ok("the late answer")
      end
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      Sync do
        subject = docent(answerer: slow)
        subject.open(anchor)
        expect(subject.ask("a-42", "why this way?")).to be_asked
      end

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.5
    end

    # `Async::Task#async` is greedy -- it runs the block inline on the calling
    # fiber until the block's first suspension -- so a docent that merely
    # SCHEDULES the answer still runs the answerer's whole synchronous prologue
    # on the editor's fiber. Measured against this answerer before the fix: 0.351s.
    # The shipped non-blocking example cannot see it, because its answerer
    # suspends on its own first line.
    it "returns before the answerer has done any work at all" do
      started = false
      spinning = lambda do |_prompt|
        started = true
        Process.clock_gettime(Process::CLOCK_MONOTONIC).then do |from|
          nil while Process.clock_gettime(Process::CLOCK_MONOTONIC) - from < 0.3
        end
        Lain::Tool::Result.ok("the late answer")
      end

      Sync do
        subject = docent(answerer: spinning)
        subject.open(anchor)
        asked = subject.ask("a-42", "why this way?")

        expect(started).to be(false)
        asked.task.stop
      end
    end
  end

  describe "the default answerer is a role, spawned fresh" do
    # The role is the swappable bench arm: what makes this a docent rather than
    # a fixed agent is that the ROLE NAME and the spawn seam are both injected,
    # so an arm swaps either without touching this class.
    it "spawns the diff_docent role over a fresh root" do
      spawn = instance_double(Lain::Skill::RoleSpawn)
      allow(spawn).to receive(:call).and_return(Lain::Tool::Result.ok("said"))

      described_class::Answerer.new(spawn:).call("the brief")

      expect(spawn).to have_received(:call).with(:diff_docent, :fresh, "the brief")
    end

    it "names a role the catalog actually ships" do
      expect(Lain::Role::Catalog.names).to include(described_class::ROLE)
    end

    # The catalog entry argues at length that this role is read-only and holds
    # no tier-3 tool -- explaining a change does not touch the tree, and a gated
    # tool would park the answer at the approval gate with a human sitting
    # mid-review waiting for it. Neither half was asserted anywhere.
    it "attenuates to read-only capabilities, none of which reach the approval gate" do
      union = Lain::Toolset.new(Lain::CLI::Wiring::BaseTools.build(Lain::Memory::Recorder.new))
      allowed = Lain::Role::Catalog.fetch(described_class::ROLE).attenuate(union)

      expect(allowed.names).to contain_exactly("glob", "grep", "list_files", "read_file")
      expect(allowed.select(&:requires_approval?)).to be_empty
    end

    it "refuses in words, never by raising, when no answerer was wired" do
      result = described_class::Unanswerable.call("the brief")

      expect(result).to be_error
      expect(result.content).to include("no docent")
    end
  end
end
