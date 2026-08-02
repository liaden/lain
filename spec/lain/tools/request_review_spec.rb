# frozen_string_literal: true

require "async"
require "stringio"
require "tmpdir"

# The editor surface as this tool sees it: ONE message, the one
# {Lain::Frontend::Neovim#open_review} answers. Both directions recorded, so an
# example can assert the file was actually handed over stamped with the
# generation the editor must send back.
#
# `raises:` is how the F1 examples reach the four routes to a wedged baton; the
# shared `log:` is how the bind-before-editor ORDERING is observable at all,
# since neither recorder alone can see the other.
class RecordingReviewEditor
  def initialize(notice: nil, raises: nil, log: [])
    @notice = notice
    @raises = raises
    @log = log
    @opened = []
  end

  attr_reader :opened

  def open_review(path, generation, epic_slug:)
    @log << :editor
    @opened << [path, generation, epic_slug]
    raise @raises if @raises

    @notice
  end
end

# {Lain::Notify}'s duck, recorded. Deliberately not the real adapter: that one
# shells out to dunstify.
class RecordingNotifier
  def initialize(raises: nil, log: [])
    @raises = raises
    @log = log
    @sent = []
  end

  attr_reader :sent

  def question(agent:, text:)
    @log << :notify
    @sent << [agent, text]
    raise @raises if @raises

    nil
  end
end

# A turn killed while the hand-over is still in flight. `Async::Stop` descends
# from Exception, NOT StandardError, so this reaches a path an ordinary rescue
# cannot see -- and it lands in the window where nobody has been told, which is
# the window the baton must not survive.
class SelfCancellingNotifier
  def question(**) = Async::Task.current.stop
end

# The human's `done` landing between the bind and a later failure. That window
# is opened ON PURPOSE -- binding first is what lets a fast gesture be routed at
# all, and the editor answers on its own thread -- so the review can already be
# settled by the time the hand-over's ensure tries to give the baton back.
class SettlingBindings
  def initialize(disk:)
    @disk = disk
  end

  def bind_review(review, token:) = review.settle(token.generation, disk: @disk)
end

# A journal that dies exactly when the give-back tries to record the abandon.
# Unlike a lost race, this leaves the baton GENUINELY held, so the failure has
# to propagate: hiding it would trade a loud error for the silent wedge.
class DeadOnCloseJournal
  def initialize(journal) = @journal = journal

  def <<(record)
    raise IOError, "the journal is gone" if record.journal_type == Lain::Epic::ReviewClosed::JOURNAL_TYPE

    @journal << record
  end
end

# {Lain::CLI::HumanReplies#bind_review}'s duck, recorded. What routes the
# editor's :LainReviewDone back to the review that can settle it.
class RecordingBindings
  def initialize(raises: nil, log: [])
    @raises = raises
    @log = log
    @bound = []
  end

  attr_reader :bound

  def bind_review(review, token:)
    @log << :bind
    @bound << [review, token.epic_slug, token.generation, token.path]
    raise @raises if @raises

    nil
  end
end

