# frozen_string_literal: true

# New code, not a port. Upstream's `StreamAccumulator` (218 lines) folds
# `<think>...</think>` tag scanning directly into itself via
# `extract_think_tags`/`consume_think_content`/`consume_non_think_content`/
# `longest_suffix_prefix`, which pushed the class past this project's default
# `Metrics/ClassLength` (100) with no `Metrics/*` loosening allowed. Tag
# scanning across streamed fragments -- tracking whether we are inside a
# `<think>` block and buffering a tag that might be split across two chunks
# -- is a real, separate responsibility from token/tool-call accumulation,
# so it is `Agent::Budget`/`Agent::ToolRunner`-style extracted rather than
# disabled away. Logic and behavior are unchanged from upstream.

module Lain
  class Provider
    module HTTP
      class StreamAccumulator
        # Splits streamed text into visible output and `<think>` content,
        # one fragment at a time. Stateful across calls: a tag split across
        # two fragments (e.g. `<thi` then `nk>`) is buffered rather than lost.
        class ThinkTagScanner
          START_TAG = "<think>"
          END_TAG = "</think>"

          def initialize
            @inside_think_tag = false
            @pending_tag = +""
          end

          # @return [Array(String, String, nil)] [visible_output, thinking_or_nil]
          def call(text)
            remaining = @pending_tag + text
            @pending_tag = +""
            output = +""
            thinking = +""

            remaining = consume(remaining, output, thinking) until remaining.empty?

            [output, thinking.empty? ? nil : thinking]
          end

          private

          def consume(remaining, output, thinking)
            @inside_think_tag ? consume_think(remaining, thinking) : consume_output(remaining, output)
          end

          def consume_think(remaining, thinking)
            end_index = remaining.index(END_TAG)
            return buffer_partial_tag(remaining, END_TAG, thinking) unless end_index

            thinking << remaining.slice(0, end_index)
            @inside_think_tag = false
            remaining.slice((end_index + END_TAG.length)..) || +""
          end

          def consume_output(remaining, output)
            start_index = remaining.index(START_TAG)
            return buffer_partial_tag(remaining, START_TAG, output) unless start_index

            output << remaining.slice(0, start_index)
            @inside_think_tag = true
            remaining.slice((start_index + START_TAG.length)..) || +""
          end

          # Neither branch found its tag in `remaining`: it might be sitting
          # right at the end, split across this fragment and the next, so the
          # longest tag-prefix suffix is held back in `@pending_tag` rather
          # than flushed to `buffer`.
          def buffer_partial_tag(remaining, tag, buffer)
            suffix_len = longest_suffix_prefix(remaining, tag)
            buffer << remaining.slice(0, remaining.length - suffix_len)
            @pending_tag = remaining.slice(-suffix_len, suffix_len)
            +""
          end

          def longest_suffix_prefix(text, tag)
            max = [text.length, tag.length - 1].min
            max.downto(1) { |len| return len if text.end_with?(tag[0, len]) }
            0
          end
        end
      end
    end
  end
end
