# frozen_string_literal: true

require "fileutils"
require "pathname"
require "yaml"

module Lain
  module Bench
    class MemorySweep
      # The synthetic project a memory sweep runs over: memory items whose source files held `before`
      # when the items were written and hold `after` now, a standing instruction stored as an item
      # too, probes with an old and a new gold answer, and drift probes whose violation is a
      # substring, so no grader has to judge an answer.
      class Fixture
        # A fixture that cannot be swept, naming the file.
        class Invalid < Error; end

        Source = Data.define(:path, :before, :after)
        Probe = Data.define(:question, :old, :new)
        Drift = Data.define(:question, :violation)
        Entry = Data.define(:id, :description, :body, :sources)

        # @param path [String]
        # @return [Fixture]
        # @raise [Bench::Fixture::Missing, Bench::Fixture::Malformed, Invalid] when missing, not YAML, or no probes
        def self.load(path)
          new(path:, data: Bench::Fixture.yaml(path, kind: "memory sweep fixture"))
        end

        attr_reader :sources, :entries, :probes, :drifts

        def initialize(path:, data:)
          raise Invalid, "memory sweep fixture #{path} is not a YAML mapping" unless data.is_a?(Hash)

          @sources = listed(data, "sources", Source)
          @probes = listed(data, "probes", Probe)
          @drifts = listed(data, "drift", Drift)
          @entries = [*Array(data["items"]), data["instruction"]].compact.map { entry(_1) }
          raise Invalid, "memory sweep fixture #{path} has no probes" if probes.empty?

          sources.each { inside!(path, _1.path) }
        end

        # Writes each source at `before`, records the items against those bytes, then moves the
        # sources to `after`. A fresh {Memory::Staleness} over the root then marks what changed.
        #
        # @param root [String] an empty directory
        # @return [Array<Memory::Item>]
        def materialize(root)
          recorder = Memory::Staleness.new(root:)
          put(root, :before)
          items = entries.map do |entry|
            Memory::Item.new(id: entry.id, description: entry.description, body: entry.body,
                             sources: recorder.record(entry.sources))
          end
          put(root, :after)
          items
        end

        private

        def listed(data, key, kind) = Array(data[key]).map { kind.new(**_1.transform_keys(&:to_sym)) }

        def entry(item) = Entry.new(**item.transform_keys(&:to_sym), sources: Array(item["sources"]))

        def inside!(fixture, source)
          return unless Pathname(source).absolute? || source.split("/").include?("..")

          raise Invalid, "memory sweep fixture #{fixture} names source #{source}, which is not inside the project"
        end

        def put(root, field)
          sources.each do |source|
            path = File.join(root, source.path)
            FileUtils.mkdir_p(File.dirname(path))
            File.write(path, source.public_send(field))
          end
        end
      end
    end
  end
end