# T23: the agent's end of the review baton. The tool resolves a stage artifact
# through the journaled home, opens a Review on it, hands the file to an editor,
# tells the human, parks on the review's promise, and renders the delta plus the
# annotations the human left -- the first reader those `annotation` records have
# ever had.
#
# Every parked example goes through {#parked}, and NOT through a bare
# `task.with_timeout`. A review is an unbounded wait by design, so a regression
# that never settles must FAIL rather than hang -- a hung run reports as "fewer
# examples, 0 failures", which reads exactly like a pass, and this chunk's
# lineage has been fooled by that shape twice. See {#parked} for why the obvious
# bound does not bound.
RSpec.describe Lain::Tools::RequestReview do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io:) }
  let(:notes) { Lain::Tools::RequestReview::Notes.new(journal:) }
  # The Review journals THROUGH the notes tee, which is what gives the tool a
  # reader for the annotation records without Review learning a new duck.
  let(:review) { Lain::Epic::Review.new(journal: notes, epic_slug: "alpha") }
  let(:editor) { RecordingReviewEditor.new }
  let(:notifier) { RecordingNotifier.new }
  let(:bindings) { RecordingBindings.new }
  let(:invocation) { Lain::Tool::Invocation.new(context: Lain::Session::Null.instance) }
  # The real journaled home wired to the real Review, because "ownership
  # returned" is a claim about THIS pair: the write refuses while the baton is
  # held and succeeds once it is handed back.
  let(:home) { Lain::Epic::Home::Journaled.new(bare_home, journal:, reviews: review) }

  def paths_for(state_home)
    Lain::Paths.new(env: { "XDG_STATE_HOME" => state_home, "HOME" => state_home })
  end

  def bare_home(slug: "alpha")
    Lain::Epic::Home.resolve(config: Lain::Config.new(epics: Lain::Config::Epics.new(home: :repo)),
                             paths: paths_for(@dir), root: @dir, slug:)
  end

  def tool(**overrides)
    described_class.new(home:, review:, notes:, editor:, bindings:, notify: notifier, **overrides)
  end

  def issue(id:, **overrides) = Lain::Epic::Issue.new(id:, title: "the #{id} issue", **overrides)

  def graph_of(*issues) = Lain::Epic::Graph.new(issues:)

  def three_issue_graph = graph_of(issue(id: "a1"), issue(id: "b2"), issue(id: "c3"))

  def markdown(graph) = Lain::Epic::Document.to_markdown(graph)

  def epic_path = bare_home.epic.path

  # Spelled out rather than read off the delta, so an assertion about WHICH
  # digest sits on which side of the arrow cannot pass tautologically.
  def blob(bytes) = Lain::Workspace::Snapshot::Blob.new(bytes:).digest

  # A bound that actually bounds.
  #
  # `task.with_timeout` alone does NOT: it raises in the CALLING task, while the
  # child spawned by `task.async` is still parked on the review's promise, and
  # `Sync` does not return until every child has finished. The timeout fires and
  # the reactor then blocks in `epoll` waiting for a child nothing will ever
  # wake. Stopping the children in an `ensure` is what returns -- so no example
  # spawns its own `task.async`; they go through {#call_in}, which registers the
  # child here. Forgetting is what has to be impossible, not merely discouraged.
  def parked(timeout: 5, &block)
    Sync do |task|
      @runs = []
      begin
        task.with_timeout(timeout) { yield(task) }
      ensure
        @runs.each(&:stop)
      end
    end
  end

  # One tool call as a child task, registered with {#parked} so it cannot
  # outlive the example. `task.async` runs the block synchronously up to its
  # first park, so the review is already open when this returns -- no sleeps, no
  # timing race (ask_human_spec's idiom).
  def call_in(task, input, subject_tool = tool)
    task.async { subject_tool.call(input, invocation) }.tap { |run| @runs << run }
  end

  # Runs one tool call to completion against a human who edits the file and
  # settles the review.
  def review_round_trip(input, disk:, annotations: [], path: epic_path, timeout: 5)
    parked(timeout:) do |task|
      run = call_in(task, input)
      generation = review.generation_for(path)
      File.write(path, disk)
      review.settle(generation, disk:, annotations:)
      run.wait
    end
  end

  # ---- Scenario: the round trip returns edits and notes ----------------------

  describe "an epic_plan review that comes back edited and annotated" do
    let(:written) { three_issue_graph }
    let(:edited) { markdown(graph_of(issue(id: "a1"), issue(id: "b2", title: "the retitled b2"), issue(id: "c3"))) }

    before { home.write_epic(written) }

    def annotation_on(text, line:)
      { "line" => line, "anchor_text" => text.lines(chomp: true).fetch(line - 1), "text" => "tighten this" }
    end

    it "names the retitled issue and quotes the annotation the human left" do
      line = edited.lines(chomp: true).index { |l| l.include?("retitled b2") } + 1
      result = review_round_trip({ "stage" => "epic_plan" }, disk: edited,
                                                             annotations: [annotation_on(edited, line:)])

      expect(result).to be_ok
      expect(result.content).to include("retitled").and include("b2")
      expect(result.content).to include("tighten this")
    end

    it "hands the file to the editor stamped with the generation the done gesture must carry" do
      review_round_trip({ "stage" => "epic_plan" }, disk: edited)

      expect(editor.opened).to eq([[epic_path, 1, "alpha"]])
    end

    it "binds the review so the editor's done gesture can be routed back to it" do
      review_round_trip({ "stage" => "epic_plan" }, disk: edited)

      expect(bindings.bound).to eq([[review, "alpha", 1, epic_path]])
    end

    it "tells the human a file is waiting on them" do
      review_round_trip({ "stage" => "epic_plan" }, disk: edited)

      expect(notifier.sent.flatten.join(" ")).to include(epic_path)
    end

    it "returns ownership: a subsequent write_epic on the path succeeds" do
      review_round_trip({ "stage" => "epic_plan" }, disk: edited)

      expect { home.write_epic(three_issue_graph) }.not_to raise_error
      expect(review.open?(epic_path)).to be(false)
    end

    it "refuses a regeneration while the human still holds the file" do
      parked do |task|
        run = call_in(task, { "stage" => "epic_plan" })

        expect { home.write_epic(three_issue_graph) }
          .to raise_error(Lain::Epic::Home::Journaled::ReviewPending)

        review.settle(review.generation_for(epic_path), disk: edited)
        run.wait
      end
    end
  end

  # ---- Scenario: a lossy settle is loud and honest in the result -------------

  describe "an epic that comes back with half its issues gone" do
    let(:written) do
      graph_of(*(1..8).map do |n|
        issue(id: "i#{n}", description: "a description long enough to weigh")
      end)
    end
    let(:truncated) { markdown(graph_of(issue(id: "i1", description: "a description long enough to weigh"))) }

    before { home.write_epic(written) }

    it "says possibly truncated, lists the ids that left, and asserts nothing" do
      result = review_round_trip({ "stage" => "epic_plan" }, disk: truncated)

      expect(result).to be_ok
      expect(result.content).to include("possibly truncated")
      expect(result.content).to include("i8").and include("i2")
      expect(result.content).not_to include("no changes were made")
    end
  end

  # ---- Scenario: concurrent reviews do not collide ---------------------------

  describe "two reviews open on different paths at once" do
    before do
      home.write_epic(three_issue_graph)
      home.research.write("the original research note, which is prose and is never parsed\n")
    end

    let(:research_path) { bare_home.research.path }
    let(:edited_epic) do
      markdown(graph_of(issue(id: "a1"), issue(id: "b2", title: "the retitled b2"), issue(id: "c3")))
    end
    let(:edited_prose) { "the research note, rewritten by hand\n" }

    it "resolves each call with its own delta and its own notes" do
      parked do |task|
        epic_run = call_in(task, { "stage" => "epic_plan" })
        prose_run = call_in(task, { "stage" => "research" })

        epic_generation = review.generation_for(epic_path)
        prose_generation = review.generation_for(research_path)
        expect(epic_generation).not_to eq(prose_generation)

        # Settled in the OPPOSITE order to the opens, an interleaving a
        # sequential-looking test could never reach.
        File.write(research_path, edited_prose)
        review.settle(prose_generation, disk: edited_prose,
                                        annotations: [{ "line" => 1, "anchor_text" => edited_prose.chomp,
                                                        "text" => "prose note" }])
        File.write(epic_path, edited_epic)
        review.settle(epic_generation, disk: edited_epic,
                                       annotations: [{ "line" => 1,
                                                       "anchor_text" => edited_epic.lines(chomp: true).first,
                                                       "text" => "epic note" }])

        epic_result = epic_run.wait
        prose_result = prose_run.wait

        expect(epic_result.content).to include("epic note")
        expect(epic_result.content).not_to include("prose note")
        expect(prose_result.content).to include("prose note")
        expect(prose_result.content).not_to include("epic note")
      end
    end

    # The SLUG half of the tee's key. Two epics draw generations from their own
    # records, so both hand out 1 -- which is the whole reason the key is a pair
    # and not a number, and the half a generation-only mutation slips past.
    it "keeps two epics' notes apart when both are holding generation 1" do
      beta_bare = bare_home(slug: "beta")
      beta_review = Lain::Epic::Review.new(journal: notes, epic_slug: "beta")
      beta_home = Lain::Epic::Home::Journaled.new(beta_bare, journal:, reviews: beta_review)
      beta_home.research.write("beta's research note\n")
      beta_tool = described_class.new(home: beta_home, review: beta_review, notes:, editor:, bindings:,
                                      notify: notifier)

      parked do |task|
        alpha_run = call_in(task, { "stage" => "research" })
        beta_run = call_in(task, { "stage" => "research" }, beta_tool)

        expect(review.generation_for(research_path)).to eq(1)
        expect(beta_review.generation_for(beta_bare.research.path)).to eq(1)

        beta_disk = "beta, rewritten\n"
        File.write(beta_bare.research.path, beta_disk)
        beta_review.settle(1, disk: beta_disk,
                              annotations: [{ "line" => 1, "anchor_text" => beta_disk.chomp,
                                              "text" => "beta note" }])
        File.write(research_path, edited_prose)
        review.settle(1, disk: edited_prose,
                         annotations: [{ "line" => 1, "anchor_text" => edited_prose.chomp,
                                         "text" => "alpha note" }])

        alpha_result = alpha_run.wait
        beta_result = beta_run.wait

        expect(alpha_result.content).to include("alpha note")
        expect(alpha_result.content).not_to include("beta note")
        expect(beta_result.content).to include("beta note")
        expect(beta_result.content).not_to include("alpha note")
      end
    end

    # A note with no issue above it and an anchor that still matches: nil
    # issue_id, drifted false. Annotation's own doc goes out of its way to keep
    # that nil apart from a drifted one, so the render must too -- "issue " with
    # an empty id claims an attribution nobody made.
    it "renders a note under no heading as a plain line, never as an issue with no id" do
      result = review_round_trip({ "stage" => "research" }, disk: edited_prose, path: research_path,
                                                            annotations: [{ "line" => 1,
                                                                            "anchor_text" => edited_prose.chomp,
                                                                            "text" => "a note on prose" }])

      expect(result.content).to include("- line 1: \"a note on prose\"")
      expect(result.content).not_to include("issue :")
      expect(result.content).not_to include("drifted")
    end

    it "never reports an uncompared prose delta as no changes" do
      result = review_round_trip({ "stage" => "research" }, disk: edited_prose, path: research_path)

      expect(result).to be_ok
      expect(result.content).not_to include("no changes")
      expect(result.content).to include("prose")
    end
  end

  # ---- F1: the wedge, and exactly where the line is --------------------------

  # `Review#open` journals `review_opened` BEFORE it hands back the token, so a
  # claim is durable the instant it exists. A raise between that and the human
  # learning the file is theirs leaves the baton held forever: no editor buffer
  # exists to send `done` from, no binding was ever routed, and a restarted lain
  # rebuilds the claim from the journal and goes on refusing every write to the
  # epic. There is no user-reachable escape at all.
  #
  # So the line is whether the human was TOLD, not whether the call succeeded.
  describe "a raise before the human is ever told" do
    before { home.write_epic(three_issue_graph) }

    def attempt(subject_tool)
      subject_tool.call({ "stage" => "epic_plan" }, invocation)
    rescue StandardError
      nil
    end

    # The three collaborators the tool touches between taking the baton and the
    # human knowing about it, each failing the way it actually fails in the
    # field: a dead nvim RPC socket, an unwired reply rail, a missing dunstify.
    {
      "the editor cannot open the file" => lambda { |spec, boom|
        spec.described_class.new(home: spec.home, review: spec.review, notes: spec.notes,
                                 editor: RecordingReviewEditor.new(raises: boom),
                                 bindings: spec.bindings, notify: spec.notifier)
      },
      "the reply rail cannot bind the review" => lambda { |spec, boom|
        spec.described_class.new(home: spec.home, review: spec.review, notes: spec.notes,
                                 editor: spec.editor, bindings: RecordingBindings.new(raises: boom),
                                 notify: spec.notifier)
      },
      "the notifier is unavailable" => lambda { |spec, boom|
        spec.described_class.new(home: spec.home, review: spec.review, notes: spec.notes,
                                 editor: spec.editor, bindings: spec.bindings,
                                 notify: RecordingNotifier.new(raises: boom))
      }
    }.each do |situation, build|
      context "when #{situation}" do
        let(:boom) { IOError.new("broken pipe") }
        let(:failing_tool) { build.call(self, boom) }

        it "propagates the failure rather than hiding a review that did not happen" do
          expect { failing_tool.call({ "stage" => "epic_plan" }, invocation) }
            .to raise_error(IOError, "broken pipe")
        end

        it "releases the baton, so lain may still regenerate the file" do
          attempt(failing_tool)

          expect(review.open?(epic_path)).to be(false)
          expect { home.write_epic(three_issue_graph) }.not_to raise_error
        end

        it "journals the release, so a restarted lain does not rebuild the wedge" do
          attempt(failing_tool)
          rebuilt = Lain::Epic::Review.from_journal(io.string.lines, journal:, epic_slug: "alpha")

          expect(rebuilt.open?(epic_path)).to be(false)
        end

        it "closes it as abandoned, not as a settle nobody made" do
          attempt(failing_tool)
          closed = Lain::Journal.records(io.string.lines, type: "review_closed").to_a.last

          expect(closed["error_kind"]).to eq(Lain::Epic::Review::Abandoned.name)
          expect(closed["changes"]).to eq({})
        end
      end
    end

    # The same window, reached by cancellation rather than by a raise. A
    # `rescue StandardError` cannot see this one, so the release has to be an
    # ensure -- and without it, a turn killed at exactly the wrong instant
    # wedges the epic with no editor buffer and no binding to escape through.
    it "releases the baton when the turn is cancelled mid hand-over" do
      cancelling = described_class.new(home:, review:, notes:, editor:, bindings:,
                                       notify: SelfCancellingNotifier.new)

      parked do |task|
        call_in(task, { "stage" => "epic_plan" }, cancelling)
        task.yield
      end

      expect(review.open?(epic_path)).to be(false)
      expect { home.write_epic(three_issue_graph) }.not_to raise_error
    end

    # `Notes#take` is delete-on-read and the awaiting call is its only reader,
    # so notes that never reach a report stay in the tee for the life of the
    # process. The baton is unaffected here -- this is only about the tee.
    it "drains the tee when the turn dies after the notes have already landed" do
      disk = markdown(graph_of(issue(id: "a1")))

      parked do |task|
        run = call_in(task, { "stage" => "epic_plan" })
        generation = review.generation_for(epic_path)
        File.write(epic_path, disk)
        review.settle(generation, disk:,
                                  annotations: [{ "line" => 1, "anchor_text" => disk.lines(chomp: true).first,
                                                  "text" => "orphan" }])
        run.stop
        task.yield

        expect(notes.take(epic_slug: "alpha", generation:)).to eq([])
      end
    end

    # The give-back runs in an `ensure`, so anything IT raises replaces whatever
    # was already propagating. `abandon` raises NotOpen exactly when a `done`
    # won the race -- and NotOpen is the give-back's own postcondition, so the
    # baton is already back and there is nothing left to do. Every other failure
    # out of `abandon` is a real bug and must still propagate.
    it "lets the real failure propagate when a done settles the review first" do
      disk = markdown(three_issue_graph)
      racing = described_class.new(home:, review:, notes:, editor:,
                                   bindings: SettlingBindings.new(disk:),
                                   notify: RecordingNotifier.new(raises: RuntimeError.new("dunstify is missing")))

      expect { racing.call({ "stage" => "epic_plan" }, invocation) }
        .to raise_error(RuntimeError, "dunstify is missing")
    end

    # The other side of that rescue, and why it may not be widened. A dead
    # journal is not a lost race: the baton is GENUINELY still held, so hiding
    # the failure would trade a loud error for the silent wedge this whole path
    # exists to close.
    it "lets a failed give-back propagate rather than hiding a baton still held" do
      dead_notes = Lain::Tools::RequestReview::Notes.new(journal: DeadOnCloseJournal.new(journal))
      dead_review = Lain::Epic::Review.new(journal: dead_notes, epic_slug: "alpha")
      dead_home = Lain::Epic::Home::Journaled.new(bare_home, journal:, reviews: dead_review)
      dead_home.write_epic(three_issue_graph)
      failing = described_class.new(home: dead_home, review: dead_review, notes: dead_notes, editor:, bindings:,
                                    notify: RecordingNotifier.new(raises: RuntimeError.new("dunstify is missing")))

      expect { failing.call({ "stage" => "epic_plan" }, invocation) }
        .to raise_error(IOError, "the journal is gone")
      expect(dead_review.open?(epic_path)).to be(true)
    end

    # The other half of the line, and it must NOT be released. Past the
    # notification the human genuinely holds the file; letting lain regenerate
    # underneath somebody mid-edit is the exact harm the baton exists to
    # prevent, and with an editor attached they can still send `done`.
    it "leaves the baton HELD when the wait itself is cancelled" do
      parked do |task|
        run = call_in(task, { "stage" => "epic_plan" })
        expect(review.open?(epic_path)).to be(true)

        run.stop
        task.yield

        expect(review.open?(epic_path)).to be(true)
        expect { home.write_epic(three_issue_graph) }
          .to raise_error(Lain::Epic::Home::Journaled::ReviewPending)
      end
    end
  end

  # ---- Scenario: implementation is refused by name ---------------------------

  describe "the implementation stage" do
    it "refuses by name, saying which stages are reviewable and why this one is not" do
      result = tool.call({ "stage" => "implementation" }, invocation)

      expect(result).to be_error
      expect(result.content).to include("implementation")
      expect(result.content).to include("research").and include("epic_plan").and include("issue_plan")
      expect(review.open_generations).to be_empty
    end

    # Every document a stage could be folded onto is on disk here, so a table
    # that quietly mapped `implementation` to one of them would open a review
    # rather than fail to find a file.
    it "opens nothing and notifies nobody, even with every document present" do
      home.write_epic(three_issue_graph)
      home.research.write("a research note\n")

      tool.call({ "stage" => "implementation" }, invocation)

      expect(editor.opened).to be_empty
      expect(notifier.sent).to be_empty
      expect(bindings.bound).to be_empty
    end
  end

  # ---- Scenario: an epic document that no longer parses ----------------------

  # The decision this card had to make. A review opened on an unparseable epic
  # document is a real state, and the alternative -- opening it as prose so the
  # human can repair it -- would journal a `review_opened` with no graph digest,
  # which is durably indistinguishable from a genuine prose artifact and would
  # render "nothing structural was claimed" about a document that IS structural.
  # So the tool reports and takes no baton.
  describe "an epic document lain can no longer parse" do
    before do
      home.write_epic(three_issue_graph)
      File.write(epic_path, "#{markdown(three_issue_graph)}### [x] a heading missing its backticks\n")
    end

    it "reports the refusal instead of raising out of the written side" do
      result = tool.call({ "stage" => "epic_plan" }, invocation)

      expect(result).to be_error
      expect(result.content).to include(epic_path)
      expect(result.content).to include("no review was opened")
    end

    # "lain still holds the baton" was the old wording, and in this tier's
    # vocabulary the baton is what the HUMAN takes -- so a model could read it
    # as "a review is open" and wait for a settle that will never come. The
    # sentence has to say the thing it means.
    it "tells the model nothing is under review, in words that cannot be read the other way" do
      result = tool.call({ "stage" => "epic_plan" }, invocation)

      expect(result.content).to include("nothing is under review")
      expect(result.content).not_to include("holds the baton")
    end

    it "takes no baton, so lain may still regenerate the file" do
      tool.call({ "stage" => "epic_plan" }, invocation)

      expect(review.open?(epic_path)).to be(false)
      expect { home.write_epic(three_issue_graph) }.not_to raise_error
    end
  end

  # ---- The issue_plan artifact, and the id it needs --------------------------

  describe "an issue_plan review" do
    before { home.plan("b2").write("the plan for b2, in prose\n") }

    it "reviews the plan document, which is what the issue_plan submission reads" do
      result = review_round_trip({ "stage" => "issue_plan", "issue_id" => "b2" },
                                 disk: "the plan for b2, rewritten\n", path: bare_home.plan("b2").path)

      expect(result).to be_ok
      expect(result.content).to include(bare_home.plan("b2").path)
    end

    it "refuses without an issue id rather than guessing one" do
      result = tool.call({ "stage" => "issue_plan" }, invocation)

      expect(result).to be_error
      expect(result.content).to include("issue_id")
    end
  end

  # ---- F3: the render is a REPORT, and every branch of it is a claim ---------

  # These pin the sentences rather than the plumbing. A renderer that collapses
  # a branch does not crash -- it makes a confident false statement about
  # somebody's work, which is the one failure this tier is built to rule out.
  describe "what the result says about what came back" do
    before { home.write_epic(three_issue_graph) }

    let(:unparseable) { "#{markdown(three_issue_graph)}### [x] a heading missing its backticks\n" }

    # The sharpest one. Lose this branch and the tool tells the model
    # "every issue compared equal" about a document that was never compared.
    it "names an epic handed back unparseable as unparsed, never as compared equal" do
      result = review_round_trip({ "stage" => "epic_plan" }, disk: unparseable)

      expect(result.content).to include("did not parse")
      expect(result.content).to include("Lain::Epic::MalformedDocument")
      expect(result.content).not_to include("compared equal")
      expect(result.content).not_to match(/^structure: (retitled|added|removed)/)
    end

    # Direction, not merely presence. Reversed, the sentence says the document
    # went from the human's version to lain's -- backwards provenance in the one
    # report whose whole job is saying what changed. The two digests are
    # computed here rather than read off the delta, so the assertion cannot pass
    # tautologically.
    it "renders the byte arrow from what lain wrote TO what came back" do
      handed_back = markdown(graph_of(issue(id: "a1"), issue(id: "b2", title: "retitled"), issue(id: "c3")))
      result = review_round_trip({ "stage" => "epic_plan" }, disk: handed_back)

      expect(result.content).to include("bytes: #{blob(markdown(three_issue_graph))} -> #{blob(handed_back)}")
    end

    # The code claims journal order IS the order the human placed them, because
    # nothing else records which note came first. An unpinned claim is one the
    # renderer can quietly reverse.
    it "quotes the notes in the order the human left them, and counts them honestly" do
      disk = markdown(three_issue_graph)
      lines = disk.lines(chomp: true)
      earlier = { "line" => 1, "anchor_text" => lines[0], "text" => "the earlier note" }
      later = { "line" => 3, "anchor_text" => lines[2], "text" => "the later note" }
      result = review_round_trip({ "stage" => "epic_plan" }, disk:, annotations: [earlier, later])

      expect(result.content).to include("annotations (2):")
      expect(result.content.index("the earlier note")).to be < result.content.index("the later note")
    end

    it "says the bytes are unchanged when the human handed it back untouched" do
      result = review_round_trip({ "stage" => "epic_plan" }, disk: markdown(three_issue_graph))

      expect(result.content).to include("bytes: unchanged")
      expect(result.content).to include("structure: unchanged")
    end

    # T22's rule at the surface: a note whose anchor slid points at a line the
    # human never pointed at, so the number is no longer evidence of which issue
    # was meant. Rendering an id there would be a guess dressed as a finding.
    it "renders a drifted note as drifted rather than attributing it to a line's issue" do
      disk = markdown(three_issue_graph)
      drifted = { "line" => 1, "anchor_text" => "a line that is nowhere in this document", "text" => "moved" }
      result = review_round_trip({ "stage" => "epic_plan" }, disk:, annotations: [drifted])

      expect(result.content).to include("drifted")
      expect(result.content).to include("moved")
      expect(result.content).not_to include("line 1, issue")
    end
  end

  # ---- F3: the orderings and refusals the comments justify -------------------

  describe "the order the collaborators are told in" do
    before { home.write_epic(three_issue_graph) }

    # The editor answers on its own thread. A `done` arriving between the two
    # calls would find no route, and the fiber parked below would never wake --
    # which is why the code binds first and why that has to be pinned rather
    # than merely commented.
    it "binds the route back BEFORE the editor is told" do
      log = []
      ordered = described_class.new(home:, review:, notes:,
                                    editor: RecordingReviewEditor.new(log:),
                                    bindings: RecordingBindings.new(log:),
                                    notify: RecordingNotifier.new(log:))

      parked do |task|
        run = call_in(task, { "stage" => "epic_plan" }, ordered)
        disk = markdown(graph_of(issue(id: "a1")))
        File.write(epic_path, disk)
        review.settle(review.generation_for(epic_path), disk:)
        run.wait
      end

      expect(log).to eq(%i[bind editor notify])
    end

    # nil when the open landed, else the editor's own words for having no window
    # to put the file in. Discarding it would leave a human whose editor refused
    # with a notification that claims a file was opened.
    it "carries the editor's refusal notice into the notification" do
      refusing = described_class.new(home:, review:, notes:, bindings:, notify: notifier,
                                     editor: RecordingReviewEditor.new(notice: "no window took it"))

      parked do |task|
        run = call_in(task, { "stage" => "epic_plan" }, refusing)
        disk = markdown(graph_of(issue(id: "a1")))
        File.write(epic_path, disk)
        review.settle(review.generation_for(epic_path), disk:)
        run.wait
      end

      expect(notifier.sent.flatten.join(" ")).to include("no window took it").and include(epic_path)
    end

    it "reports a path somebody already holds instead of raising past the model" do
      held = review.open(path: epic_path, written: Lain::Epic::Intake::Written.new(graph: three_issue_graph))

      result = tool.call({ "stage" => "epic_plan" }, invocation)

      expect(result).to be_error
      expect(result.content).to include("already under review")
      # A refusal must never release somebody else's baton on its way out.
      expect(review.generation_for(epic_path)).to eq(held.generation)
    end
  end

  # ---- The surface itself ----------------------------------------------------

  describe "the model-facing surface" do
    it "is named and described, and takes no approval gate" do
      expect(tool.name).to eq("request_review")
      expect(tool.description).not_to be_empty
      expect(tool.requires_approval?).to be(false)
      expect(tool.parallel_safe?).to be(false)
    end

    it "offers the closed stage vocabulary as an enum rather than a second list" do
      expect(tool.input_schema.dig("properties", "stage", "enum")).to eq(Lain::Epic::STAGES)
    end

    it "binds through the same message CLI::HumanReplies already answers" do
      expect(Lain::CLI::HumanReplies.instance_method(:bind_review).parameters)
        .to eq([%i[req review], %i[keyreq token]])
    end
  end

  # ---- The Null Objects ------------------------------------------------------

  describe "a headless run" do
    before { home.write_epic(three_issue_graph) }

    # The wiring passes `views:` straight through, and it is nil when no editor
    # is attached -- so the coalesce has to live here, not as an `if` there.
    it "takes a nil editor and a not-yet-wired binding thunk without a guard at the wiring site" do
      parked do |task|
        unwired = described_class.new(home:, review:, notes:, editor: nil, bindings: -> {}, notify: notifier)
        run = call_in(task, { "stage" => "epic_plan" }, unwired)
        disk = markdown(graph_of(issue(id: "a1")))
        File.write(epic_path, disk)
        review.settle(review.generation_for(epic_path), disk:)

        expect(run.wait).to be_ok
      end
    end

    it "opens and settles a review with no editor and no binding attached" do
      parked do |task|
        headless = described_class.new(home:, review:, notes:, notify: notifier)
        run = call_in(task, { "stage" => "epic_plan" }, headless)
        disk = markdown(graph_of(issue(id: "a1")))
        File.write(epic_path, disk)
        review.settle(review.generation_for(epic_path), disk:)

        expect(run.wait).to be_ok
      end
    end
  end

  # ---- The notes tee ---------------------------------------------------------

  describe Lain::Tools::RequestReview::Notes do
    let(:tee) { described_class.new(journal:) }

    def annotation(generation:, text:)
      Lain::Epic::Annotation.new(epic_slug: "alpha", generation:, issue_id: "b2", line: 3,
                                 anchor_text: "### `b2`", text:, drifted: false)
    end

    it "forwards every record to the real journal untouched" do
      tee << Lain::Epic::ReviewOpened.new(epic_slug: "alpha", path: "/tmp/a.md", generation: 1,
                                          written_digest: "blake3:beef")

      expect(Lain::Journal.records(io.string.lines, type: "review_opened").to_a.size).to eq(1)
    end

    it "keeps each review's notes apart by the pair a generation is identified by" do
      tee << annotation(generation: 1, text: "first")
      tee << annotation(generation: 2, text: "second")

      expect(tee.take(epic_slug: "alpha", generation: 1).map(&:text)).to eq(["first"])
      expect(tee.take(epic_slug: "alpha", generation: 2).map(&:text)).to eq(["second"])
    end

    it "hands each review's notes over exactly once, so nothing accumulates" do
      tee << annotation(generation: 1, text: "first")

      expect(tee.take(epic_slug: "alpha", generation: 1).size).to eq(1)
      expect(tee.take(epic_slug: "alpha", generation: 1)).to eq([])
    end

    it "answers an empty list for a review that drew no notes" do
      expect(tee.take(epic_slug: "alpha", generation: 9)).to eq([])
    end
  end
end
