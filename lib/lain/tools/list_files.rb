# frozen_string_literal: true

module Lain
  module Tools
    # Tier 1 (structured): lists the entries of a directory by path. Direct
    # Ruby, no subprocess. {Glob} carries the note on why no tier-1 tool checks
    # a path and where the secret boundary actually sits.
    class ListFiles < Tool
      include Tool::FileTarget

      # The wire shape: a required path, plus an optional recursion flag.
      class Input < Tool::Input
        field :path, :string, description: "Directory to list.", required: true
        field :recursive, :boolean,
              description: "List nested directories recursively. Defaults to false."
      end

      input_model Input

      # Hoisted out of the reject block: FNM_DOTMATCH yields these for every
      # directory the glob walks, so a literal there allocates once per entry.
      DOTS = %w[. ..].freeze

      # A listing is an ENUMERATION under {Tool::Bounds}' stated boundary: the
      # first N rows ARE a usable partial answer and the model can narrow the
      # path itself, so it caps and discloses in band rather than refusing.
      #
      # Deliberately the SAME 500 as {Glob}, from the same byte budget: the two
      # produce the identical row shape, are read by the identical
      # {Middleware::WithholdSecretPaths::Listing} reader, and a model that
      # learned one tool's ceiling has learned the other's. This one needs it
      # more -- a recursive listing at a repo root walks `.git` and runs to tens
      # of thousands of entries.
      BOUND = Tool::Bounds::Enumeration.new(limit: 500, unit: "paths")

      class << self
        # Public and class-level so {Middleware::WithholdSecretPaths} can
        # recognize this exact sentinel STRUCTURALLY -- rebuilding it from this
        # one definition and comparing -- rather than by matching words inside
        # it, which is what let an empty listing under a gated directory get
        # misread as a withheld path (an observed regression).
        def empty_message(path)
          "list_files: #{path.inspect} is empty -- no entries."
        end
      end

      def name = "list_files"

      def description
        "Lists the entries of a directory at the given path, one per line, " \
          "sorted. Set recursive: true to descend into subdirectories. " \
          "Output is capped at #{BOUND.limit} paths; a capped listing says so " \
          "and names the true entry count rather than truncating silently. " \
          "Returns an error result if the path does not exist, is not a " \
          "directory, or cannot be read. An empty directory is not an error " \
          "-- the result names it as empty rather than returning blank content."
      end

      # Audited: reads Session#worker_env.cwd (a value read, not a mutation) to
      # resolve the path, then only the filesystem. No Session write, and never
      # a chdir -- no process-global state.
      def parallel_safe? = true

      protected

      def perform(input, invocation)
        # Entries stay relative to the RESOLVED root, so the model-visible
        # listing reads the same however the model spelled the path.
        path = target(invocation, input.path)
        problem = problem_with(path, expecting: :directory)
        return Tool::Result.error(problem) if problem

        failing("list", path) do
          listing = entries(path, input.recursive)
          Tool::Result.ok(listing.empty? ? self.class.empty_message(path) : listing.join("\n"))
        end
      end

      private

      # `**` with FNM_DOTMATCH visits the directory itself as "." but never
      # loops into "..", so filtering the two dot entries is all that keeps the
      # listing to real children.
      #
      # {BOUND} is applied at the END of this chain rather than in `#perform`,
      # and the position is the point: `cap` reads the true count off the
      # collection it is handed, after `.sort`, so the surviving rows are
      # decided by the ordering rather than by the walk.
      def entries(path, recursive)
        pattern = recursive ? File.join(path, "**", "*") : File.join(path, "*")
        BOUND.cap(Dir.glob(pattern, File::FNM_DOTMATCH)
                     .reject { |entry| DOTS.include?(File.basename(entry)) }
                     .map { |entry| entry.delete_prefix("#{path}/") }
                     .sort)
      end
    end
  end
end
