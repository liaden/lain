# frozen_string_literal: true

module Lain
  module Chores
    # What became of one chore. `session` is the chat's session file and `sha`
    # the commit it queued; either is nil when the run never got that far.
    Outcome = Data.define(:item, :status, :session, :sha, :note) do
      # @return [Symbol] the {Queue#finish} outcome this status writes
      def finished = status == :failed ? :failed : :done

      # @return [String] the note kept in the chore's line
      def summary = [note, sha, session].compact.join(" ")

      # @return [String] the feed note's body
      def body = status == :failed ? "failed: #{summary}" : summary
    end
  end
end
