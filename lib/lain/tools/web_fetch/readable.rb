# frozen_string_literal: true

require "nokogiri"
require "uri"

module Lain
  module Tools
    class WebFetch < Tool
      # An HTML page reduced to the text a reader would read: page chrome and
      # hidden elements dropped, headings as `#`, list items as `-`, links as
      # their text beside an absolute url, preformatted text verbatim, and prose
      # whitespace collapsed. A fetched page is mostly markup, scripts and
      # navigation, and every byte of that is spent from a window that has room
      # for the article.
      #
      # A fragment in the url narrows the page to the element that id or anchor
      # names -- a heading's section when it names a heading -- because that is
      # the narrower fetch a refusal over the ceiling offers.
      module Readable
        # Raised in place of the parser's own ArgumentError, whose message
        # describes the parser rather than the page.
        class Unparseable < Lain::Error
        end

        # The page has more nodes than the walk will visit.
        class TooMany < Lain::Error
        end

        # The text passed the limit, and the walk stopped there.
        class Overflow < Lain::Error
        end

        # The url's fragment names nothing on the page.
        class Unanchored < Lain::Error
        end

        DROPPED = %w[script style nav aside form noscript svg template iframe].freeze
        # The site's banner and footer, except inside an article, where a
        # header holds the article's own title.
        CHROME = %w[header footer].freeze
        HEADINGS = %w[h1 h2 h3 h4 h5 h6].freeze
        LISTS = %w[ul ol].freeze
        CELLS = %w[td th].freeze
        CODE = %w[code kbd samp].freeze
        BLOCKS = %w[address article blockquote body center dd details div dl dt fieldset figcaption figure
                    header footer hr html main p section summary tbody tfoot thead].freeze
        LINKED = %w[http https].freeze
        # How many section ids a refused fragment lists, and the longest one
        # worth listing: enough to pick from, never a page of its own.
        SUGGESTED = 20
        SUGGESTED_BYTES = 64
        PLAIN_ID = /\A[^\s`\p{C}]+\z/
        SECTIONS = "//*[self::h1 or self::h2 or self::h3 or self::h4 or self::h5 or self::h6 or self::section][@id]"
        EMPTY_PAGE = "[web_fetch: the page has no readable text -- it may build its content with JavaScript; " \
                     "fetch it with raw: true to see the markup]"

        class << self
          # @param html [String] the decoded page
          # @param base_url [String] the url the page was fetched from; links
          #   resolve against it, and its fragment narrows the page
          # @param limit [Integer] bytes of text past which the walk stops
          # @return [String] frozen; a bracketed notice when there is no text
          # @raise [Unparseable] when the page is past a limit the parser keeps
          # @raise [TooMany] when the page has more nodes than the walk visits
          # @raise [Overflow] once the text passes `limit`
          # @raise [Unanchored] when the fragment names nothing on the page
          def call(html, base_url, limit:)
            document = parse(html)
            fragment = fragment(base_url)
            roots, owner = scope(document, fragment)
            text = Page.new(link_base(document, base_url), Writer.new(limit), exempt: owner).render(roots)
            text.empty? ? empty(fragment) : text
          end

          # The charset a page declares in its own markup, read from its first
          # kilobyte by nokogiri's legacy HTML parser, which prescans for one;
          # nil when it declares none.
          #
          # @param bytes [String] the undecoded body
          # @return [String, nil]
          def meta_charset(bytes) = Nokogiri::HTML4(bytes.byteslice(0, 1024)).meta_encoding

          private

          # The parser's limits are depth, attributes per element and errors
          # kept; only the first is about nesting, so only it says so.
          def parse(html)
            Nokogiri::HTML5(html)
          rescue ArgumentError => e
            reason = if e.message.include?("depth") then "nests elements deeper than the HTML parser builds"
                     else "was refused by the HTML parser"
                     end
            raise Unparseable, "the page #{reason} (#{e.message}) -- fetch it with raw: true to read the markup"
          end

          def fragment(base_url)
            raw = URI.parse(base_url).fragment
            URI.decode_uri_component(raw) if raw
          rescue URI::InvalidURIError
            nil
          end

          # The nodes to render, beside the one element that is rendered even
          # if it is of a kind the walk drops, because the model asked for it.
          def scope(document, fragment)
            return [[default_root(document)], nil] unless fragment

            target = document.at_xpath("(//*[@id=$name] | //a[@name=$name])[1]", nil, { "name" => fragment })
            raise Unanchored, unanchored(document, fragment) unless target

            owner = owner(target)
            [section(owner), owner]
          end

          def default_root(document)
            document.at_xpath("//main") || document.at_xpath("//*[@role='main']") || sole_article(document) ||
              document.at_xpath("//body")
          end

          def sole_article(document)
            articles = document.css("article")
            articles.first if articles.one?
          end

          # An anchor inside a heading, or an empty one just before it, marks
          # that heading's section.
          def owner(target)
            heading = target.ancestors.find { |node| HEADINGS.include?(node.name) }
            following = target.next_element
            heading || (following if target.text.strip.empty? && HEADINGS.include?(following&.name)) || target
          end

          # A heading owns what follows it up to the next heading of its rank
          # or higher, which is where a reader's eye takes the section to end.
          def section(target)
            return [target] unless HEADINGS.include?(target.name)

            rank = target.name[1].to_i
            [target, *target.xpath("following-sibling::node()").take_while { |node| !outranked?(node, rank) }]
          end

          def outranked?(node, rank) = HEADINGS.include?(node.name) && node.name[1].to_i <= rank

          def unanchored(document, fragment)
            ids = section_ids(document)
            suggestion = ", or with the id of one of its sections: #{ids.join(", ")}" unless ids.empty?
            "no element with id or name `#{fragment}` on this page -- fetch it without the fragment#{suggestion}"
          end

          # Page-authored text inside an error, so only ids the walk would
          # render and only in a shape that cannot carry a sentence: no
          # whitespace, backticks, control or format characters.
          def section_ids(document)
            nodes = document.xpath(SECTIONS).lazy.reject { |node| [node, *node.ancestors].any? { |one| dropped?(one) } }
            ids = nodes.map { |node| node["id"] }.select { |id| id.bytesize <= SUGGESTED_BYTES && PLAIN_ID.match?(id) }
            ids.first(SUGGESTED).map { |id| "`#{id}`" }
          end

          public

          # Whether the walk drops this node and everything under it: page
          # chrome, what the page hides from its readers, and elements that are
          # not prose at all.
          #
          # @param node [Nokogiri::XML::Node]
          # @return [Boolean]
          def dropped?(node)
            return false unless node.element?

            DROPPED.include?(node.name) || hidden?(node) ||
              (CHROME.include?(node.name) && node.ancestors("article").empty?)
          end

          private

          def hidden?(node) = node.key?("hidden") || node["aria-hidden"].to_s.strip.casecmp?("true")

          # A `<base href>` moves where relative links point, but only to
          # another web address: any other scheme is refused as a link would be.
          def link_base(document, base_url)
            href = document.at_css("base[href]")&.[]("href")
            resolved = URI.join(base_url, href.strip) if href
            LINKED.include?(resolved&.scheme) ? resolved.to_s : base_url
          rescue URI::Error
            base_url
          end

          def empty(fragment)
            return EMPTY_PAGE unless fragment

            "[web_fetch: the element with id or name `#{fragment}` holds no readable text]"
          end
        end

        # The text as it is written: blocks a blank line apart, lines within a
        # block one apart, and a raise the moment the text passes the limit, so
        # a page far over the ceiling costs a walk to the ceiling and no more.
        class Writer
          # Bidi overrides and isolates, zero-width spaces and marks, and the
          # byte-order mark: they change what a human reading the result sees
          # without changing the words. The joiners stay, since emoji and
          # scripts such as Persian need them.
          INVISIBLE = /[\u200B\u200E\u200F\u202A-\u202E\u2060-\u2064\u2066-\u2069\uFEFF]/
          # A line holding nothing but the separators of empty table cells.
          SEPARATORS_ONLY = /\A[|\s]*\z/

          # @param limit [Integer] bytes of text past which {Overflow} is raised
          def initialize(limit)
            @limit = limit
            @out = +""
            @lines = []
            @lines_bytes = 0
            @line = +""
            @prefix = ""
            @serial = 0
          end

          # @param words [String] prose; whitespace runs become one space, and
          #   none opens a line or doubles one already there
          def text(words) = literal(self.class.clean(words))

          # @param content [String] written with its whitespace untouched, after
          #   the same one-space rule where it meets the line
          def literal(content)
            @line << (@line.empty? || @line.end_with?(" ") ? content.lstrip : content)
            overflow! if pending > @limit + 1
          end

          def space = text(" ")

          # Ends the line being written, and starts the next with a prefix.
          def line(prefix = "")
            finish
            @prefix = prefix
          end

          # Ends the block being written.
          def block
            finish
            return if @lines.empty?

            commit(@lines.join("\n"))
            @lines = []
            @lines_bytes = 0
          end

          # A block written as it is, with no whitespace touched.
          def verbatim(content)
            block
            commit(content)
          end

          # Where a link's text starts, so the link can ask what it wrote.
          def mark = [@serial, @line.bytesize]

          # What was written on this line since `mark`, or nil once the line
          # it was taken on has ended.
          def since(mark) = (@line.byteslice(mark.last..) if mark.first == @serial)

          def to_s
            block
            @out.dup.freeze
          end

          # Prose with the invisible characters gone and whitespace collapsed.
          def self.clean(string) = verbatim(string).gsub(/[[:space:]]+/, " ")

          # Content with only the invisible characters gone.
          def self.verbatim(string) = string.gsub(INVISIBLE, "")

          private

          def finish
            written = @line.strip
            unless written.empty? || written.match?(SEPARATORS_ONLY)
              @lines << "#{@prefix}#{written}"
              @lines_bytes += @lines.last.bytesize + 1
            end
            @line = +""
            @prefix = ""
            @serial += 1
          end

          def commit(content)
            @out << "\n\n" unless @out.empty?
            @out << content
            overflow! if @out.bytesize > @limit
          end

          # What the finished text holds at least, give or take the one trailing
          # space a line may yet lose: separators still to come only add to it.
          # A prefix counts once its line has words, since an empty line drops it.
          def pending = @out.bytesize + @lines_bytes + @line.bytesize + (@line.empty? ? 0 : @prefix.bytesize)

          def overflow! = raise(Overflow, "the text passed #{@limit} bytes")
        end

        # The walk over one page, ITERATIVE over an explicit stack: tools run on
        # reactor fibers, whose stack a recursive walk exhausted at ninety-nine
        # nested divs, and SystemStackError is not a StandardError, so nothing
        # between the tool and the loop would have answered it.
        class Page
          # @param base_url [String] what relative links resolve against
          # @param writer [Writer]
          # @param exempt [Nokogiri::XML::Node, nil] rendered even if its kind
          #   is dropped, because it is what the model asked for
          def initialize(base_url, writer, exempt: nil)
            @base_url = base_url
            @writer = writer
            @exempt = exempt
            @inline = 0
            @lists = 0
            @tables = 0
            @cells = [0]
            @visited = 0
          end

          # What entering each element does, by name. Every opener answers
          # either {DONE}, when it has written the element whole and its
          # children are not walked, or a callable run once they have been.
          OPENERS = { "pre" => :preformatted, "br" => :line_break, "a" => :anchor, "li" => :item,
                      "table" => :table, "tr" => :row }
                    .merge(HEADINGS.to_h { |name| [name, :heading] }, CODE.to_h { |name| [name, :code] },
                           LISTS.to_h { |name| [name, :list] }, CELLS.to_h { |name| [name, :cell] },
                           BLOCKS.to_h { |name| [name, :block] })
                    .freeze
          DONE = :done
          # The nodes one walk visits before it refuses. A page of empty
          # elements holds no text for the ceiling to stop at, and at about
          # 5 microseconds a node this caps the reactor stall such a page causes
          # near a second, while an ordinary article has a few thousand.
          WALK_BUDGET = 200_000
          NOTHING = -> {}

          # @param roots [Array<Nokogiri::XML::Node>]
          # @return [String]
          def render(roots)
            stack = roots.reverse.map { |node| [:enter, node] }
            step(stack, *stack.pop) until stack.empty?
            @writer.to_s
          end

          private

          def step(stack, phase, subject)
            return subject.call if phase == :leave

            visit
            return @writer.text(subject.text) if subject.text?
            return unless subject.element? && !dropped?(subject)

            closing = send(OPENERS.fetch(subject.name, :inline), subject)
            return if closing == DONE

            stack.push([:leave, closing])
            subject.children.reverse_each { |child| stack.push([:enter, child]) }
          end

          def visit
            @visited += 1
            return if @visited <= WALK_BUDGET

            raise TooMany, "the page has more than #{WALK_BUDGET} elements and text runs to walk -- fetch it " \
                           "with raw: true to read the markup, or fetch a narrower url"
          end

          # Between blocks in the page's flow, a blank line; inside a list item,
          # a table or a heading, where a line break would break the structure,
          # a space that keeps words apart.
          def flowing? = @inline.zero? && @lists.zero? && @tables.zero?

          def separate = flowing? ? @writer.block : @writer.space

          def inline(_node) = NOTHING

          def block(_node)
            separate
            -> { separate }
          end

          def heading(node)
            return block(node) unless flowing?

            @writer.block
            @writer.line("#{"#" * node.name[1].to_i} ")
            @inline += 1
            lambda do
              @inline -= 1
              @writer.block
            end
          end

          def preformatted(node)
            content = Writer.verbatim(node.text).chomp
            fence = fence_for(content, 3)
            flowing? ? @writer.verbatim("#{fence}\n#{content}\n#{fence}") : @writer.text(" #{content} ")
            DONE
          end

          def code(node)
            content = Writer.verbatim(node.text).gsub(/[\r\n]+/, " ")
            unless content.empty?
              fence = fence_for(content, 1)
              padding = content.start_with?("`") || content.end_with?("`") ? " " : ""
              @writer.literal("#{fence}#{padding}#{content}#{padding}#{fence}")
            end
            DONE
          end

          # One backtick longer than the longest run the content holds, so the
          # page's own backticks can never close the fence early.
          def fence_for(content, least) = "`" * [least, (content.scan(/`+/).map(&:size).max || 0) + 1].max

          def line_break(_node)
            @tables.zero? ? @writer.line : @writer.space
            DONE
          end

          def anchor(node)
            mark = @writer.mark
            target = absolute(node["href"].to_s.strip)
            -> { link(mark, target) }
          end

          def list(_node)
            flowing? ? @writer.block : @writer.line
            @lists += 1
            lambda do
              @lists -= 1
              flowing? ? @writer.block : @writer.line
            end
          end

          def item(_node)
            @writer.line("#{"  " * [@lists - 1, 0].max}- ")
            @inline += 1
            lambda do
              @inline -= 1
              @writer.line
            end
          end

          def table(_node)
            separate
            @tables += 1
            lambda do
              @tables -= 1
              separate
            end
          end

          def row(_node)
            @writer.line
            @cells.push(0)
            lambda do
              @cells.pop
              @writer.line
            end
          end

          def cell(_node)
            @writer.text(" | ") if @cells.last.positive?
            @cells[-1] += 1
            @inline += 1
            -> { @inline -= 1 }
          end

          def link(mark, target)
            written = @writer.since(mark)&.strip
            @writer.text(" (#{target})") if target && written && !written.empty? && written != target
          end

          # nil for a link that leaves nothing to fetch: none at all, one to a
          # place on this same page, or a scheme such as `javascript:`.
          def absolute(href)
            return nil if href.empty? || href.start_with?("#")

            uri = URI.join(@base_url, href)
            uri.to_s if LINKED.include?(uri.scheme)
          rescue URI::Error
            nil
          end

          def dropped?(node) = node != @exempt && Readable.dropped?(node)
        end
      end
    end
  end
end
