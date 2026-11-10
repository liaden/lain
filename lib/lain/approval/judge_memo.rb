# frozen_string_literal: true

module Lain
  module Approval
    # The judge's approvals this session, by exact call, so a repeat is not
    # paid for twice. The key covers the place as the judge was told it, so a
    # changed requester, cwd, classification, fact or request is a new call.
    # Only an approve is kept: a deny or a defer is asked again, since a human
    # or the next answer may differ.
    class JudgeMemo
      CANNOT_KEY = [Canonical::UnsupportedType, Canonical::NonFiniteFloat, Canonical::AmbiguousKey].freeze

      # The memo of a project that turned it off.
      module Off
        # @param _key [String, nil]
        # @return [Boolean] never
        def self.approved?(_key) = false

        # @param _key [String, nil]
        # @return [nil]
        def self.approve(_key) = nil
      end

      # @return [Off] remembers nothing
      def self.off = Off

      # @param tool [String]
      # @param input [Object] digested in its canonical form, so a Symbol and a String key match
      # @param place [Judge::Place] where the judge was told the call runs
      # @return [String, nil] nil when the input has no canonical form
      # Every member of the place, so one added to it later keys apart by default, as it changes the prompt.
      def self.key(tool:, input:, place:)
        texts = { facts: place.facts.to_s, request: place.request&.to_s,
                  classified: place.classified.transform_values(&:to_s) }
        Canonical.digest({ **place.to_h, **texts, tool:, input: })
      rescue *CANNOT_KEY
        nil
      end

      # Guarded, because one memo serves every worker thread's judged rung.
      def initialize
        @approved = Set.new
        @lock = Mutex.new
        freeze
      end

      # @param key [String, nil] a digest of tool, input and place; nil is never remembered
      # @return [Boolean]
      def approved?(key) = @lock.synchronize { @approved.include?(key) }

      # @param key [String, nil] as {#approved?}
      # @return [void]
      def approve(key)
        @lock.synchronize { @approved.add(key) } unless key.nil?
      end
    end
  end
end
