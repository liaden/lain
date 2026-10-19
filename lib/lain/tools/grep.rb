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
    # The regex is Ruby's own, built with a {REGEX_TIMEOUT}, so a pattern that
    # backtracks without end comes back as an error {Result} rather than a hang.
    class Grep < Tool
      include Tool::FileTarget

      # Capped, not truncated silently -- {#format_matches} says so in the
      # result content.
      MAX_MATCHES = 200

      # Seconds one pattern may spend backtracking on one line.
      REGEX_TIMEOUT = 1

      # The search hands back a {Tool::Bounds::Found} inside a {Searched}, and the
      # collect-one-past-the-cap discipline stays inside it (see
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
              description: "Regular expression to search for.",
              required: true
        field :path, :string, description: "File or directory to search. A directory is searched recursively.",
                              required: true
        field :case_insensitive, :boolean, description: "Match case-insensitively. Defaults to false."
      end

      # What one search arm hands back: the capped rows, and whatever trailer
      # only that arm's walk could write.
      Searched = Data.define(:found, :notices)

      Files = Data.define(:root, :readable, :unreadable, :listed)

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
        EVERY = ->(_name) { true }
        SKIPPED = "%<count>d %<noun>s skipped: unreadable name"

        # @param path [String] the resolved target, a file or a directory
        # @param walk_limit [Tool::Bounds::WalkLimit] the entries the walk may list
        # @param include [Array<String>] ignored files to list anyway, as {FileWalk} reads them
        # @param keep [#call] whether the walk would search a name at all, asked
        #   before its readability, so only a name it wanted can count as skipped
        # @return [Files]
        def self.under(path, keep: EVERY, walk_limit: Tool::Bounds::WalkLimit::DEFAULT, include: [])
          return new(root: nil, readable: [path].freeze, unreadable: 0, listed: 0) if File.file?(path)

          root = utf8(path)
          walk = FileWalk.new(root: path, links: true, entries: walk_limit.entries, include:)
          names = walked(walk).select { |name| keep.call(name) }
          readable, unreadable = names.partition { |name| relative(name, root).valid_encoding? }
          new(root:, readable: readable.sort.freeze, unreadable: unreadable.size, listed: walk.listed)
        end

        # Judged on the part a label prints, never the whole path: a project
        # whose own directory is not UTF-8 still labels `ok.rb` as text.
        def self.relative(name, root) = name.delete_prefix("#{root}/")

        # {FileWalk} lists what git would show, so a repository's ignored build
        # output is never visited. Links come back and are filtered by what they
        # point at, so a link to a file is still searched as it always was.
        def self.walked(walk) = walk.map { |entry| utf8(entry) }.select { |entry| File.file?(entry) }

        def self.utf8(name) = String.new(name, encoding: Encoding::UTF_8)
        private_class_method :walked, :utf8

        # A DIRECTORY target labels hits relative to the walked root; a
        # SINGLE-FILE target labels them with `display`, the model's own
        # spelling, so a relative `README.md` stays `README.md:1:` rather than
        # leaking the WorkerEnv-resolved absolute path.
        def label(file, display) = root ? Files.relative(file, root) : display

        def notices
          return [] if unreadable.zero?

          [format(SKIPPED, count: unreadable, noun: unreadable == 1 ? "file" : "files")]
        end

        # @param limit [Tool::Bounds::WalkLimit]
        # @return [Reads]
        def within(limit) = Reads.new(self, limit)
      end

      # The byte budget of one search, settled from file sizes before any file is
      # read, so its notice does not depend on how far the search pulled.
      class Reads
        def initialize(files, limit)
          @files = files
          @limit = limit
        end

        # @return [Array<String>] files that fit the budget, ending before the first that does not
        def each_file = budget.first

        # @return [Array<String>] the skipped-name notice and whatever limit the search hit
        def notices
          [*@files.notices, *@limit.notice(listed: @files.listed, read_bytes: budget.last)]
        end

        def label(file, display) = @files.label(file, display)

        private

        # The total counts the refused file too, which is what marks a stop.
        def budget
          @budget ||= begin
            total = 0
            admitted = @files.readable.take_while { (total += File.size?(_1).to_i) <= @limit.bytes }
            [admitted, total]
          end
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

      # The tool's tier-1 claim in full: {FileWalk} and File.foreach, no boundary.
      #
      # An {Enumerator} so the MAX_MATCHES+1 pull stops reading files the moment
      # it has enough, rather than scanning every file under `path` before
      # throwing most of the result away.
      class RubySearch
        def initialize(walk_limit, include)
          @walk_limit = walk_limit
          @include = include
        end

        def call(path, input)
          Tool::Offload.call do
            reads = Files.under(path, walk_limit: @walk_limit, include: @include).within(@walk_limit)
            found = WALK_CAP.apply(matching(reads, input.path, build_regex(input)).lazy)
            Searched.new(found:, notices: reads.notices)
          end
        end

        private

        def build_regex(input)
          Regexp.new(input.pattern, input.case_insensitive ? Regexp::IGNORECASE : 0, timeout: REGEX_TIMEOUT)
        end

        # `display` is the model's original spelling, for {Files#label}.
        def matching(reads, display, regex)
          Enumerator.new do |yielder|
            reads.each_file.each do |file|
              label = reads.label(file, display)
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

      def initialize(walk_limit: Tool::Bounds::WalkLimit::DEFAULT, include: [])
        super()
        @search = RubySearch.new(walk_limit, include)
      end

      def name = "grep"

      def description
        "Searches file contents for a regular expression pattern. " \
          "Returns matching lines as file:line plus the line text. Given a directory, " \
          "searches recursively, skipping .git and, inside a git repository, " \
          "files git ignores. A line that is not valid UTF-8 " \
          "comes back with each invalid byte written as \\xNN; a file whose name " \
          "is not valid UTF-8 is skipped and counted. Output is capped at " \
          "#{MAX_MATCHES} matches; a capped result says so explicitly rather " \
          "than truncating silently. No " \
          "matches is an ok result naming the pattern, not an error -- and " \
          "not an empty string."
      end

      # Reads Session#worker_env.cwd to resolve `path`, then walks the
      # filesystem. No Session write, no chdir, no shared state across calls.
      def parallel_safe? = true

      def rerunnable? = true

      protected

      def perform(input, invocation)
        # The FILESYSTEM locator. The match LABELS keep the model's original
        # spelling -- see {RubySearch#matching}.
        path = target(invocation, input.path)
        # `:either` because grep takes a file or a directory and says so in one sentence.
        problem = problem_with(path, expecting: :either)
        return Tool::Result.error(problem) if problem

        Tool::Result.ok(format_matches(@search.call(path, input), input))
      # TimeoutError is a RegexpError, so it must be rescued first.
      rescue Regexp::TimeoutError => e
        Tool::Result.error("pattern #{input.pattern.inspect} hit the #{REGEX_TIMEOUT}s regex timeout: #{e.message}")
      rescue RegexpError => e
        Tool::Result.error("invalid pattern #{input.pattern.inspect}: #{e.message}")
      end

      private

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
