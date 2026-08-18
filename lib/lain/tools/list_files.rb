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

      # Hoisted out of the reject block below: FNM_DOTMATCH yields these for every
      # directory the glob walks, so a literal there allocates once per entry.
      DOTS = %w[. ..].freeze

      class << self
        # A pure function of the resolved path. Public and class-level so
        # {Middleware::WithholdSecretPaths} can recognize this exact sentinel
        # STRUCTURALLY -- by rebuilding it from this one definition and
        # comparing -- rather than by matching words inside it, which is
        # what let an empty listing under a gated directory get misread as a
        # withheld path (T7's own regression). See {Tools::WebSearch}'s
        # not_configured_message for the template this follows.
        def empty_message(path)
          "list_files: #{path.inspect} is empty -- no entries."
        end
      end

      def name = "list_files"

      def description
        "Lists the entries of a directory at the given path, one per line, " \
          "sorted. Set recursive: true to descend into subdirectories. " \
          "Returns an error result if the path does not exist, is not a " \
          "directory, or cannot be read. An empty directory is not an error " \
          "-- the result names it as empty rather than returning blank content."
      end

      # Audited: reads Session#worker_env.cwd (a value read, not a mutation) to
      # resolve the path, then only the filesystem (Dir.glob, File.exist?/
      # directory?/readable?). No Session write, and never a chdir -- no
      # process-global state.
      def parallel_safe? = true

      protected

      def perform(input, invocation)
        # A relative path resolves against the session's WorkerEnv cwd (Dir.pwd
        # under the default, so byte-identical to the pre-WorkerEnv listing); an
        # absolute one is honored as given. Entries stay relative to the
        # resolved root, so the model-visible listing is unchanged either way.
        path = File.expand_path(input.path, session_of(invocation).worker_env.cwd)
        problem = problem_with(path)
        return Tool::Result.error(problem) if problem

        listing = entries(path, input.recursive)
        Tool::Result.ok(listing.empty? ? self.class.empty_message(path) : listing.join("\n"))
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
           .reject { |entry| DOTS.include?(File.basename(entry)) }
           .map { |entry| entry.delete_prefix("#{path}/") }
           .sort
      end
    end
  end
end
