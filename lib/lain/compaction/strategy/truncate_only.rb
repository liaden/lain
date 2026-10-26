# frozen_string_literal: true

module Lain
  module Compaction
    module Strategy
      # A span collapses to its own text, cut by fixed rules, with no model call:
      # assistant and human text stay (a human turn up to {HUMAN_CHARS}), a tool
      # call becomes one `[tool] name arguments` line, a tool result is cut to
      # {RESULT_CHARS}. Thinking, images and blank parts are dropped.
      #
      # CUMULATIVE ONLY. A cut that dropped what an earlier cut summarized would
      # have to remove a held replacement, and {Derivation} renders held
      # collapses from their recorded content before the strategy is asked
      # anything, so each cut here covers only the span after the last one and
      # every earlier replacement stays.
      #
      # One block per part, so {#blocks} is the concatenation of a per-message
      # map and the homomorphism laws hold. The parts are not labelled by role:
      # a label is a forgeable `user:` line when a tool result carries one. A
      # failed result alone is marked, because the model must still see it failed.
      class TruncateOnly < Base
        prepend Freezable

        RESULT_CHARS = 500
        ARGUMENT_CHARS = 150
        HUMAN_CHARS = 20_000
        ERROR_MARK = "[tool error]"

        # The whole span, less a trailing tool call whose result lies beyond it:
        # cutting between the two would leave a call the provider rejects.
        def propose_ranges(messages, span:)
          kept = span.to_a.reverse.drop_while { |index| dangling?(messages.fetch(index)) }
          kept.empty? ? [] : [span.first..kept.first]
        end

        def blocks(messages) = messages.flat_map { |message| parts(message) }

        private

        def dangling?(message)
          message.fetch("role") == "assistant" && content(message).any? { |b| b["type"] == "tool_use" }
        end

        def content(message) = message.fetch("content").grep(Hash)

        def parts(message)
          cap = message.fetch("role") == "user" ? HUMAN_CHARS : nil
          content(message).filter_map { |block| text_block(part(block, cap)) }
        end

        def part(block, cap)
          case block["type"]
          when "text" then clipped(block["text"], cap)
          when "tool_use" then call_line(block)
          when "tool_result" then result_line(block)
          end
        end

        def call_line(block)
          "[tool] #{block.fetch("name")} #{clipped(Canonical.dump(block.fetch("input", {})), ARGUMENT_CHARS)}"
        end

        # Scrubbed before the cut: a tool's bytes are not guaranteed UTF-8 and a
        # block that cannot be JSON-encoded would fail the turn that renders it.
        def clipped(text, cap)
          legible = Utf8.legible(text)
          cap ? legible[0, cap] : legible
        end

        def result_line(block)
          body = clipped(result_text(block["content"]), RESULT_CHARS)
          block["is_error"] ? "#{ERROR_MARK} #{body}" : body
        end

        def result_text(body)
          return body.to_s unless body.is_a?(Array)

          body.grep(Hash).filter_map { |block| block["text"] if block["type"] == "text" }.join("\n")
        end

        def text_block(text) = text.blank? ? nil : { "type" => "text", "text" => text }
      end
    end
  end
end
