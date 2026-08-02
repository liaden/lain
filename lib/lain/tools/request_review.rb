# frozen_string_literal: true

# For `$ERROR_INFO`: the failure an `ensure` sees is not an argument to it, and
# {RequestReview#give_back} has to journal which one it was.
require "English"

module Lain
  module Tools
    # Hands one of an epic's documents to the human and waits for it back --
    # the agent's end of the ownership baton {Epic::Review} keeps.
    #
    # The exchange is {Tools::AskHuman}'s shape applied to a file instead of a
    # sentence: resolve the artifact, open a review on it, ask an editor to
    # open it, tell the human, then park on that review's promise inside
    # {#perform}. Parking parks the FIBER, so the reactor keeps running and a
    # second review on a second path proceeds alongside. The wait is unbounded
    # on purpose -- a review is done when the human says it is.
    #
    # == No instance-wide pending state, and why that is structural
    #
    # AskHuman's single-question `@pending` ivar is its own invariant and is
    # deliberately not copied here. Everything one call needs -- the generation,
    # the path, the baseline, the promise -- rides the {Epic::Review::Token} that
    # call opened, and the notes it draws are keyed by `(epic_slug, generation)`
    # in {Notes}. Two agents reviewing two paths therefore cannot resolve each
    # other's delta, which an ivar would do in silence.
    #
    # == Three stages are reviewable, and `implementation` is refused by name
    #
    # {REVIEWABLE} is the whole of it, because {Epic::Home} holds exactly these
    # documents. `implementation` gates an external changeset digest rather than
    # a document, so "review it" would mean reviewing a diff -- a surface lain
    # does not have. It is refused with that sentence rather than silently, so a
    # model that asks learns why instead of guessing a neighbouring stage.
    #
    # == What the written side is, per stage
    #
    # Only `epic_plan` is a resolved graph, which is both why it lives at
    # `home.epic` and why its written side is {Epic::Intake::Written}. The other
    # two are {Epic::Intake::Prose}, which is never parsed: running the epic
    # grammar over a research note reports the human's ordinary prose as a
    # malformed epic, which is a false alarm about their work rather than a
    # report of it. {Epic::Review#baseline_for} reads that difference off
    # `graph_digest`, so this tool chooses the written side and never a baseline.
    class RequestReview < Tool
      # An artifact whose bytes are read whole, then wrapped in the written side
      # that names what may honestly be compared over them. ONE table because it
      # is one decision, not two that must agree.
      #
      # The graph comes from parsing the bytes THIS read returned, not from a
      # second `Home#read_epic`: two reads can straddle a write, and a graph from
      # one revision handed to {Epic::Intake::Written} with bytes from another is
      # exactly what that value refuses.
      PROSE = ->(bytes) { Epic::Intake::Prose.new(bytes:) }
      GRAPH = ->(bytes) { Epic::Intake::Written.new(graph: Epic::Document.parse_markdown(bytes), bytes:) }

      REVIEWABLE = {
        "research" => [->(home, _id) { home.research }, PROSE],
        "epic_plan" => [->(home, _id) { home.epic }, GRAPH],
        "issue_plan" => [->(home, id) { home.plan(id) }, PROSE]
      }.freeze

      WAITING = "%<path>s is open for review (generation %<generation>d, epic %<slug>s). " \
                "lain is waiting for it back."

      ABANDONED = "the hand-over failed before the human was told the file was theirs: " \
                  "%<error>s (%<kind>s). Nothing went out and nothing came back."

      AGENT = "lain"

      # The stage vocabulary is {Epic::STAGES} entire, including the one
      # {REVIEWABLE} omits: a schema that quietly dropped `implementation` would
      # leave a model to guess a neighbouring stage for a changeset, where the
      # refusal above tells it there is no such surface. One list, so the wire
      # contract cannot drift from the pipeline.
      class Input < Tool::Input
        field :stage, :string, required: true,
                               description: "Which of the epic's stage artifacts to hand to the human: " \
                                            "research, epic_plan, or issue_plan. implementation is refused -- " \
                                            "it names a changeset, not a document."
        field :issue_id, :string,
              description: "The issue whose plan to review. Required for stage issue_plan, ignored otherwise."

        validates :stage, inclusion: { in: Epic::STAGES, message: "names no epic stage" }
      end

      input_model Input

      # The editor that is not there ({CLI::HumanReplies::NoEditor}'s name, and
      # {Sink::Null}'s bargain): a headless run still opens and settles a
      # review, the human just finds the file themselves -- the notification
      # below names the path either way. Nothing asks whether one is attached.
      module NoEditor
        def self.open_review(_path, _generation, **) = nil
      end

      # No rail for the editor's `done` gesture to arrive on, so nothing to
      # route it to. The message is {CLI::HumanReplies#bind_review}'s exactly,
      # because that is the object the wiring binds in as this duck.
      module NoBindings
        def self.bind_review(_review, **) = nil
      end

      # No tee between the Review and the journal, so the notes went only to the
      # journal and this call has none to quote. A review still opens, settles,
      # and reports its delta -- see {Notes} for why the tee is what reads them.
      module NoNotes
        def self.take(**) = []
      end

      # @param home [Epic::Home::Journaled, #call] the epic's artifacts
      # @param review [Epic::Review, #call] the baton for this epic
      # @param notes [Notes] the journal tee this review's annotations land in
      # @param editor [#open_review] the surface that shows the human the file
      # @param bindings [#bind_review] where the editor's `done` is routed
      # @param notify [#question] the desktop notifier
      def initialize(home:, review:, notes: NoNotes, editor: NoEditor,
                     bindings: NoBindings, notify: Notify::Null.new)
        super()
        @home = home
        @review = review
        @notes = notes
        @editor = editor
        @bindings = bindings
        @notify = notify
      end

      def name = "request_review"

      def description
        "Hands one of this epic's documents to the human to read and edit, and " \
          "waits until they hand it back. Takes `stage` (research, epic_plan or " \
          "issue_plan) and, for issue_plan, `issue_id`. Returns what changed -- " \
          "bytes, structure, and any notes they left in the margin. Use it when a " \
          "plan needs human judgement before the next stage opens. The call waits."
      end

      protected

      def perform(input, _invocation)
        reader, written_side = REVIEWABLE[input.stage]
        return Refusals.no_document if reader.nil?

        artifact = reader.call(home, input.issue_id)
        hold(artifact, written_side)
      rescue Epic::Home::MalformedName => e
        Refusals.needs_issue_id(e)
      rescue *Epic::Intake::PARSE_FAILURES => e
        Refusals.unparseable(e, artifact)
      rescue Epic::Home::MissingArtifact, Epic::Home::UnreadableArtifact, Epic::Review::AlreadyOpen => e
        Refusals.unopened(e)
      end

      private

      def hold(artifact, written_side)
        written = written_side.call(artifact.read)
        settled(open_on(artifact, written), written)
      end

      # The await and the report over it. Its own method so the `ensure` names
      # ONE token rather than guarding on whether a review was ever opened.
      #
      # {Notes#take} is delete-on-read and this is its only reader, so notes
      # that never reach a report would sit in the tee for the life of the
      # process. The drain therefore runs whether or not the report is built --
      # a `done` that lands while this turn is being cancelled is the case.
      # Idempotent by construction: on the ordinary path the line above already
      # took them and this takes nothing.
      def settled(token, written)
        Tool::Result.ok(Report.new(path: token.path, delta: token.await, compared: !written.graph_digest.nil?,
                                   notes: notes_of(token)).to_s)
      ensure
        notes_of(token)
      end

      def notes_of(token) = @notes.take(epic_slug: token.epic_slug, generation: token.generation)

      # The route back is bound BEFORE the editor is told, because the editor
      # answers on its own thread: a human fast enough to hit `done` between the
      # two calls would otherwise send a gesture nothing could route, and the
      # awaiting fiber below would never wake.
      #
      # The editor's answer is a NOTICE, not an outcome -- nil when the open
      # landed, else its own words for having no window to put the file in. It
      # rides the notification rather than being discarded, so a human whose
      # editor refused still learns where the file is.
      def open_on(artifact, written)
        tell(review.open(path: artifact.path, written:))
      end

      # Everything between taking the baton and the human knowing they have it,
      # in one method because a raise anywhere in it means the same thing.
      #
      # {Epic::Review#open} journals its claim BEFORE handing back the token, so
      # the claim is durable the instant it exists. A raise here therefore wedges
      # the epic permanently: no editor buffer exists to send `done` from, no
      # binding was routed for the CLI to settle through, and a restarted lain
      # rebuilds the claim from the journal and goes on refusing every write.
      # There is no user-reachable escape at all -- so the baton goes back before
      # the error propagates.
      #
      # An `ensure` and not a `rescue`, which is the difference between
      # implementing the rule and implementing half of it: `Async::Stop`
      # descends from Exception rather than StandardError, so a turn cancelled
      # at exactly this instant is invisible to any ordinary rescue -- and it
      # lands in precisely the window where nobody has been told and no `done`
      # can ever arrive. `ensure` covers the raise, the cancellation and the
      # throw alike.
      #
      # Whatever was propagating goes on propagating, with one deliberate
      # exception that {#give_back} names and nothing else: an `ensure` that
      # raises REPLACES the error it was cleaning up after, which is why the
      # give-back has to be careful about what it may raise.
      #
      # {Effect::Handler} turns a raising tool into an error Result, so a dead
      # RPC socket or a missing notifier still reaches the model as a failure
      # rather than as a review that quietly did not happen.
      #
      # Deliberately NOT extended over `token.await`. Past this point the human
      # genuinely holds the file: a cancelled turn must leave the baton exactly
      # where it is, because releasing it would let lain regenerate underneath
      # somebody mid-edit, which is the harm the baton exists to prevent.
      def tell(token)
        bindings.bind_review(review, token:)
        notice = editor.open_review(token.path, token.generation, epic_slug: token.epic_slug)
        @notify.question(agent: AGENT, text: waiting(token, notice))
        told = true
        token
      ensure
        give_back(token) unless told
      end

      # `$ERROR_INFO` because the failure is not an argument here: `ensure` sees
      # whatever is propagating, including the cancellations a rescue cannot
      # name, and the journal should say which one it was.
      #
      # {Epic::Review::NotOpen} is swallowed, and it is the ONLY thing that may
      # be. It means the baton is already back -- which is this method's entire
      # postcondition -- so there is nothing left to do and nothing to report.
      # The race is real and the bind-first ordering opens it deliberately: the
      # editor answers on its own thread, so a `done` can settle the review
      # between the bind and a later failure. Without this, `abandon` would
      # raise out of the caller's `ensure` and REPLACE the real error with a
      # refusal about a review that had already closed itself -- including
      # replacing an `Async::Stop`, which is the very class the ensure exists
      # for.
      #
      # Nothing wider. Any other failure out of `abandon` -- a dead journal
      # above all -- is a real breakage AND leaves the baton genuinely held, so
      # hiding it would trade a loud error for the silent wedge this whole path
      # was built to close.
      def give_back(token)
        failure = $ERROR_INFO
        review.abandon(token.generation,
                       reason: format(ABANDONED, error: failure&.message || "the hand-over did not complete",
                                                 kind: failure&.class&.name || "a cancellation"))
      rescue Epic::Review::NotOpen
        nil
      end

      def waiting(token, notice)
        [format(WAITING, path: token.path, generation: token.generation, slug: token.epic_slug), notice]
          .compact.join(" ")
      end

      # The wiring builds the toolset BEFORE some of these exist --
      # `CLI::HumanReplies` is constructed after it -- so a collaborator may
      # arrive as a thunk read at call time, which is {AskHuman}'s `parent:`
      # idiom and its reason.
      #
      # nil coalesces to the Null Object HERE, which is the whole point: the
      # wiring passes `views:` straight through whether or not an editor is
      # attached, and a thunk read too early answers nil for the same "not
      # wired yet" reason. {CLI::HumanReplies#bind_editor}'s rule -- one nil
      # check, in the one place that owns the question.
      #
      # `home` and `review` have no null: which epic this is cannot be
      # defaulted, and a tool wired to neither is a wiring bug that must not
      # quietly review nothing.
      def home = live(@home)
      def review = live(@review)
      def editor = live(@editor) || NoEditor
      def bindings = live(@bindings) || NoBindings

      def live(collaborator) = collaborator.respond_to?(:call) ? collaborator.call : collaborator
    end

    # Reopened so the two collaborators below are measured on their own rather
    # than inflating the class they serve ({Tool::SchemaValidator}'s idiom).
    class RequestReview
      # Every way this tool can decline, as the sentences the MODEL reads.
      #
      # Its own object because "hold a document and report what came back" and
      # "explain to a model why this call cannot happen" are different jobs, and
      # {Metrics/AbcSize} said so when the four branches sat in {#perform}. Each
      # one names what did not happen -- no review was opened -- because the
      # difference between a refused call and a settled one that found nothing
      # is the whole of what a model needs to decide what to do next.
      module Refusals
        module_function

        NO_DOCUMENT = "the implementation stage cannot be reviewed: it gates a changeset digest rather than a " \
                      "document, so reviewing it would mean reviewing a diff, and lain has no surface for that. " \
                      "The reviewable stages are %<stages>s -- each is a file in the epic home a human can open."

        # It says "nothing is under review" rather than "lain still holds the
        # baton". The baton is what the HUMAN takes when a review opens, so the
        # shorter sentence read as its own opposite -- a model could take it for
        # "a review is open" and wait for a settle that is never coming.
        UNPARSEABLE = "%<path>s no longer parses as an epic document, so there is nothing to compare a review " \
                      "against and no review was opened: %<reason>s. The file is untouched and nothing is " \
                      "under review, so lain may still regenerate it -- or repair it by hand."

        NEEDS_ID = "%<reason>s. An issue_plan review needs an issue_id naming the issue whose plan to review."

        # Reachable only for `implementation`: {Input} closes the field on
        # {Epic::STAGES} and {REVIEWABLE} covers the other three, so the miss is
        # total rather than a fallthrough.
        def no_document = Tool::Result.error(format(NO_DOCUMENT, stages: REVIEWABLE.keys.join(", ")))

        # The only {Epic::Home::MalformedName} this tool can provoke: its slug
        # was checked when the home resolved, so the name it composes here is
        # the issue id and nothing else.
        def needs_issue_id(error) = Tool::Result.error(format(NEEDS_ID, reason: error.message))

        def unparseable(error, artifact)
          Tool::Result.error(format(UNPARSEABLE, path: artifact.path,
                                                 reason: error.message))
        end

        def unopened(error) = Tool::Result.error("#{error.message} -- no review was opened")
      end

      # A journal decorator that forwards every record and REMEMBERS the
      # annotations, keyed by the `(epic_slug, generation)` pair a review is
      # identified by.
      #
      # This is the reader those records have never had. {Epic::Review#settle}
      # journals the notes and only then resolves the promise, so by the time
      # the awaiting fiber wakes they are already here -- an ordering that is
      # {Review#settle}'s own and is why no coordination is needed between them.
      #
      # `take` rather than `for`: the notes belong to the one call that awaited
      # them, and a reader that left them behind would grow for the life of the
      # process.
      #
      # == What that leaves, stated rather than left to be found
      #
      # An abandoned review ({Epic::Review#abandon}) draws no notes at all, and
      # a settle from the CLI is the ORDINARY path -- it resolves the promise,
      # which is what wakes the awaiting call that takes them. Neither leaks.
      # {RequestReview#settled} drains in an `ensure`, so a turn cancelled after
      # the notes have landed does not either.
      #
      # What remains is a turn cancelled BEFORE its settle: the drain has
      # already run, and the notes arrive after it. Those stay. It is bounded by
      # reviews-per-process rather than by anything this object can enforce --
      # closing it would need `Review` to tell the tee that a generation is
      # finished, and it journals the close BEFORE the notes, so there is no
      # such moment to hook.
      class Notes
        def initialize(journal:)
          @journal = journal
          @notes = Hash.new { |kept, key| kept[key] = [] }
        end

        # @return [self] so it stands where a Journal does
        def <<(record)
          @journal << record
          keep(record)
          self
        end

        def take(epic_slug:, generation:) = @notes.delete(key(epic_slug, generation)) || []

        private

        # On the record's own durable discriminator rather than its class, which
        # is what every other reader in this tier keys on.
        def keep(record)
          return unless record.respond_to?(:journal_type) && record.journal_type == Epic::Annotation::JOURNAL_TYPE

          @notes[key(record.epic_slug, record.generation)] << record
        end

        def key(epic_slug, generation) = [epic_slug.to_s, generation]
      end

      # What the model reads when the human hands the file back.
      #
      # Every line is a report and none is a judgement, which is
      # {Epic::Intake}'s own rule kept at the surface. The three ways an account
      # can be empty are spelled out separately, because a renderer that
      # collapsed them would make a false statement about somebody's work:
      # prose was never compared, a rebuilt review no longer holds what lain
      # wrote, and a document that did not parse could not be compared -- none
      # of them is "nothing changed".
      class Report
        NOT_PROSE = "structure: not compared -- this artifact is prose, so nothing structural was claimed " \
                    "either way. The byte addresses above are the whole of what was measured."
        RESTARTED = "structure: not compared -- lain restarted and no longer holds the document it wrote, so " \
                    "there was nothing to compare the disk against. This is NOT a corrupt file."
        REFUSED = "structure: not compared -- the document on disk did not parse: %<error>s (%<kind>s)"
        EQUAL = "structure: unchanged -- every issue compared equal."
        TRUNCATED = "possibly truncated: less than half the bytes lain wrote came back. A legitimate mass " \
                    "edit trips this too, so it is a suspicion to check rather than a finding."

        def initialize(path:, delta:, notes:, compared:)
          @path = path
          @delta = delta
          @notes = notes
          @compared = compared
        end

        def to_s = [heading, bytes, structure, truncation, *annotations].compact.join("\n")

        private

        def heading = "Review of #{@path} settled."

        def bytes
          return "bytes: unchanged (#{@delta.written_digest})" if @delta.byte_identical?

          "bytes: #{@delta.written_digest} -> #{@delta.disk_digest}"
        end

        def structure
          return NOT_PROSE unless @compared
          return RESTARTED if @delta.error_kind == Epic::Review::Unrecoverable.name
          return format(REFUSED, error: @delta.error, kind: @delta.error_kind) if @delta.malformed?
          return EQUAL unless @delta.structural?

          "structure: #{@delta.account.changes.map { |kind, ids| "#{kind} #{ids.join(", ")}" }.join("; ")}"
        end

        def truncation = @delta.lossy? ? TRUNCATED : nil

        # Quoted verbatim and in journal order, which is the order the human
        # placed them: nothing else records which note came first.
        def annotations
          return ["annotations: none."] if @notes.empty?

          ["annotations (#{@notes.size}):", *@notes.map { |note| "  - #{whereabouts(note)}: #{note.text.inspect}" }]
        end

        def whereabouts(note)
          return "line #{note.line}, drifted so it is attributed to no issue" if note.drifted

          note.issue_id.nil? ? "line #{note.line}" : "line #{note.line}, issue #{note.issue_id}"
        end
      end
    end
  end
end
