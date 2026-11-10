# frozen_string_literal: true

require "json"

module TestMap
  # Never requires lain: the commit hook runs before `rake compile` has built lain.so.
  class Map
    class Incomplete < StandardError; end

    GLOB_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB

    def self.build(raw_dir, expected:, tree:)
      boot = {}
      specs = {}
      Dir.glob(File.join(raw_dir.to_s, "*.ndjson")).each do |file|
        File.foreach(file) { |text| absorb(JSON.parse(text), boot, specs) }
      end
      missing = expected - specs.keys
      raise Incomplete, "no record for: #{missing.sort.join(", ")}" unless missing.empty?

      new(tree:, boot: boot.transform_values(&:sort), specs:)
    end

    def self.absorb(record, boot, specs)
      if record.key?("boot")
        union_spans(boot, record["boot"])
      else
        entry = (specs[record.fetch("spec")] ||= blank_entry)
        fold_entry(entry, record)
      end
    end

    def self.blank_entry
      { "lines" => {}, "methods" => {}, "reads" => [], "globs" => [], "ext" => [], "spawns" => [],
        "lain_child" => false, "tree_reader" => false }
    end

    def self.fold_entry(entry, record)
      record.fetch("lines", {}).each { |path, hits| entry["lines"][path] = ((entry["lines"][path] || []) | hits).sort }
      union_spans(entry["methods"], record.fetch("methods", {}))
      %w[reads globs ext spawns].each { |key| entry[key] |= record.fetch(key, []) }
      %w[lain_child tree_reader].each { |key| entry[key] ||= record.fetch(key, false) }
    end

    def self.union_spans(into, from)
      from.each { |path, spans| into[path] = ((into[path] || []) | spans).sort }
    end

    def self.from_h(hash) = new(tree: hash.fetch("tree"), boot: hash.fetch("boot"), specs: hash.fetch("specs"))

    attr_reader :tree

    def initialize(tree:, boot:, specs:)
      @tree = tree
      @boot = boot
      @specs = specs
    end

    def to_h = { "tree" => @tree, "boot" => @boot, "specs" => @specs }

    def merge(other) = self.class.new(tree: @tree, boot: @boot, specs: @specs.merge(other.specs_hash))

    def specs_running(path, lines)
      first, last = lines.minmax
      return [] if first.nil?

      matching do |entry|
        entry["lines"].fetch(path, []).any? { |hit| hit.between?(first, last) } ||
          overlapping?(entry["methods"].fetch(path, []), first..last)
      end
    end

    def specs_running_file(path) = matching { |entry| entry["lines"].key?(path) || entry["methods"].key?(path) }

    def boot_method?(path, span) = overlapping?(@boot.fetch(path, []), span)

    def specs_reading(path)
      matching do |entry|
        entry["reads"].include?(path) || entry["globs"].any? { |glob| File.fnmatch?(glob, path, GLOB_FLAGS) }
      end
    end

    def specs_calling(constants) = matching { |entry| entry["ext"].intersect?(constants.to_a) }

    def specs_spawning(binary) = matching { |entry| entry["spawns"].include?(binary) }

    def lain_child_specs = matching { |entry| entry["lain_child"] }

    def tree_reader_specs = matching { |entry| entry["tree_reader"] }

    def covers?(path)
      @boot.key?(path) || @specs.each_value.any? { |entry| entry["lines"].key?(path) || entry["methods"].key?(path) }
    end

    protected

    def specs_hash = @specs

    private

    def matching(&block) = @specs.select { |_, entry| yield entry }.keys.sort

    # A span's last line is part of it, so a Range here is read as inclusive.
    def overlapping?(spans, range)
      spans.any? { |from, to| from <= range.last && to >= range.first }
    end
  end
end
