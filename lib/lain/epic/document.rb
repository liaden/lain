# frozen_string_literal: true

module Lain
  module Epic
    class MalformedDocument < Error; end

    # The epic as the markdown a human edits, and the parse that reads those
    # edits back. {Plan::Document}'s grammar idiom throughout -- module-scope
    # regexes, one status map read both directions -- with one deliberate
    # difference: prose INSIDE an issue is `description`, and description is
    # meaning, so it moves the digest. Prose ABOVE the first heading is the epic
    # preamble and is ignored exactly as Plan ignores prose around its steps: the
    # author owns it, we never emit it, and it cannot move the digest.
    #
    # The round trip is TOTAL in the strong sense: `parse_markdown(to_markdown(g))`
    # is `g` by digest, or the emit is refused loudly naming the value it cannot
    # write. Nothing is silently reinterpreted in either direction -- a line the
    # grammar has no slot for is an error naming the line, never prose the author
    # never sees again (the precedent is `Gherkin::Parse::COLON_TOKEN`). Parse and
    # emit refuse the same shapes, so a document that parses always emits.
    #
    # `Blocked by:` is never written. It is derived from the `blocks` edges of
    # the issues that block an issue, and a derived line that is also authorable
    # is a second source of truth.
    module Document
      # A status shown as a one-char mark inside the heading's checkbox, and the
      # exact inverse used to read it back -- one map, both directions, so emit
      # and parse cannot drift. `fetch`ed at both ends, so a status added to
      # STORED_STATUSES without a mark fails loudly here rather than emitting a
      # heading that will not parse.
      STATUS_MARKS = { "pending" => " ", "in_flight" => "~", "done" => "x", "abandoned" => "!" }.freeze
      MARK_STATUSES = STATUS_MARKS.invert.freeze
      MARK_LEGEND = STATUS_MARKS.map { |status, mark| "[#{mark}] #{status}" }.join(", ").freeze

      # The markdown vocabulary. An issue is an `###` heading carrying its mark,
      # its id in backticks, and its title; its body runs to the next heading or
      # to end of document (stated in the grammar, so a closing note under the
      # last issue is knowingly that issue's prose rather than silently absorbed).
      # A link line is a capitalized kind, a colon, and backticked ids.
      HEADING = /\A### \[(?<mark>.)\] `(?<id>[^`]+)` (?<title>.+)\z/
      # Exactly three hashes: a line at the issue level that is not a valid issue
      # heading is a typo'd heading, and reading it as prose would drop an issue
      # silently. A DEEPER heading (`#### Notes`) is unambiguous markdown that
      # round-trips as prose, so the grammar carries it rather than refusing it --
      # a grammar refuses what it cannot write back, not everything that looks
      # nearby.
      HEADING_LEVEL = /\A###(?!#)/
      # The link-line SHAPE, matched before the kind is known: a line wearing it
      # is author intent to declare an edge, so an unknown kind is refused rather
      # than demoted to prose. That is why an ordinary prose line may not begin
      # `Capitalized words: `.
      LINK_LINE = /\A(?<kind>[A-Z][A-Za-z ]*): (?<value>.*)\z/
      LINK_ID = /`([^`]+)`/
      LINK_FIELDS = { "Blocks" => :blocks, "Related" => :related, "Discovered from" => :discovered_from }.freeze
      # Which of those fields hold ONE id rather than a set -- consulted by both
      # directions, so the arity cannot drift between read and write.
      #
      # The three kinds are not validated alike, and the asymmetry is deliberate:
      # Graph resolves `blocks` and `related` against the issue set and leaves
      # `discovered_from` alone, because a split REMOVES the issue its parts grew
      # out of and provenance has to outlive it. So `Blocks: `zz`` naming nothing
      # is refused at parse and `Discovered from: `zz`` is not. A spec pins both,
      # since the difference is invisible to an author who typos an id.
      SINGULAR_LINKS = %i[discovered_from].freeze
      WRITABLE_LINKS = LINK_FIELDS.keys.map { |kind| "#{kind}:" }.join(", ").freeze
      # Kinds an author might reasonably write that this grammar refuses on
      # purpose, with the reason, so the message teaches rather than scolds.
      DERIVED_LINKS = { "Blocked by" => ", it is derived from the `blocks` edges of the issues that block it " \
                                        "(Graph#blocked_by) and is never written back" }.freeze
      UNKNOWN_LINK = "line %<number>d: `%<kind>s:` is not a link line this grammar writes%<why>s -- the " \
                     "writable link kinds are %<writable>s"

      # Read from Gherkin rather than restated: the criteria block is a gherkin
      # fence, and forking that grammar is how the two would drift.
      FENCE = Gherkin::Parse::FENCE
      GHERKIN_TAG = Gherkin::Parse::TAG

      # The ONE statement of "this text holds bytes the parse would strip",
      # spliced into every field's rule list below. Both fields are subject to the
      # same single normalization -- {Document.normalize_line} -- so stating it
      # once and splicing is what keeps them from disagreeing. They did disagree:
      # the description rule was written with `String#chomp`, which removes
      # "\r\n" as ONE unit and so hid a CR from the very comparison meant to
      # catch it, and the criteria list had no per-line rule at all. Between them
      # that was five classes of silent digest change. `delete_suffix("\n")`
      # removes the terminator and nothing else, which is precisely the
      # comparison this needs.
      STRIPPED_BYTES = [
        ["cannot hold a line ending in whitespace -- a trailing space, a blank line of spaces, or a \\r -- " \
         "because the parse strips every line it reads and those bytes would not survive the round trip",
         ->(text) { text.each_line.any? { |line| Document.normalize_line(line) != line.delete_suffix("\n") } }]
      ].freeze

      # What a description must already be for the grammar to write it back
      # unchanged, as message-and-predicate pairs in the order a reader wants to
      # hear them -- the fence rule before the link rule, because a fenced
      # `Scenario:` line wears the link shape and the fence is the better
      # diagnosis. Emit refuses rather than normalizes: silently rewriting an
      # author's prose to something that round-trips is the quiet reinterpretation
      # this unit exists to prevent.
      DESCRIPTION_RULES = [
        ["cannot begin with a blank line (the grammar puts one under the heading and eats it coming back)",
         ->(text) { text.start_with?("\n") }],
        ["cannot end in whitespace or a line break (the grammar strips it, so those bytes would not survive)",
         ->(text) { text != text.rstrip }],
        *STRIPPED_BYTES,
        ["cannot hold a line beginning `###` (the grammar reads it as the next issue heading)",
         ->(text) { text.each_line.any? { |line| HEADING_LEVEL.match?(line) } }],
        ["cannot hold a ``` fence (the grammar reads it as the acceptance-criteria block)",
         ->(text) { text.each_line.any? { |line| line.strip.start_with?(FENCE) } }],
        ["cannot hold a `Kind: value` link line (the grammar reads it as an edge declaration)",
         ->(text) { text.each_line.any? { |line| LINK_LINE.match?(line.delete_suffix("\n")) } }]
      ].freeze

      # The same statement for the criteria source. The fence DELIMITERS are part
      # of the stored value -- Gherkin::Criteria only finds scenarios inside a
      # fence, so a stored body without them would parse to nothing -- and the
      # closing fence line keeps its own line break, because the value is a block
      # of markdown lines rather than a phrase.
      CRITERIA_RULES = [
        ["must open with a ```gherkin fence line (the delimiters are part of the stored source)",
         ->(text) { text.lines.first.to_s.strip.delete_prefix(FENCE).split.first != GHERKIN_TAG }],
        ["must close with a bare ``` fence line",
         ->(text) { text.lines.last.to_s.strip != FENCE }],
        ["must end in the closing fence line's own line break",
         ->(text) { !text.end_with?("\n") }],
        *STRIPPED_BYTES
      ].freeze

      module_function

      # The parse's per-line normalization, named once. Every raw line {Reader}
      # reads goes through this, and the emit-side guard above is written in
      # terms of it rather than as a second, hand-maintained statement of the
      # same rule -- two lists that had to agree, and did not, is exactly what
      # let a CR through.
      def normalize_line(line) = line.rstrip

      # The author-editable document read back into the value. Everything above
      # the first heading is preamble and is dropped, so the digest is a function
      # of the issues alone.
      def parse_markdown(source) = Graph.new(issues: Reader.new(source).issues)

      # The whole graph as the document a human edits: issues in the graph's own
      # id order, sections in a fixed order, nothing carried over from whatever
      # document the graph was parsed from. A trailing newline because this is a
      # whole file, unlike Plan's embedded section.
      def to_markdown(graph)
        body = graph.map { |issue| Writer.new(issue).to_s }.join("\n\n")
        (body.empty? ? body : "#{body}\n").freeze
      end

      # The fence being gathered: the line its opener sat on, and the lines so
      # far. {Fence::None} is the "nothing open" state, so Reader asks the fence
      # whether it is open rather than testing two ivars against nil -- the same
      # move {Preamble} makes for "no issue open yet".
      class Fence
        def initialize(number, opener)
          @number = number
          @lines = [opener]
        end

        attr_reader :number

        def open? = true
        def closed_by?(text) = text.strip == FENCE

        def gather(text)
          @lines << text
          self
        end

        # The stored criteria source keeps the closing fence line's own line
        # break: the value is a block of markdown lines, not a phrase, and
        # CRITERIA_RULES refuses any criteria that does not already end that way.
        def source = "#{@lines.join("\n")}\n"

        # No fence open. `open?` is the only message it is ever sent, because
        # every other one is behind that question.
        class None
          def open? = false
        end
      end

      # The line-oriented parse: the one mutable thing in the unit, held apart
      # from the values it builds the way `Gherkin::Parse::Fences` is.
      #
      # Fence state is tested FIRST, and it is tracked in the preamble too: a
      # preamble that SHOWS the grammar (a fenced example heading) must not be
      # read AS the grammar.
      class Reader
        def initialize(source)
          @drafts = []
          @draft = Preamble.new
          @fence = Fence::None.new
          source.to_s.each_line.with_index(1) { |raw, number| feed(number, Document.normalize_line(raw)) }
          refuse_unclosed!
        end

        def issues = @drafts.map(&:to_issue)

        private

        def feed(number, text)
          if @fence.open? then inside_fence(text)
          elsif fence?(text) then @fence = Fence.new(number, text)
          elsif (heading = HEADING.match(text)) then open_issue(number, heading)
          elsif HEADING_LEVEL.match?(text) then refuse_heading!(number, text)
          else @draft.line(number, text)
          end
        end

        def inside_fence(text)
          @fence.gather(text)
          close_fence if @fence.closed_by?(text)
        end

        def close_fence
          @draft.criteria(@fence.number, @fence.source)
          @fence = Fence::None.new
        end

        def open_issue(number, heading)
          @draft = Draft.new(number, heading)
          @drafts << @draft
        end

        def fence?(text) = text.strip.start_with?(FENCE)

        # A fence left open swallows every heading below it, which is exactly the
        # quiet loss Gherkin::Parse::Fences refuses for the same reason.
        def refuse_unclosed!
          return unless @fence.open?

          raise MalformedDocument, "line #{@fence.number}: unclosed ``` fence (no closing ``` before end of document)"
        end

        def refuse_heading!(number, text)
          raise MalformedDocument, "line #{number}: #{text.inspect} is not an issue heading, though it begins " \
                                   "like one (expected `### [<mark>] `<id>` <title>`, marks #{MARK_LEGEND})"
        end
      end

      # Everything above the first heading. It answers a {Draft}'s whole duck and
      # drops it, so the reader carries no "are we inside an issue yet" branch and
      # the epic's own prose is ignored the way Plan ignores prose around its
      # steps -- including a link-shaped line, which is only author intent once it
      # is inside an issue.
      class Preamble
        def line(_number, _text) = nil
        def criteria(_number, _source) = nil
      end

      # One issue's body, accumulating until the next heading. Mutable while
      # parsing, emitting a frozen {Issue}.
      class Draft
        def initialize(number, heading)
          @number = number
          @heading = heading
          @prose = []
          @links = {}
          @criteria = nil
          @criteria_line = nil
        end

        def line(number, text)
          link = LINK_LINE.match(text)
          link ? add_link(number, link) : @prose << text
        end

        def criteria(number, source)
          refuse_second_fence!(number)
          refuse_foreign_fence!(number, source)
          @criteria = source
          @criteria_line = number
        end

        # Issue is what validates ids, titles, and statuses, so the draft does not
        # restate those rules -- it re-raises them against the heading line,
        # because an author fixing this is looking at a line number rather than at
        # a value object.
        def to_issue
          Issue.new(id: @heading[:id], title: @heading[:title], status:, description:, criteria: @criteria, **@links)
        rescue MalformedIssue => e
          raise MalformedDocument, "line #{@number}: #{e.message}"
        end

        private

        def status
          MARK_STATUSES.fetch(@heading[:mark]) do
            raise MalformedDocument, "line #{@number}: unknown status mark #{@heading[:mark].inspect} " \
                                     "(the marks are #{MARK_LEGEND})"
          end
        end

        # Leading and trailing blank lines are the grammar's own separators
        # between heading, prose, links, and fence, so they are dropped;
        # everything between is the author's prose, verbatim, interior blank lines
        # included. Writer refuses to emit a description that is not already in
        # that shape, which is what makes this normalization one the round trip
        # cannot lose bytes to.
        #
        # A link line lifted out of the middle of the prose leaves the blank lines
        # that surrounded it behind, so prose either side of one comes back with a
        # blank run one longer. Squeezing blank runs would fix the cosmetics and
        # silently edit an author's deliberate paragraph spacing; leaving them is
        # stable under a second pass, which is what the round trip actually needs.
        def description
          @prose.drop_while(&:empty?).reverse.drop_while(&:empty?).reverse.join("\n")
        end

        def add_link(number, link)
          kind = link[:kind]
          field = LINK_FIELDS.fetch(kind) { refuse_kind!(number, kind) }
          refuse_repeat!(number, kind) if @links.key?(field)
          @links[field] = targets(number, link, field)
        end

        def targets(number, link, field)
          ids = link[:value].scan(LINK_ID).flatten
          refuse_unbackticked!(number, link) if ids.empty?
          return ids unless SINGULAR_LINKS.include?(field)

          refuse_plural!(number, link, ids) unless ids.one?
          ids.first
        end

        def refuse_kind!(number, kind)
          raise MalformedDocument, format(UNKNOWN_LINK, number:, kind:, why: DERIVED_LINKS.fetch(kind, ""),
                                                        writable: WRITABLE_LINKS)
        end

        def refuse_repeat!(number, kind)
          raise MalformedDocument, "line #{number}: a second `#{kind}:` line for issue #{@heading[:id].inspect} " \
                                   "-- one line per kind, or whichever came last would silently win"
        end

        def refuse_unbackticked!(number, link)
          raise MalformedDocument, "line #{number}: `#{link[0]}` names no backticked issue id " \
                                   "(ids are written `like this`)"
        end

        def refuse_plural!(number, link, ids)
          raise MalformedDocument, "line #{number}: `#{link[:kind]}:` names one issue id, got " \
                                   "#{ids.map(&:inspect).join(", ")}"
        end

        def refuse_second_fence!(number)
          return if @criteria.nil?

          raise MalformedDocument, "line #{number}: issue #{@heading[:id].inspect} already carries a " \
                                   "```#{GHERKIN_TAG} criteria fence (opened at line #{@criteria_line})"
        end

        # An issue body has exactly one slot for a fenced block, and it is the
        # criteria. A ```ruby fence read as prose could not be written back (the
        # description rules refuse a fence), so refusing it here is what keeps
        # "everything that parses, emits" true.
        def refuse_foreign_fence!(number, source)
          return if source.lines.first.to_s.strip.delete_prefix(FENCE).split.first == GHERKIN_TAG

          raise MalformedDocument, "line #{number}: only a ```#{GHERKIN_TAG} fence may sit in an issue body " \
                                   "(this one opens #{source.lines.first.to_s.strip.inspect})"
        end
      end

      # One issue as the document's four sections, in a fixed order. Refuses --
      # rather than mangles -- a value the grammar cannot write back: a document
      # that parsed to a different digest than the graph it came from would be a
      # silent edit of the author's epic, which is the one failure this unit
      # exists to prevent.
      class Writer
        def initialize(issue)
          @issue = issue
        end

        def to_s = [heading, description, links, criteria].reject(&:empty?).join("\n\n")

        private

        attr_reader :issue

        def heading = "### [#{STATUS_MARKS.fetch(issue.status)}] `#{issue.id}` #{issue.title}"

        def description
          refuse!(DESCRIPTION_RULES, "description", issue.description)
          issue.description
        end

        # The stored source carries the closing fence line's own line break and
        # the section join supplies the blank line, so exactly one terminator is
        # chomped here.
        def criteria
          return "" if issue.criteria.nil?

          refuse!(CRITERIA_RULES, "criteria", issue.criteria)
          issue.criteria.chomp
        end

        def links = LINK_FIELDS.filter_map { |kind, field| link_line(kind, field) }.join("\n")

        def link_line(kind, field)
          ids = targets(field)
          "#{kind}: #{ids.map { |id| "`#{id}`" }.join(", ")}" unless ids.empty?
        end

        # SINGULAR_LINKS names which fields hold one id, so the arity question is
        # answered by the same constant the parse consults rather than by asking
        # the value what it looks like.
        def targets(field)
          value = issue.public_send(field)
          SINGULAR_LINKS.include?(field) ? [value].compact : value
        end

        def refuse!(rules, field, value)
          broken = rules.find { |_message, predicate| predicate.call(value) }
          return if broken.nil?

          raise MalformedDocument, "issue #{issue.id.inspect} #{field} #{broken.first} (got #{value.inspect})"
        end
      end
    end
  end
end
