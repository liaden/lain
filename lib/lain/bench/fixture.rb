# frozen_string_literal: true

require "yaml"

module Lain
  module Bench
    # The file-level gate every committed bench fixture goes through: absent and
    # unparseable are two different mistakes, and each names the path, so the
    # exe presents either without a backtrace. Structure checks stay per sweep.
    module Fixture
      # A checkout or packaging mistake, never user input to refuse.
      class Missing < Lain::Error; end

      # A fixture that exists but is not YAML: a bug in the file to surface, never a skip.
      class Malformed < Lain::Error; end

      # @param path [String]
      # @param kind [String] what the file is, for the message ("arm-task fixture")
      # @return [Object] the parsed document
      # @raise [Missing, Malformed]
      def self.yaml(path, kind:)
        YAML.safe_load_file(existing!(path, kind:))
      rescue Psych::Exception => e
        raise Malformed, "#{kind} at #{path} is not valid YAML: #{e.message}"
      end

      # @param path [String]
      # @param kind [String]
      # @return [String] path, unchanged
      # @raise [Missing]
      def self.existing!(path, kind:)
        raise Missing, "no #{kind} at #{path}" unless File.file?(path)

        path
      end
    end
  end
end
