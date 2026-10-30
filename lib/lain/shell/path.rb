# frozen_string_literal: true

module Lain
  module Shell
    # One PATH grammar, so no site can forget that an empty entry is not the cwd.
    module Path
      # @param path [String] a PATH value
      # @return [Array<String>] its directories; an empty entry means the cwd to a shell, so it is dropped
      def self.entries(path) = path.to_s.split(File::PATH_SEPARATOR).reject(&:empty?)

      # Both questions, because `File.executable?` answers true for every directory.
      # @param program [String]
      # @param path [String] a PATH value
      # @param filesystem [#file?, #executable?]
      # @return [String, nil] the first executable file named program on path
      def self.find(program, path:, filesystem: File)
        entries(path).map { |dir| File.join(dir, program) }
                     .find { |file| filesystem.file?(file) && filesystem.executable?(file) }
      end
    end
  end
end
