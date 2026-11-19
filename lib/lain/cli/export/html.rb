# frozen_string_literal: true

require "erb"
require "json"

module Lain
  module CLI
    class Export
      # One self-contained HTML page of the turn chain the head ends on. Every
      # string goes through `html_escape`, so a tool result shaped like markup
      # is shown as text.
      class Html
        TEMPLATE = File.join(__dir__, "template.html.erb")

        # @param records [Array<Hash>] applied records, in file order
        # @param redactions [Journal::Projection::Redactions] the counts the footer prints
        # @param home [String, nil] written as `~` wherever it appears
        # @param root [String, nil] the project root, written as `<project>`
        # @param secrets [#to_a] values masked wherever they appear, whether or not a read ever masked them
        def initialize(records:, redactions:, home: nil, root: nil, secrets: [])
          @records = records
          @redactions = redactions
          @secrets = secrets
          @blocks = {}.compare_by_identity
          @released = redactions.released
          @prefixes = prefixes([[root, "<project>"], [home, "~"]])
        end

        # @return [Boolean] whether the page would show no turn, whatever turn records exist
        def empty? = rows.none? { |row| row["type"] == "turn" }

        # @return [Integer] regions masked as placeholders: the session's own plus the known values found here
        def masked = @redactions.masked + shown.fresh

        # @return [String]
        def render = ERB.new(File.read(TEMPLATE), trim_mode: "-").result(binding)

        private

        def rows
          @records.filter_map do |record|
            case record["type"]
            when "turn" then record if chain.include?(record["digest"])
            when "compaction_cut" then { "type" => "cut" }
            end
          end
        end

        def chain
          @chain ||= follow(head, @records.select { |r| r["type"] == "turn" }.to_h { |r| [r["digest"], r["parent"]] })
        end

        def head
          @records.reduce(nil) do |tip, record|
            case record["type"]
            when "turn" then record["digest"]
            when "rewound" then record["to"]
            else tip
            end
          end
        end

        def follow(digest, parents)
          digest.nil? ? [] : [digest, *follow(parents[digest], parents)]
        end

        def regions(count) = "#{count} #{"region".pluralize(count)}"
        def were(count) = count == 1 ? "was" : "were"

        # Memoized by content so the block a row renders is the one {#shown} masked.
        def blocks(content)
          @blocks[content] ||= (content.is_a?(Array) ? content : [content]).map do |block|
            block.is_a?(Hash) ? block : { "type" => "text", "text" => block.to_s }
          end
        end

        def block_text(block) = shown.text(block)

        # Every piece masks as one transcript, so a region reads the same wherever it stands and the
        # numbers run across the page. It follows the path scrub, or a random directory name reads as a secret.
        def shown = @shown ||= Shown.new(pieces, @secrets)

        def pieces
          rows.select { |row| row["type"] == "turn" }.flat_map { |row| blocks(row["content"]) }
              .map { |block| [block, scrubbed(raw_text(block))] }
        end

        def raw_text(block)
          case block["type"]
          when "text" then block["text"].to_s
          when "tool_use" then "#{block["name"]} #{JSON.generate(block["input"])}"
          when "tool_result" then result_text(block["content"])
          else omitted(block)
          end
        end

        def result_text(content)
          blocks(content).map { |part| part["type"] == "text" ? part["text"] : omitted(part) }.join
        end

        def omitted(block) = "[omitted: #{block["type"]}]"

        def scrubbed(text) = @prefixes.reduce(text.to_s) { |out, (prefix, label)| out.gsub(prefix, label) }

        # Both spellings, because a tool reports whichever the OS handed it; longest first so the
        # project root wins over the home it sits under.
        def prefixes(pairs)
          pairs.flat_map { |path, label| spellings(path).map { |spelling| [spelling, label] } }
               .select { |spelling, _| spelling.length >= 2 }
               .sort_by { |spelling, _| -spelling.length }
               .map { |spelling, label| [at_boundary(spelling), label] }
        end

        def spellings(path)
          return [] if path.nil?

          [path.to_s, File.realpath(path.to_s)].uniq
        rescue SystemCallError
          [path.to_s]
        end

        def at_boundary(spelling) = /(?<![^\s"'=(:])#{Regexp.escape(spelling.chomp("/"))}(?![\w.@+-])/

        def h(value) = ERB::Util.html_escape(value)

        # The pieces of a page masked together, and how many regions that masked.
        class Shown
          # @return [Integer] placeholders the masking added
          attr_reader :fresh

          # @param pieces [Array<Array(Hash, String)>] each block with the text it renders
          # @param secrets [#to_a]
          def initialize(pieces, secrets)
            masked = Sensitivity::TextMask.transcript(pieces.map(&:last), secrets:)
            @texts = pieces.map(&:first).zip(masked).each_with_object({}.compare_by_identity) { |(b, t), by| by[b] = t }
            @fresh = count(masked) - count(pieces.map(&:last))
          end

          # @param block [Hash]
          # @return [String] the text of a block this was built over
          def text(block) = @texts.fetch(block)

          private

          def count(texts) = texts.sum { Sensitivity::Regions.placeholders(_1) }
        end
      end
    end
  end
end
