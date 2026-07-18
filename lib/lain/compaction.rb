# frozen_string_literal: true

require_relative "compaction/need"

module Lain
  # WHETHER a compaction is warranted, kept apart from {Context::Compact}
  # (which performs one) and from any later scheduling policy
  # (`cache-aware-compaction.md`'s cache-warmth-aware scheduler, not built
  # yet) that decides WHEN to spend it. {Need} is the detector; today it is
  # this module's only member.
  module Compaction
  end
end
