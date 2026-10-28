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
        REDACTIONS = %w[source_masked command_redacted search_redacted].freeze

        # @param records [Array<Hash>] applied records, in file order
        # @param released [Integer] regions the model saw in clear
        # @param home [String, nil] written as `~` wherever it appears
        # @param root [String, nil] the project root, written as `<project>`
        def initialize(records:, released:, home: nil, root: nil)
          @records = records
          @released = released
          @prefixes = prefixes([[root, "<project>"], [home, "~"]])
        end

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

        def masked = @records.sum { |r| REDACTIONS.include?(r["type"]) ? r.fetch("regions") : 0 }

        def regions(count) = "#{count} #{count == 1 ? "region" : "regions"}"

        def blocks(content)
          (content.is_a?(Array) ? content : [content]).map do |block|
            block.is_a?(Hash) ? block : { "type" => "text", "text" => block.to_s }
          end
        end

        def block_text(block)
          scrubbed(
            case block["type"]
            when "text" then block["text"]
            when "tool_use" then "#{block["name"]} #{JSON.generate(block["input"])}"
            when "tool_result" then result_text(block["content"])
            else omitted(block)
            end
          )
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
      end
    end
  end
end
