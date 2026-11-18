# frozen_string_literal: true

# .lain/summarizers.rb. A summarizer is plain Ruby: no model call and no IO.
# The first declared summarizer that says `suitable?` wins.

summarizer "rspec" do
  def suitable?(result) = result.tool_name == "bash" && result.text.include?("examples,")

  def compact(result) = result.text.lines.grep(/examples,|^rspec /).join
end
