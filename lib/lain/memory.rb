# frozen_string_literal: true

module Lain
  # Durable, project-wide memory: one {Memory::ProjectStore} per project, so a
  # fresh chat sees what earlier chats and `lain consolidate` wrote. Retrieval
  # is BM25, vector and the hybrid over both; compaction is a different
  # subsystem with its own records, and neither reads the other.
  module Memory; end
end
