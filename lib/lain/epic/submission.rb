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

    # What a human's reply to {Submission#gate_question} decides, read through
    # {Approval::Reply}, the one reply grammar. It lives beside the question
    # because the question is the only place a human is told which words
    # count, so the words it names and the words read back are one list.
    #
    # A reply the grammar cannot read is no verdict, so it is {Gate::Unheard}
    # and the gate asks again: "the human denied this" would be a claim
    # nobody made. A blank reply denies, as the prompt's cue says, and the end
    # of input is {EOF}, because nobody typed the denial it stands for.
    module GateReply
      EOF = "eof"

      def self.words(kind)
        *leading, last = Approval::Reply::WORDS.fetch(kind)
        "#{leading.join(", ")} or #{last}"
      end
      private_class_method :words

      INSTRUCTION = "Reply #{words(Approval::Verdict::Approve)} to approve, " \
                    "#{words(Approval::Verdict::Deny)} to deny, or #{words(Approval::Verdict::Hold)} to pause " \
                    "the work until you speak again. A note may follow the word after a comma, as in " \
                    "\"approve, re-signed unchanged\" or \"deny, wrong crate\"; any other reply decides " \
                    "nothing and is asked again.".freeze

      WAVE_INSTRUCTION = "Reply approve, deny or hold alone to decide every issue in the wave. To decide issues " \
                         "one by one, write clauses split by ; or new lines, each a verdict word, an issue id and " \
                         "an optional note after a colon, as in \"approve; deny b: wrong crate; hold c\". A leading " \
                         "bare verdict decides every issue the reply does not name; without one, name every issue. " \
                         "A reply naming an issue outside the wave, or any other reply, decides nothing and is " \
                         "asked again."

      UNHEARD_CLIP = 300

      # @param words [String, nil] what the human wrote; nil when nothing was
      # @param surface [String] who is credited with a recognised verdict
      # @return [Gate::Answer, Gate::Unheard]
      def self.answer(words, surface:)
        return Gate::Answer.deny(EOF) if words.nil?
        return Gate::Answer.deny(surface) if words.strip.empty?

        verdict = read(words)
        return Gate::Unheard.new(words:) if verdict.is_a?(Approval::Reply::Unrecognised)

        Gate::Answer.new(verdict:, surface:)
      end

      # @param text [String] one reply, or one wave clause with its id taken out
      # @return [Approval::Verdict::Approve, Approval::Verdict::Hold, Approval::Verdict::Deny,
      #   Approval::Reply::Unrecognised] the verdict, its note made legible
      def self.read(text)
        verdict = Approval::Reply.parse(text.strip)
        return verdict if verdict.is_a?(Approval::Reply::Unrecognised) || verdict.note.nil?

        verdict.class.new(note: legible_text(verdict.note.strip))
      end

      # @param unheard [Gate::Unheard] the reply that decided nothing
      # @param question [String] the artifact's own question
      # @return [String] the question asked again, led by why
      def self.again(unheard, question)
        why = unheard.why || "The reply #{clipped(unheard.words.to_s.strip).inspect} decides nothing"
        "#{why}, so nothing was decided. #{question}"
      end

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
      def self.clipped(text, limit: UNHEARD_CLIP)
        escaped = Utf8.escaped(text.gsub(/\s+/, " "))
        return escaped if escaped.bytesize <= limit

        "#{escaped.byteslice(0, limit).scrub("")}..."
      end
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
      # A reply is clauses, each opened by a verdict word at the start, after
      # `;` or at a line start, so a semicolon inside a note stays in it. A
      # clause naming an id is read by {GateReply.read} with the id taken out;
      # a bare one decides every issue no clause names. Any reply that leaves
      # an issue undecided, or names an id outside the wave, decides nothing:
      # the issue it meant is otherwise the one it decides wrongly.
      #
      # `standing` names the wave's issues left out of this question because
      # their approval stands, so a clause naming one is told so, not called a typo.
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

        # @param said [Gate::Said] what the human wrote
        # @return [Gate::Outcome, Gate::Unheard] each issue's verdict, or why the reply decided nothing
        def heard(said)
          return outcome(GateReply.answer(said.words, surface: said.surface)) if said.words.to_s.strip.empty?

          readings = said.words.split(Submission::WaveReading::CLAUSE).map { Submission::WaveReading.new(self, _1) }
          unheard = readings.lazy.filter_map(&:refusal).first || undecided(readings)
          return Gate::Unheard.new(words: said.words, why: unheard) if unheard

          Gate::Outcome.new(verdicts: decided(readings), surface: said.surface)
        end

        # @param answer [Gate::Answer] one answer for the whole wave
        # @return [Gate::Outcome]
        def outcome(answer) = Gate::Outcome.new(verdicts: ids.to_h { [_1, answer.verdict] }, surface: answer.surface)

        # @param id [String] an id a clause named
        # @return [String, nil] why the id is not one this question asks about
        def unasked(id)
          return if ids.include?(id)
          return "#{id} is in wave #{number} but was not asked this time: its approval stands" if standing.include?(id)

          "#{id} is not in wave #{number} (#{(ids + standing).join(", ")})"
        end

        private

        def undecided(readings)
          named = readings.filter_map(&:id)
          bare = readings.count { _1.id.nil? }
          return "the reply gives #{bare} bare verdicts" if bare > 1

          twice = named.tally.select { _2 > 1 }.keys
          return "the reply names #{twice.join(", ")} twice" unless twice.empty?

          missing = ids - named
          "the reply decides nothing for #{missing.join(", ")}" if bare.zero? && !missing.empty?
        end

        def decided(readings)
          bare = readings.find { _1.id.nil? }&.verdict
          named = readings.select(&:id).to_h { [_1.id, _1.verdict] }
          ids.to_h { [_1, named.fetch(_1) { bare }] }
        end
      end

      # One clause of a wave's reply: a verdict word, then an id the wave
      # knows or any word followed by a colon, then a note after a colon. Ids
      # are matched case and all, so a word that only resembles one fails
      # closed. A clause that could be read 2 ways decides nothing: an id
      # followed by anything but a colon, a note naming an id, a verdict word
      # in a bare deny or hold note, or a word taking an approval back may
      # mean a second issue the reading would decide wrongly.
      class WaveReading
        WORDS = Approval::Reply::WORDS.values.flatten.freeze
        # Words that take an approval back, which its note may not hold: the
        # deny and hold words, and the plain negations a human types.
        AGAINST = (Approval::Reply::WORDS.fetch(Approval::Verdict::Deny) +
                   Approval::Reply::WORDS.fetch(Approval::Verdict::Hold) +
                   %w[reject rejected not don't dont cancel cancelled decline declined veto vetoed]).freeze
        TOKEN = /[[:alpha:]]+(?:'[[:alpha:]]+)*/
        WORD = WORDS.sort_by { -_1.size }.join("|")
        CLAUSE = /[;\n](?=[ \t]*(?:#{WORD})(?![\w-]))/i
        ID = /[A-Za-z0-9][\w-]*/
        SHAPE = /\A\s*(?<word>#{WORD})[ \t]+(?<id>#{ID})(?<rest>.*)\z/mi
        NOTE = /\A(?:[ \t]*:.*)?\z/m

        attr_reader :id, :verdict

        # @param wave [Wave] the question this clause answers
        # @param clause [String] one clause of the reply
        def initialize(wave, clause)
          @wave = wave
          @clause = clause
          shape = SHAPE.match(clause)
          @id = shape[:id] if shape && named?(shape)
          @loose = @id && !NOTE.match?(shape[:rest])
          @verdict = GateReply.read(@id ? "#{shape[:word]}: #{shape[:rest].sub(/\A[ \t]*:?/, "")}" : clause)
        end

        # @return [String, nil] why this clause decides nothing
        def refusal
          return @wave.unasked(id) if id && @wave.unasked(id)
          return "the clause #{quoted} gives #{id} a note without a colon, so it reads 2 ways" if @loose
          return "the clause #{quoted} decides nothing" if verdict.is_a?(Approval::Reply::Unrecognised)

          "the note in #{quoted} names #{tangled.join(", ")}, so it reads 2 ways" unless tangled.empty?
        end

        private

        def known = @wave.ids + @wave.standing

        def named?(shape) = known.include?(shape[:id]) || shape[:rest].match?(/\A[ \t]*:/)

        def quoted = GateReply.clipped(@clause.strip).inspect

        # A deny or hold note after an id's colon cannot open a clause, so it
        # may hold any word; an approval is the one reading nobody may guess
        # into, so its note may not take it back. Ids in a note match in any
        # case, since a human naming one there was not typing a clause.
        #
        # NFKC first, so a fullwidth "ｎｏ" reads as the "no" it shows.
        def tangled
          note = verdict.note.to_s.unicode_normalize(:nfkc).tr("’", "'")
          named = note.scan(ID).map(&:downcase)
          known.select { named.include?(_1.downcase) } + (note.downcase.scan(TOKEN) & refused_words)
        end

        def refused_words
          return AGAINST if verdict.approved?

          id ? [] : WORDS
        end
      end
    end
  end
end
