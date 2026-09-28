# frozen_string_literal: true

require "json"

module Lain
  module QA
    Answer = Data.define(:verdict, :confidence, :executed, :summary, :evidence, :reproduction) do
      # @param text [String] one rung's whole reply
      # @return [Answer] never nil, and never an exception -- not for a missing
      #   fence, not for bad JSON, not for undecodable bytes
      def self.parse(text)
        blocks = QA.readable(text).scan(Answer::PATTERN)
        return unverified(because: Answer::NO_BLOCK) if blocks.empty?

        body = blocks.last.first
        return unverified(because: Answer::EMPTY_BLOCK) if Blankness.blank?(body)

        wire = JSON.parse(body)
        return unverified(because: Answer::NOT_AN_OBJECT) unless wire.is_a?(Hash)

        from_wire(wire)
      rescue JSON::ParserError => e
        unverified(because: "#{Answer::DID_NOT_READ}: #{e.message}")
      end

      # The door for a reply that never reached {parse} at all -- a provider
      # that typed the silence itself, a rung that was never asked, a budget
      # spent. It takes the reason rather than the failure, so nothing here has
      # to know what shape the other side's refusal was, and it refuses a reason
      # that says nothing: an unverified answer nobody can read is the blank
      # answer this namespace calls a finding.
      #
      # @param because [String] why the criterion could not be settled
      # @return [Answer]
      # @raise [MalformedAnswer] for a reason that is blank or not words
      def self.unverified(because:)
        reason = QA.word!(because, field: "because", refusal: MalformedAnswer)
        new(verdict: "unverified", confidence: 0.0, executed: false, summary: reason, evidence: reason,
            reproduction: "")
      end

      # A wire object that names no verdict at all answered nothing, and saying
      # so is worth more to the next rung than an empty answer carrying the
      # model's evidence for a judgement it never made.
      def self.from_wire(wire)
        return unverified(because: Answer::NO_VERDICT) if QA.readable(wire["verdict"]).strip.empty?

        new(verdict: wire["verdict"], confidence: wire["confidence"], executed: wire["executed"] == true,
            summary: wire["summary"], evidence: wire["evidence"], reproduction: wire["reproduction"])
      end
      private_class_method :from_wire

      def initialize(verdict:, confidence:, executed:, summary:, evidence:, reproduction:)
        super(verdict: verdict_of(verdict), confidence: confidence_of(confidence), executed: executed == true,
              summary: QA.said(summary), evidence: QA.said(evidence), reproduction: QA.said(reproduction))
      end

      # Whether this rung established anything about the criterion at all.
      def settled? = verdict != "unverified"

      # This answer as findings against the criterion it was asked about: one
      # when it is a defect somebody else can check, none when it is not.
      #
      # A pass is not a finding, and neither is an unverified answer -- that one
      # is an unsettled criterion, which the report carries in its own right
      # ({Report#unsettled}) rather than as a defect nobody observed. A fail
      # with no evidence or no way to reproduce it is exactly the weak-model
      # false positive the ladder exists to keep away from an implementer, so it
      # yields nothing either.
      #
      # @return [Array<Finding>]
      def findings(criterion:, tier:, severity:)
        return [] unless verdict == "fail"

        [Finding.new(severity:, criterion:, tier:, summary: summary.empty? ? "fails: #{criterion}" : summary,
                     evidence:, reproduction:)]
      rescue MalformedFinding
        []
      end

      private

      # A spelling outside the closed set is not a fourth verdict: it is a rung
      # that did not answer the question, which is what `unverified` means.
      def verdict_of(value)
        word = QA.readable(value).strip
        VERDICTS.include?(word) ? -word : "unverified"
      end

      # Clamped rather than refused, because a self-reported rank is evidence
      # and not control flow ({Oracle::SecretRead} argues the same about its
      # own): a model claiming 5 has said "as sure as I get", and a model
      # answering in words has said nothing a threshold can read.
      def confidence_of(value) = (Float(value, exception: false) || 0.0).clamp(0.0, 1.0)
    end

    # One rung's answer about one criterion, read out of its reply.
    #
    # The child is asked to END its reply with ONE fenced block holding a JSON
    # object, so the LAST fence is the answer: a model that restates the
    # requested shape before filling it in is ordinary, and reading the first
    # block would report the template. A reply truncated mid-fence has no last
    # block to find and falls back to an earlier one, which is the template
    # where a prompt shows one: nothing here detects an unterminated trailing
    # fence, and a token cap is the commonest way a small model stops.
    #
    # A reply with no such block, one that does not parse, or one whose bytes
    # are broken is not an error here -- it reads as `unverified` with the
    # reason kept as its evidence. A small model that
    # cannot hold a format is a reason to climb the ladder, and raising over it
    # would spend the whole pass on the cheapest rung's weakness. Read the
    # namespace's {VERDICTS} for why that is not an abstention.
    class Answer
      FENCE = "qa-answer"
      PATTERN = /^```#{FENCE}[ \t]*\r?\n(.*?)^```[ \t]*$/m

      NO_BLOCK = "the reply held no ```#{FENCE} block".freeze
      EMPTY_BLOCK = "the reply's ```#{FENCE} block is empty".freeze
      NOT_AN_OBJECT = "the reply's block is not an object"
      DID_NOT_READ = "the reply's block did not read"
      NO_VERDICT = "the reply's block names no verdict"
    end
  end
end
