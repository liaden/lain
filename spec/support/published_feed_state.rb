# frozen_string_literal: true

# A complete StatusFeed state: the 3 keys every production publish carries, at
# the values a fresh feed has, under whatever an example sets. A fixture that
# hand-writes a partial state would be refused by Reading, which reads them
# without a fallback.
module PublishedFeedState
  DEFAULTS = { "inbox_count" => 0, "derivation_refusal_streak" => 0, "window_guessed" => nil }.freeze

  def self.build(state = {}) = DEFAULTS.merge(state.transform_keys(&:to_s))
end
