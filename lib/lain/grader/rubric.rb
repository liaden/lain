# frozen_string_literal: true

require "json"

require_relative "../grader"
require_relative "../error"
require_relative "../request"

module Lain
  module Grader
    # An LLM judge. Where {Fixture} is a deterministic bundle of hard assertions,
    # a Rubric asks a model to score a subject against prose criteria -- the tool
    # for "is this answer actually good?", which no assertion can decide.
    #
    # Two properties make it trustworthy rather than a black box:
    #
    # * A SEPARATE context window. The judge is a fresh {Request} built from the
    #   rubric and the subject alone -- never the run-under-study's own Timeline.
    #   A judge that could see the trajectory it is grading would be scoring the
    #   reasoning, not the result, and its verdict would leak the very thing it
    #   is meant to assess independently.
    # * `#why` is mandatory. An unexplainable judgment is unusable, so the judge
    #   is required to return a reason and a blank one is a LOUD failure (the
    #   {Grade} constructor raises), not a silent zero.
    #
    # One round trip, no loop: judging is a single completion, so this drives a
    # {Provider} directly rather than an Agent. That keeps it usable against the
    # real API under `:live` and against {Provider::Mock} offline with no change.
    class Rubric
      # The judge answered in a shape we cannot read a verdict out of. Raising
      # rather than inventing a score keeps a malformed judgment from silently
      # becoming data.
      class Unparseable < Lain::Error; end

      # The judge's marching orders: score against the criteria, and reply as a
      # single JSON object so the verdict is machine-readable. Kept terse -- the
      # criteria carry the substance.
      INSTRUCTION = <<~PROMPT
        You are a strict grader. Score how well the answer below satisfies the criteria.
        Reply with ONE JSON object and nothing else:
        {"score": <number between 0 and 1>, "why": "<one sentence explaining the score>"}
      PROMPT

      # @param criteria [String] what a good answer looks like
      # @param provider [Lain::Provider] the judge model's provider
      # @param model [String] the judge model
      # @param max_tokens [Integer] the judge's reply budget
      def initialize(criteria:, provider:, model:, max_tokens: 512)
        @criteria = criteria.to_s
        @provider = provider
        @model = model
        @max_tokens = max_tokens
      end

      # Score `subject` against the criteria.
      #
      # NOTE on `Grade#pass?`: a Rubric scores on a CONTINUOUS 0..1 scale, so the
      # returned Grade's `#pass?` carries {Grade}'s default meaning (score >=
      # 1.0) and is rarely useful -- an LLM judge almost never returns a hard
      # 1.0. Threshold `#score` yourself for a pass/fail decision (e.g.
      # `grade.score >= 0.8`); do not read `#pass?` as the judge's verdict. It is
      # deliberately not overridden here because a Rubric has no one true
      # threshold -- that policy belongs to the caller, not the judge.
      #
      # @param subject [#to_s] the answer/output under judgment
      # @return [Grade] score + mandatory explanation
      # @raise [Unparseable] when the judge's reply carries no JSON verdict
      # @raise [ArgumentError] when the judge omits the required explanation
      def grade(subject)
        response = @provider.complete(request_for(subject))
        verdict = parse(response.text)
        Grade.new(score: verdict.fetch("score", 0), why: verdict["why"].to_s)
      end

      private

      def request_for(subject)
        Request.new(
          model: @model,
          system: "#{INSTRUCTION}\n\nCriteria:\n#{@criteria}",
          messages: [{ "role" => "user", "content" => [{ "type" => "text", "text" => subject.to_s }] }],
          max_tokens: @max_tokens,
          stream: false
        )
      end

      # Prefer the whole reply as JSON; fall back to the first balanced-looking
      # object embedded in prose. A judge that returns neither is Unparseable --
      # we do not guess a score for it.
      def parse(text)
        object = json_object(text) || json_object(text[/\{.*\}/m].to_s)
        raise Unparseable, "judge reply carried no JSON verdict: #{text.inspect}" unless object.is_a?(Hash)

        object
      end

      def json_object(candidate)
        return nil if candidate.to_s.strip.empty?

        parsed = JSON.parse(candidate)
        parsed.is_a?(Hash) ? parsed : nil
      rescue JSON::ParserError
        nil
      end
    end
  end
end
