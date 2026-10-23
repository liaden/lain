# frozen_string_literal: true

# A replacement renders inside the recap frame; a spec about what the strategy
# wrote reads its text with the frame set aside, whatever position it holds.
module RecapText
  module_function

  # @param content [Array<Hash>] a message's content blocks
  # @return [Array<String>] each block's text, less the recap preamble and end tag
  def unframed(content)
    frame = [Lain::Compaction::Recap::PREAMBLE, Lain::Compaction::Recap::CLOSING]
    content.map { |block| block["text"] }.reject { |text| frame.include?(text) }
  end
end
