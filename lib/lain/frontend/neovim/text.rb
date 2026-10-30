# frozen_string_literal: true

module Lain
  module Frontend
    class Neovim
      # One line of text for a buffer, however many lines the source held.
      module Text
        # Folded out so a rendered item is ONE line. `\R` is wider than the transport needs --
        # `nvim_buf_set_lines` rejects only `\n` and `\r\n` -- on purpose: a stray CR renders as `^M`
        # and reads as corruption. The transport's narrower refusal is {RenderQueue#checked_lines}.
        NEWLINES = /\R+/

        # ONE line is a contract: a timeline indexes digests by position and the runtime anchors
        # folds at "^%a+:", so a multi-line preview would desynchronize the pins from what is drawn.
        # @param content [Array<Hash>, nil]
        # @return [String] its text on one line, else the block kinds, else "(empty)"
        def self.preview(content)
          text = Array(content).select { |block| block["type"] == "text" }.map { |block| block["text"] }.join(" ")
          return text.gsub(NEWLINES, " ") unless text.empty?

          kinds = Array(content).filter_map { |block| block["type"] }.uniq
          kinds.empty? ? "(empty)" : "(#{kinds.join(", ")})"
        end
      end
    end
  end
end
