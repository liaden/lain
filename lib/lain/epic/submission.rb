# frozen_string_literal: true

module Lain
  module Epic
    # Reopened from {Records}' own `module Guards` (see that file's header): one
    # validate-then-freeze carrier per record shape, checked BEFORE the
    # auto-frozen Data value exists, so {Submission} never touches ActiveModel
    # and stays `Ractor.shareable?`.
    module Guards
      # `stage` IS restated here, unlike {Guards::StageTransition}'s deliberate
      # omission: a Submission is built directly by its own class methods below
      # rather than passed a caller-supplied stage, so there is no {Stage} value
      # anywhere on this path to own the check instead.
      class Submission < Guard
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

        # `presence:` alone lets a Hash/Array/Integer digest through -- every
        # one of those answers `#dup`/`#freeze` too, but only SHALLOWLY: a
        # Hash whose values are ordinary Strings still holds MUTABLE Strings
        # inside it, which flips `Ractor.shareable?(submission)` to false and
        # lets a caller mutate the "content address" after construction. A
        # String is the one digest shape `#dup.freeze` below actually
        # deep-freezes, and it is what all three of this class's own
        # constructors already produce -- `implementation` is the one path
        # that takes a digest from OUTSIDE, so it is the one path that needs
        # this checked rather than assumed. Skipped when nil, which
        # `presence:` above already reports -- reporting both would repeat
        # the same complaint in two voices.
        def content_digest_is_a_string
          return if content_digest.nil?

          return if content_digest.is_a?(String)

          errors.add(:content_digest, "must be a String content address, got #{content_digest.class}")
        end

        # `#digest` canonicalizes `slug` (see {Submission}'s header on why the
        # gate identity composes stage/slug/artifact together), and
        # `Canonical.normalize` raises on a String that cannot be re-encoded to
        # UTF-8. Unchecked, that turns `#digest` -- documented and relied on as
        # TOTAL over every constructible Submission, the same way
        # {Epic::Issue#digest}/{Epic::Graph#digest} are -- into a method that
        # raises deep inside `Approval::Gate#call` (its first line is
        # `artifact.digest`), three frames before the asker is ever reached.
        # That is the exact defect class round 1 fixed for `text`/`graph`
        # (an unnamed exception standing in for a refusal), reintroduced here
        # at `slug`. A slug plausibly arrives via a Linux directory name
        # (`Epic::Home`), which is arbitrary bytes, not guaranteed UTF-8 --
        # so this is checked at construction, not assumed.
        def slug_is_canonicalizable
          return if slug.nil? # presence: above already reports this

          Canonical.normalize(slug)
        rescue Canonical::UnsupportedType => e
          errors.add(:slug, "must be valid UTF-8 -- it is hashed into #digest -- (#{e.message})")
        end
      end

      # The raw prose handed to `.research`/`.issue_plan`, checked BEFORE
      # `Canonical.digest`/`#bytesize` ever touch it. Without this: nil text
      # raises `NoMethodError: undefined method 'bytesize' for nil` three
      # frames down, naming neither the constructor nor the field; and a
      # Hash/Integer/Symbol sails through `Canonical.digest` (which
      # canonicalizes all three happily) and acquires a real gate identity --
      # the ONLY thing stopping that today is the incidental `#bytesize` call
      # building `fact`, which a later refactor could drop without anyone
      # noticing non-prose had started being gated as if it were prose.
      #
      # Deliberately does NOT reject an empty String: "no research was
      # written" is a fact this class reports honestly (`fact` says "0
      # bytes"), not a malformed artifact -- whether zero bytes of prose is
      # worth asking a human to approve is a Policy/UX question, not a shape
      # this constructor is positioned to judge.
      class Prose < Guard
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
      class GraphArtifact < Guard
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
      class IssueId < Guard
        attribute :issue_id
        validates :issue_id, presence: { message: "must name the issue this submission is for, got nil" }
      end
    end

    # One artifact bound to one stage of an epic's pipeline: the gate's whole
    # duck ({#digest}, {#gate_question}), spelled out for the four shapes the
    # pipeline actually produces. {Approval::Gate} never learns which
    # constructor built the value it holds -- see that class's header for the
    # three call sites this satisfies.
    #
    # == `#digest` is `(stage, slug, artifact)`, not the artifact alone
    #
    # {Approval::Gate}'s registry is keyed on `#digest` alone (it knows nothing
    # of stages or epics -- see that class's own header). If `#digest` answered
    # only the artifact's content address, two different (stage, epic) pairs
    # that happen to wrap the SAME bytes would be the SAME key: approving epic
    # `alpha`'s 3-issue plan would silently open epic `beta`'s identical plan,
    # and approving a research doc would silently open an issue_plan
    # resubmitting the same words verbatim. Nobody signed off on either of
    # those -- `#digest` is the join key the registry trusts, so it has to be
    # the thing that was actually asked about: "this stage, this epic, this
    # content" together, never content alone. So `#digest` composes all three:
    #
    #   Canonical.digest("stage" => stage, "epic" => slug, "artifact" => content_digest)
    #
    # This is a COMPUTED method, not a stored field, for the same reason
    # {Epic::Issue#digest}/{Epic::Graph#digest} are: the value is frozen and
    # the hash is cheap, so memoizing would buy nothing and cost the deep
    # freeze. It is documented as TOTAL over every constructible Submission --
    # {Guards::Submission#slug_is_canonicalizable} is what keeps that true (see
    # its comment): a slug that cannot round-trip through `Canonical.normalize`
    # is refused at construction rather than surfacing as an unnamed exception
    # out of `Approval::Gate#call`.
    #
    # An alternative was considered and rejected: let the stage live INSIDE the
    # artifact's own text, so the content digest moves naturally on its own.
    # That works for `research`/`issue_plan` (prose digests its bytes
    # directly) but not for `epic_plan` -- `Graph = Data.define(:issues)`
    # carries no slug, `Graph#canonical` is `{"issues" => ...}`,
    # `Document.to_markdown` emits no header, and `parse_markdown` drops any
    # preamble -- and not for `implementation`, which takes an external sha
    # with no text at all to embed anything IN. Making it work would mean
    # adding a slug member to a landed, mutation-tested value and
    # invalidating every graph digest ever computed. Composing the three
    # components in `#digest` gets the same semantics -- the stage inherently
    # changes the digest, uniformly across all four constructors -- without
    # touching {Graph}, {Document}, or {Approval::Gate} at all.
    #
    # `#content_digest` stays public: it is still a meaningful value in its
    # own right (for `epic_plan` it equals {Epic::Graph#digest} exactly), it
    # is just no longer the value the Gate keys its registry on. Named
    # `content_digest` rather than `artifact_digest`: the latter is already
    # the Approval subsystem's own name for the COMPOSED gate identity
    # (`GateDecision#artifact_digest`, `SignoffQueue::Item#artifact_digest`,
    # `Gate::Policy`/`Gate::Adjudicator` both `park(artifact_digest:
    # artifact.digest, ...)`) -- reusing that word here for the raw content
    # address would read as the SAME value four call sites away when it is
    # the one value that is explicitly NOT the gate key.
    #
    # Prose artifacts (`research`, `issue_plan`) digest their BYTES through
    # {Canonical.digest}: two renderings of the same words are two different
    # approvals, because a human signed off on THOSE words. `epic_plan` instead
    # reuses {Epic::Graph#digest} -- the graph's own address, computed over its
    # normalized issue set rather than the markdown that produced it -- so
    # re-rendering an unchanged graph (reordered issues, different whitespace)
    # does not cost a fresh sign-off on work nobody actually changed.
    # `implementation` takes its digest as GIVEN: by the time an implementation
    # is submitted, something else (the changeset) already computed the address
    # that names it, and re-hashing here would be a second, possibly-diverging
    # opinion on the same content.
    #
    # Disk-free on purpose: a Submission holds only what it is handed, never a
    # path, so it stays a pure value the gate can journal and replay without
    # ever touching {Epic::Home}.
    Submission = Data.define(:stage, :slug, :content_digest, :fact) do
      def self.research(text:, slug:)
        Guards::Prose.check!(text:)
        new(stage: "research", slug:, content_digest: Canonical.digest(text), fact: "#{text.bytesize} bytes")
      end

      def self.epic_plan(graph:, slug:)
        Guards::GraphArtifact.check!(graph:)
        new(stage: "epic_plan", slug:, content_digest: graph.digest, fact: "#{graph.issues.size} issues")
      end

      def self.issue_plan(text:, slug:, issue_id:)
        Guards::Prose.check!(text:)
        issue_id = clean_issue_id(issue_id)
        new(stage: "issue_plan", slug:, content_digest: Canonical.digest(text),
            fact: "issue #{issue_id}, #{text.bytesize} bytes")
      end

      def self.implementation(slug:, issue_id:, digest:)
        issue_id = clean_issue_id(issue_id)
        new(stage: "implementation", slug:, content_digest: digest, fact: "issue #{issue_id}")
      end

      # Interned/stripped BEFORE the guard, so `presence:` judges the bytes
      # that actually land in `fact` -- the same ordering {Records::IssueTransition}
      # uses for its own `issue_id`. Shared by the two constructors that take
      # one; `research`/`epic_plan` have no issue to name.
      def self.clean_issue_id(issue_id)
        cleaned = -issue_id.to_s.strip
        Guards::IssueId.check!(issue_id: cleaned)
        cleaned
      end
      private_class_method :clean_issue_id

      def initialize(stage:, slug:, content_digest:, fact:)
        # Interned/dup'd-and-frozen BEFORE the guard, so `presence:` judges the
        # bytes that actually get asked and journaled -- the same ordering
        # {Approval::GateDecision} and {Records::IssueTransition} both use.
        stage = -stage.to_s
        slug = -slug.to_s
        fact = -fact.to_s
        Guards::Submission.check!(stage:, slug:, content_digest:, fact:)

        super(stage:, slug:, content_digest: content_digest.dup.freeze, fact:)
      end

      # THE GATE IDENTITY -- see the class header for why this composes
      # stage + slug + artifact rather than answering the artifact's content
      # address alone. This is what {Approval::Gate#call}/`#ensure_approved!`
      # key their registry on. TOTAL over every constructible Submission --
      # see {Guards::Submission#slug_is_canonicalizable}.
      def digest
        Canonical.digest("stage" => stage, "epic" => slug, "artifact" => content_digest)
      end

      # The one rendering {Approval::Gate#call} asks through the artifact duck
      # (`asker.ask(artifact.gate_question)`): the stage, the slug, and the one
      # concrete fact that distinguishes this submission from another at the
      # same stage.
      def gate_question
        # `slug.inspect` rather than plain interpolation: {Gate::Policy} and
        # {Gate::Adjudicator} journal this question straight into NDJSON, so a
        # slug carrying a literal newline must not break the line it lands on
        # -- `#inspect`'s escaping is what keeps the rendered question
        # JSON-safe. (An invalid-UTF-8 slug never reaches here at all --
        # {Guards::Submission#slug_is_canonicalizable} refuses it at
        # construction.)
        #
        # `-"..."` rather than a plain literal: a shareable Submission must
        # not be the one thing on it that hands back a mutable String, or a
        # caller mutating the return value would read as this record's own
        # state changing.
        -"Approve the #{stage} stage for #{slug.inspect}? (#{fact}) Reply approve or deny."
      end
    end
  end
end
