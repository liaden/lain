# frozen_string_literal: true

module Lain
  module Forge
    # The closed set of external effects this tier will ever ask for, and the
    # only strings {Intent} accepts. Closed on purpose: an action names an argv
    # verb an executor knows how to run, so a free-form action would be a
    # model-authored command by another name -- the tier-3 shape the forge tier
    # exists to avoid.
    #
    # Promotion IS the push. There is no separate `push` action, because
    # pushing a ref to `epic/<slug>/<issue>` is the whole of what promoting
    # means here, and a second spelling would fold as different work.
    PROMOTE = "promote"
    PR_CREATE = "pr_create"
    PR_MERGE = "pr_merge"
    ACTIONS = [PROMOTE, PR_CREATE, PR_MERGE].freeze

    # Construction contracts for the tier's two journal records, in the house
    # validate-then-freeze convention: a throwaway {Lain::Guard} carrier checked
    # BEFORE the auto-frozen Data value exists, so neither record ever touches
    # ActiveModel and both stay `Ractor.shareable?`.
    #
    # These same guards are what {Reconcile} re-checks each journaled record
    # against on the way back IN, so the shape a write refuses and the shape a
    # read refuses are one declaration rather than two that can drift.
    module Guards
      # An action must be one this tier can run, and an intent must say which
      # epic and issue it is doing the work for -- an unattributed intent is one
      # no reconcile can report to a human as anybody's problem.
      class Intent < Guard
        attribute :action
        attribute :epic_slug
        attribute :issue_id
        validates :action, inclusion: { in: ACTIONS,
                                        message: "must be one of #{ACTIONS.join("/")}, got %<value>s" }
        validates :epic_slug, presence: { message: "must name the epic this intent belongs to, got nil" }
        validates :issue_id, presence: { message: "must name the issue this intent is for, got nil" }
      end

      # `ok` and `observed` are checked as booleans rather than for truthiness
      # because both are FOLDED on, and a record missing either is evidence the
      # line was damaged -- {Approval::SignoffQueue::Guards::Decision}'s
      # truncation-canary reasoning, for the same reason: a missing field reads
      # as `false`, and `false` here is a verdict nobody recorded.
      class Outcome < Guard
        attribute :intent_id
        attribute :ok
        attribute :observed
        validates :intent_id, presence: { message: "must name the intent it answers, got nil" }
        validates :ok, inclusion: { in: [true, false], message: "must be true or false, got %<value>s" }
        validates :observed, inclusion: { in: [true, false], message: "must be true or false, got %<value>s" }
        validate :observed_entails_ok

        def observed_entails_ok
          return unless observed == true && ok == false

          errors.add(:observed, "means the effect was found already in place, which is a success")
        end
      end
    end

    # One external effect, journaled BEFORE it is attempted.
    #
    # The ordering is the whole design, and it is {Middleware::JournalRequests}'
    # rule applied to a bigger stake: that middleware records a request before
    # the round trip dispatches, so a call that dies still leaves its attempt on
    # record. A forge action pushes a ref or merges a pull request -- effects no
    # local file can be re-read to discover -- so an intent with no outcome is
    # precisely the shape of a crash, and {Reconcile} is what reads it back.
    #
    # (The opposite ordering is also correct where it is used: {Epic::Home::Journaled}
    # journals AFTER the write, because `doc_written` is an ack of a completed
    # local write rather than a bet on an external one.)
    #
    # == The id is an address, not a sequence number
    #
    # `intent_id` is `Canonical.digest` over the action and its params, and
    # nothing else -- not the epic, not the issue, not a clock. Two attempts at
    # the same action therefore share ONE id, which is what makes re-promoting
    # the same sha legible as a repeat rather than as new work. It is also why
    # {Reconcile} pairs positionally instead of by id alone: with a repeated
    # action the id no longer distinguishes the attempts, and only journal order
    # can.
    Intent = Data.define(:intent_id, :action, :epic_slug, :issue_id, :params) do
      include Telemetry::Journalable

      # The address of an action-and-params pair. Public because a caller that
      # wants to look an intent up without building one (a replaying executor
      # keyed on intent_id) needs the same function that stamped it.
      #
      # `Canonical.digest` normalizes on the way in, so a Symbol-keyed params
      # Hash addresses identically to its String-keyed twin -- they are the same
      # message on the wire.
      #
      # == THE OBLIGATION THIS PLACES ON EVERY ACTION'S PARAMS
      #
      # The epic and the issue are excluded, so `params` is the WHOLE address
      # and every action's params must identify their effect uniquely
      # REPO-WIDE. Two intents differing only in `epic_slug` or `issue_id`
      # share an id, and one issue's outcome will then settle the other's
      # intent.
      #
      # Today's actions honour that by construction and must keep doing so: a
      # promote carries `refs/heads/epic/<slug>/<issue>`, which already contains
      # both, and a pr_merge carries a repo-unique number. An action whose
      # params could repeat across two issues does not belong in {ACTIONS}
      # until they cannot -- widening the digest instead would break the
      # positional pairing this tier is built on, since a repeat of ONE action
      # must go on sharing its id.
      #
      # @return [String] "blake3:..."
      def self.id_for(action:, params:) = Canonical.digest("action" => action.to_s, "params" => params.to_h)

      # Rebuild from a journal record ({Journal.parse}'s shape).
      #
      # The STORED id is kept rather than re-derived. An outcome joined on the
      # id that was WRITTEN, so re-deriving would silently unpair every record
      # written before any future change to the address -- turning settled work
      # into an unsettled intent and a live outcome into an orphan.
      def self.from_record(record)
        new(intent_id: record["intent_id"], action: record["action"], epic_slug: record["epic_slug"],
            issue_id: record["issue_id"], params: record["params"])
      end

      # @param action [String] one of {ACTIONS} -- the closed set of argv verbs
      #   an executor knows how to run
      # @param epic_slug [String] the epic this intent's effect belongs to --
      #   excluded from the address, so two epics sharing an action and params
      #   share an id (see "THE OBLIGATION" above)
      # @param issue_id [String] the issue this intent's effect is for --
      #   excluded from the address for the same reason as `epic_slug`
      # @param params [Hash] the action's own arguments; together with `action`
      #   this is the WHOLE address, so they must identify the effect uniquely
      #   REPO-WIDE
      # @param intent_id [String, nil] nil derives the address from `action` and
      #   `params`, which is what every fresh intent wants; {.from_record}
      #   passes the recorded one
      def initialize(action:, epic_slug:, issue_id:, params: {}, intent_id: nil)
        # Interned BEFORE the guard, so `presence:` judges the bytes that get
        # journaled: an id object whose #to_s is blank passes a presence check
        # on the raw object and then names work no fold can match back.
        action = -action.to_s
        epic_slug = -epic_slug.to_s
        issue_id = -issue_id.to_s.strip
        # Canonical form buys three things at once: the value journals
        # deterministically, it addresses the same whatever key flavour a caller
        # passed, and it is deeply frozen. `nil.to_h` is the empty params, so
        # "no params" needs no nil check.
        params = Canonical.normalize(params.to_h)
        Guards::Intent.check!(action:, epic_slug:, issue_id:)
        intent_id = intent_id.nil? ? self.class.id_for(action:, params:) : -intent_id.to_s

        super
      end
    end

    # Reopened rather than declared inside the `Data.define ... do` block: a
    # constant there is lexically scoped to the enclosing MODULE, not the Data
    # class (the pinned Ruby trap {Request::SYSTEM_PREFIX} records).
    class Intent
      # The discriminator, pinned as a constant so readers name it once and a
      # rename breaks loudly at the constant instead of quietly re-labelling
      # records nobody can join anymore ({Epic::IssueTransition::JOURNAL_TYPE}'s
      # reasoning).
      JOURNAL_TYPE = "forge_intent"

      # {Telemetry::Journalable} would derive "intent" from the class basename.
      # These records ride the SAME session journals as every other tier's, and
      # a bare "intent"/"outcome" is a name another tier could plausibly want;
      # the `forge_` prefix keeps the discriminator unambiguous in a shared
      # NDJSON stream.
      def journal_type = JOURNAL_TYPE
    end

    # What happened when an {Intent} was attempted, journaled after the fact.
    #
    # `observed` is the tier's honesty flag: true means the effect was found
    # ALREADY in place and confirmed rather than performed. Re-promoting a sha
    # that is already pushed is an `ok` outcome with `observed` true and no
    # force flag anywhere -- the `Handback#preserve` / `Salvage#already_committed?`
    # doctrine that idempotency is asked of the world, never remembered locally.
    #
    # `detail` is the structured payload a reader needs and the digest does not
    # carry: a PR number, a refusal reason, the sha a diverged remote actually
    # holds. It defaults to `{}` rather than nil, so nothing downstream guards
    # on its absence.
    Outcome = Data.define(:intent_id, :ok, :observed, :detail) do
      include Telemetry::Journalable

      # A record missing `ok` or `observed` is refused rather than defaulted:
      # both are written on every outcome this tier produces, so the only line
      # that can lack one is a damaged line, and defaulting it would invent a
      # verdict nobody recorded. See {Guards::Outcome}.
      def self.from_record(record)
        new(intent_id: record["intent_id"], ok: record["ok"], observed: record["observed"],
            detail: record["detail"])
      end

      # rubocop:disable Naming/MethodParameterName -- `ok` is the record's
      # journaled field name; a longer parameter would have to be renamed back
      # on the way into `super`, so the wire name wins.
      def initialize(intent_id:, ok:, observed: false, detail: {})
        intent_id = -intent_id.to_s
        detail = Canonical.normalize(detail.to_h)
        Guards::Outcome.check!(intent_id:, ok:, observed:)

        super
      end
      # rubocop:enable Naming/MethodParameterName

      def ok? = ok

      def observed? = observed
    end

    # Reopened for its constant, for the reason {Intent} is.
    class Outcome
      # See {Intent::JOURNAL_TYPE}.
      JOURNAL_TYPE = "forge_outcome"

      def journal_type = JOURNAL_TYPE
    end
  end
end
