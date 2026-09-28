# frozen_string_literal: true

module Lain
  module QA
    # A plan document read for what QA holds it to: each card's claimed files,
    # its risk, and its acceptance criteria.
    #
    # The grammar is the one the plan documents under `planning/specs/` are
    # written in -- a card headed `### T<id> ... [risk: <level>]`, its paths
    # backticked on a `**Files:**` paragraph that runs to the next blank line,
    # its criteria in gherkin fences -- and no further. It is a writing
    # convention rather than a schema, so a card stating a part some other way
    # yields nothing for that part, which the checks downstream report as a
    # card with nothing to hold it to, and never a guess.
    #
    # A claimed path is a PATHSPEC, not a literal, and {ClaimCheck} matches it
    # as one: real plans here claim `.../skill/*/skill.md`, brace lists like
    # `handler/{live,mock}.rb`, and bare directories. Each is a false major
    # finding under an exact match, the defect this rung exists to remove.
    #
    # A card's criteria are {Gherkin::Scenario}s, which ALREADY say whether a
    # human judges one: `mechanical` is false where the pinned `# rubric`
    # marker flags it. A second such axis belongs in that marker rather than in
    # a parallel flag here, at a price worth knowing first -- the marker is
    # grammar, and moving it moves {Gherkin::Criteria#digest}, a content address
    # {Approval::Gate}, {Plan::Step} and {Epic::Issue} all cite.
    #
    # Per-part silence is reported. Silence about the whole DOCUMENT is not:
    # zero cards yield zero claims and zero findings, which is indistinguishable
    # from a clean pass, so a document with no card in it is refused.
    class PlanCards
      include Enumerable

      # A digit AND the title separator, because a plan is written in English
      # and heads its sections with it: measured over this repo's plan corpus,
      # a bare letter-then-word pattern read 26 prose headings as card ids
      # across 10 documents ("The bench", "Three shapes considered"), and two
      # of those in one document invented a duplicate id as well. A digit alone
      # is not enough -- a heading discussing a card in the possessive still
      # begins with that card's id.
      CARD = /^###\s+(T\d[\w.-]*)\s+[—–-]/
      RISK = /\[risk:\s*(\w+)\]/
      FILES = /^\*\*Files:\*\*(.*?)(?=^\s*$|^\*\*\w|\z)/m
      PATH = /`([^`\s]+)`/
      HEADING = /\A###\s/
      FENCE = /\A\s*(`{3,}|~{3,})/

      # A plan QA cannot be held to. Both arms are the same rule: a reading
      # that looks like a clean pass and is not one.
      class MalformedPlan < Error; end

      # One card. `risk` is `medium` when the heading names none or names one
      # outside {RISKS}: the middle arm neither waves a criterion through nor
      # spends a strong model on every one.
      Card = Data.define(:id, :risk, :files, :criteria) do
        def initialize(id:, risk:, files:, criteria:)
          super(id: -id.to_s, risk: -risk.to_s, files: files.map { |path| -path.to_s }.freeze, criteria:)
        end
      end

      # @param markdown [String] the plan doc
      # @return [PlanCards]
      # @raise [MalformedPlan] when no card is recognised, or two share an id
      # @raise [Lain::Gherkin::MalformedBlock] for a card whose criteria do not parse
      def self.read(markdown)
        cards = sections(markdown).filter_map { |section| card(section) }
        raise MalformedPlan, "no cards in the plan: QA would hold the work to nothing" if cards.empty?

        new(cards)
      end

      # A fence can quote anything, `###` headings included, and a phantom card
      # forked out of one takes the real card's criteria with it -- the silent
      # scenario loss {Gherkin} exists to refuse, one layer up.
      def self.sections(markdown)
        opener = nil
        markdown.to_s.lines.slice_before do |line|
          opens = HEADING.match?(line) && opener.nil?
          opener = fenced(opener, line[FENCE, 1])
          opens
        end.map(&:join)
      end

      # CommonMark's rule, and why a toggle was not enough: a fence closes only
      # on a run of its own character at least as long as its opener, so the
      # four-backtick fence a document quotes a three-backtick one inside stays
      # open across it.
      def self.fenced(opener, run)
        return opener if run.nil?
        return run if opener.nil?

        run[0] == opener[0] && run.length >= opener.length ? nil : opener
      end

      def self.card(section)
        id = section[CARD, 1]
        return if id.nil?

        risk = section[RISK, 1]
        Card.new(id:, risk: RISKS.include?(risk) ? risk : "medium", files: paths(section),
                 criteria: Gherkin::Criteria.parse(section))
      end

      def self.paths(section) = section[FILES, 1].to_s.scan(PATH).flatten.uniq
      private_class_method :sections, :fenced, :card, :paths

      def initialize(cards)
        @cards = cards.freeze
        @claims = claimed.freeze
        freeze
      end

      def each(&block) = @cards.each(&block)

      # @!attribute [r] claims
      #   @return [Hash{String=>Array<String>}] card id to the pathspecs it
      #     claims, every card present even when it claims nothing --
      #     {ClaimCheck}'s input
      attr_reader :claims

      private

      # Two cards under one id would collapse here, last one winning, and the
      # loser's files would then surface as work nobody claimed.
      def claimed
        each_with_object({}) do |card, claims|
          raise MalformedPlan, "two cards share the id #{card.id}" if claims.key?(card.id)

          claims[card.id] = card.files
        end
      end
    end
  end
end
