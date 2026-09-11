# frozen_string_literal: true

module Lain
  module Epic
    module Contracts
      # Reopened from {Records}' own `module Contracts`; that file's header is
      # the one docstring, and carries the validate-then-freeze convention.

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
        # into a method that raises deep inside `Approval::Gate#call`, whose
        # first line is `artifact.digest`, three frames before the asker is ever
        # reached. A slug plausibly arrives via a Linux directory name
        # ({Epic::Home}), which is arbitrary bytes and not guaranteed UTF-8.
        def slug_is_canonicalizable
          return if slug.nil? # presence: above already reports this

          Canonical.normalize(slug)
        rescue Canonical::UnsupportedType => e
          errors.add(:slug, "must be valid UTF-8 -- it is hashed into #digest -- (#{e.message})")
        end
      end

      # The raw prose handed to `.research`/`.issue_plan`, checked BEFORE
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

      # `issue_id` NAMES which issue a submission is for. Nothing downstream
      # of `fact`'s interpolation would ever catch a blank one: `"issue "` is
      # non-blank prose, so a human ends up asked to approve an unnamed issue
      # rather than the constructor refusing to build at all.
      class IssueId < Declarative::Carrier
        attribute :issue_id
        validates :issue_id, presence: { message: "must name the issue this submission is for, got nil" }
      end
    end

    # One artifact bound to one stage of an epic's pipeline: the gate's whole
    # duck ({#digest}, {#gate_question}), for the four shapes the pipeline
    # produces. {Approval::Gate} never learns which constructor built the value.
    #
    # `#digest` composes `(stage, slug, artifact)` and not the artifact alone,
    # because {Approval::Gate}'s registry is keyed on `#digest` and knows nothing
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
    # signed off on THOSE words. An `issue_plan` composes its bytes with the
    # issue it is for and that issue's {Gherkin::Criteria#digest}: a plan is
    # written to satisfy its criteria, so approving one approves both, and an
    # edited criterion is a different, un-approved plan -- which is what keeps
    # an implementation from passing against criteria nobody signed off.
    # `epic_plan` reuses {Epic::Graph#digest} -- over
    # the normalized issue set rather than the markdown -- so re-rendering an
    # unchanged graph costs no fresh sign-off. `implementation` takes its digest
    # as GIVEN, because the changeset already computed the address that names it
    # and re-hashing would be a second, possibly-diverging opinion.
    #
    # Disk-free on purpose: a Submission holds only what it is handed, never a
    # path, so it stays a pure value the gate can journal and replay without ever
    # touching {Epic::Home}.
    #
    # `issue_id` names the issue an issue-scoped submission is about, and
    # `criteria_digest` the criteria an issue plan carries; both are nil for the
    # epic's own two documents. They ride beside the gate identity as well as
    # inside a plan's content address, because the gate decision and the
    # sign-off queue partition on the issue, and a grader joins on the criteria.
    Submission = Data.define(:stage, :slug, :content_digest, :fact, :issue_id, :criteria_digest) do
      def self.research(text:, slug:)
        Contracts::Prose.check!(text:)
        new(stage: "research", slug:, content_digest: Canonical.digest(text), fact: "#{text.bytesize} bytes")
      end

      def self.epic_plan(graph:, slug:)
        Contracts::GraphArtifact.check!(graph:)
        new(stage: "epic_plan", slug:, content_digest: graph.digest, fact: "#{graph.issues.size} issues")
      end

      # `criteria_digest` is REQUIRED and may be nil: an issue with no criteria
      # says so, where a forgotten keyword would gate a plan as if it had none.
      def self.issue_plan(text:, slug:, issue_id:, criteria_digest:)
        Contracts::Prose.check!(text:)
        issue_id = clean_issue_id(issue_id)
        new(stage: "issue_plan", slug:, content_digest: planned(text, issue_id, criteria_digest),
            fact: "issue #{issue_id}, #{text.bytesize} bytes", issue_id:, criteria_digest:)
      end

      def self.planned(text, issue_id, criteria_digest)
        Canonical.digest("plan" => Canonical.digest(text), "issue" => issue_id, "criteria" => criteria_digest)
      end
      private_class_method :planned

      def self.implementation(slug:, issue_id:, digest:)
        issue_id = clean_issue_id(issue_id)
        new(stage: "implementation", slug:, content_digest: digest, fact: "issue #{issue_id}", issue_id:)
      end

      # Interned and stripped BEFORE the contract, so `presence:` judges the
      # bytes that actually land in `fact` -- {Records::IssueTransition}'s
      # ordering, for its reason.
      def self.clean_issue_id(issue_id)
        cleaned = -issue_id.to_s.strip
        Contracts::IssueId.check!(issue_id: cleaned)
        cleaned
      end
      private_class_method :clean_issue_id

      def initialize(stage:, slug:, content_digest:, fact:, issue_id: nil, criteria_digest: nil)
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
              issue_id: issue_id && -issue_id.to_s, criteria_digest: criteria_digest && -criteria_digest.to_s)
      end

      # THE GATE IDENTITY, which {Approval::Gate#call}/`#ensure_approved!` key
      # their registry on. See the class header for why it composes stage + slug
      # + artifact rather than the artifact's content address alone.
      def digest
        Canonical.digest("stage" => stage, "epic" => slug, "artifact" => content_digest)
      end

      # The one rendering {Approval::Gate#call} asks through the artifact duck:
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
        -"Approve the #{stage} stage for #{slug.inspect}? (#{fact}) Reply approve or deny."
      end
    end
  end
end
