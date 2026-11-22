# frozen_string_literal: true

module Lain
  module Epic
    # One issue as an implementer reads it, composed on every read from the
    # three places its parts live: the issue in `epic.md`, the graph around it,
    # and the authored `issues/<id>.md`.
    #
    # The authored file holds only what nothing else knows: prose, the scenarios
    # the epic left implicit, and references. The header, the description and
    # scenarios signed off at the epic gate, and the Links are rendered, so what
    # the epic signed off reaches the view byte for byte and an edge edited in
    # the graph shows on the next read with no file rewritten. {#refuse_derived!}
    # keeps the authored file from carrying what the view renders: a link line,
    # a `# ` header, a `## Links` heading, a gherkin fence outside the criteria
    # section, or a restated epic scenario.
    class IssueView
      # Error taxonomy: a refusal subclasses {Lain::Error} beside its raiser.
      class DerivedLine < Error; end

      CRITERIA_HEADING = "## Acceptance criteria"
      REFERENCES_HEADING = "## References"
      LINKS_HEADING = "## Links"
      # Any case, level 2 or 3: a typo in the heading must not read as an issue with no limit.
      ALLOWED_HEADING = /\A\#{2,3}[ \t]+allowed paths[ \t]*\z/i
      # A list item's first word, its backticks and a leading `./` dropped.
      ALLOWED_ITEM = %r{\A\s*[-*]\s+`?(?:\./)?(?<path>[^`\s,]+)}
      DERIVED_KINDS = [*Document::LINK_FIELDS.keys, *Document::DERIVED_LINKS.keys,
                       *Document::LABEL_LINKS.keys].freeze
      # What parts the words of a References line: markdown's own punctuation as well as space.
      REFERENCE_BREAKS = /[\s`'"<>()\[\],]+/
      # A path outside the project names at least 1 segment under `/` or `~/`: never the root or home alone, nor
      # a `//host` or a `/24` subnet.
      OUTSIDE = %r{\A~?/(?!/)(?!\d+\z)[^/]}
      # A sentence's closing `.`, `:` or `;`, but never a dot of a trailing `..`, which steps up a directory.
      SENTENCE_END = /(?<!\.)\.?[:;]*\z/
      # Rendered markdown hides a comment, so a path in one is nothing the approving human saw.
      HTML_COMMENT = /<!--.*?-->/m

      # The authored file is read first, so a malformed id is refused as a
      # filename before the graph is asked about it.
      #
      # @param home [#read_epic, #issue] an {Epic::Home} or its journaled decorator
      # @param id [String] the issue id
      # @return [IssueView]
      def self.read(home, id)
        authored = home.issue(id).read
        graph = home.read_epic
        new(issue: graph.fetch(id), graph:, authored:)
      end

      # @param issue [Issue] the issue as `epic.md` holds it
      # @param graph [Graph] the epic it sits in, for the derived Blocked by
      # @param authored [String] the bytes of `issues/<id>.md`
      def initialize(issue:, graph:, authored:)
        @issue = issue
        @graph = graph
        @authored = Authored.new(authored)
      end

      # @return [Issue] the issue as `epic.md` holds it
      attr_reader :issue

      # @return [Array<String>] the ids whose Blocks edges name this issue
      def blocked_by = @graph.blocked_by(@issue.id)

      # @return [String] the whole view, ending in one line break
      def to_markdown
        sections = ["# #{@issue.id} -- #{@issue.title}", @issue.description, @authored.prose,
                    section(CRITERIA_HEADING, criteria_section), section(REFERENCES_HEADING, @authored.references),
                    section(LINKS_HEADING, links)]
        "#{sections.reject(&:empty?).join("\n\n")}\n"
      end

      # The paths outside the project its References name, which the approval of this view lends its agents.
      #
      # @param home [String] what a leading `~` names
      # @return [Array<String>] each absolute or home-relative path, expanded, in the order written
      def lends(home:)
        shown = @authored.references.gsub(HTML_COMMENT, " ")
        words = shown.split(REFERENCE_BREAKS).map { _1.sub(SENTENCE_END, "") }.grep(OUTSIDE)
        words.map { File.expand_path(_1.sub(/\A~/, home)) }.uniq
      end

      # The section stays in the prose as written, so an issue without one renders, and digests, as it always did.
      #
      # @return [Array<String>, nil] the paths the authored Allowed paths section lists; nil when it has none
      def allowed_paths
        shown = @authored.allowed_lines&.join("\n")&.gsub(HTML_COMMENT, " ")
        shown&.lines&.filter_map { _1[ALLOWED_ITEM, :path] }&.uniq
      end

      # @return [Gherkin::Criteria] epic.md's scenarios, then the authored ones
      def criteria
        sources = [@issue.criteria, @authored.scenarios]
        Gherkin::Criteria.new(scenarios: sources.flat_map { |source| Gherkin::Criteria.parse(source).scenarios })
      end

      # The rendered bytes' address, through the same blob framing a journaled
      # write uses, so a view and a file of the same bytes share one address.
      # The Links are inside it on purpose: a changed blocker set is a changed
      # plan, so a new edge reopens the issue's issue_plan gate.
      #
      # @return [String] a `blake3:` digest
      def digest = Workspace::Snapshot::Blob.new(bytes: to_markdown).digest

      # @return [self]
      # @raise [DerivedLine] for an authored link line, header, Links heading, stray
      #   gherkin fence or restated epic scenario
      # @raise [Gherkin::MalformedBlock] for an authored gherkin fence that does not parse
      def refuse_derived!
        problems = [link_line_problem, rendered_heading_problem, stray_fence_problem, restated_problem].compact
        return self if problems.empty?

        raise DerivedLine, "issues/#{@issue.id}.md holds what lain renders:\n#{problems.map { "- #{_1}" }.join("\n")}"
      end

      private

      def section(heading, body) = body.empty? ? "" : "#{heading}\n\n#{body}"

      def criteria_section = [@issue.criteria.to_s.chomp, @authored.scenarios].reject(&:empty?).join("\n\n")

      def links = Document.link_lines(@issue, blocked_by: @graph.blocked_by(@issue.id)).join("\n")

      def link_line_problem
        line = @authored.link_lines.find { |_number, kind| DERIVED_KINDS.include?(kind) }
        return unless line

        "line #{line.first}: `#{line.last}:` is a link line, and lain renders the Links from the epic graph in " \
          "epic.md -- write no link lines here; change an edge in epic.md or with epic_graph"
      end

      def rendered_heading_problem
        line = @authored.rendered_headings.first
        return unless line

        "line #{line.number}: #{line.text.strip.inspect} is lain's to write in the rendered view -- the header " \
          "comes from epic.md and the Links from its graph"
      end

      def stray_fence_problem
        line = @authored.stray_fences.first
        return unless line

        "line #{line.number}: a gherkin fence outside #{CRITERIA_HEADING} -- every added scenario goes under " \
          "that heading, so the criteria live in one place"
      end

      def restated_problem
        restated = @authored.scenario_names & Gherkin::Criteria.parse(@issue.criteria).map(&:name)
        return if restated.empty?

        "restates #{restated.map(&:inspect).join(", ")} from epic.md, and lain renders every scenario epic.md " \
          "carries for this issue -- add only new ones"
      end

      # A line inside a fence never starts a section or declares a link: a
      # gherkin `Scenario:` line wears the link shape.
      class Authored
        Line = Data.define(:number, :text, :fenced)

        def initialize(text)
          @text = text
          @lines = numbered(text)
          @sections = @lines.slice_before { |line| heading?(line) }.to_a
        end

        def prose = joined(@sections.reject { |lines| named?(lines) }.flatten)

        def scenarios = body(CRITERIA_HEADING)

        def references = body(REFERENCES_HEADING)

        def scenario_names = Gherkin::Criteria.parse(@text).map(&:name)

        # @return [Array<Array(Integer, String)>] each unfenced link-shaped line's number and kind
        def link_lines
          @lines.reject(&:fenced).filter_map do |line|
            match = Document::LINK_LINE.match(line.text)
            [line.number, match[:kind]] if match
          end
        end

        def rendered_headings
          @lines.reject(&:fenced).select { |line| line.text.start_with?("# ") || heading_text(line) == LINKS_HEADING }
        end

        # @return [Array<String>, nil] the unfenced lines under the Allowed paths heading, up to the next heading
        def allowed_lines
          start = @lines.index { |line| !line.fenced && line.text.match?(ALLOWED_HEADING) }
          return if start.nil?

          @lines.drop(start + 1).take_while { |line| line.fenced || !line.text.start_with?("#") }
                .reject(&:fenced).map(&:text)
        end

        def body(heading) = joined(@sections.select { |lines| heading_of(lines) == heading }.flat_map { _1.drop(1) })

        def stray_fences
          outside = @sections.reject { |lines| heading_of(lines) == CRITERIA_HEADING }
          outside.flatten.select { |line| gherkin_opener?(line) }
        end

        private

        def gherkin_opener?(line)
          text = line.text.strip
          text.start_with?(Document::FENCE) && text.delete_prefix(Document::FENCE).split.first == Document::GHERKIN_TAG
        end

        def numbered(text)
          fenced = false
          text.lines(chomp: true).each_with_index.map do |line, index|
            fence = line.strip.start_with?(Document::FENCE)
            numbered = Line.new(number: index + 1, text: line, fenced: fenced || fence)
            fenced ^= fence
            numbered
          end
        end

        def named?(lines) = [CRITERIA_HEADING, REFERENCES_HEADING].include?(heading_of(lines))

        def heading_of(lines) = heading_text(lines.first)

        def heading_text(line) = heading?(line) ? line.text.rstrip : nil

        def heading?(line) = !line.fenced && line.text.start_with?("## ")

        def joined(lines) = lines.map(&:text).join("\n").sub(/\A\n+/, "").rstrip
      end
      private_constant :Authored
    end
  end
end
