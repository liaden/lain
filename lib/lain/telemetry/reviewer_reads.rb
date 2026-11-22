# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # A review is keyed by its epic, its issue and the commit it read, so none may be blank.
      class ReviewerReads < Declarative::Carrier
        attribute :epic_slug, :lain_interned
        attribute :issue_id, :lain_interned
        attribute :sha, :lain_interned
        attribute :reads, :lain_canonical
        validates :epic_slug, presence: { message: "must name the epic reviewed, got %<value>s" }
        validates :issue_id, presence: { message: "must name the issue reviewed, got %<value>s" }
        validates :sha, presence: { message: "must name the commit the review read, got %<value>s" }
      end
    end

    # What an implementation reviewer read before it answered: each file a
    # read_file opened, and each bash command that named a path and exited 0.
    # A failed read is left out, so a review whose every read failed records
    # none, and the gate can say its verdict rests on nothing.
    #
    # `epic_slug` is there because the session journals are the project's, and
    # two epics can each hold an issue of the same id.
    #
    # `sha` is the commit the reviewer's checkout was cut from, which is not
    # always the commit the gate is later asked about.
    ReviewerReads = Data.define(:epic_slug, :issue_id, :sha, :reads) do
      include Journalable

      def initialize(epic_slug:, issue_id:, sha:, reads:)
        super(**Carriers::ReviewerReads.settle!(epic_slug:, issue_id:, sha:, reads: reads.map(&:to_s)))
      end
    end
  end
end
