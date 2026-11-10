# frozen_string_literal: true

module TestMap
  # @return [String, nil] where this process records its test map, or nil when it does not record
  RECORD_DIR = ENV.delete("LAIN_TEST_MAP_DIR")&.then { |dir| File.expand_path(dir).freeze }
end

if TestMap::RECORD_DIR
  require "coverage"
  Coverage.start(lines: true, methods: true)
end
