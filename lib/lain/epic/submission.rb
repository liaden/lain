# frozen_string_literal: true

module Lain
  module Epic
    module Contracts
      # Reopened from `epic/contracts.rb`; that file's header is the one
      # docstring, and carries the validate-then-freeze convention.

      # `stage` IS restated here, unlike {Contracts::StageTransition}'s
      # deliberate omission: a Submission is built by its own class methods
      # below rather than passed a caller-supplied stage, so there is no {Stage}
      # value anywhere on this path to own the check instead.
      class Submission < Declarative::Carrier
        attribute :stage
        attribute :slug
        attribute :content_digest
        attribute :fact
        validates :stage, inclusion: { in: STAGES, message: "must be one of #{STAGES.join("/")}, got %<value>s" }
        validates :slug, presence: { message: "must name the epic this submission belongs to, got nil" }
        validate :slug_is_canonicalizable
        validates :content_digest, presence: { message: "must carry a content address, got nil" }
        validate :content_digest_is_a_string
        validates :fact, presence: { message: "must carry the one concrete fact gate_question names, got nil" }

        private

        # `presence:` alone lets a Hash/Array/Integer digest through, and a
        # content ADDRESS is a String or it is not an address: `#digest` composes
        # this value into `Canonical.digest`, so a Hash here acquires a real gate
        # identity for something nobody can look up. Three of the four
        # constructors produce a String themselves; `implementation` is the one
        # path that takes a digest from OUTSIDE, so it is the one path that needs
        # this checked rather than assumed.
        def content_digest_is_a_string
          return if content_digest.nil?

          return if content_digest.is_a?(String)

          errors.add(:content_digest, "must be a String content address, got #{content_digest.class}")
        end

        # `#digest` canonicalizes `slug`, and `Canonical.normalize` raises on a
        # String that cannot be re-encoded to UTF-8. Unchecked, that turns
        # `#digest` -- relied on as TOTAL over every constructible Submission --
        # into a method that raises deep inside `Epic::Gate#call`, after the
        # human has answered and before the verdict is journaled. A slug
        # plausibly arrives via a Linux directory name
        # ({Epic::Home}), which is arbitrary bytes and not guaranteed UTF-8.
        def slug_is_canonicalizable
          return if slug.nil? # presence: above already reports this

          Canonical.normalize(slug)
        rescue Canonical::UnsupportedType => e
          errors.add(:slug, "must be valid UTF-8 -- it is hashed into #digest -- (#{e.message})")
        end
      end

      # The raw prose handed to `.research`, checked BEFORE
      # `Canonical.digest`/`#bytesize` ever touch it. Without this, nil text
      # raises `NoMethodError` three frames down naming neither the constructor
      # nor the field, and a Hash/Integer/Symbol sails through `Canonical.digest`
      # -- which canonicalizes all three happily -- to acquire a real gate
      # identity. The only thing stopping that today is the incidental
      # `#bytesize` call building `fact`, which a refactor could drop without
      # anyone noticing non-prose had started being gated as prose.
      #
      # Deliberately does NOT reject an empty String: "no research was written"
      # is a fact this class reports honestly (`fact` says "0 bytes"), and
      # whether that is worth a human's approval is a Policy question rather than
      # a shape this constructor is positioned to judge.
      class Prose < Declarative::Carrier
        attribute :text
        validate :must_be_prose

        private

        def must_be_prose
          return errors.add(:text, "must be prose text, got nil") if text.nil?

          errors.add(:text, "must be a String (prose text), got #{text.class}") unless text.is_a?(String)
        end
      end

      # The raw graph handed to `.epic_plan`, checked before `#digest` is sent
      # to it -- the same reasoning as {Prose}, once removed: `nil.digest`
      # raises unnamed, and anything answering `#digest` (a stray Hash-like
      # double, say) would silently pass as an epic plan.
      class GraphArtifact < Declarative::Carrier
        attribute :graph
        validate :must_be_a_graph

        private

        def must_be_a_graph
          return errors.add(:graph, "must be an Epic::Graph, got nil") if graph.nil?

          errors.add(:graph, "must be an Epic::Graph, got #{graph.class}") unless graph.is_a?(Graph)
        end
      end

      # The rendered issue handed to `.issue_plan`, checked before its digest
      # is asked for, for {GraphArtifact}'s reason.
      class ViewArtifact < Declarative::Carrier
        attribute :view
        validate :must_be_a_view

        private

        def must_be_a_view
          return errors.add(:view, "must be an Epic::IssueView, got nil") if view.nil?

          errors.add(:view, "must be an Epic::IssueView, got #{view.class}") unless view.is_a?(IssueView)
        end
      end

      # `issue_id` NAMES which issue a submission is for. Nothing downstream
      # of `fact`'s interpolation would ever catch a blank one: `"issue "` is
      # non-blank prose, so a human ends up asked to approve an unnamed issue
      # rather than the constructor refusing to build at all.
      class IssueId < Declarative::Carrier
        attribute :issue_id
        validates :issue_id, presence: { message: "must name the issue this submission is for, got nil" }
      end
    end

    # What a human's reply to {Submission#gate_question} decides. It lives beside
    # the question because the question is the only place a human is told which
    # words count, so the words it names and the words read back are one list.
    #
    # Only a word the question names is a human's verdict. Anything else still
    # denies -- an approval is the one reading nobody may guess into -- but is
    # journaled as {UNRECOGNISED} with the reply in its reason, because
    # "the human denied this" would be a claim nobody made. End of input is
    # {EOF} for the same reason.
    #
    # A hold word is no verdict either: the human asked for the work to wait
    # for them, so it is journaled as {HELD}, approving nothing and revoking
    # nothing. Like a denial word it only has to stand alone at the start, so
    # "hold on" holds, with "on" as its note.
    module GateReply
      APPROVALS = %w[approve approved y yes].freeze
      DENIALS = %w[deny denied n no].freeze
      HOLDS = %w[hold wait stop].freeze

      UNRECOGNISED = "unrecognised"
      EOF = "eof"
      HELD = "held"

      # How a reply is spoken, as opposed to what it says: case, surrounding
      # space and a closing full stop or exclamation mark. Only those two: a
      # trailing `?` turns "approve" into a question back, and an ellipsis into
      # a hesitation, and neither is a verdict anybody gave.
      TRAILING_PUNCTUATION = /[.!]+\z/

      INSTRUCTION = "Reply #{APPROVALS.join(", ")} to approve, #{DENIALS.join(", ")} to deny, " \
                    "or #{HOLDS.join(", ")} to pause the work until you speak again; " \
                    "a reason may follow a denial word, and a note a hold word; " \
                    "any other reply is recorded as #{UNRECOGNISED} and denies.".freeze

      # A wave names its issues by id, so a denial may name the ones it means.
      WAVE_INSTRUCTION = "Reply #{APPROVALS.first} to approve every issue in the wave, #{DENIALS.first} to deny " \
                         "every one, or #{DENIALS.first} <id>: <reason> to deny only the issues named, starting " \
                         "each further one with ; <id>: or on a new line; the issues not named are approved. " \
                         "Reply #{HOLDS.join(", ")} to pause the whole wave; any other reply, or an id not in " \
                         "the wave, is recorded as #{UNRECOGNISED} and denies every issue.".freeze

      SEPARATOR = '[\s.!:,;\-]'

      def self.word_then_reason(words) = /\A\s*(?:#{words.join("|")})(?:#{SEPARATOR}*\z|#{SEPARATOR}+(?<reason>.*\S))/mi
      private_class_method :word_then_reason

      DENIAL = word_then_reason(DENIALS)
      HOLD = word_then_reason(HOLDS)

      UNRECOGNISED_CLIP = 300

      # @param words [String, nil] what the human wrote; nil when nothing was
      # @param surface [String] who is credited with a recognised verdict
      # @return [Epic::Gate::Answer]
      def self.answer(words, surface:)
        return Epic::Gate::Answer.deny(EOF) if words.nil?

        word = words.to_s.strip.downcase.sub(TRAILING_PUNCTUATION, "")
        return Epic::Gate::Answer.approve(surface) if APPROVALS.include?(word)
        return led(DENIAL, words, surface) if DENIAL.match?(words.to_s)
        return led(HOLD, words, HELD) if HOLD.match?(words.to_s)

        Epic::Gate::Answer.new(approved: false, surface: UNRECOGNISED, reason: unrecognised(words))
      end

      # @param answered_by [#to_s, nil] a decision's surface
      # @return [Boolean] whether the human held the gate rather than deciding it
      def self.held?(answered_by) = answered_by.to_s == HELD

      def self.led(pattern, words, surface)
        reason = pattern.match(words.to_s)[:reason]
        Epic::Gate::Answer.new(approved: false, surface:, reason: reason && legible_text(reason))
      end
      private_class_method :led

      # A reply cannot pose as a second result line: control bytes are written
      # out, and the reader indents every continuation line.
      def self.legible_text(text)
        escaped = Utf8.escaped(text, keep: "\n")
        return escaped if escaped.bytesize <= Tool::Bounds::RESULT_BYTES

        kept = escaped.byteslice(0, Tool::Bounds::RESULT_BYTES).scrub("")
        "#{kept}\n[reason cut at #{kept.bytesize} of #{escaped.bytesize} bytes]"
      end
      private_class_method :legible_text

      # @param text [String] what the human wrote
      # @param limit [Integer] the most bytes kept
      # @return [String] the text on one line, control bytes written out, cut to `limit` bytes with `...`
      def self.clipped(text, limit: UNRECOGNISED_CLIP)
        escaped = Utf8.escaped(text.gsub(/\s+/, " "))
        return escaped if escaped.bytesize <= limit

        "#{escaped.byteslice(0, limit).scrub("")}..."
      end

      def self.unrecognised(words)
        "the reply #{clipped(words.to_s).inspect} is none of #{(APPROVALS + DENIALS + HOLDS).join(", ")}, " \
          "so the gate denied it"
      end
      private_class_method :unrecognised
    end

    # One artifact bound to one stage of an epic's pipeline: the gate's whole
    # duck ({#digest}, {#gate_question}), for the four shapes the pipeline
    # produces. {Epic::Gate} never learns which constructor built the value.
    #
    # `#digest` composes `(stage, slug, artifact)` and not the artifact alone,
    # because {Epic::Gate}'s registry is keyed on `#digest` and knows nothing
    # of stages or epics. Answering the content address alone would make two
    # different (stage, epic) pairs wrapping the SAME bytes one key: approving
    # epic `alpha`'s 3-issue plan would silently open `beta`'s identical plan,
    # and approving a research doc would open an issue_plan resubmitting the same
    # words. Nobody signed off on either. So:
    #
    #   Canonical.digest("stage" => stage, "epic" => slug, "artifact" => content_digest)
    #
    # COMPUTED rather than stored, as {Epic::Issue#digest}/{Epic::Graph#digest}
    # are: the value is frozen and the hash is cheap, so memoizing would buy
    # nothing and cost the deep freeze. It is TOTAL over every constructible
    # Submission, which {Contracts::Submission#slug_is_canonicalizable} is what
    # keeps true.
    #
    # The alternative -- letting the stage live INSIDE the artifact's own text so
    # the content digest moves on its own -- was rejected. It works for
    # `research`/`issue_plan`, which digest their bytes directly, but not for
    # `epic_plan` (`Graph` carries no slug, `Document.to_markdown` emits no
    # header, and `parse_markdown` drops any preamble) and not for
    # `implementation`, which takes an external sha with no text to embed
    # anything in. Making it work would mean adding a slug member to a landed,
    # mutation-tested value and invalidating every graph digest ever computed.
    #
    # `#content_digest` stays public -- for `epic_plan` it equals
    # {Epic::Graph#digest} exactly -- and is named `content_digest` rather than
    # `artifact_digest` because the Approval subsystem already uses that word for
    # the COMPOSED gate identity. Reusing it here would read as the same value
    # four call sites away, when it is the one value that is explicitly NOT the
    # gate key.
    #
    # Which address each stage digests is a decision per stage. Prose digests its
    # BYTES: two renderings of the same words are two approvals, because a human
    # signed off on THOSE words. An `issue_plan` composes the issue's own digest
    # with its rendered {IssueView}: the epic's criteria, the authored file and
    # the Links all reach the view, so an edit to any is a different,
    # un-approved plan -- which is what keeps an implementation from passing
    # against criteria nobody signed off.
    # `epic_plan` reuses {Epic::Graph#digest} -- over
    # the normalized issue set rather than the markdown -- so re-rendering an
    # unchanged graph costs no fresh sign-off. `implementation` composes the
    # changeset address it is GIVEN -- never re-deriving it, which would be a
    # second, possibly-diverging opinion -- with the issue it is offered for:
    # one commit can be offered as two issues' work, and an address keyed on
    # the commit alone would let an approval for one open the other's gate.
    #
    # Disk-free on purpose: a Submission holds only what it is handed, never a
    # path, so it stays a pure value the gate can journal and replay without ever
    # touching {Epic::Home}.
    #
    # `issue_id` names the issue an issue-scoped submission is about, and
    # `criteria_digest` the criteria an issue plan carries; both are nil for the
    # epic's own two documents. `changeset` is the address an implementation
    # was given, kept because its content address no longer is that address and
    # a reader asked to look at the commit needs the commit. They ride beside the gate identity as well as
    # inside a plan's content address, because the gate decision and the
    # sign-off queue partition on the issue, and a grader joins on the criteria.
    Submission = Data.define(:stage, :slug, :content_digest, :fact, :issue_id, :criteria_digest, :changeset,
                             :review, :manual_commands) do
      # `sources` maps each source name to its text, so an approval of the
      # research is an approval of the facts it cites. With none the digest is
      # the text's alone, as it was before sources existed.
      def self.research(text:, slug:, sources: {})
        Contracts::Prose.check!(text:)
        new(stage: "research", slug:, content_digest: research_digest(text, sources),
            fact: "#{text.bytesize} bytes")
      end

      def self.research_digest(text, sources)
        return Canonical.digest(text) if sources.empty?

        cited = sources.sort.map { |name, source| [name, Canonical.digest(source)] }
        Canonical.digest("research" => Canonical.digest(text), "sources" => cited)
      end
      private_class_method :research_digest

      def self.epic_plan(graph:, slug:)
        Contracts::GraphArtifact.check!(graph:)
        new(stage: "epic_plan", slug:, content_digest: graph.digest, fact: issue_count(graph.issues.size))
      end

      # @param size [Integer]
      # @return [String] the count, in the singular for 1
      def self.issue_count(size) = size == 1 ? "1 issue" : "#{size} issues"

      # @param view [IssueView] the issue as it renders now
      # @param slug [String] the epic
      # @param issue_id [String] the issue, refused unless it is the view's
      # @return [Submission]
      def self.issue_plan(view:, slug:, issue_id:)
        Contracts::ViewArtifact.check!(view:)
        issue_id = viewed_issue!(clean_issue_id(issue_id), view)
        new(stage: "issue_plan", slug:, issue_id:, criteria_digest: view.criteria.digest,
            content_digest: Canonical.digest("issue" => view.issue.digest, "view" => view.digest),
            fact: viewed(view, slug))
      end

      def self.viewed_issue!(issue_id, view)
        return issue_id if issue_id == view.issue.id

        raise ArgumentError, "issue_id #{issue_id.inspect} is not the viewed issue #{view.issue.id.inspect}"
      end
      private_class_method :viewed_issue!

      # Quoted where the text is authored, so a title or scenario name cannot
      # break the journaled line the question lands on.
      def self.viewed(view, slug)
        id = view.issue.id
        names = view.criteria.map { _1.name.inspect }
        ["issue #{id} #{view.issue.title.inspect}",
         "blocked by #{view.blocked_by.empty? ? "nothing" : view.blocked_by.join(", ")}",
         names.empty? ? "no scenarios" : "scenarios #{names.join(", ")}",
         "read lain://epic/#{slug}/issues/#{id}.md"].join("; ")
      end
      private_class_method :viewed

      # @param slug [String] the epic
      # @param views [Array<IssueView>] the wave's issues as they render now
      # @param number [Integer] the wave's place in {Graph#waves}, counted from 1
      # @return [Wave]
      def self.wave(slug:, views:, number:)
        raise ArgumentError, "wave #{number} holds no issues, so there is nothing to ask about" if views.empty?

        Submission::Wave.new(slug: -slug.to_s, number:,
                             submissions: views.map { |view| issue_plan(view:, slug:, issue_id: view.issue.id) }.freeze)
      end

      # The changeset address is checked as given, before it is composed: a
      # Hash would otherwise canonicalize into a real gate identity.
      #
      # `tests` is evidence for the human and stays out of the address, so a
      # re-asked gate over the same commit is the same gate.
      # `manual_commands` is nil for an issue judged by tests, and for one a
      # human judges, the commands its scenarios name.
      def self.implementation(slug:, issue_id:, digest:, tests: nil, manual_commands: nil)
        issue_id = clean_issue_id(issue_id)
        fact = "issue #{issue_id}, #{digest}, tests: #{tests_said(tests)}#{manual_said(manual_commands)}"
        Contracts::Submission.check!(stage: "implementation", slug:, content_digest: digest, fact:)
        new(stage: "implementation", slug:, content_digest: implemented(digest, issue_id), fact:, issue_id:,
            changeset: digest, manual_commands:)
      end

      def self.manual_said(commands)
        return "" if commands.nil?

        ", manual acceptance (a human runs: #{commands.empty? ? "none named" : commands.join("; ")})"
      end

      def self.tests_said(tests)
        return "not run (no test run was recorded for this submission)" if tests.nil?
        return "not run (#{tests.why})" unless tests.ran

        [count(tests.passed, "passed"), (count(tests.failed, "failed") if tests.failed.positive?),
         (count(tests.errors, tests.errors == 1 ? "error" : "errors") if tests.errors.positive?)].compact.join(", ")
      end

      def self.count(number, word) = "#{number} #{word}"
      private_class_method :count
      private_class_method :tests_said

      def self.implemented(digest, issue_id) = Canonical.digest("changeset" => digest, "issue" => issue_id)
      private_class_method :implemented

      # Interned and stripped BEFORE the contract, so `presence:` judges the
      # bytes that actually land in `fact` -- {Records::IssueTransition}'s
      # ordering, for its reason.
      def self.clean_issue_id(issue_id)
        cleaned = -issue_id.to_s.strip
        Contracts::IssueId.check!(issue_id: cleaned)
        cleaned
      end
      private_class_method :clean_issue_id

      def initialize(stage:, slug:, content_digest:, fact:, issue_id: nil, criteria_digest: nil, changeset: nil,
                     review: nil, manual_commands: nil)
        # Interned BEFORE the contract, so `presence:` judges the bytes that
        # actually get asked and journaled.
        stage = -stage.to_s
        slug = -slug.to_s
        fact = -fact.to_s
        # `settle!` rather than `check!` for the one member interning cannot
        # reach: `content_digest` arrives from outside on the `implementation`
        # path, and settling deep-freezes it -- validating FIRST, so the copy
        # only ever happens to a value already agreed to be a String. The three
        # interned members are shareable already and pass through untouched, so
        # nothing loses its deduplication.
        super(**Contracts::Submission.settle!(stage:, slug:, content_digest:, fact:),
              issue_id: issue_id && -issue_id.to_s, criteria_digest: criteria_digest && -criteria_digest.to_s,
              changeset: changeset && -changeset.to_s, review: review && -review.to_s,
              manual_commands: manual_commands&.map { |command| -command.to_s }&.freeze)
      end

      def manual_acceptance? = !manual_commands.nil?

      # THE GATE IDENTITY, which {Epic::Gate#call}/`#ensure_approved!` key
      # their registry on. See the class header for why it composes stage + slug
      # + artifact rather than the artifact's content address alone.
      def digest
        Canonical.digest("stage" => stage, "epic" => slug, "artifact" => content_digest)
      end

      # The one rendering {Epic::Gate#call} asks through the artifact duck:
      # the stage, the slug, and the one concrete fact that distinguishes this
      # submission from another at the same stage.
      def gate_question
        # `slug.inspect` rather than plain interpolation: {Gate::Policy} and
        # {Gate::Adjudicator} journal this question straight into NDJSON, so a
        # slug carrying a literal newline must not break the line it lands on.
        #
        # `-"..."` rather than a plain literal: a shareable Submission must not
        # be the one thing on it that hands back a mutable String, or a caller
        # mutating the return value would read as this record's state changing.
        -["Approve the #{stage} stage for #{slug.inspect}? (#{fact})", (Submission::ReviewQuote.line(review) if review),
          GateReply::INSTRUCTION].compact.join(" ")
      end
    end

    class Submission
      # The agent's quote of a review is evidence for the human and nothing a
      # reply is read against, so it is bounded and kept on one quoted line.
      module ReviewQuote
        BYTES = 600

        LABEL = "Review verdict (quoted by the agent):"

        # Whitespace collapses first so a newline cannot start a line of its own
        # (a wave's reply grammar opens clauses at a line start), and `inspect`
        # quotes what is left so it reads as a quotation, not as the question.
        #
        # @param review [String]
        # @return [String] the label and the quoted, clamped text, on one line
        def self.line(review)
          quoted = review.to_s.split.join(" ").inspect[1..-2]
          shown = quoted.bytesize > BYTES ? "#{whole_escapes(quoted.byteslice(0, BYTES).scrub(""))}..." : quoted
          "#{LABEL} \"#{shown}\""
        end

        # A cut can land inside an escape such as `\u0000`, which would read as a
        # different character, so a trailing partial escape is dropped.
        def self.whole_escapes(text) = text.sub(/\\(?:u\h{0,3}|x\h?)?\z/, "")
      end

      # One wave's issue plans put to the human as one question. Each issue is
      # still decided under its own {Submission}, so the wave adds a question
      # and a reading of the reply, and no gate identity of its own.
      #
      # A denial is read against the wave's ids only once they are known: a
      # clause opens only at the start, at `; <id>:` or at a line opening
      # `<id>:`, so a semicolon or newline inside a reason stays in it. Any
      # clause naming an id outside the wave denies every issue, because the
      # issue it meant to deny is otherwise the one it approves.
      #
      # `standing` names the wave's issues left out of this question because
      # their approval stands, so a deny naming one is told so, not called a typo.
      Wave = Data.define(:slug, :number, :submissions, :standing, :review) do
        def initialize(slug:, number:, submissions:, standing: [], review: nil)
          super(slug:, number:, submissions:, standing: standing.map { -_1.to_s }.freeze,
                review: review && -review.to_s)
        end

        def stage = "issue_plan"

        def ids = submissions.map(&:issue_id)

        def gate_question
          count = Submission.issue_count(submissions.size)
          -["Approve the #{stage} stage for #{slug.inspect}, wave #{number} (#{count})?",
            (Submission::ReviewQuote.line(review) if review),
            *submissions.map { |submission| "  #{submission.fact}" }, GateReply::WAVE_INSTRUCTION].compact.join("\n")
        end

        # @param answer [Gate::Answer] the reply as {GateReply.answer} read it
        # @return [Gate::Answer] the same reply, or an unrecognised denial when
        #   any clause names an id outside this question
        def heard(answer)
          stray = named(answer).find { |id| !ids.include?(id) }
          return answer if stray.nil?

          Gate::Answer.new(approved: false, surface: GateReply::UNRECOGNISED,
                           reason: "#{unasked(stray)}, so the gate denied the whole wave: #{answer.reason}")
        end

        # @param answer [Gate::Answer] a reply {#heard} has read
        # @return [Gate::Outcome]
        def outcome(answer)
          return Gate::Outcome.new(approved: ids, denied: {}, held: false) if answer.approved?
          return Gate::Outcome.new(approved: [], denied: {}, held: true) if GateReply.held?(answer.surface)

          denied = clauses(answer) || ids.to_h { |id| [id, answer.reason] }
          Gate::Outcome.new(approved: ids - denied.keys, denied:, held: false)
        end

        private

        def worded?(answer)
          !answer.approved? && !answer.reason.nil? && answer.surface != GateReply::UNRECOGNISED &&
            !GateReply.held?(answer.surface)
        end

        # Wider than an id on purpose: a word in another case or with an
        # underscore is not the wave id it resembles, and must fail closed.
        def named(answer)
          return [] unless worded?(answer)

          answer.reason.scan(/(?:\A|[;\n])\s*([A-Za-z0-9][\w-]*)[ \t]*:/).flatten
        end

        def unasked(stray)
          return "#{stray} is in wave #{number} but was not asked this time: its approval stands" if
            standing.include?(stray)

          "#{stray} is not in wave #{number} (#{(ids + standing).join(", ")})"
        end

        def clauses(answer)
          return unless worded?(answer) && ids.include?(named(answer).first)

          answer.reason.split(/[;\n](?=[ \t]*(?:#{opener})[ \t]*:)/).each_with_object({}) do |clause, denied|
            id, why = clause.match(/\A\s*(#{opener})[ \t]*:(.*)\z/m).captures
            denied[id] = joined(denied[id], why.strip)
          end
        end

        # Longest first, so an id that prefixes another cannot claim its clause.
        def opener = ids.sort_by { -_1.size }.map { Regexp.escape(_1) }.join("|")

        def joined(earlier, why)
          said = [earlier, why].compact.reject(&:empty?).join("; ")
          said unless said.empty?
        end
      end
    end
  end
end
