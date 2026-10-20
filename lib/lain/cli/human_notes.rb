# frozen_string_literal: true

module Lain
  module CLI
    # What a line typed while a run is in flight, with nothing asking the human
    # for one, becomes: a note the agent reads in its next request, rather than
    # the next prompt. A slash command keeps its place as the next prompt, since
    # it is addressed to lain and not to the model.
    #
    # Asked only by a producer that has seen nothing is published: a line typed
    # at a parked `human>` or `[y/N]` is that prompt's to answer, and the tool
    # that parked it is running the whole time.
    class HumanNotes
      # The chat that takes no notes: every line is held or answers a prompt.
      module Null
        def self.mailbox = Context::Mailbox::Null
        def self.take?(_line) = false
        def self.pending?(_timeline) = false
      end

      COMMAND = "/"

      # @return [Context::Mailbox::Live] the inbox the agent folds notes from
      attr_reader :mailbox

      # @param mailbox [#post, #pending?] the agent's inbox
      # @param in_flight [#call] whether a model call or a tool is running now
      #   ({Agent#working?}); read at each line
      def initialize(mailbox:, in_flight:)
        @mailbox = mailbox
        @in_flight = in_flight
      end

      # @param line [String]
      # @return [Boolean] true when it queued the line as a note
      def take?(line)
        return false unless note?(line)

        @mailbox.post(from: Tools::AskHuman::HUMAN, text: line)
        true
      end

      # @param timeline [Ext::Timeline] the agent's chain as it stands
      # @return [Boolean] whether a note has not yet reached a request
      def pending?(timeline) = @mailbox.pending?(timeline)

      private

      def note?(line) = !Blankness.blank?(line) && !line.lstrip.start_with?(COMMAND) && @in_flight.call
    end
  end
end
