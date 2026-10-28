# frozen_string_literal: true

require "json"

module Lain
  module Bench
    # Outranks any inference, because a person looked.
    class Labels
      # @param path [String] a JSONL file, one `{"digest": "...", "label": "...", "by": "..."}` per line
      # @param allowed [Array<String>] the labels a line may carry
      # @return [Labels]
      # @raise [ArgumentError] naming the line, on a line that is not such an object, carries a label outside
      #   `allowed`, or repeats a digest with a different label; or naming the path when it is missing
      def self.load(path, allowed:)
        entries = {}
        File.foreach(path).each_with_index do |line, index|
          record_line(entries, line, index + 1, allowed) unless line.strip.empty?
        end
        new(entries.transform_values(&:first))
      rescue Errno::ENOENT
        raise ArgumentError, "labels file not found: #{path}"
      end

      def self.record_line(entries, line, number, allowed)
        record = parse(line, number)
        label = checked(record["label"], allowed, number)
        seen_label, seen_number = entries[record["digest"]]
        if seen_label && seen_label != label
          raise ArgumentError, "labels digest #{record["digest"]} is labelled #{seen_label.inspect} on line " \
                               "#{seen_number} and #{label.inspect} on line #{number}"
        end
        entries[record["digest"]] ||= [label, number]
      end
      private_class_method :record_line

      def self.parse(line, number)
        record = JSON.parse(line)
        digest = record["digest"] if record.is_a?(Hash)
        return record if digest.is_a?(String) && !digest.empty?

        raise ArgumentError, "labels line #{number} is not an object with a digest"
      rescue JSON::ParserError => e
        raise ArgumentError, "labels line #{number} is not JSON: #{e.message}"
      end
      private_class_method :parse

      def self.checked(label, allowed, number)
        return label if allowed.include?(label)

        raise ArgumentError, "labels line #{number} has label #{label.inspect}, allowed: #{allowed.join(", ")}"
      end
      private_class_method :checked

      def initialize(entries)
        @entries = entries.freeze
        freeze
      end

      # @param digest [String]
      # @return [String, nil]
      def fetch(digest) = @entries[digest]

      # @return [Boolean] false for a Labels no one wrote
      def labelled? = true

      # Answers nil for every digest, and says so itself rather than being compared against.
      class Unwritten < Labels
        def labelled? = false
      end
      private_constant :Unwritten

      NONE = Unwritten.new({})
    end
  end
end
