# frozen_string_literal: true

module Lain
  module Exec
    # What a bash result ends with, so the model reads the tier its call ran under: the line
    # {Confine::Profile#tier_line} words, given a result of its own.
    Sandboxed::Tier = Data.define(:net_enforced) do
      # @param text [String] a result's stderr, or a timeout's message
      # @return [String, nil] its last line when that is a tier line, which a spilled result and a replaced
      #   timeout report carry beside what they show
      def self.last_line(text)
        # Bytewise, because a timeout's report quotes what the command printed, which need not be text.
        text.b[/^\[ran: [^\n]*\]\n\z/]&.force_encoding(Encoding::UTF_8)
      end

      # Left out of the size, which the output ceiling is judged on: it must never move a result across the
      # spill, and a result that spilled still ends with it. A call that timed out ran, so it ends with it too.
      #
      # @param profile [Confine::Profile] what the call ran under
      # @return [Capture] the block's capture, its stderr ending in the line
      # @raise [Timeout] the block's, its message ending in the line, with the block's as its cause
      def over(profile)
        capture = yield
        Capture.new(**capture.to_h, stderr: line(capture.stderr, profile))
      rescue Timeout => e
        raise Timeout, line(e.message, profile), cause: e
      end

      private

      # On a line of its own, or a stderr with no newline would glue it on and hide it from the spill's reader.
      def line(text, profile)
        "#{text}#{"\n" unless text.empty? || text.end_with?("\n")}#{profile.tier_line(net_enforced:)}\n"
      end
    end
  end
end
