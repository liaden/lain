# frozen_string_literal: true

module Lain
  module Grader
    # Ranked hits arrive as bare ids or as anything answering #id (a
    # Memory::Manifest::Hit, a BM25 hit); the graders compare them as strings.
    module Hits
      def self.id_of(hit) = (hit.respond_to?(:id) ? hit.id : hit).to_s.-@
    end
  end
end
