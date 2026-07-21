# frozen_string_literal: true

module Lain
  module Tools
    # Tier 1 (structured): lists the entries of a directory by path. Direct
    # Ruby, no subprocess -- see {ReadFile} and the plan's "Tool tiers" for why
    # that is the lowest-risk shape.
    class ListFiles < Tool
      # The wire shape: a required path, plus an optional recursion flag.
      class Input < Tool::Input
        field :path, :string, description: "Directory to list.", required: true
        field :recursive, :boolean,
              description: "List nested directories recursively. Defaults to false."
      end

      input_model Input

      def name = "list_files"

      def description
        "Lists the entries of a directory at the given path, one per line, " \
          "sorted. Set recursive: true to descend into subdirectories. " \
          "Returns an error result if the path does not exist, is not a " \
          "directory, or cannot be read."
      end

      # Audited: reads the filesystem only (Dir.glob, File.exist?/directory?/
      # readable?), touches no Session, and never chdirs -- no process-global
      # state.
      def parallel_safe? = true

      protected

      def perform(input, _invocation)
        path = input.path
        problem = problem_with(path)
        return Tool::Result.error(problem) if problem

        Tool::Result.ok(entries(path, input.recursive).join("\n"))
      rescue SystemCallError => e
        Tool::Result.error("could not list #{path}: #{e.message}")
      end

      private

      def problem_with(path)
        return "no such directory: #{path}" unless File.exist?(path)
        return "not a directory: #{path}" unless File.directory?(path)
        return "directory is not readable: #{path}" unless File.readable?(path)

        nil
      end

      # `**` with FNM_DOTMATCH visits the directory itself (as ".") but never
      # loops into "..", so filtering the two dot entries is all that is
      # needed to keep the listing to real children.
      def entries(path, recursive)
        pattern = recursive ? File.join(path, "**", "*") : File.join(path, "*")
        Dir.glob(pattern, File::FNM_DOTMATCH)
           .reject { |entry| %w[. ..].include?(File.basename(entry)) }
           .map { |entry| entry.delete_prefix("#{path}/") }
           .sort
      end
    end
  end
end
