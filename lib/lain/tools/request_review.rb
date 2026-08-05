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
    # == Two halves, one baton: three documents and one changeset
    #
    # {REVIEWABLE} holds three stages because {Epic::Home} holds exactly three
    # documents. {IMPLEMENTATION} is the fourth and it is NOT a document: it
    # gates a changeset digest, so the review that opens over it is a
    # {Review::Session} over a {Review::Changeset} drawn on a {Review::Surface}.
    # This tool refused that stage by name until the surface existed; it does
    # now, and the two halves are told apart by ONE branch in {#perform} rather
    # than by a table that could fold a stage onto the wrong artifact.
    #
    # Both halves take a generation from the SAME {Epic::Review}, and that is
    # what makes "a second review proceeds alongside the first" true across
    # them: two documents already shared the counter, and a changeset review
    # with a counter of its own would hand out a number a document review had
    # already stamped on a buffer.
    #
    # What the changeset half's claim HOLDS is nothing, and that is deliberate.
    # {Epic::Review#open?} is asked with {Epic::Home::Artifact#path} -- an
    # absolute path -- and this claim's is {Review::Session#digest}, a
    # scheme-prefixed content address ({Review::Keying.digest}) that no
    # filesystem path can equal. So the write guard stays inert, which is
    # correct for a review holding no document, while a SECOND review of the
    # same changeset is still refused by {Epic::Review::AlreadyOpen}.
    #
    # `review_closed` therefore records the diff on both sides, because a
    # changeset review hands back a JUDGEMENT and not edited bytes -- the same
    # statement {Epic::Review#abandon} makes deliberately about its own close,
    # except this one really did complete. The judgement itself is journaled by
    # {Review::Session#submit} as a `review_verdict`, addressed to the changeset
    # it judged, which is the record {Epic::Submission.implementation} takes as
    # its `digest:`.
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

      # The one stage {REVIEWABLE} does not hold, because the artifact behind it
      # is a diff. See the class doc for what its review claims and what it does
      # not.
      IMPLEMENTATION = "implementation"

      # What a changeset is read against when the caller names only a base: the
      # working tree's own head, which is the revision an agent has just written
      # and the human is being asked about.
      HEAD = "HEAD"

      # Everything, in one view. {Review::Bounds} is what decides when a
      # cumulative view is too large to be one, and wiring it is the review
      # CLI's card rather than this one's.
      SCOPE = :cumulative

      WAITING = "%<path>s is open for review (generation %<generation>d, epic %<slug>s). " \
                "lain is waiting for it back."

      CHANGESET_WAITING = "%<base>s..%<head>s is open for review (generation %<generation>d, epic %<slug>s), " \
                          "%<files>d file(s) changed. lain is waiting for a verdict."

      ABANDONED = "the hand-over failed before the human was told the file was theirs: " \
                  "%<error>s (%<kind>s). Nothing went out and nothing came back."

      AGENT = "lain"

      # The stage vocabulary is {Epic::STAGES} entire, and now every member of
      # it opens a review. One list, so the wire contract cannot drift from the
      # pipeline.
      #
      # `base` is the field the changeset half cannot default. A diff is read
      # against a ref, and picking one here -- `main`, `origin/HEAD`, the fork
      # point -- would be lain guessing which work is under review; the wrong
      # guess shows a human somebody else's commits and asks them to judge them.
      # So it is asked for, and its absence is a refusal ({Refusals.needs_base})
      # rather than a default.
      class Input < Tool::Input
        field :stage, :string, required: true,
                               description: "Which of the epic's stages to hand to the human: research, " \
                                            "epic_plan or issue_plan hands over a document; implementation " \
                                            "opens a changeset review over the diff."
        field :issue_id, :string,
              description: "The issue whose plan to review. Required for stage issue_plan, ignored otherwise."
        field :base, :string,
              description: "The ref the changeset is reviewed against. Required for stage implementation, " \
                           "ignored otherwise; the head is always the working tree's own HEAD."

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

      # A verdict has no rail to arrive on, so a changeset review could never be
      # answered. Its own refusal because there is nothing to do about it after
      # the fact: see {NoBindings}.
      class Unroutable < Error; end

      # No rail for the editor's `done` or `verdict` gestures to arrive on, so
      # nothing to route them to. Both messages are {CLI::HumanReplies}'s
      # exactly, because that is the object the wiring binds in as this duck.
      #
      # == The two halves answer DIFFERENTLY, and that difference is the object
      #
      # `bind_review` absorbs, which is what {NoEditor}'s bargain already buys:
      # the notification names the path, the human edits the real file, and the
      # review is keyed by `(epic_slug, generation)` -- so a `done` gesture
      # routed by a later bind still settles it.
      #
      # `bind_changeset_review` REFUSES, because not one of those is true of it.
      # There is no file, no `:LainReviewDone`, and no second answer path: a
      # verdict arrives on this rail or it never arrives, so a review that parks
      # with nothing bound parks forever with nothing said. A Null Object is
      # right when a message has an honest nowhere to go ({Sink::Null}); this
      # one has none, so the honest null is the one that says so -- and the
      # SILENT version is worse than the missing source beside it, which at
      # least refuses in a sentence.
      #
      # It raises rather than answering a refusal value because
      # {Implementation#tell} binds BEFORE anything is drawn: the raise lands
      # inside the window whose `ensure` gives the baton back, so the caller
      # gets a refusal with no claim left behind.
      module NoBindings
        UNROUTABLE = "no rail is bound for a changeset verdict to arrive on, so this review could never be " \
                     "answered and none was opened. Unlike a document review there is no file to hand over " \
                     "and no second way in -- the verdict rail is the only one."

        def self.bind_review(_review, **) = nil

        def self.bind_changeset_review(_review) = raise(Unroutable, UNROUTABLE)
      end

      # Nothing is wired to produce a changeset, so `implementation` has nothing
      # to review. LOUD rather than silent, and unlike {NoEditor} it is not a
      # bargain a headless run can still work under: a human without an editor
      # can open a file the notification names, and there is no equivalent way
      # to read a diff that was never built.
      module NoChangesets
        # `source` and not `call`, deliberately: {#live} treats anything
        # answering `call` as a thunk to be read with no arguments, so a
        # callable seam here would be invoked as one and answer the source it
        # was asked to build.
        def self.source(base:, head:) = nil # rubocop:disable Lint/UnusedMethodArgument
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
      # @param changesets [#source] builds the {Review::Source} an
      #   `implementation` review reads its diff from
      # @param surface [#present, #annotate, #mark, #thread, #verdict, #refuse, #call]
      #   where a changeset is drawn; checked against the port
      #   ({Review::Surface.check!}) before anything durable is journaled, or a
      #   THUNK reading one -- `bindings:`' late binding, for `bindings:`' reason
      #   (the frontend that owns a surface is built after the toolset). See
      #   {Implementation::Seams} for what a thunk costs that check.
      # @param view [#open, #marks, #call] the rendering a review gesture's row
      #   number is resolved through ({Frontend::Neovim::ReviewView}), or a thunk
      #   reading one. It must be the SAME instance the surface draws with: a
      #   rendering stamp is only resolvable by the view that issued it.
      # @param policy [Review::Verdict::Policy] whether a verdict may stand.
      #   Injected up to HERE and not merely into {Review::Session}, because the
      #   run that needs to swap it -- an unattended one under the `deferred`
      #   gate, which cannot mark a hunk and so can never satisfy
      #   {Review::Verdict::Policy::EveryHunk} -- reaches the session only
      #   through this tool.
      def initialize(home:, review:, notes: NoNotes, editor: NoEditor,
                     bindings: NoBindings, notify: Notify::Null.new,
                     changesets: NoChangesets, surface: nil, view: nil, policy: nil)
        super()
        @home = home
        @review = review
        @notes = notes
        @editor = editor
        @bindings = bindings
        @notify = notify
        @seams = Implementation::Seams.new(changesets:, surface:, view:, policy:)
      end

      def name = "request_review"

      def description
        "Hands one of this epic's stages to the human and waits until they are " \
          "done with it. Takes `stage`; for research, epic_plan and issue_plan " \
          "that is a document to read and edit (issue_plan also needs `issue_id`) " \
          "and the result says what changed -- bytes, structure, and any notes " \
          "they left in the margin. For implementation it is a changeset review " \
          "over the diff (needs `base`, the ref to review against) and the result " \
          "carries their verdict and the changeset's address. Use it when work " \
          "needs human judgement before the next stage opens. The call waits."
      end

      protected

      # ONE branch, because there are two kinds of artifact and not four. The
      # document half is a table; {Implementation} is the other.
      def perform(input, _invocation)
        input.stage == IMPLEMENTATION ? implementation.hold(input) : hold_document(input)
      end

      private

      # Built per call and never held, so the thunked collaborators below
      # ({#bindings}, {#changesets}) are read at the moment they are used --
      # which is the whole reason they are thunks.
      def implementation
        Implementation.new(review:, notes: @notes, bindings:, notify: @notify, seams: @seams)
      end

      # `fetch` and not `[]`: {Implementation} takes the one stage this table
      # omits, so a member added to {Epic::STAGES} with no artifact behind it
      # raises here rather than falling through to a refusal that would describe
      # it as a document.
      def hold_document(input)
        reader, written_side = REVIEWABLE.fetch(input.stage)
        artifact = reader.call(home, input.issue_id)
        hold(artifact, written_side)
      rescue Epic::Home::MalformedName => e
        Refusals.needs_issue_id(e)
      rescue *Epic::Intake::PARSE_FAILURES => e
        Refusals.unparseable(e, artifact)
      rescue Epic::Home::MissingArtifact, Epic::Home::UnreadableArtifact, Epic::Review::AlreadyOpen => e
        Refusals.unopened(e)
      end

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
      def give_back(token) = Baton.give_back(review, token)

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

    class RequestReview
      # Reopened so the collaborators below are measured on their own rather
      # than inflating the class they serve ({Tool::SchemaValidator}'s idiom).

      # Handing the baton back when the hand-over never completed. Its own
      # module because BOTH halves of this tool need it and neither owns it:
      # {RequestReview#tell} and {Implementation#tell} open the same window and
      # close it the same way, and a second copy would be free to close it
      # differently.
      module Baton
        # The baton as {Review::Handover} sees it: one message, and the epic's
        # whole share of a changeset review.
        #
        # It exists so that the handover -- which is the review tier's object,
        # and is bound by callers that have no epic at all -- never names
        # {Epic::Review}. A review opened outside one passes
        # {Review::Handover::Unheld}, whose `settle` is genuinely nothing;
        # everything an epic needs to be told is here.
        #
        # `disk:` is the DIFF on both sides, and that is a statement rather than
        # a placeholder: a changeset review hands back a judgement and not
        # edited bytes, so what is "on disk" is exactly what lain drew. See the
        # class doc on {RequestReview}.
        class Held
          def initialize(review:, token:, written:)
            @review = review
            @token = token
            @written = written
          end

          # Nothing is rescued here. {Epic::Review::NotOpen} -- the second
          # answer to a review that has already closed -- is a refusal the human
          # is owed in words, and the rail that called this is the one that
          # turns it into one ({Review::Handover#wrote_verdict}); swallowing it
          # here would report a verdict that settled nothing as one that stood.
          #
          # @return [Epic::Intake::Delta] whatever the epic made of the close
          def settle = @review.settle(@token.generation, disk: @written.bytes)
        end

        module_function

        # `$ERROR_INFO` because the failure is not an argument here: `ensure`
        # sees whatever is propagating, including the cancellations a rescue
        # cannot name, and the journal should say which one it was.
        #
        # {Epic::Review::NotOpen} is swallowed, and it is the ONLY thing that
        # may be. It means the baton is already back -- which is this method's
        # entire postcondition -- so there is nothing left to do and nothing to
        # report. The race is real and the bind-first ordering opens it
        # deliberately: the editor answers on its own thread, so a `done` can
        # settle the review between the bind and a later failure. Without this,
        # `abandon` would raise out of the caller's `ensure` and REPLACE the
        # real error with a refusal about a review that had already closed
        # itself -- including replacing an `Async::Stop`, which is the very
        # class the ensure exists for.
        #
        # Nothing wider. Any other failure out of `abandon` -- a dead journal
        # above all -- is a real breakage AND leaves the baton genuinely held,
        # so hiding it would trade a loud error for the silent wedge this whole
        # path was built to close.
        def give_back(review, token)
          failure = $ERROR_INFO
          review.abandon(token.generation,
                         reason: format(ABANDONED, error: failure&.message || "the hand-over did not complete",
                                                   kind: failure&.class&.name || "a cancellation"))
        rescue Epic::Review::NotOpen
          nil
        end
      end

      # The `implementation` stage's half of this tool: build a changeset, open
      # a {Review::Session} over it, hand it to a human, park on the baton, and
      # report the verdict.
      #
      # Its own object because it shares NOTHING with the document half but the
      # baton and the notifier -- no {Epic::Home}, no {Epic::Intake} comparison,
      # no editor, no {Notes} tee -- and the two were sitting in one class only
      # because one `stage` argument reaches both. `Metrics/ClassLength` said so
      # first.
      class Implementation
        # The three collaborators the changeset half needs and the document half
        # has no use for, with their nulls resolved ONCE.
        #
        # A plain class and deliberately NOT a `Data.define`, which is what the
        # shape suggests and what `spec/value_object_shareability_spec.rb`
        # refuses: every Data value here is deeply frozen and Ractor-shareable,
        # and these are live COLLABORATORS -- a surface holding an RPC socket, a
        # policy, a source factory. Freezing them would be a lie about what they
        # are.
        #
        # == When the port is checked, and why it is not always at construction
        #
        # {Review::Surface.check!} ran HERE, when the tool was constructed, and
        # still does for a surface handed over as itself: that is before any
        # `review_opened` claim exists, so a surface answering the port badly
        # refuses a WIRING rather than wedging an epic.
        #
        # A THUNK cannot be checked then -- there is nothing behind it yet, and
        # a Proc answers none of the six messages -- so a thunked surface is
        # checked when it RESOLVES, on every {Implementation#hold}. That is
        # still before anything durable: the read happens while `Session.open`'s
        # arguments are evaluated, ahead of its own `changeset_opened` and well
        # ahead of the epic's claim, and `hold` answers the refusal as a
        # {Refusals.unopened}. What is lost is only the moment -- a bad wiring
        # is found by the first `implementation` call instead of at startup.
        #
        # The nulls resolve HERE and nowhere else, which is why every reader
        # below coalesces rather than any caller nil-checking.
        class Seams
          attr_reader :policy

          def initialize(changesets: nil, surface: nil, view: nil, policy: nil)
            @changesets = changesets
            @surface = surface
            @view = view
            @policy = policy || Review::Verdict::Policy.default
            Review::Surface.check!(@surface) unless @surface.nil? || thunk?(@surface)
          end

          def changesets = live(@changesets) || NoChangesets

          # @return [#open, #marks] {Review::Handover::Detached} when no editor
          #   is attached, which is the run that can receive no gesture at all
          def view = live(@view) || Review::Handover::Detached

          # @raise [Review::Surface::Incomplete] for a thunk resolving to a
          #   surface that does not answer the port
          def surface
            resolved = live(@surface) || Review::Surface::Null.new
            Review::Surface.check!(resolved)
            resolved
          end

          private

          def thunk?(seam) = seam.respond_to?(:call)

          def live(seam) = thunk?(seam) ? seam.call : seam
        end

        def initialize(review:, notes:, bindings:, notify:, seams:)
          @review = review
          @notes = notes
          @bindings = bindings
          @notify = notify
          @seams = seams
        end

        # {RequestReview#hold_document}'s shape: resolve the artifact, open a
        # review on it, hand it over, park.
        #
        # The session is opened BEFORE the baton, and that order is what lets
        # the claim be keyed on {Review::Session#digest} -- the address a
        # verdict will judge. The other order would need the claim to name
        # something else, and then one review would have two identities.
        def hold(input)
          return Refusals.needs_base if Blankness.blank?(input.base)

          source = @seams.changesets.source(base: input.base, head: HEAD)
          return Refusals.no_changeset if source.nil?

          judged(*opened(session_over(source), source))
        rescue Review::Source::UnknownRef, Review::Changeset::Unparseable,
               Review::Changeset::Unattributed, Epic::Review::AlreadyOpen,
               Review::Surface::Incomplete, Unroutable => e
          Refusals.unopened(e)
        end

        private

        def session_over(source)
          Review::Session.open(changeset: Review::Changeset.new(source:), journal: @notes,
                               source: source.class.name, surface: @seams.surface, policy: @seams.policy)
        end

        # The award of the baton, on the changeset's own address. The written
        # side is the DIFF -- the bytes lain drew for the human -- which is
        # prose by {Epic::Intake::Prose}'s reading, so nothing structural is
        # claimed over it either way.
        def opened(session, source)
          written = Epic::Intake::Prose.new(bytes: source.diff)
          [session, tell(@review.open(path: session.digest, written:), session, written)]
        end

        # {RequestReview#tell}'s rule on the changeset rail, and its whole
        # `ensure` argument with it: bind BEFORE anything is drawn, because a
        # human fast enough to answer between the two would otherwise send a
        # verdict nothing could route, and give the baton back if the
        # hand-over raises before they have been told.
        #
        # `present` answers a refusal SENTENCE or nothing ({Review::Surface}'s
        # convention, which is exactly `open_review`'s), so it rides the
        # notification the same way: a human whose editor refused still learns
        # a review is waiting on them.
        def tell(token, session, written)
          @bindings.bind_changeset_review(handover(session, token, written))
          notice = session.present(scope: SCOPE)
          @notify.question(agent: AGENT, text: waiting(token, session, notice))
          told = true
          token
        ensure
          Baton.give_back(@review, token) unless told
        end

        # The open review as BOTH rails see it (T31a). One object, bound once
        # here and fanned out to the editor's answered rail by whoever holds
        # both ({CLI::HumanReplies#bind_changeset_review}) -- so a note and a
        # verdict cannot reach two different reviews.
        #
        # The view comes off the seams rather than off the surface, and it has
        # to: a surface holds no review state and exposes no rendering, while a
        # gesture's row number is only resolvable by the view that STAMPED the
        # rendering it came from. The wiring passes one object to both.
        #
        # `reviewing` is the other half of that one wiring (T32a): the view's
        # diff surface is built with the editor and holds no round, so a `<CR>`
        # on a sidebar row opens nothing until the changeset reaches it from
        # whoever opened one. Sent on the same line of reasoning as the bind
        # below -- before anything is drawn, because a row the human can see is a
        # row they can press.
        def handover(session, token, written)
          view = @seams.view
          view.reviewing(session.changeset)
          Review::Handover.new(session:, view:,
                               baton: Baton::Held.new(review: @review, token:, written:))
        end

        # It parks on the BATON's promise and reads the verdict off the session
        # afterwards, because the two are one event:
        # {Review::Handover#wrote_verdict} submits the verdict and settles the
        # claim in that order, so a woken fiber cannot observe a settled claim
        # with no judgement on it.
        # The `ensure` IS extended over `token.await` here, and that is the one
        # place this half deliberately departs from {RequestReview#tell}'s rule
        # rather than copying it.
        #
        # The document half must NOT release on a cancelled wait: past the
        # hand-over a human genuinely holds a file, and letting lain regenerate
        # underneath somebody mid-edit is the harm the baton exists to prevent.
        # Its own example says the escape is that "with an editor attached they
        # can still send `done`".
        #
        # None of that transfers. Nobody holds anything -- the claim's path is a
        # synthetic digest, so there is no file to protect, no `:LainReviewDone`
        # to send and no CLI that abandons it. A cancelled park would therefore
        # leave a claim that {Epic::Review.from_journal} rebuilds across a
        # RESTART, after which every `implementation` call over that changeset
        # refuses {Epic::Review::AlreadyOpen} forever -- and the very
        # inertness that makes the claim harmless to the write guard is what
        # makes that wedge silent instead of loud.
        #
        # Idempotent on the ordinary path: {Review::Handover#wrote_verdict}
        # settles before it resolves, so `settled` is already true and the
        # give-back never runs -- and were it to, {Epic::Review::NotOpen} is
        # exactly what {Baton.give_back} swallows.
        def judged(session, token)
          token.await
          settled = true
          Tool::Result.ok(ChangesetReport.new(session:, token:).to_s)
        ensure
          Baton.give_back(@review, token) unless settled
        end

        def waiting(token, session, notice)
          changeset = session.changeset
          [format(CHANGESET_WAITING, base: changeset.base_ref, head: changeset.head_ref,
                                     generation: token.generation, slug: token.epic_slug,
                                     files: changeset.files.size), notice].compact.join(" ")
        end
      end

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

        # There is no changeset half to refuse ANY MORE, and the two sentences
        # below are what replaced the one that did. `NO_DOCUMENT` said reviewing
        # an implementation "would mean reviewing a diff, and lain has no
        # surface for that"; there is one, so the stage opens a review and the
        # only things left to decline are a call that named no base and a run
        # with nothing wired to build a diff. Both are about THIS call or THIS
        # wiring, never about the stage.
        NO_CHANGESET = "no changeset could be built for this run, so there is no diff to review and no review " \
                       "was opened. `implementation` reads its changeset from a source the chat is wired with; " \
                       "this one has none."

        NEEDS_BASE = "an implementation review needs a base: the ref the changeset is read against. Without " \
                     "one there is no diff to open, and guessing would ask a human to judge somebody else's " \
                     "commits. No review was opened."

        # It says "nothing is under review" rather than "lain still holds the
        # baton". The baton is what the HUMAN takes when a review opens, so the
        # shorter sentence read as its own opposite -- a model could take it for
        # "a review is open" and wait for a settle that is never coming.
        UNPARSEABLE = "%<path>s no longer parses as an epic document, so there is nothing to compare a review " \
                      "against and no review was opened: %<reason>s. The file is untouched and nothing is " \
                      "under review, so lain may still regenerate it -- or repair it by hand."

        NEEDS_ID = "%<reason>s. An issue_plan review needs an issue_id naming the issue whose plan to review."

        def no_changeset = Tool::Result.error(NO_CHANGESET)

        def needs_base = Tool::Result.error(NEEDS_BASE)

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

      # What the model reads when a changeset review closes.
      #
      # {Report}'s rule kept: every line is a report and none is a judgement --
      # except the one line that IS the human's judgement, which is quoted
      # rather than interpreted. The changeset ADDRESS is on it because that is
      # what {Epic::Submission.implementation} takes as its `digest:`: a report
      # naming the verdict and not the address would leave the stage's gate with
      # nothing to key on.
      class ChangesetReport
        def initialize(session:, token:)
          @session = session
          @token = token
        end

        # {Review::Session#regenerated?} is deliberately NOT among these lines.
        # It compares the round's opened digest against the changeset's address
        # NOW, and this tool opens a session and never resumes one, so both are
        # computed from the one changeset it holds and the answer is false for
        # every call that can reach here. A line that can never render is a
        # claim with no test behind it; the honest place for it is whatever
        # resumes a round, which is not this tool.
        def to_s = [heading, verdict, address, *annotations].compact.join("\n")

        private

        def changeset = @session.changeset

        def heading
          "Review of #{changeset.base_ref}..#{changeset.head_ref} settled " \
            "(generation #{@token.generation}, epic #{@token.epic_slug})."
        end

        def verdict = "verdict: #{@session.verdict}"

        def address = "changeset: #{@session.digest}"

        def annotations
          notes = @session.annotations
          return ["annotations: none."] if notes.empty?

          ["annotations (#{notes.size}):",
           *notes.map { |note| "  - #{note.path}:#{note.line} (#{note.side}): #{note.text.inspect}" }]
        end
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
