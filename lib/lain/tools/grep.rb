# frozen_string_literal: true

module Lain
  module Tools
    # Tier 1 (structured): searches file contents for a pattern, in pure
    # Ruby -- no subprocess, so there is no command string for the model to
    # control and no approval gate (see {ReadFile} and the plan's "Tool
    # tiers, and where the security boundary is"). This is the tool that
    # keeps "grep for X" off the tier-3 `bash` path, where a free-form
    # `grep -r ...` command would otherwise sit behind Effect::Handler::Gate.
    #
    # `pattern` is Ruby regex syntax, not a bare literal -- grep's whole
    # value over read_file is "find where this occurs", and a regex is what
    # lets the model ask that without exact-substring recall. An invalid
    # pattern is reported as an error {Result}, never a raise.
    class Grep < Tool
      # The output bound: a pattern matching thousands of lines must not
      # flood the turn. Capped, not truncated silently -- {#format_matches}
      # says so in the result content.
      MAX_MATCHES = 200

      # The wire shape: a required pattern, a required path (a file OR a
      # directory -- a directory is walked recursively), and an optional
      # case-insensitivity flag.
      class Input < Tool::Input
        field :pattern, :string, description: "Regular expression to search for (Ruby regex syntax).",
                                 required: true
        field :path, :string, description: "File or directory to search. A directory is searched recursively.",
                              required: true
        field :case_insensitive, :boolean, description: "Match case-insensitively. Defaults to false."
      end

      input_model Input

      def name = "grep"

      def description
        "Searches file contents for a regular expression pattern (Ruby " \
          "regex syntax). Returns matching lines as file:line plus the " \
          "line text. Given a directory, searches recursively, skipping " \
          ".git and any file that cannot be read as text. Output is capped " \
          "at #{MAX_MATCHES} matches; a capped result says so explicitly " \
          "rather than truncating silently. No matches is an ok, empty " \
          "result, not an error."
      end

      # Audited: reads Session#worker_env.cwd to resolve `path`, then only
      # walks the filesystem (Dir.glob, File.foreach) -- no Session write, no
      # chdir, no shared state across calls.
      def parallel_safe? = true

      protected

      def perform(input, invocation)
        path = resolved_path(input, invocation)
        problem = problem_with(path)
        return Tool::Result.error(problem) if problem

        regex = build_regex(input)
        # One more than the cap is all that is ever pulled off the lazy
        # walk -- enough to know whether the result was capped, without
        # reading a single byte past what the cap needs.
        matches = search(path, input.path, regex).lazy.first(MAX_MATCHES + 1)
        Tool::Result.ok(format_matches(matches))
      rescue RegexpError => e
        Tool::Result.error("invalid pattern #{input.pattern.inspect}: #{e.message}")
      end

      private

      # A relative path resolves against the session's WorkerEnv cwd (Dir.pwd
      # under the default, so byte-identical to the pre-WorkerEnv raw path); an
      # absolute path is honored as given. This is the FILESYSTEM locator; the
      # match LABELS keep the model's original spelling (see {#search}).
      def resolved_path(input, invocation)
        File.expand_path(input.path, session_of(invocation).worker_env.cwd)
      end

      def problem_with(path)
        return "no such file or directory: #{path}" unless File.exist?(path)
        return "not readable: #{path}" unless File.readable?(path)

        nil
      end

      def build_regex(input)
        Regexp.new(input.pattern, input.case_insensitive ? Regexp::IGNORECASE : 0)
      end

      # An Enumerator so the MAX_MATCHES+1 cap above can stop walking the
      # filesystem the moment it has enough, rather than scanning every file
      # under `path` before throwing most of the result away.
      #
      # `path` is the resolved filesystem locator; `display` is the model's
      # original spelling. A DIRECTORY target labels each hit by its path
      # relative to the walked root; a SINGLE-FILE target labels its hits with
      # `display` verbatim -- so a relative `README.md` stays `README.md:1:`
      # rather than leaking the WorkerEnv-resolved absolute path.
      def search(path, display, regex)
        root = path if File.directory?(path)
        Enumerator.new do |yielder|
          files_under(path).each do |file|
            label = root ? file.delete_prefix("#{root}/") : display
            each_matching_line(file, regex) { |line_no, line| yielder << [label, line_no, line] }
          end
        end
      end

      def files_under(path)
        return [path] if File.file?(path)

        Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH)
           .reject { |entry| skip?(entry) }
           .select { |entry| File.file?(entry) }
           .sort
      end

      # `**` with FNM_DOTMATCH visits every dotfile (matching {ListFiles}'
      # convention) but also "." and ".." and anything under ".git" -- none
      # of which is content worth searching.
      def skip?(entry)
        entry.split("/").intersect?(%w[. .. .git])
      end

      def each_matching_line(file, regex)
        File.foreach(file).with_index(1) { |line, line_no| yield(line_no, line.chomp) if regex.match?(line) }
      rescue ArgumentError, SystemCallError, IOError
        # Invalid encoding (binary content) or a file that vanished/denies
        # read between the walk and here -- skipped silently, the same way
        # a real grep skips what it cannot read rather than aborting the
        # whole search over one bad file.
        nil
      end

      def format_matches(matches)
        return "" if matches.empty?

        capped = matches.size > MAX_MATCHES
        lines = matches.first(MAX_MATCHES).map { |file, line_no, line| "#{file}:#{line_no}:#{line}" }
        lines << "... capped at #{MAX_MATCHES} matches" if capped
        lines.join("\n")
      end
    end
  end
end
