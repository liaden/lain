# frozen_string_literal: true

module Lain
  module Telemetry
    # Each claimed record class by the type it journals as, for {Telemetry.read}. The type is read
    # off {Journalable#journal_type} itself, so a record that names its own type is found by that
    # name and a nested record is found at all. A record is claimed when a carrier is named for its
    # type.
    module Readers
      # Constants only where they are defined, so an alias of a class elsewhere is not walked into.
      #
      # @param scope [Module]
      # @return [Array<Class>] the Journalable classes defined under it, nested ones included
      def self.records_under(scope)
        scope.constants(false).map { |name| [name, scope.const_get(name, false)] }
             .select { |name, child| child.is_a?(Module) && child.name == "#{scope.name}::#{name}" }
             .flat_map { |_, child| [*(child if record?(child)), *records_under(child)] }
      end

      def self.record?(child) = child.is_a?(Class) && child.include?(Journalable)
      private_class_method :record?

      # @return [Hash{String=>Class}]
      BY_TYPE = records_under(Telemetry).filter_map do |klass|
        type = klass.allocate.journal_type
        [type, klass] if Carriers.const_defined?(type.camelize, false)
      end.to_h.freeze
    end
  end
end
