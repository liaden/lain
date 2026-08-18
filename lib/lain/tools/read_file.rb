# frozen_string_literal: true

module Lain
  module Tools
    # Tier 1 (structured): reads one file's contents by path, whole or through
    # a line window. Direct Ruby, no subprocess -- there is no command string
    # here for the model to control, which is what makes tier 1 the lowest-risk
    # shape (see the plan's "Tool tiers, and where the security boundary is").
    #
    # A missing path, a directory, or an unreadable file is reported as an
    # error {Tool::Result}, never a raise: the model asked a reasonable
    # question and deserves an answer it can act on, not a crashed tool call.
    #
    # == The window, and why completeness is the interesting half
    #
    # `offset`/`limit` exist so a file too large to hand back whole is still
    # reachable. The bytes are the easy part; what matters is what the
    # read-set is told. A window that leaves lines unseen records
    # `complete: false`, so {Tools::EditFile} refuses the edit and says WHY --
    # editing from a window would clobber lines the model never saw -- and the
    # result itself carries one line saying the same thing, so the model learns
    # it before spending a turn on the refusal.
    #
    # A window that covers the whole file records a COMPLETE read, and that is
    # load-bearing rather than a nicety: it is the only path by which a file
    # that cannot be read unwindowed becomes editable at all. {Tools::WriteFile}
    # is not an alternative -- its overwrite contract asks {Lain::Session#read?}
    # too, and it replaces the whole file rather than one span.
    #
    # == The two ceilings, and why there are two
    #
    # A file's contents are a WHOLE ARTIFACT in {Tool::Bounds}' sense: the
    # first N bytes of one are not a partial answer, they are an answer that
    # reads complete and is wrong. So an oversized read is refused and told
    # where to go instead, never truncated.
    #
    # {WHOLE_BOUND} governs the unwindowed read and is decided from `File.size`
    # before the file is opened. {WINDOW_BOUND} governs the bytes a WINDOW
    # hands back, because `limit: 50_000_000` is a whole-artifact read wearing
    # a window's clothes and a bound only one of them could reach would not be
    # a bound.
    #
    # They are deliberately DIFFERENT numbers, and the gap is load-bearing.
    # {Tools::EditFile} accepts a file only after a COMPLETE read, and for a
    # file over {WHOLE_BOUND} the only complete read available is a window that
    # covers it -- so a window ceiling equal to the whole-read ceiling would
    # make every file between them permanently uneditable, which is the exact
    # deadlock this pair of cards exists to avoid. The window ceiling therefore
    # sits above the whole-read one: the unwindowed read is bounded against
    # spending a context window by ACCIDENT, the window against spending one
    # deliberately without limit.
    class ReadFile < Tool
      # 256 KiB for a whole read. Measured against this repository rather than
      # guessed: the largest hand-written file tracked here is 231 KB and the
      # largest source file 113 KB, so nothing a person authored is refused,
      # while the one tracked file above it -- a 659 KB embeddings blob -- is
      # exactly the artifact no whole read should ever hand back. It is also
      # ~65k tokens, already a third of a 200k context for ONE observation.
      #
      # ⚠️ The margin is thinner than it sounds and it is closing:
      # `planning/specs/chunk-review-surface.md` is 213,211 bytes, **81% of
      # this ceiling**, and plan docs are exactly what an agent reads whole.
      # The next one past 262,144 becomes window-only -- still readable and
      # still editable through a full-cover window, but a behaviour change a
      # reader should meet here rather than discover.
      WHOLE_BOUND = Tool::Bounds::Artifact.new(limit: 256 * 1024)

      # 1 MiB for what a window hands back: four times the whole-read ceiling,
      # so every file tracked in this repository stays readable end to end --
      # and therefore editable -- through a window that covers it, while a
      # window over a genuinely unbounded file still meets a wall.
      WINDOW_BOUND = Tool::Bounds::Artifact.new(limit: 1024 * 1024)

      # What a refusal offers that is not a window. Named unconditionally
      # rather than by extension: a second notion of "is this code" would be
      # one more thing to drift, and these tools already refuse what they
      # cannot parse.
      STRUCTURAL = [
        "outline it with code_outline, file_symbols or ast_search",
        "grep it for the lines you actually need"
      ].freeze

      # The route back to an EDITABLE file, offered only when it exists: a
      # window covering the whole file records a complete read, but only if the
      # file is small enough for that window to be admitted. Advice that would
      # itself be refused is a loop, not a move.
      FULL_COVER = "read it with read_file's offset and limit (a window covering the whole file " \
                   "counts as a complete read, so edit_file still accepts it)"

      # What is left to say when even a full-cover window is over the ceiling.
      PART_ONLY = "read part of it with read_file's offset and limit"

      # A window that hands back too much has one obvious narrower form, and
      # naming it is what keeps the model from re-issuing the same call.
      WINDOW_NARROWER = ["narrow the window with a smaller limit or a later offset", *STRUCTURAL].freeze

      # What is left when ONE line is over the ceiling by itself -- a minified
      # bundle, one-line JSON, a binary. No offset and no limit reaches inside
      # a line, so the only narrower read is a byte range, and this tool does
      # not take one.
      #
      # It names a byte COUNT rather than leaving one to be guessed, and the
      # count sits under {Tools::Bash}'s own ceiling. Following this advice
      # steps the model DOWN a ceiling -- 1 MiB here, 128 KiB there -- and onto
      # an approval-gated tier-3 tool, so a `head -c` sized from the number in
      # this message would be refused on arrival.
      LONG_LINE_NARROWER = [
        "take a byte range with bash (`head -c 100000 PATH`, or tail -c, or cut) -- one line alone is over the ceiling",
        *STRUCTURAL
      ].freeze

      # The largest line number an input may name. Not a bound on how much may
      # be READ -- {WHOLE_BOUND} and {WINDOW_BOUND} own that -- but on what a
      # line number can MEAN: past 2^53 a JSON number no longer carries an integer exactly,
      # so the value the model sent and the value we received stop being the
      # same number. It is also what keeps `offset`/`limit` away from Ruby's own
      # allocator, where the failure is a bare `RangeError: bignum too big to
      # convert into 'long'` naming neither the parameter nor a remedy.
      MAX_LINE_NUMBER = (2**53) - 1

      # The wire shape: one required path, and an optional line window.
      class Input < Tool::Input
        field :path, :string, description: "Path to the file to read.", required: true
        field :offset, :integer,
              description: "1-based line number to start reading at. Defaults to the first line."
        field :limit, :integer,
              description: "Maximum number of lines to return, counting from offset. " \
                           "Defaults to the rest of the file."

        # Shape, not safety (see the header of tool/input.rb): a line number
        # below 1 does not name a line, and one above MAX_LINE_NUMBER does not
        # survive the wire. Nothing here is a bound on how much may be read.
        validates :offset, numericality: {
          greater_than_or_equal_to: 1, less_than_or_equal_to: MAX_LINE_NUMBER
        }, allow_nil: true
        validates :limit, numericality: {
          greater_than_or_equal_to: 1, less_than_or_equal_to: MAX_LINE_NUMBER
        }, allow_nil: true
      end

      input_model Input

      # What a read handed back, and whether the model saw the whole file.
      # The two travel together because {Lain::Session#record_read} needs both
      # and neither {Whole} nor {Window} may answer one without deciding the
      # other.
      Read = Data.define(:contents, :complete) do
        # The read-set is the point of tier 1 reads: a later edit-before-write
        # contract asks the session whether this file was read. Only a
        # SUCCESSFUL read counts -- a missing, unreadable or REFUSED path
        # taught the model nothing about the file's contents.
        def deliver(session, path)
          session.record_read(path, complete:)
          Tool::Result.ok(contents)
        end
      end

      # A read refused for size, and the sibling of {Read} rather than a flag
      # on it. It holds the refusal and NOTHING else, so "the refusal carries
      # none of the bytes" is a property of what this object can contain; and
      # because it answers the same message, the branch that refuses cannot
      # reach {Lain::Session#record_read} at all.
      Refused = Data.define(:result) do
        def deliver(_session, _path) = result
      end

      # The unwindowed read: `File.read`, byte for byte what this tool did
      # before a window existed, and complete by construction. Its own object
      # rather than a branch, so the default path cannot drift as the windowed
      # one grows (Null Object, as {Sink::Null} is to {Sink::IOAdapter}).
      class Whole
        # `File.size` FIRST, and that ordering is the whole memory claim: the
        # decision to refuse costs a stat, so a file over the ceiling is never
        # opened, let alone materialised. A post-hoc `File.read(path).bytesize`
        # would produce the same message having already paid the cost the
        # message exists to avoid.
        #
        # But a stat is a DECISION, not a guarantee, and the second read is not
        # belt-and-braces. `File.size` answers a moment before the open, and an
        # appender writing in between handed back 1,309,696 bytes through a
        # 262,144-byte ceiling (measured). So the read itself takes a length:
        # one byte past the ceiling is enough to know it was exceeded, and
        # costs one byte. Cheap first, then correct -- neither alone is both.
        def read(path)
          size = File.size(path)
          return ReadFile.too_large(path, size) unless WHOLE_BOUND.admits?(size)

          contents = capped(path)
          return ReadFile.grew_past(path, contents.bytesize) unless WHOLE_BOUND.admits?(contents.bytesize)

          Read.new(contents:, complete: true)
        end

        # One shared frozen instance, for {Channel::Null}'s reason: it has no
        # state, so every unwindowed read reuses this rather than allocating a
        # fresh reader per call.
        INSTANCE = new.freeze

        # @return [Whole] the shared instance
        def self.instance = INSTANCE

        private

        # `File.read` with a length reads in BINARY and answers nil at EOF, so
        # both are undone here: without the `force_encoding` an ordinary UTF-8
        # file would come back ASCII-8BIT and stop comparing equal to the bytes
        # this tool returned yesterday. Nothing is validated, exactly as
        # `File.read` validates nothing -- an invalid-UTF-8 file keeps its bytes
        # and its invalidity.
        #
        # `+""` and NOT `""`, and the whole difference is one unary plus. This
        # file is `frozen_string_literal`, so a bare literal is frozen while
        # `force_encoding` MUTATES its receiver -- and nil-at-EOF is not an
        # exotic case, it is every zero-length file there is: a `touch`ed .rb,
        # an empty `__init__.py`, a `.keep`. Those raised `FrozenError` past
        # this class's `rescue SystemCallError, IOError` and reached the model
        # as a refusal naming a frozen String. The shared contract table in
        # `spec/support/shared_examples/tier_one_read_contract.rb` is what
        # catches the next one.
        def capped(path)
          (File.read(path, WHOLE_BOUND.limit + 1) || +"").force_encoding(Encoding.default_external)
        end
      end

      # `limit` lines from 1-based `offset`, either bound optional.
      class Window
        # A running byte total with a ceiling, filled from a lazy line stream.
        # It stops at the FIRST line that carries the returned bytes past the
        # ceiling, so an oversized window costs the ceiling plus one line
        # rather than the file -- and because it COUNTS that line, {#size} is
        # the exact size of the exact span {#lines} covers. That is what lets
        # the refusal state a measurement instead of a floor -- a walk that
        # abandoned the crossing line would know only "at least this much".
        #
        # `take_while` rather than `each` with a `break` (house style): the
        # predicate is what accumulates, so the walk stops the instant the
        # ceiling is crossed and nothing after it is read.
        class Budget
          attr_reader :lines, :size

          # @param ceiling [Integer] bytes this window may hand back
          # @param keep [Integer, Float] how many of the lines consumed will
          #   actually be handed back. The one line {Window#bounded} pulls PAST
          #   the window is evidence of a longer file, not payload, so its
          #   bytes are not charged -- otherwise a window sitting exactly on
          #   the ceiling would be refused for a line it never returns.
          def initialize(ceiling, keep: Float::INFINITY)
            @ceiling = ceiling
            @keep = keep
            @lines = []
            @size = 0
          end

          # @param stream [Enumerator::Lazy] the window's lines
          # @return [self]
          def fill(stream)
            stream.take_while do |line|
              charge(line)
              !over?
            end.force
            self
          end

          def over? = size > @ceiling

          private

          def charge(line)
            @size += line.bytesize if @lines.size < @keep
            @lines << line
          end
        end

        # Watches the chunks `File.foreach`'s byte limit hands back and stops
        # the walk at the first one big enough to be a refusal on its own.
        #
        # It exists because that byte limit SPLITS a long line while `offset`
        # and `limit` count LINES. Left to itself, a walk that counted chunks
        # would step over a split boundary and renumber everything after it:
        # measured, on a file whose line 1 was 1.5 MiB, `offset: 2, limit: 3`
        # returned **success** with 512 KB of line 1's tail labelled "lines
        # 2-4", and `offset: 4, limit: 2` returned real lines 3-4 as "lines
        # 4-5" -- a line 5 that does not exist. A wrong answer handed back as a
        # success is the exact outcome {Tool::Bounds}' whole-artifact doctrine
        # exists to prevent, so a file holding such a line refuses the window
        # WHATEVER the offset. That is a real loss (the short lines after a
        # 5 MiB line become unreachable by `read_file`) and it is the honest
        # one: the alternative is rejoining the line to count it, which is the
        # allocation the byte limit was added to avoid.
        #
        # The line NUMBER is right because it counts completed lines rather
        # than chunks: a chunk ending in the separator finishes a line, one
        # that does not is the head of a line still running. So a 512 MiB
        # separatorless file is line 1 however far past its end the offset
        # reached.
        #
        # It also subsumes the predicate this used to ask after the fact
        # ("did the last chunk end in a newline?"), which was one byte away
        # from wrong: a line of exactly the chunk limit INCLUDING its newline
        # arrives whole, and the model was told to narrow a window that had
        # nothing in it to narrow. Any single chunk over the ceiling is the
        # long-line case, terminated or not.
        class LongLine
          # @param ceiling [Integer] bytes a window may hand back
          # @param offset [Integer] the 1-based line the window was asked to
          #   start at, kept so the refusal can say where the offending line
          #   fell RELATIVE to what was asked for
          def initialize(ceiling, offset:)
            @ceiling = ceiling
            @offset = offset
            @number = 1
            @size = nil
          end

          # Passes chunks through until one is over the ceiling, then ends the
          # stream -- so a `drop` for a large offset over a huge line stops at
          # the first chunk instead of reading its way to the offset.
          #
          # @param stream [Enumerator::Lazy]
          # @return [Enumerator::Lazy]
          def through(stream)
            stream.take_while do |chunk|
              note(chunk)
              !found?
            end
          end

          def found? = !@size.nil?

          # "the first N bytes of line M" stays true whether the line was split
          # at N or happens to be exactly N long, which is why one phrasing
          # covers both and neither has to be distinguished.
          def refusal(path)
            Refused.new(result: WINDOW_BOUND.refusal(subject: "the first #{@size} bytes of line #{@number} of #{path}",
                                                     size: @size, narrower:))
          end

          private

          def note(chunk)
            return @size = chunk.bytesize if chunk.bytesize > @ceiling

            @number += 1 if chunk.end_with?("\n")
          end

          # WHERE the offending line fell decides what to advise, and getting
          # that wrong is not cosmetic: a model that asked for line 4990 was
          # being told to `head -c` the START of the file, which is the other
          # end of it.
          #
          # The arithmetic is one fact. A window ending at line M pulls line
          # M + 1 as its completeness probe, so the last window a file with an
          # over-long line at N can serve is one ending at N - 2. From an
          # offset X that is a limit of N - 1 - X, and when that is not at
          # least 1 no window starting at X can be served at all.
          def narrower
            stop = @number - 1 - @offset
            if stop.positive?
              return ["stop the window before line #{@number}: offset #{@offset} with limit at most #{stop}",
                      *STRUCTURAL]
            end
            return [outside_window, *STRUCTURAL] if @number >= 3

            LONG_LINE_NARROWER
          end

          # No window from the requested offset can be served, so this names
          # the one that can -- and says which line is in the way, because the
          # model did not ask to hear about it.
          def outside_window
            "line #{@number} is #{placed} the window you asked for and cannot be walked past -- " \
              "read a window that ends before it: offset 1 with limit at most #{@number - 2}"
          end

          def placed
            return "before" if @number < @offset
            return "at the start of" if @number == @offset

            "just past"
          end
        end

        def initialize(offset:, limit:)
          @offset = offset || 1
          @limit = limit
          freeze
        end

        # ONE line past the window is the entire evidence for "there is more of
        # this file you have not seen", and pulling exactly one is what lets
        # completeness be decided without materialising the file a window
        # exists to avoid materialising -- the same collect-one-past-the-cap
        # discipline {Tools::Grep} uses for MAX_MATCHES. With no `limit` the
        # window runs to EOF, so there is no line past it and completeness
        # rests on `offset` alone.
        #
        # `take(n).force` and NOT `first(n)`, and the difference is not style:
        # `first` RESERVES an Array of n slots before a single line is read
        # (measured: 381 MB of address space at n = 5*10^7), and n here is a
        # number the model chose. `take` reserves nothing and returns the same
        # Array. Under an address-space cap the difference is a `NoMemoryError`,
        # which is not a StandardError -- so it would escape
        # {Effect::Handler::Live}'s rescue and propagate past the loop.
        # The third argument to `File.foreach` is a per-line BYTE limit, and it
        # is what keeps {Budget} from being handed something too big to weigh.
        # A file with no separator in it is ONE line, so `foreach` alone
        # materialises the whole thing before any counter sees a byte --
        # measured at 512 MB peak RSS on a 512 MiB file, and at real scale that
        # is a `NoMemoryError`, which is not a StandardError and so escapes
        # {Effect::Handler::Live}'s rescue and propagates past the loop. The
        # same failure T3's `take` over `first` note describes, by a different
        # route.
        #
        # `+ 1` is what makes a split ALWAYS a refusal. `foreach` never returns
        # a chunk shorter than the limit except at EOF (it runs on to finish a
        # multibyte character rather than cutting one -- measured: 1002 bytes
        # for a limit of 1001 on UTF-8), so a chunk that was split is already
        # over the ceiling. {LongLine} is what turns that into the refusal, and
        # it has to sit BEFORE the `drop`, because `drop` is the thing that
        # would otherwise miscount.
        def read(path)
          watch = LongLine.new(WINDOW_BOUND.limit, offset: @offset)
          lines = watch.through(File.foreach(path, WINDOW_BOUND.limit + 1).lazy).drop(@offset - 1)
          read = @limit ? bounded(lines, path) : to_eof(lines, path)
          # Consulted AFTER the force, because the walk is lazy: nothing has
          # been read at the point the watcher is built. A long line inside the
          # window would also make Budget refuse, and this branch wins on
          # purpose -- its advice is the one that goes anywhere.
          watch.found? ? watch.refusal(path) : read
        end

        private

        def bounded(lines, path)
          budget = Budget.new(WINDOW_BOUND.limit, keep: @limit).fill(lines.take(@limit + 1))
          return refused(budget, path) if budget.over?

          taken = budget.lines
          disclosed(taken.take(@limit), complete: from_the_top? && taken.size <= @limit)
        end

        def to_eof(lines, path)
          budget = Budget.new(WINDOW_BOUND.limit).fill(lines)
          return refused(budget, path) if budget.over?

          disclosed(budget.lines, complete: from_the_top?)
        end

        # It names the span it MEASURED and that span's true size, so the
        # sentence stays true of a window the model may have asked to be far
        # larger: "the window over lines 1-16385 of x.log is 1048640 bytes" is
        # a fact about a prefix, where "the window is 1048640 bytes" would be a
        # guess about a tail nobody read.
        #
        # Getting here means at least TWO lines were charged -- a single chunk
        # over the ceiling is {LongLine}'s case and never reaches this one --
        # so "narrow the window with a smaller limit" always has somewhere to
        # go.
        def refused(budget, path)
          Refused.new(result: WINDOW_BOUND.refusal(
            subject: "the window over #{covered(budget.lines.size)} of #{path}",
            size: budget.size, narrower: WINDOW_NARROWER
          ))
        end

        # A complete window withheld nothing, so it says nothing -- and stays
        # byte-identical to the unwindowed read, which is what lets a window
        # covering the whole file stand in for one.
        #
        # The notice is added AFTER {Budget} has weighed the lines, so a
        # partial window at the ceiling hands back the ceiling plus this one
        # sentence -- ~94 bytes over 1 MiB. Charging it would need the count
        # the notice states, which is not known until the count is final, so
        # the overshoot is bounded and named rather than chased.
        def disclosed(seen, complete:)
          return Read.new(contents: seen.join, complete: true) if complete

          Read.new(contents: "#{terminated(seen.join)}#{notice(seen.size)}", complete: false)
        end

        # In {Tools::Grep}'s register: it names the window and the fact of
        # partialness, never a total -- knowing how many lines the file has
        # would mean reading the whole file, which is the cost a window exists
        # to avoid.
        def notice(count)
          "... window only: #{covered(count)}; the rest of the file was not read, " \
            "so edit_file will refuse it"
        end

        def covered(count)
          return "no lines at or after line #{@offset}" if count.zero?

          "lines #{@offset}-#{@offset + count - 1}"
        end

        # The notice needs a line of its own. A file whose last line has no
        # terminator is the one case where saying so costs a byte the file does
        # not contain, and running the two together would be worse.
        def terminated(text) = text.empty? || text.end_with?("\n") ? text : "#{text}\n"

        def from_the_top? = @offset == 1
      end

      # The refusal an oversized WHOLE read produces. Class-level because
      # {Whole} is a shared frozen instance with no state of its own, and
      # because the conditional half of the advice is a fact about the FILE,
      # not about the reader.
      #
      # @param path [String] the resolved path, as the model spelled it back
      # @param size [Integer] `File.size`, measured before any open
      # @return [Refused]
      def self.too_large(path, size)
        Refused.new(result: WHOLE_BOUND.refusal(subject: path, size:, narrower: narrower_for(size)))
      end

      # @return [Array<String>] the actions that would work on a file this big
      def self.narrower_for(size) = [WINDOW_BOUND.admits?(size) ? FULL_COVER : PART_ONLY, *STRUCTURAL]

      # The refusal for the SECOND check, where the read came back one byte
      # past the ceiling and so the file is bigger than the stat claimed --
      # by an unknown amount. Both halves of the message answer to that. The
      # subject names the PREFIX that was measured rather than asserting a
      # total nobody read, and the advice offers only a partial window: a
      # full-cover one might work and might be refused in turn, and this branch
      # is the one that just learned it cannot trust a size.
      #
      # @param path [String] the resolved path
      # @param size [Integer] bytes actually read, always the ceiling plus one
      # @return [Refused]
      def self.grew_past(path, size)
        Refused.new(result: WHOLE_BOUND.refusal(subject: "the first #{size} bytes of #{path}", size:,
                                                narrower: [PART_ONLY, *STRUCTURAL]))
      end

      def name = "read_file"

      def description
        "Reads a text file at the given path. Reads the whole file by default; pass offset " \
          "(1-based line number) and/or limit (number of lines) to read one window of it instead. " \
          "A window that does not cover the whole file is labelled as partial and does not satisfy " \
          "edit_file's read-before-write requirement -- read the file whole, or window it end to " \
          "end, before editing it. A read is refused rather than truncated when it would hand back " \
          "more than #{WHOLE_BOUND.limit} bytes whole or #{WINDOW_BOUND.limit} bytes through a " \
          "window, and the refusal names what to do instead. Returns an error result if the path " \
          "does not exist, is a directory, or cannot be read."
      end

      # Audited: this tool only reads the filesystem and appends to the
      # Session's read-set (Session::Journaled#record_read is documented
      # fiber-safe, no yield between its check and its mutate -- session.rb).
      # No process-global state: WorkerEnv#cwd is read, never chdir'd.
      def parallel_safe? = true

      protected

      def perform(input, invocation)
        session = session_of(invocation)
        # A relative path resolves against the session's WorkerEnv cwd (Dir.pwd
        # under the default, so byte-identical to a raw File.read); the RESOLVED
        # absolute path is what both the read and the read-set see, so the
        # edit-before-write contract matches on the same file regardless of how
        # the model spelled it.
        path = File.expand_path(input.path, session.worker_env.cwd)
        problem = problem_with(path)
        return Tool::Result.error(problem) if problem

        window_for(input).read(path).deliver(session, path)
      rescue SystemCallError, IOError => e
        Tool::Result.error("could not read #{path}: #{e.message}")
      end

      private

      # A window from line one with no limit IS the whole file, so it takes the
      # whole-file path rather than materialising every line as its own String
      # to reach a byte-identical answer. Not merely wasteful: once the
      # unwindowed read is bounded by size, routing this spelling through
      # {Window} would make it a one-keyword bypass of that bound, at the
      # highest memory cost of the three spellings rather than the lowest.
      def window_for(input)
        return Whole.instance if input.limit.nil? && (input.offset.nil? || input.offset == 1)

        Window.new(offset: input.offset, limit: input.limit)
      end

      # The regular-file check is a MEMORY guard wearing a validation's
      # clothes, and it belongs here because it has to answer before the size
      # does. `File.size` is 0 for a character device and for a fifo, so both
      # sail through {WHOLE_BOUND} -- measured under `ulimit -v`,
      # `read_file /dev/zero` died with `NoMemoryError`, which is not a
      # StandardError and so escapes both the rescue below and
      # {Effect::Handler::Live}'s. A fifo does not even fail: it blocks until
      # somebody writes.
      #
      # `File.file?` and not `File.ftype`, which uses `lstat` and would answer
      # "link" for a symlink to a perfectly ordinary file.
      def problem_with(path)
        return "no such file: #{path}" unless File.exist?(path)
        return "is a directory, not a file: #{path}" if File.directory?(path)
        return "not a regular file (a device, socket or fifo has no size to bound): #{path}" unless File.file?(path)
        return "file is not readable: #{path}" unless File.readable?(path)

        nil
      end
    end
  end
end
