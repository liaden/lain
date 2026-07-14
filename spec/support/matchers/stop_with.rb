# frozen_string_literal: true

# The 122-site `expect(response.stop_reason).to eq(:tool_use)` idiom, phrased
# as `expect(response).to stop_with(:tool_use)` and, on failure, printing the
# whole Response (content block count, tool count) alongside the mismatched
# reason -- the reason alone rarely explains why a turn stopped where it did.
RSpec::Matchers.define :stop_with do |expected_reason|
  match { |response| response.stop_reason == expected_reason }

  failure_message do |response|
    "expected stop_reason #{expected_reason.inspect}, got #{response.stop_reason.inspect} " \
      "(response: #{response.inspect})"
  end

  failure_message_when_negated do |response|
    "expected stop_reason not to be #{expected_reason.inspect}, but it was " \
      "(response: #{response.inspect})"
  end
end
