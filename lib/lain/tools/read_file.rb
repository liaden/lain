# frozen_string_literal: true

require_relative "../session"
require_relative "../tool"

module Lain
  module Tools
    # Tier 1 (structured): reads one file's full contents by path. Direct
    # Ruby, no subprocess -- there is no command string here for the model to
    # control, which is what makes tier 1 the lowest-risk shape (see the
    # plan's "Tool tiers, and where the security boundary is").
    #
    # A missing path, a directory, or an unreadable file is reported as an
    # error {Tool::Result}, never a raise: the model asked a reasonable
    # question and deserves an answer it can act on, not a crashed tool call.
    class ReadFile < Tool
      # The wire shape: one required path.
      class Input < Tool::Input
        field :path, :string, description: "Path to the file to read.", required: true
      end

      input_model Input

      def name = "read_file"

      def description
        "Reads the full contents of a text file at the given path. Returns " \
          "an error result if the path does not exist, is a directory, or " \
          "cannot be read."
      end

      protected

      def perform(input, invocation)
        path = input.path
        problem = problem_with(path)
        return Tool::Result.error(problem) if problem

        contents = File.read(path)
        # The read-set is the point of tier 1 reads: a later edit-before-write
        # contract asks the session whether this file was read. Only a SUCCESSFUL
        # read counts -- a missing or unreadable path taught the model nothing.
        session_of(invocation).record_read(path)
        Tool::Result.ok(contents)
      rescue SystemCallError, IOError => e
        Tool::Result.error("could not read #{path}: #{e.message}")
      end

      private

      def problem_with(path)
        return "no such file: #{path}" unless File.exist?(path)
        return "is a directory, not a file: #{path}" if File.directory?(path)
        return "file is not readable: #{path}" unless File.readable?(path)

        nil
      end
    end
  end
end
