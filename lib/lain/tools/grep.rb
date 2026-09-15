# frozen_string_literal: true

module Lain
  module Tools
    # Tier 1 (structured): searches file contents for a pattern, with no
    # subprocess -- so there is no command string for the model to control and
    # no approval gate. This is the tool that keeps "grep for X" off the tier-3
    # `bash` path, where a free-form `grep -r ...` would sit behind
    # {Middleware::Gate}. An invalid pattern is reported as an error
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
    #     {Files.walk}, because a depth-first walk with sorted
    #     entries yields paths in exactly the order you get by sorting their
    #     COMPONENT ARRAYS. It is left out because it would change which
    #     matches today's in-process callers get. Pinned as a witness in
    #     spec/lain/core/grep_parity_spec.rb rather than smoothed over.
    #
    # VCS ignore rules were the other divergence and are RESOLVED in favour of
    # the in-process semantics: the daemon can apply .gitignore/.ignore and
    # Dir.glob cannot, so {CoreSearch} sends `respect_ignores: false`.
    class Grep < Tool
      include Tool::FileTarget

      # Capped, not truncated silently -- {#format_matches} says so in the
      # result content.
      MAX_MATCHES = 200

      # Both paths hand back the same {Tool::Bounds::Found} inside a {Searched}, so
      # {#format_matches} never learns which one ran, and the collect-one-
      # past-the-cap discipline stays inside the path that needs it (see
      # {RubySearch#call}) rather than being re-derived from the rows
      # downstream. Shared with {Tools::AstSearch}, the other tool that caps
      # mid-walk and cannot use {Tool::Bounds::Enumeration} for the reason
      # {Tool::Bounds} itself records.
      WALK_CAP = Tool::Bounds::WalkCap.new(limit: MAX_MATCHES)

      # Two hundred matches is a row cap, and one match inside a minified line
      # is a single row of any size, so the rows also meet a byte ceiling.
      BOUND = Tool::Bounds::Fill.new(
        limit: Tool::Bounds::CEILINGS.fetch("grep"), unit: "matches",
        narrower: ["narrow the pattern or the path",
                   "take a short excerpt of a long line with bash (`grep -oE '.{0,200}PATTERN.{0,200}' FILE`)"]
      )

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

      # What one search arm hands back: the capped rows, and whatever trailer
      # only that arm's walk could write.
      Searched = Data.define(:found, :notices)

      Files = Data.define(:root, :readable, :unreadable)

      # The files under a search target whose NAMES can be read as text, and how
      # many could not. Shared with {AstSearch}, the other tool that walks a
      # tree and prints each hit under its file's name.
      #
      # Every name is read as UTF-8, whatever tag the target arrived with:
      # `Dir.pwd` answers BINARY under a C locale, and a label in that tag cannot
      # be interpolated beside a UTF-8 line. A name whose bytes are not UTF-8 can
      # be neither printed as text nor classified by
      # {Middleware::WithholdSecretPaths}, so the file is skipped -- and
      # counted, because a search that quietly read fewer files reads as a
      # complete answer.
      #
      # Reopened rather than written in the `Data.define` block, whose constants
      # would land on {Grep}.
      class Files
        IGNORED = %w[. .. .git].freeze
        EVERY = ->(_name) { true }
        SKIPPED = "%<count>d %<noun>s skipped: unreadable name"

        # @param path [String] the resolved target, a file or a directory
        # @param keep [#call] whether the walk would search a name at all, asked
        #   before its readability, so only a name it wanted can count as skipped
        # @return [Files]
        def self.under(path, keep: EVERY)
          return new(root: nil, readable: [path].freeze, unreadable: 0) if File.file?(path)

          root = utf8(path)
          names = walk(path).select { |name| keep.call(name) }
          readable, unreadable = names.partition { |name| relative(name, root).valid_encoding? }
          new(root:, readable: readable.sort.freeze, unreadable: unreadable.size)
        end

        # Judged on the part a label prints, never the whole path: a project
        # whose own directory is not UTF-8 still labels `ok.rb` as text.
        def self.relative(name, root) = name.delete_prefix("#{root}/")

        # `**` with FNM_DOTMATCH visits every dotfile, matching {ListFiles}'
        # convention, but also "." and ".." and anything under ".git". The
        # trailing `.sort` in {.under} is a FLAT sort of full paths, which is not
        # the order the daemon walks in -- see the walk-order note on {Grep}. It
        # stays flat deliberately: changing it would change which matches
        # today's callers get back from a capped search.
        def self.walk(path)
          Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH)
             .map { |entry| utf8(entry) }
             .reject { |entry| ignored?(entry) }
             .select { |entry| File.file?(entry) }
        end

        # Split as bytes, since a name that is not UTF-8 raises out of a text
        # split -- and one under `.git` is not searched, so it is not skipped.
        def self.ignored?(entry) = entry.b.split("/").intersect?(IGNORED)

        def self.utf8(name) = String.new(name, encoding: Encoding::UTF_8)
        private_class_method :walk, :ignored?, :utf8

        # A DIRECTORY target labels hits relative to the walked root; a
        # SINGLE-FILE target labels them with `display`, the model's own
        # spelling, so a relative `README.md` stays `README.md:1:` rather than
        # leaking the WorkerEnv-resolved absolute path.
        def label(file, display) = root ? Files.relative(file, root) : display

        def notices
          return [] if unreadable.zero?

          [format(SKIPPED, count: unreadable, noun: unreadable == 1 ? "file" : "files")]
        end
      end

      # A matched line, read as bytes and tagged UTF-8 whatever the locale: a
      # bare read tags it with `Encoding.default_external`, US-ASCII under
      # `LC_ALL=C`, where every non-ASCII line failed to decode and ended its
      # file without a word.
      #
      # A line that is not UTF-8 is still searched, and returned with each
      # invalid byte written as `\xNN`. The escape is display only: the pattern
      # matches the line with its invalid bytes replaced by U+FFFD, so searching
      # for `xE9` never finds the escape it printed, and the valid characters
      # beside a stray byte still match as characters -- `.` is one `é`, never
      # one of its bytes. The one quirk left is that a pattern naming U+FFFD
      # matches a character the file does not contain.
      module Line
        ESCAPE = "\\x%02X"

        def self.match?(regex, line) = regex.match?(line.valid_encoding? ? line : line.scrub)

        def self.text(line)
          return line if line.valid_encoding?

          line.scrub { |bad| bad.bytes.map { format(ESCAPE, _1) }.join }
        end
      end

      # The default, and the tool's tier-1 claim in full: Dir.glob and
      # File.foreach, no subprocess and no boundary.
      #
      # An {Enumerator} so the MAX_MATCHES+1 pull stops reading files the moment
      # it has enough, rather than scanning every file under `path` before
      # throwing most of the result away.
      class RubySearch
        def call(path, input)
          files = Files.under(path)
          Searched.new(found: WALK_CAP.apply(matching(files, input.path, build_regex(input)).lazy),
                       notices: files.notices)
        end

        private

        def build_regex(input)
          Regexp.new(input.pattern, input.case_insensitive ? Regexp::IGNORECASE : 0)
        end

        # `display` is the model's original spelling, for {Files#label}.
        # {CoreSearch} reproduces both labelling rules.
        def matching(files, display, regex)
          Enumerator.new do |yielder|
            files.readable.each do |file|
              label = files.label(file, display)
              each_matching_line(file, regex) { |line_no, line| yielder << [label, line_no, line] }
            end
          end
        end

        def each_matching_line(file, regex)
          File.foreach(file, encoding: Encoding::UTF_8).with_index(1) do |line, line_no|
            yield(line_no, Line.text(line.chomp)) if Line.match?(regex, line)
          end
        rescue SystemCallError, IOError
          # A file that vanished or denies read between the walk and here --
          # skipped silently, the way a real grep skips what it cannot read
          # rather than aborting over one bad file. Matches already yielded are
          # downstream: this ends the FILE, not the search.
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
          # The daemon's walk reports no skipped names, so this arm writes none.
          Searched.new(found: Tool::Bounds::Found.new(rows:, capped: reply.fetch("capped")), notices: [])
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
          "searches recursively, skipping .git. A line that is not valid UTF-8 " \
          "comes back with each invalid byte written as \\xNN; a file whose name " \
          "is not valid UTF-8 is skipped and counted. Output is capped at " \
          "#{MAX_MATCHES} matches; a capped result says so explicitly rather " \
          "than truncating silently. No " \
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
        # The FILESYSTEM locator. The match LABELS keep the model's original
        # spelling -- see {RubySearch#matching}.
        path = target(invocation, input.path)
        # Asked on THIS side whichever arm runs, so a missing or unreadable
        # target reads identically and costs no round trip. `:either` because
        # grep takes a file or a directory and says so in one sentence.
        problem = problem_with(path, expecting: :either)
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

      # The daemon refusing a pattern its engine cannot compile is the
      # out-of-process spelling of {RubySearch}'s RegexpError, and the only
      # refusal the model can act on. Any OTHER refusal is a bug on THIS side --
      # a param spelled wrong, a daemon too old to know "grep" -- and stays a
      # raise.
      def pattern_refusal(error)
        raise error unless error.message.start_with?("invalid pattern")

        Tool::Result.error(error.message)
      end

      # A skipped name is reported beside the no-match sentence too: "no
      # matches" alone claims files nobody searched.
      def format_matches(searched, input)
        found = searched.found
        return [self.class.no_matches_message(input.pattern, input.path), *searched.notices].join("\n") if
          found.rows.empty?

        trailers = [*(WALK_CAP.notice("matches") if found.capped), *searched.notices]
        rows = found.rows.map { |file, line_no, line| "#{file}:#{line_no}:#{line}" }
        [*BOUND.fit(rows, beside: trailers), *trailers].join("\n")
      end
    end
  end
end
