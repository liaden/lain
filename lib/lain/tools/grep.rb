# frozen_string_literal: true

module Lain
  module Tools
    # Tier 1 (structured): searches file contents for a pattern, with no
    # subprocess -- so there is no command string for the model to control and
    # no approval gate. This is the tool that keeps "grep for X" off the tier-3
    # `bash` path, where a free-form `grep -r ...` would sit behind
    # {Effect::Handler::Gate}. An invalid pattern is reported as an error
    # {Result}, never a raise.
    #
    # TWO SEARCH PATHS, one result shape: the walk runs in this process by
    # default, and a started {Core::Client} sends the same call to the
    # lain-core daemon instead. They are NOT interchangeable, and the
    # differences are behavioural rather than cosmetic:
    #
    #   * REGEX DIALECT. The daemon's engine is finite automata, so it has no
    #     backreferences and no lookaround -- and that absence is what bounds a
    #     pathological pattern. {#description} therefore promises the SUBSET
    #     both paths accept and never names Ruby, because that string is what
    #     the model reads to decide what to send.
    #   * WALK ORDER, AND THEREFORE WHICH MATCHES. Dir.glob sorts ONE flat list
    #     of full paths, where "." (0x2E) sorts before "/" (0x2F); the daemon
    #     sorts per directory during a depth-first walk. Two entries show it:
    #
    #         {a.txt, a/b.txt}  ->  in process: ["a.txt", "a/b.txt"]
    #                               over wire:  ["a/b.txt", "a.txt"]
    #
    #     NOT cosmetic: a search that exceeds {MAX_MATCHES} stops as soon as it
    #     has enough, so the two paths return DIFFERENT SUBSETS of the same
    #     tree, not the same 200 reordered. Decided and left standing. The fix,
    #     if ever wanted, is `.sort_by { |entry| entry.split("/") }` in
    #     {RubySearch#files_under}, because a depth-first walk with sorted
    #     entries yields paths in exactly the order you get by sorting their
    #     COMPONENT ARRAYS. It is left out because it would change which
    #     matches today's in-process callers get. Pinned as a witness in
    #     spec/lain/core/grep_parity_spec.rb rather than smoothed over.
    #
    # VCS ignore rules were the other divergence and are RESOLVED in favour of
    # the in-process semantics: the daemon can apply .gitignore/.ignore and
    # Dir.glob cannot, so {CoreSearch} sends `respect_ignores: false`.
    class Grep < Tool
      # Capped, not truncated silently -- {#format_matches} says so in the
      # result content.
      MAX_MATCHES = 200

      # Both paths hand back the same {Tool::Bounds::Found}, so
      # {#format_matches} never learns which one ran, and the collect-one-
      # past-the-cap discipline stays inside the path that needs it (see
      # {RubySearch#call}) rather than being re-derived from the rows
      # downstream. Shared with {Tools::AstSearch}, the other tool that caps
      # mid-walk and cannot use {Tool::Bounds::Enumeration} for the reason
      # {Tool::Bounds} itself records.
      WALK_CAP = Tool::Bounds::WalkCap.new(limit: MAX_MATCHES)

      # The wire shape: a required pattern, a required path (a file OR a
      # directory -- a directory is walked recursively), and an optional
      # case-insensitivity flag.
      class Input < Tool::Input
        field :pattern, :string,
              description: "Regular expression to search for. Backreferences and lookaround are not supported.",
              required: true
        field :path, :string, description: "File or directory to search. A directory is searched recursively.",
                              required: true
        field :case_insensitive, :boolean, description: "Match case-insensitively. Defaults to false."
      end

      # The default, and the tool's tier-1 claim in full: Dir.glob and
      # File.foreach, no subprocess and no boundary.
      #
      # An {Enumerator} so the MAX_MATCHES+1 pull stops walking the filesystem
      # the moment it has enough, rather than scanning every file under `path`
      # before throwing most of the result away.
      class RubySearch
        def call(path, input)
          WALK_CAP.apply(matching(path, input.path, build_regex(input)).lazy)
        end

        private

        def build_regex(input)
          Regexp.new(input.pattern, input.case_insensitive ? Regexp::IGNORECASE : 0)
        end

        # `path` is the resolved filesystem locator; `display` is the model's
        # original spelling. A DIRECTORY target labels hits relative to the
        # walked root; a SINGLE-FILE target labels them with `display` verbatim,
        # so a relative `README.md` stays `README.md:1:` rather than leaking the
        # WorkerEnv-resolved absolute path. {CoreSearch} reproduces both rules.
        def matching(path, display, regex)
          root = path if File.directory?(path)
          Enumerator.new do |yielder|
            files_under(path).each do |file|
              label = root ? file.delete_prefix("#{root}/") : display
              each_matching_line(file, regex) { |line_no, line| yielder << [label, line_no, line] }
            end
          end
        end

        # The trailing `.sort` is a FLAT sort of full paths, which is not the
        # order the daemon walks in -- see the walk-order note on {Grep}. It
        # stays flat deliberately: changing it would change which matches
        # today's callers get back from a capped search.
        def files_under(path)
          return [path] if File.file?(path)

          Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH)
             .reject { |entry| skip?(entry) }
             .select { |entry| File.file?(entry) }
             .sort
        end

        # `**` with FNM_DOTMATCH visits every dotfile, matching {ListFiles}'
        # convention, but also "." and ".." and anything under ".git".
        def skip?(entry)
          entry.split("/").intersect?(%w[. .. .git])
        end

        def each_matching_line(file, regex)
          File.foreach(file).with_index(1) { |line, line_no| yield(line_no, line.chomp) if regex.match?(line) }
        rescue ArgumentError, SystemCallError, IOError
          # Invalid encoding, or a file that vanished or denies read between
          # the walk and here -- skipped silently, the way a real grep skips
          # what it cannot read rather than aborting over one bad file. Matches
          # already yielded are downstream: this ends the FILE, not the search.
          nil
        end
      end

      # The same search, one msgpack-RPC round trip out of process. The daemon
      # owns the walk, the engine and the cap; this class owns the params it
      # sends and the one label the reply does not spell our way: a FILE target
      # comes back labelled with the `path` param VERBATIM, which is the
      # WorkerEnv-resolved absolute locator rather than the model's spelling,
      # so `input.path` is substituted back.
      class CoreSearch
        # The started {Core::Client} is injected: the caller owns the daemon's
        # lifecycle and its reactor. One round trip per search, and the client
        # demuxes by msgid, which keeps {Grep#parallel_safe?} true here.
        def initialize(client)
          @client = client
        end

        def call(path, input)
          reply = @client.call("grep", [wire_params(path, input)])
          # ONE target means one labelling rule, decided once rather than
          # re-derived -- and re-stat'd -- for each of up to 200 rows.
          under_root = File.directory?(path)
          rows = reply.fetch("matches").map do |match|
            [under_root ? match.fetch("path") : input.path, match.fetch("line_number"), match.fetch("line")]
          end
          Tool::Bounds::Found.new(rows:, capped: reply.fetch("capped"))
        end

        private

        # msgpack has no "absent": a flag the model omitted would ride as nil.
        # Today's daemon happens to read that nil as false (measured), but that
        # is a decoder's incidental behaviour and not the wire contract, so the
        # default is resolved HERE and the wire always carries a bool.
        #
        # `respect_ignores` is sent FALSE explicitly and always, and is not a
        # model-facing input: the daemon can apply .gitignore/.ignore rules and
        # {RubySearch} cannot, so leaving them on would make the same tool
        # answer differently depending on whether a client happened to be wired.
        # SENDING it rather than leaning on the daemon's default is what makes
        # this side's intent auditable on the wire.
        def wire_params(path, input)
          { "pattern" => input.pattern, "path" => path,
            "case_insensitive" => input.case_insensitive || false,
            "respect_ignores" => false }
        end
      end

      class << self
        # Public and class-level so {Middleware::WithholdSecretPaths} can
        # recognize this exact sentinel STRUCTURALLY -- rebuilding it from this
        # one definition and comparing -- rather than by matching words inside
        # it. `path` is the model's own spelling, never the WorkerEnv-resolved
        # locator, matching {RubySearch#matching}'s label rule.
        def no_matches_message(pattern, path)
          "grep: no matches for #{pattern.inspect} in #{path}"
        end
      end

      input_model Input

      # The out-of-process arm is OPTED INTO, because it is a different
      # dialect and a different walk (see the class note), not merely a
      # different wire.
      def initialize(client: nil)
        super()
        @search = client ? CoreSearch.new(client) : RubySearch.new
      end

      def name = "grep"

      def description
        "Searches file contents for a regular expression pattern. " \
          "Backreferences and lookaround are not supported -- write a plain " \
          "regular expression, with no (?=...), (?<=...) or \\1. Returns " \
          "matching lines as file:line plus the line text. Given a directory, " \
          "searches recursively, skipping .git and any file that cannot be " \
          "read as text. Output is capped at #{MAX_MATCHES} matches; a capped " \
          "result says so explicitly rather than truncating silently. No " \
          "matches is an ok result naming the pattern, not an error -- and " \
          "not an empty string."
      end

      # Audited on BOTH paths: reads Session#worker_env.cwd to resolve `path`,
      # then either walks the filesystem or makes one {Core::Client#call},
      # which demuxes concurrent callers by msgid. No Session write, no chdir,
      # no shared state across calls either way.
      def parallel_safe? = true

      protected

      def perform(input, invocation)
        path = resolved_path(input, invocation)
        problem = problem_with(path)
        return Tool::Result.error(problem) if problem

        Tool::Result.ok(format_matches(@search.call(path, input), input))
      rescue RegexpError => e
        Tool::Result.error("invalid pattern #{input.pattern.inspect}: #{e.message}")
      rescue Core::Client::Refused => e
        pattern_refusal(e)
      rescue Core::Died, Core::Client::Stopped => e
        # Boundary death is a tool ERROR, never a raise past the loop: loud,
        # named and immediate.
        Tool::Result.error("lain-core boundary failed: #{e.class}: #{e.message}")
      end

      private

      # The FILESYSTEM locator. The match LABELS keep the model's original
      # spelling -- see {RubySearch#matching}.
      def resolved_path(input, invocation)
        File.expand_path(input.path, session_of(invocation).worker_env.cwd)
      end

      # Asked on THIS side whichever path runs, so a missing or unreadable
      # target reads identically and costs no round trip.
      def problem_with(path)
        return "no such file or directory: #{path}" unless File.exist?(path)
        return "not readable: #{path}" unless File.readable?(path)

        nil
      end

      # The daemon refusing a pattern its engine cannot compile is the
      # out-of-process spelling of {RubySearch}'s RegexpError, and the only
      # refusal the model can act on. Any OTHER refusal is a bug on THIS side --
      # a param spelled wrong, a daemon too old to know "grep" -- and stays a
      # raise.
      def pattern_refusal(error)
        raise error unless error.message.start_with?("invalid pattern")

        Tool::Result.error(error.message)
      end

      def format_matches(found, input)
        return self.class.no_matches_message(input.pattern, input.path) if found.rows.empty?

        lines = found.rows.map { |file, line_no, line| "#{file}:#{line_no}:#{line}" }
        lines << WALK_CAP.notice("matches") if found.capped
        lines.join("\n")
      end
    end
  end
end
