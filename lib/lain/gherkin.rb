# frozen_string_literal: true

module Lain
  # A typed, content-addressed IR for the Gherkin acceptance criteria plan docs
  # and skill scaffolds already carry as fenced code blocks. Parsing the house
  # format into deeply frozen values gives the grader a stable digest to attest
  # against: two criteria that mean the same thing hash the same, and any edited
  # clause is a different address.
  #
  # The grammar is deliberately narrow -- exactly what the corpus uses: fenced
  # blocks of `Scenario:` headers over `Given|When|Then|And` clauses, wrapped
  # continuation lines folded into the clause they trail, comment lines ignored.
  # The one pinned marker is `# rubric` alone on the line immediately before a
  # `Scenario:`, flagging it human-judged rather than mechanical. Every other
  # placement of that marker, and anything the grammar cannot account for, is a
  # loud {MalformedBlock} naming the line -- no silent placement ambiguity.
  module Gherkin
    class MalformedBlock < Error; end

    # One `Given|When|Then|And` step: the keyword and its (continuation-folded)
    # text. Interned Strings, so the value is Ractor-shareable.
    Clause = Data.define(:keyword, :text) do
      def initialize(keyword:, text:)
        super(keyword: -keyword.to_s, text: -text.to_s)
      end

      # Plain-hash wire form for {Canonical}; String keys, sorted downstream.
      def canonical
        { "keyword" => keyword, "text" => text }
      end
    end

    # A named scenario: its ordered clauses and whether a generated test proves
    # it (`mechanical`) or a human judges it (flagged by a `# rubric` line). The
    # clauses Array is frozen over shareable Clauses, so the value is
    # Ractor-shareable.
    Scenario = Data.define(:name, :clauses, :mechanical) do
      def initialize(name:, clauses:, mechanical: true)
        super(name: -name.to_s, clauses: clauses.freeze, mechanical:)
      end

      def canonical
        { "name" => name, "mechanical" => mechanical, "clauses" => clauses.map(&:canonical) }
      end

      # Back OUT to the house format the parser accepts. It lives on the value
      # so a consumer that quotes a scenario -- {TestGeneration}'s prompt --
      # quotes it in the parser's own wording rather than a copy of these
      # lines, and a scenario quoted one way and parsed another is a difference
      # nothing would report.
      #
      # NOT {#canonical}'s business, which is the digest's wire form: this one is
      # read by people, so it may be reformatted without changing an address.
      def render
        (["Scenario: #{name}"] + clauses.map { |clause| "  #{clause.keyword} #{clause.text}" }).join("\n")
      end
    end

    # The whole IR: the ordered scenarios parsed out of a markdown document, plus
    # the content address over their canonical bytes.
    Criteria = Data.define(:scenarios) do
      include Enumerable

      def self.parse(source)
        new(scenarios: Parse.call(source.to_s))
      end

      def initialize(scenarios:)
        super(scenarios: scenarios.freeze)
      end

      def each(&block)
        scenarios.each(&block)
      end

      # `Canonical` sorts object keys and preserves array order, so clause order
      # and scenario order both count: an edited or reordered clause is a
      # different criteria.
      def digest
        Canonical.digest("scenarios" => scenarios.map(&:canonical))
      end
    end

    # The line-oriented parser, held apart from the values it builds because it is
    # the one mutable thing here. Kept out of a `Data.define` block on purpose:
    # constants and nested classes declared inside one scope to the enclosing
    # module, not the value class.
    module Parse
      module_function

      FENCE = "```"
      TAG = "gherkin"
      KEYWORDS = %w[Given When Then And].freeze
      RUBRIC = "# rubric"
      # A capitalized word ending in a colon is unambiguous author intent to name
      # a step or section, so it is never a wrapped-prose continuation -- an
      # unknown one fails loud rather than being silently absorbed. `Scenario:`
      # is handled before this ever runs.
      COLON_TOKEN = /\A[A-Z][A-Za-z]*:\z/

      def call(source)
        Fences.new(source).blocks.flat_map { |open_line, lines| Block.new(open_line, lines).scenarios }
      end

      # Splits a document into gherkin-fenced blocks, with 1-based line numbers so
      # a {MalformedBlock} names the offending line. Its one job is fence
      # integrity: a fence left open at EOF, or interrupted by another fence
      # before its bare closing run of backticks, is a loud error naming the
      # opener, because a dropped closing fence silently swallowing scenarios is
      # exactly the quiet loss the loud-failure doctrine forbids. An opener
      # followed only by blank lines is an empty block, an author mistake and not
      # "zero scenarios"; prose that never opens a fence is simply no blocks.
      class Fences
        def initialize(source)
          @open_line = nil
          @body = nil
          @blocks = []
          source.lines.each_with_index { |raw, index| feed(index + 1, raw.strip) }
          raise MalformedBlock, unclosed("no closing ``` before end of document") if inside?
        end

        attr_reader :blocks

        private

        def feed(line_number, text)
          if inside? then consume(line_number, text)
          elsif gherkin_fence?(text) then open_gherkin(line_number, text)
          end
        end

        # Recognized by its FIRST info-string token, so a decorated opener is
        # never silently dropped -- but the house grammar is bare-only, so
        # anything after the tag is a loud error. Loud beats both silent-parse
        # and silent-drop.
        def open_gherkin(line_number, text)
          raise MalformedBlock, "line #{line_number}: ```gherkin opener must be bare" unless bare_opener?(text)

          start_block(line_number)
        end

        def consume(line_number, text)
          if text == FENCE then close
          elsif text.start_with?(FENCE) then raise MalformedBlock, unclosed("a new fence opened before it closed")
          else @body << [line_number, text]
          end
        end

        def start_block(line_number)
          @open_line = line_number
          @body = []
        end

        def close
          raise MalformedBlock, "line #{@open_line}: empty ```gherkin block declares no scenarios" if empty_body?

          @blocks << [@open_line, @body]
          @open_line = nil
          @body = nil
        end

        def unclosed(why) = "line #{@open_line}: unclosed ```gherkin fence (#{why})"
        def empty_body? = @body.all? { |_, text| text.empty? }
        def inside? = !@open_line.nil?
        def gherkin_fence?(text) = text.start_with?(FENCE) && text.delete_prefix(FENCE).split.first == TAG
        def bare_opener?(text) = text.delete_prefix(FENCE).strip == TAG
      end

      # A single block's fold. Mutable while parsing, emitting frozen Scenarios.
      class Block
        def initialize(open_line, numbered_lines)
          @open_line = open_line
          @scenarios = []
          @name = nil
          @scenario_line = nil
          @clauses = nil
          @mechanical = true
          @rubric_pending = false
          @rubric_line = nil
          numbered_lines.each { |line_number, text| feed(line_number, text) }
          finish
        end

        attr_reader :scenarios

        private

        # A pending `# rubric` may be followed ONLY by a `Scenario:` line; any
        # other line is the placement-ambiguity error, named at the MARKER's line
        # rather than the trailing line that exposed it.
        def feed(line_number, text)
          if @rubric_pending && !scenario?(text)
            raise MalformedBlock,
                  "line #{@rubric_line}: `# rubric` must sit on its own line immediately before a `Scenario:` line"
          end

          dispatch(line_number, text)
        end

        def dispatch(line_number, text)
          if rubric_marker?(text) then mark_rubric(line_number)
          elsif scenario?(text) then open_scenario(line_number, text)
          elsif ignorable?(text) then nil
          elsif colon_token?(text) then reject_colon_token(line_number, text)
          elsif keyword?(text) then add_clause(line_number, text)
          else add_continuation(line_number, text)
          end
        end

        def reject_colon_token(line_number, text)
          raise MalformedBlock, "line #{line_number}: `#{text}` is not a known keyword (colon-suffixed token)"
        end

        def mark_rubric(line_number)
          @rubric_pending = true
          @rubric_line = line_number
        end

        def open_scenario(line_number, text)
          close_scenario
          name = text.delete_prefix("Scenario:").strip
          raise MalformedBlock, "line #{line_number}: a scenario needs a name after `Scenario:`" if name.empty?

          @name = name
          @scenario_line = line_number
          @clauses = []
          @mechanical = !@rubric_pending
          @rubric_pending = false
        end

        def add_clause(line_number, text)
          raise MalformedBlock, "line #{line_number}: `#{text}` is a clause outside any Scenario" if @clauses.nil?

          keyword, _, rest = text.partition(" ")
          raise MalformedBlock, "line #{line_number}: `#{keyword}` has no text" if rest.strip.empty?
          if keyword == "And" && @clauses.empty?
            raise MalformedBlock,
                  "line #{line_number}: `And` has no preceding Given/When/Then"
          end

          @clauses << [keyword, rest.strip]
        end

        def add_continuation(line_number, text)
          if @clauses.nil? || @clauses.empty?
            raise MalformedBlock,
                  "line #{line_number}: `#{text}` continues nothing -- no clause to attach it to"
          end

          keyword, existing = @clauses.last
          @clauses[-1] = [keyword, "#{existing} #{text}".strip]
        end

        def close_scenario
          return if @name.nil?

          raise MalformedBlock, "line #{@scenario_line}: scenario `#{@name}` has no clauses" if @clauses.empty?

          @scenarios << Scenario.new(name: @name, clauses: build_clauses, mechanical: @mechanical)
          @name = nil
          @scenario_line = nil
          @clauses = nil
        end

        def build_clauses
          @clauses.map { |keyword, text| Clause.new(keyword:, text:) }
        end

        def finish
          if @rubric_pending
            raise MalformedBlock,
                  "line #{@rubric_line}: `# rubric` ends the block with no following `Scenario:`"
          end

          close_scenario
        end

        def scenario?(text) = text.start_with?("Scenario:")
        def rubric_marker?(text) = text == RUBRIC
        def ignorable?(text) = text.empty? || text.start_with?("#")
        def colon_token?(text) = text.partition(" ").first.match?(COLON_TOKEN)
        def keyword?(text) = KEYWORDS.include?(text.partition(" ").first)
      end
    end
  end
end
