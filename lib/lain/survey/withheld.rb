# frozen_string_literal: true

module Lain
  module Survey
    Withheld = Data.define(:path, :reason, :explanation)

    # A path the walk found and will not hand to the corpus, and why.
    #
    # Its own value rather than a bare path, because "somehow" is four answers
    # in four places: the corpus decides what a withheld path does to `#files`,
    # two surfaces render the disclosure, and the accretion gesture refuses an
    # added denied path with a report. Each needs the REASON, and a Symbol
    # nobody can typo is what keeps those four readings the same one.
    #
    # WITHHELD IS NOT IGNORED. An ignored path -- `tmp/`, a vendored tree, a
    # build artifact -- is simply not listed and never appears here: withholding
    # means found-and-not-handed-over, with a reason worth telling the human,
    # and a disclosure that named every gitignored file would bury the entries
    # that matter.
    #
    # Three reasons and no fourth. A DENIED path is off limits by name, ahead of
    # any approval, and denial is not approvable -- so it can never enter, and
    # the classifier's own explanation is carried verbatim rather than
    # paraphrased. BINARY content is withheld because a review of bytes nobody
    # can read is not a review. An OUTSIDE path is a symbolic link resolving
    # out of the surveyed tree: the bytes are real and readable, but the human
    # pointed at a directory, and quietly reviewing what a link reaches beyond
    # it is a scope nobody agreed to. A GATED path is not here at all: it enters
    # masked to its released regions ({Projection}), because withholding it
    # wholesale would make a survey stricter than the read path over the same
    # file.
    class Withheld
      # Checked, not coerced, for {Sensitivity::Verdict}'s reason: a wrong value
      # answering in silence is what an admission boundary must not do.
      REASONS = %i[denied binary outside].freeze

      # Said here rather than taken from a classifier, because no classifier saw
      # these bytes -- the walk did, and this is what it saw.
      BINARY = "binary content"

      # Likewise the walk's own finding, and NOT a verdict: the classifier is
      # lexical and has no notion of a surveyed root.
      OUTSIDE = "a link out of the surveyed tree"

      # @param path [String] as the walk lists it, relative to the surveyed root
      # @param verdict [Sensitivity::Verdict] the denial, whose explanation is
      #   carried as it stands so "why is my file withheld?" is answerable
      #   without us
      def self.denied(path, verdict) = new(path:, reason: :denied, explanation: verdict.explanation)

      def self.binary(path) = new(path:, reason: :binary, explanation: BINARY)

      def self.outside(path) = new(path:, reason: :outside, explanation: OUTSIDE)

      # @raise [ArgumentError] on an unknown reason, a non-String path, or a
      #   withholding with no stated why
      def initialize(path:, reason:, explanation:)
        super(path: named!(path), reason: known!(reason), explanation: stated!(explanation))
      end

      def denied? = reason == :denied
      def binary? = reason == :binary
      def outside? = reason == :outside

      # One disclosure line. Safe to render at a human and safe in a prompt:
      # every part of it is a name the survey was asked about, never a byte of
      # the file -- {Sensitivity::Regions::Region#to_s}' rule, met by carrying
      # nothing that could break it.
      def to_s = "#{path}: #{explanation}"

      private

      # `dup.freeze` and not `-@` on both Strings: a path is unbounded caller
      # data, and interning it leaks it into the fstring table for the life of
      # the process ({Sensitivity::Rules.rule}'s reason).
      def named!(path)
        raise ArgumentError, "a path must be a String, got #{path.inspect}" unless path.is_a?(String)

        path.dup.freeze
      end

      def known!(reason)
        raise ArgumentError, "reason must be one of #{REASONS.join(", ")}, got #{reason.inspect}" \
          unless REASONS.include?(reason)

        reason
      end

      # A withheld path with no stated why is a mystery a surface cannot render
      # and a human cannot act on.
      def stated!(explanation)
        raise ArgumentError, "an explanation is required, got #{explanation.inspect}" \
          unless explanation.is_a?(String) && !explanation.strip.empty?

        explanation.dup.freeze
      end
    end
  end
end
