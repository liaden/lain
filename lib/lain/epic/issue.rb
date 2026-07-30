# frozen_string_literal: true

module Lain
  module Epic
    # The statuses an issue may CARRY. `ready` is deliberately not a member: it
    # is a predicate the graph derives (pending with every blocker done), and a
    # closed set holding a value no author may write is a special case waiting
    # to be forgotten. Refusing it by name, with the reason, is what keeps the
    # set closed and the derivation discoverable.
    STORED_STATUSES = %w[pending in_flight done abandoned].freeze
    DERIVED_STATUSES = %w[ready].freeze
    # The one member of that set that means FINISHED, named because three
    # separate readers already turn on it as a bare literal -- {Graph#ready}
    # (only a done blocker is satisfied), {Progress#summary}'s tally, and
    # {Document::STATUS_MARKS}' glyph -- and a fourth arrived with
    # `lain epic status`, whose whole remaining-work rule is "not done is
    # remaining". `abandoned` is deliberately NOT this: it is work somebody
    # stopped, it still blocks, and only an edge edit gets past it. A status the
    # tier's semantics hinge on deserves a name beside the set it belongs to.
    DONE = "done"

    # The characters an id reserves for the epic-markdown grammar (see
    # Document), where an issue is headed `### [<mark>] `<id>` <title>`. This is
    # the SAME grammar Plan uses for its own ids, and the two constants are
    # pinned equal by a spec: the shared markdown-identifier object both should
    # depend on is not extracted yet, so the pin is what makes drift loud.
    ID_RESERVED = /[`\r\n]/
    # Which reserved character was found, so the message names the grammar that
    # actually forbids it -- a line break is not a backtick-delimiter problem.
    # `fetch`ed on purpose: growing ID_RESERVED without saying why here fails
    # loudly instead of mislabelling the new character.
    ID_GRAMMARS = { "`" => "the `id` backtick delimiters", "\r" => "the one-line issue heading",
                    "\n" => "the one-line issue heading" }.freeze
    # Message-and-predicate pairs, in the order a reader wants to hear them: the
    # emptiest diagnosis first, so "  " is reported as whitespace rather than as
    # a trimming problem. An id is the graph's join key and T9's filename, so an
    # empty one is a duplicate-key collision and an unnamed file, not a cosmetic
    # defect.
    ID_RULES = [
      ["cannot be empty", ->(id) { id == "" }],
      ["cannot be only whitespace", ->(id) { id.strip == "" }],
      ["cannot have leading or trailing whitespace (the markdown grammar trims it)",
       ->(id) { id != id.strip }]
    ].freeze
    # A title is free text at the tail of that one heading line, so it may hold
    # no line break, no leading or trailing whitespace (the parser trims), and
    # may not END in a ` {...}` group. These rules coincide with Plan's today
    # rather than being required to; a spec pins the agreement behaviorally, so
    # a deliberate divergence stays possible and an accidental one does not.
    TITLE_BRACE_SUFFIX = /\s\{[^}]*\}\z/
    TITLE_RULES = [
      ["cannot be empty", ->(title) { title == "" }],
      ["is one line and cannot contain a line break", ->(title) { title.match?(/[\r\n]/) }],
      ["cannot have leading or trailing whitespace (the markdown grammar trims it)",
       ->(title) { title != title.strip }],
      ["cannot end in a ` {...}` group (it collides with the criteria-digest grammar)",
       ->(title) { title.match?(TITLE_BRACE_SUFFIX) }]
    ].freeze
    # Gherkin::Parse only sees scenarios inside a fence, so fence-less criteria
    # parse to zero scenarios and hash to one address that EVERY malformed issue
    # would share. That is the likeliest author mistake producing the least
    # visible failure, so it is refused at construction.
    NO_SCENARIOS = "issue criteria declare no scenarios -- they must sit inside a ```gherkin fence, and " \
                   "the delimiters are part of the stored source so the markdown round-trip re-emits " \
                   "them verbatim"

    class MalformedIssue < Error; end

    # One issue in an epic. `status` is one of STORED_STATUSES; `blocks` and
    # `related` are edge SETS naming other issue ids; `discovered_from` names
    # the issue a split, merge, or mid-flight discovery grew this one out of,
    # and `nil` is its only spelling of absent.
    #
    # `criteria` holds the Gherkin acceptance criteria as SOURCE TEXT, fence
    # delimiters included, not as a digest: hashing is one-way, so a stored
    # digest could never re-emit the fence the author wrote. Carrying the source
    # is what makes the markdown round-trip verbatim, and {#criteria_digest}
    # derives the content address from it on demand.
    #
    # Construction is total in both directions: everything that constructs can
    # be content-addressed (Canonical normalizes each field, so bytes it cannot
    # encode are refused here rather than raising later out of #digest), and
    # everything refused is refused as a MalformedIssue -- a Lain::Error, so
    # exe/lain renders it instead of crashing.
    #
    # Interned Strings, frozen edge arrays, and nil-or-frozen optionals, so the
    # whole value is Ractor-shareable.
    Issue = Data.define(:id, :title, :description, :status, :criteria, :blocks, :related, :discovered_from) do
      def initialize(id:, title:, description: "", status: "pending", criteria: nil,
                     blocks: [], related: [], discovered_from: nil)
        super(id: clean_id(id, "issue id"), title: clean_title(title),
              description: text(description, "issue description"), status: stored_status(status),
              criteria: criteria && clean_criteria(criteria), blocks: clean_edges(blocks, "blocks"),
              related: clean_edges(related, "related"),
              discovered_from: discovered_from && clean_id(discovered_from, "discovered_from"))
      end

      # A new issue at `status`, everything else preserved. Data#with re-enters
      # this constructor, so the new value is revalidated rather than trusted.
      def with_status(status) = with(status:)

      # The content address of the acceptance criteria, derived rather than
      # stored. No memoization: the value is frozen and the parse is cheap, so a
      # cached ivar would buy nothing and cost the deep freeze. Construction
      # already proved this source parses to at least one scenario.
      def criteria_digest = criteria && Gherkin::Criteria.parse(criteria).digest

      def digest = Canonical.digest(canonical)

      # Plain-hash wire form for {Canonical}; String keys, sorted downstream.
      # Every key is always present (nil when unset) so the shape is stable
      # across issues. `criteria` contributes its source text, so an edited
      # clause is a different issue -- prose and criteria are meaning here,
      # unlike edge order.
      def canonical
        { "id" => id, "title" => title, "description" => description, "status" => status,
          "criteria" => criteria, "blocks" => blocks, "related" => related,
          "discovered_from" => discovered_from }
      end

      # Whether this issue reaches BOTH downstream artifacts: the document
      # grammar ({Document::Writer} emits `epic.md`) and the filesystem
      # grammar ({Home} emits `issues/<id>.md`), so a graph operation that
      # mints an un-renderable issue is detectable here rather than at a
      # render or a write raising at a distance.
      def emittable? = emittable_failures.empty?

      # Every reason this issue is not emittable, each naming the grammar it
      # breaks -- {Home}'s filesystem-name check inlined, since nothing else
      # asks for it alone. Empty exactly when {#emittable?} is true.
      def emittable_failures
        [*document_grammar_failures.map { |f, m| "#{f} #{m} -- the document grammar" },
         *[Home.filesystem_name_failure(id, "issue id")].compact.map { |m| "#{m} -- the filesystem grammar" }]
      end

      # {Document} owns DESCRIPTION_RULES/CRITERIA_RULES, so it is asked
      # rather than walked again here -- the field-keyed Hash lets
      # {Document::Writer} consult one field at a time.
      def document_grammar_failures = Document.grammar_failures(description:, criteria:)

      private

      # Every String entering the value goes through Canonical, because Canonical
      # is what will hash it: a value that constructs but cannot be
      # content-addressed is the same silent failure as criteria that parse to
      # nothing. Normalizing here rather than restating the UTF-8 rule keeps "it
      # constructs" and "it has a digest" the same statement, and it settles
      # encoding before ids are deduplicated, so one id cannot reach the graph
      # under two spellings. The interning is Canonical's own, and it is free:
      # the digest path interns these same bytes anyway.
      def text(value, field)
        raise MalformedIssue, "#{field} cannot be nil" if value.nil?

        Canonical.normalize(value.to_s)
      rescue Canonical::UnsupportedType => e
        raise MalformedIssue, "#{field} cannot be content-addressed: #{e.message}"
      end

      def clean_id(value, field)
        id = text(value, field)
        rule_break!(ID_RULES, field, id)
        reserved!(id, field)
        id
      end

      def clean_title(title)
        title = text(title, "an issue title")
        rule_break!(TITLE_RULES, "an issue title", title)
        title
      end

      # Sorted and deduplicated, the way Event normalizes its causal parents: an
      # edge set is a SET, so insertion order is not meaning and must not move
      # the digest. Built fresh, so the caller keeps ownership of the array it
      # passed while our member stays immutable. Array-ness is asserted rather
      # than ducked: Array() would read nil as no edges and "b" as one edge, and
      # quiet coercion is what this constructor exists to refuse.
      def clean_edges(ids, field)
        raise MalformedIssue, "#{field} must be an Array of issue ids (got #{ids.inspect})" unless ids.is_a?(Array)

        ids.map { |id| clean_id(id, "#{field} edge") }.uniq.sort.freeze
      end

      def clean_criteria(source)
        source = text(source, "issue criteria")
        raise MalformedIssue, "#{NO_SCENARIOS} (got #{source.inspect})" if Gherkin::Criteria.parse(source).none?

        source
      rescue Gherkin::MalformedBlock => e
        raise MalformedIssue, "issue criteria are not a parseable gherkin block: #{e.message}"
      end

      def stored_status(status)
        status = text(status, "issue status")
        if DERIVED_STATUSES.include?(status)
          raise MalformedIssue, "issue status #{status.inspect} is derived from the blocks graph, never stored " \
                                "(a stored status is one of #{STORED_STATUSES.join("/")})"
        end
        unless STORED_STATUSES.include?(status)
          raise MalformedIssue, "unknown issue status #{status.inspect} (expected #{STORED_STATUSES.join("/")})"
        end

        status
      end

      def rule_break!(rules, field, value)
        broken = rules.find { |_message, predicate| predicate.call(value) }
        raise MalformedIssue, "#{field} #{broken.first} (got #{value.inspect})" if broken
      end

      def reserved!(id, field)
        offender = id[ID_RESERVED]
        return if offender.nil?

        raise MalformedIssue, "#{field} #{id.inspect} contains #{offender.inspect}, a character reserved for " \
                              "#{ID_GRAMMARS.fetch(offender)}"
      end
    end
  end
end
