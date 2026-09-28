# frozen_string_literal: true

module Lain
  # Quality assurance over work that has already landed: a reader that runs the
  # change and REPORTS, never fixes, climbing a ladder of model tiers from the
  # free checks to the expensive ones only as far as the evidence demands.
  #
  # The closed vocabularies live here for {Review::SIDES}' reason: every guard
  # that cites one resolves it while its own class body runs. Strings, because
  # the report file is the durable artifact, so a second declaration in the
  # Symbol form would be worse than a duplicate -- Review's header argues that
  # at length. {VERDICTS} argues why this namespace spells a three-valued
  # answer its own way; if the four are ever collapsed, what to extract is the
  # shared SHAPE -- a closed set whose third member means "not settled here,
  # climb" -- and never the words. One set must pick one spelling, and
  # {Approval::Escalation::Ruling::VERDICTS} is Symbols journalled as Symbols
  # while {Oracle::SecretRead}'s `defer` is prose inside a prompt measured
  # against real ollama, whose earlier phrasing failed 4 times out of 4.
  # Renaming that one is a model-behaviour change, not a rename.
  module QA
    # A finding at one of the first two holds the work; `minor` is carried in
    # the report and holds nothing. Closed because the gate's whole rule is
    # "does any finding hold", and a fourth spelling would silently hold
    # nothing.
    SEVERITIES = %w[blocker major minor].freeze
    HOLDING = %w[blocker major].freeze

    # The ladder's rungs, cheapest first. The first spends no model at all; the
    # last is the media rung, reached only for a criterion that is visual.
    TIERS = %w[t0 t1 t2 t3].freeze

    # What one rung may say about one criterion -- and why that is not
    # {Approval::Escalation::Ruling::VERDICTS}' `abstain` under a new name.
    #
    # LIFETIME is the argument, and it is written in the tree: `escalation.rb`'s
    # `decisive` ends `ruling.abstain? ? nil : ruling` (line 269), so an
    # abstention is mapped to nil and discarded the moment the ladder moves on.
    # It has done its whole job by then. `unverified` has to OUTLIVE the ladder:
    # when the rungs are spent it becomes an unsettled criterion in the report
    # ({Report#unsettled}), which is what a human still owes. Two symbols with
    # opposite lifetimes are not one symbol.
    #
    # The question differs too. allow/deny/abstain and {Oracle::SecretRead}'s
    # approve/deny/defer answer MAY THIS HAPPEN: a decision about an action not
    # yet taken, which needs no evidence and cannot be wrong. These answer DID
    # THIS HAPPEN, an observation somebody else can re-run, which is where
    # {Finding}'s falsifiable-or-refused rule comes from. ({Review::VERDICTS} is
    # not a third three-valued set -- it holds one member, deliberately.)
    VERDICTS = %w[pass fail unverified].freeze

    # The risks a plan's cards carry, which the ladder reads to decide how much
    # corroboration a verdict needs. At any rung, never a veto: an earlier cut read
    # this as a bound on a CHEAP verdict and escalated every high-risk criterion
    # unconditionally, which spent the whole ladder and then owed a manual pass on
    # exactly the cards a gate exists for.
    RISKS = %w[low medium high].freeze

    # What it means for a QA record to say nothing, in ONE place. {Blankness} is
    # that place for the test itself, and the reason is its own docstring's:
    # ASCII `strip` and ActiveSupport's `blank?` both pass U+200B, U+200D,
    # U+2060 and U+FEFF, so a finding whose evidence is one zero-width space is
    # accepted, holds the work, and renders as `- evidence: `.
    SAID_NOTHING = "cannot be blank: a QA record nobody can check is an opinion"

    # Stringifying whatever arrives is that failure one step earlier: a Hash
    # becomes `"{}"` and an Array reaches the markdown a human reads as `["a"]`,
    # both of them opinions wearing a finding's clothes.
    NOT_WORDS = "must be a string, got %<got>s"

    # Every member of a QA record that has to be words, judged together so one
    # raise names all of them.
    #
    # @param values [Hash{Symbol=>Object}] wire members, by name
    # @param refusal [Class] what a fault raises
    # @return [Hash{Symbol=>String}] scrubbed, stripped, interned
    # @raise [MalformedFinding, MalformedReport, MalformedAnswer] whichever the
    #   caller handed as `refusal`, naming every member that is not words
    def self.words!(values, refusal:)
      faults = values.filter_map { |field, value| fault(field, value) }
      raise refusal, faults.join(", ") unless faults.empty?

      values.transform_values { |value| -readable(value).strip }
    end

    # @return [String] for a caller holding one member rather than a record
    def self.word!(value, field:, refusal:) = words!({ field.to_sym => value }, refusal:).fetch(field.to_sym)

    # Undecodable bytes dropped rather than raised on, {Blankness}' own rule:
    # the cheapest rung reads small quantised local models, where broken bytes
    # are ordinary, and a reader that raises on one spends the whole pass on
    # that rung's weakness. Anything that is not a String read nothing.
    #
    # @return [String] NOT interned -- a whole model reply goes through here
    def self.readable(value) = value.is_a?(String) ? value.scrub("") : ""

    # What a rung actually said, for a member an {Answer} may legitimately leave
    # empty. A non-String said nothing READABLE, so it says nothing -- never its
    # inspect form, which would reach a report as if a model had written it.
    def self.said(value) = -readable(value)

    def self.fault(field, value)
      return "#{field} #{format(NOT_WORDS, got: value.class)}" unless value.is_a?(String)

      "#{field} #{SAID_NOTHING}" if Blankness.blank?(value)
    end
    private_class_method :fault

    # A finding that could not be filed, named for what it is rather than for a
    # field: the refusals are all one rule, that a finding nobody can check is
    # an opinion.
    class MalformedFinding < Error; end

    # An answer that reported nothing where a report was owed. Distinct from
    # {MalformedFinding} because the responses differ: a bad finding is dropped
    # and the pass goes on, while no report at all is the silent pass
    # {Report.parse} exists to refuse.
    class MalformedReport < Error; end

    # An {Answer} built by a caller rather than read off a reply. Reading one is
    # never an error -- that is the ladder's whole premise -- so this is raised
    # only where a programmer hands {Answer.unverified} a reason that says
    # nothing, which is the blank answer this namespace exists to refuse.
    class MalformedAnswer < Error; end
  end
end
