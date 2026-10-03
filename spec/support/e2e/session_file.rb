# frozen_string_literal: true

require "json"
require_relative "../wait_until"

module E2E
  # The journal a chat wrote under the sandbox's XDG state, read as the NDJSON it is.
  class SessionFile
    include WaitUntil

    def self.in(sandbox) = new(sandbox.state_home)

    def initialize(state_home)
      @state_home = state_home
    end

    def records(type = nil)
      all = paths.flat_map { |path| File.foreach(path, encoding: "UTF-8").filter_map { |line| parse(line) } }
      type ? all.select { |record| record["type"] == type } : all
    end

    def wait_for(type, timeout: 15, &match)
      found = nil
      wait_until(timeout:, reason: "a #{type} record") do
        found = records(type).find { |record| match.nil? || yield(record) }
      end
      found
    end

    private

    def paths = Dir.glob(@state_home.join("lain", "sessions", "*", "*.ndjson").to_s)

    # A record being written is a partial line, which the next poll reads whole.
    def parse(line)
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end
  end
end
