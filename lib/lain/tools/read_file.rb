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
    # The bytes are the easy part; what matters is what the read-set is told. A
    # read records the lines it covered and the file version it saw, so windows
    # over one version add up: {Tools::EditFile} refuses an edit until they
    # cover every line -- editing from a window would clobber lines the model
    # never saw -- and a partial window's result carries one line saying so,
    # ahead of the refusal.
    #
    # Windows adding up is load-bearing: it is the only path by which a file too
    # large to read unwindowed becomes editable at all. {Tools::WriteFile} is not
    # an alternative -- its overwrite contract asks {Lain::Session#read?} too.
    #
    # == The two ceilings, and why there are two
    #
    # A file's contents are a WHOLE ARTIFACT in {Tool::Bounds}' sense: the
    # first N bytes of one are not a partial answer, they are an answer that
    # reads complete and is wrong. So an oversized read is refused and told
    # where to go instead, never truncated.
    #
    # {WHOLE_BOUND} governs the unwindowed read, decided from `File.size`
    # before the file is opened. {WINDOW_BOUND} governs the bytes a WINDOW
    # hands back, because `limit: 50_000_000` is a whole-artifact read wearing
    # a window's clothes.
    #
    # The two numbers DIFFER, and the gap is load-bearing. For a file over
    # {WHOLE_BOUND} the only complete read available is a window covering it,
    # so equal ceilings would make every file between them permanently
    # uneditable. The window ceiling therefore sits above: the unwindowed read
    # is bounded against spending a context window by ACCIDENT, the window
    # against spending one deliberately without limit.
    class ReadFile < Tool
      include Tool::FileTarget

      # 256 KiB for a whole read, measured against this repository rather than
      # guessed: the largest hand-written file tracked here is 231 KB, so
      # nothing a person authored is refused, while the one tracked file above
      # it -- a 659 KB embeddings blob, ~65k tokens -- is exactly the artifact
      # no whole read should hand back.
      #
      # The margin is closing: `planning/specs/chunk-review-surface.md` is
      # 213,211 bytes, 81% of this ceiling, and plan docs are exactly what an
      # agent reads whole. The next one past 262,144 becomes window-only --
      # still readable and editable through a full-cover window, but a
      # behaviour change a reader should meet here rather than discover.
      WHOLE_BOUND = Tool::Bounds::Artifact.new(limit: 256 * 1024)

      # 1 MiB, four times the whole-read ceiling, so every file tracked here
      # stays readable end to end -- and therefore editable -- through a window
      # that covers it, while a genuinely unbounded file still meets a wall.
      WINDOW_BOUND = Tool::Bounds::Artifact.new(limit: 1024 * 1024)

      # Named unconditionally rather than by extension: a second notion of "is
      # this code" would be one more thing to drift, and these tools already
      # refuse what they cannot parse.
      STRUCTURAL = [
        "outline it with file_symbols or ast_search",
        "grep it for the lines you actually need"
      ].freeze

      # Offered only when it exists: a full-cover window records a complete
      # read, but only if the file is small enough for that window to be
      # admitted. Advice that would itself be refused is a loop, not a move.
      FULL_COVER = "read it with read_file's offset and limit (windows that together cover the whole file " \
                   "count as a complete read, so edit_file still accepts it)"

      # For a file past even a full-cover window that still HAS lines a window
      # can land between. One enormous line gets {LONG_LINE_NARROWER} instead,
      # because `offset` and `limit` count lines and cannot narrow it at all.
      PART_ONLY = "read part of it with read_file's offset and limit"

      # Naming the narrower form is what keeps the model from re-issuing the
      # same call.
      WINDOW_NARROWER = ["narrow the window with a smaller limit or a later offset", *STRUCTURAL].freeze

      # ONE line over the ceiling by itself -- a minified bundle, one-line
      # JSON, a binary. No offset or limit reaches inside a line, so the only
      # narrower read is a byte range, which this tool does not take.
      #
      # The byte COUNT is named rather than left to be guessed, and it sits
      # under {Tools::Bash}'s own ceiling: this advice steps the model DOWN a
      # ceiling (1 MiB here, 128 KiB there) onto an approval-gated tier-3 tool,
      # so a `head -c` sized from this number would be refused on arrival.
      LONG_LINE_NARROWER = [
        "take a byte range with bash (`head -c 100000 PATH`, or tail -c, or cut) -- one line alone is over the ceiling",
        *STRUCTURAL
      ].freeze

      # Neither `offset` nor `limit` can make invalid bytes valid, and the
      # structural tools refuse the same file for the same reason, so the
      # advice leaves read_file entirely rather than naming a call that would
      # be refused identically.
      NOT_TEXT_NARROWER = [
        "identify it with bash (`file PATH`)",
        "look at its bytes with bash (`xxd PATH | head`)"
      ].freeze

      # 16 KiB, the block {ReadFile.separator_within?} reads in. Two numbers
      # meet here and neither is the ceiling: what a single refusal may
      # ALLOCATE, and how much of an ordinary file has to be read before a
      # newline turns up. A file with lines in it answers on block one, while a
      # separatorless megabyte is 64 of these read one after another and never
      # held together.
      PROBE_BLOCK = 16 * 1024

      # Not a bound on how much may be READ -- {WHOLE_BOUND} and {WINDOW_BOUND}
      # own that -- but on what a line number can MEAN: past 2^53 a JSON number
      # no longer carries an integer exactly, so the value the model sent and
      # the value received stop being the same number. It also keeps
      # `offset`/`limit` away from Ruby's allocator, where the failure is a bare
      # `RangeError: bignum too big to convert into 'long'` naming neither the
      # parameter nor a remedy.
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

      # They travel together because {Lain::Session#record_read} needs the
      # span and the version the bytes came from, and neither {Whole} nor
      # {Window} may answer one without deciding the others.
      Read = Data.define(:contents, :lines, :identity) do
        # Only a SUCCESSFUL read joins the read-set -- a missing, unreadable or
        # REFUSED path taught the model nothing about the file's contents.
        #
        # Bytes that could never become a turn are refused HERE, the one point
        # both readers pass through and the last that still knows which path
        # produced them. Left alone they reach `Canonical.normalize` on
        # {Timeline#commit}, which raises `UnsupportedType` naming no file and
        # takes the whole ask down with it.
        def deliver(session, path, tool_use_id)
          return ReadFile.not_text(path) unless committable?

          session.record_read(path, lines:, identity:, tool_use_id:)
          Tool::Result.ok(contents)
        end

        # The version was named from the open file before its bytes were read;
        # asked of the same descriptor again now, a different answer means the
        # bytes are of no one version, so they are delivered {Unsettled}.
        #
        # @param file [File] the descriptor the bytes were read from
        # @return [Read, Unsettled]
        def settled(file) = Session::FileIdentity.from_stat(file.stat) == identity ? self : Unsettled.new(read: self)

        # Canonical's UTF-8 rule, restated rather than asked: `normalize`
        # interns what it returns, so asking directly would pay a full-string
        # hash and pin a quarter-megabyte of file contents in the process-wide
        # fstring table on every tier-1 read. A spec reads every byte shape
        # through both, so the copy cannot drift silently.
        #
        # NARROWER than Canonical's on one point, forced by {#deliver} shipping
        # `contents` UNCONVERTED: Canonical admits whatever it can CONVERT, so
        # it would admit a UTF-16 read -- one encoding on the wire to the model
        # and a different one on the Timeline. The sound question for a value
        # nobody converts is whether Canonical would hand back the SAME BYTES:
        # already UTF-8, or ASCII-only under an ASCII-compatible tag.
        #
        # That second arm is not bet-hedging. `Array#join` answers US-ASCII for
        # an EMPTY array, so a complete window over an empty file arrives tagged
        # US-ASCII whatever the read was told to decode. Demanding the UTF-8 tag
        # alone refuses `.keep`, an empty `__init__.py`, and every other
        # zero-length file reached through a window. Public because {Unsettled}
        # hands the same bytes over and has to ask the same question.
        def committable?
          contents.valid_encoding? && (contents.encoding == Encoding::UTF_8 || contents.ascii_only?)
        end
      end

      # The sibling of {Read} rather than a flag on it: it holds the refusal
      # and NOTHING else, so "the refusal carries none of the bytes" is a
      # property of what this object can contain, and the branch that refuses
      # cannot reach {Lain::Session#record_read} at all.
      Refused = Data.define(:result) do
        def deliver(_session, _path, _tool_use_id) = result

        def settled(_file) = self
      end

      # What an {Unsettled} read says in place of being recorded.
      UNSETTLED = "... the file changed while it was being read, so this read does not count toward " \
                  "edit_file; read it again"

      # Bytes read from a file that changed while they were read: whatever the
      # model is shown, no version of the file ever held exactly that, so the
      # read is not recorded, and the result says so rather than letting a
      # later edit refusal claim the file was never read. Not recording it is
      # the one choice that cannot add up with anything.
      Unsettled = Data.define(:read) do
        def deliver(_session, path, _tool_use_id)
          return ReadFile.not_text(path) unless read.committable?

          contents = read.contents
          Tool::Result.ok("#{contents.empty? || contents.end_with?("\n") ? contents : "#{contents}\n"}#{UNSETTLED}")
        end
      end

      # The unwindowed read, complete by construction. Its own object rather
      # than a branch, so the default path cannot drift as the windowed one
      # grows.
      class Whole
        # `File.size` FIRST, and that ordering is the whole memory claim: the
        # decision to refuse costs a stat, so a file over the ceiling is never
        # materialised. A post-hoc `File.read(path).bytesize` would produce the
        # same message having already paid the cost the message exists to avoid.
        #
        # But a stat is a DECISION, not a guarantee. `File.size` answers a
        # moment before the open, and an appender writing in between handed back
        # 1,309,696 bytes through a 262,144-byte ceiling (measured). So the read
        # itself takes a length: one byte past the ceiling is enough to know it
        # was exceeded, and costs one byte. Cheap first, then correct.
        #
        # The version comes from the OPEN descriptor, not the path, so a file
        # renamed over this one after the open cannot lend its name to bytes it
        # never held; {Read#settled} asks the descriptor again afterwards.
        def read(path)
          size = File.size(path)
          return ReadFile.too_large(path, size) unless WHOLE_BOUND.admits?(size)

          File.open(path, "rb") do |file|
            identity = Session::FileIdentity.from_stat(file.stat)
            contents = capped(file)
            return ReadFile.grew_past(path, contents.bytesize) unless WHOLE_BOUND.admits?(contents.bytesize)

            Read.new(contents:, lines: Session::WHOLE_FILE, identity:).settled(file)
          end
        end

        # No state, so every unwindowed read reuses this rather than
        # allocating a fresh reader per call.
        INSTANCE = new.freeze

        # @return [Whole] the shared instance
        def self.instance = INSTANCE

        private

        # A binary read with a length answers nil at EOF, so both are undone
        # here: without the `force_encoding` an ordinary UTF-8 file would come
        # back ASCII-8BIT and stop comparing equal to the bytes this tool
        # returned yesterday. Nothing is validated, exactly as `File.read`
        # validates nothing -- {Read#deliver} is the one judge.
        #
        # UTF-8 by NAME, and not `Encoding.default_external`: under a C locale
        # (containers, systemd units) that is US-ASCII, so {Read#committable?}
        # would refuse an ordinary UTF-8 file with a message saying it is not
        # UTF-8, and the model would have no move.
        #
        # `+""` and NOT `""`: this file is `frozen_string_literal`, so a bare
        # literal is frozen while `force_encoding` MUTATES its receiver -- and
        # nil-at-EOF is every zero-length file there is. Those raised
        # `FrozenError` past this class's `rescue SystemCallError, IOError` and
        # reached the model as a refusal naming a frozen String.
        def capped(file)
          (file.read(WHOLE_BOUND.limit + 1) || +"").force_encoding(Encoding::UTF_8)
        end
      end

      # `limit` lines from 1-based `offset`, either bound optional.
      class Window
        # Stops at the FIRST line that carries the returned bytes past the
        # ceiling, so an oversized window costs the ceiling plus one line rather
        # than the file -- and because it COUNTS that line, {#size} is the exact
        # size of the exact span {#lines} covers. That is what lets the refusal
        # state a measurement instead of a floor: a walk that abandoned the
        # crossing line would know only "at least this much".
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

        # Stops the walk at the first chunk big enough to be a refusal on its
        # own.
        #
        # It exists because `File.foreach`'s byte limit SPLITS a long line while
        # `offset` and `limit` count LINES. A walk that counted chunks would
        # step over a split boundary and renumber everything after it: measured,
        # on a file whose line 1 was 1.5 MiB, `offset: 2, limit: 3` returned
        # SUCCESS with 512 KB of line 1's tail labelled "lines 2-4", and
        # `offset: 4, limit: 2` returned real lines 3-4 as "lines 4-5" -- a line
        # 5 that does not exist. A wrong answer handed back as a success is what
        # {Tool::Bounds}' whole-artifact doctrine exists to prevent, so a file
        # holding such a line refuses the window WHATEVER the offset. That loses
        # the short lines after a 5 MiB line, and it is the honest loss: the
        # alternative is rejoining the line to count it, the very allocation the
        # byte limit was added to avoid.
        #
        # The line NUMBER is right because it counts completed lines rather than
        # chunks, so a 512 MiB separatorless file is line 1 however far past its
        # end the offset reached.
        #
        # Any single chunk over the ceiling is the long-line case, terminated or
        # not -- asking "did the last chunk end in a newline?" instead was one
        # byte from wrong, since a line of exactly the chunk limit INCLUDING its
        # newline arrives whole and has nothing in it to narrow.
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

          # Ends the stream at the first over-ceiling chunk, so a `drop` for a
          # large offset over a huge line stops there instead of reading its
          # way to the offset.
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
          # it wrong is not cosmetic: a model that asked for line 4990 was
          # being told to `head -c` the START of the file, the other end of it.
          #
          # The arithmetic is one fact: a window ending at line M pulls line
          # M + 1 as its completeness probe, so the last window a file with an
          # over-long line at N can serve ends at N - 2. From an offset X that
          # is a limit of N - 1 - X, and when that is under 1 no window
          # starting at X can be served at all.
          def narrower
            stop = @number - 1 - @offset
            if stop.positive?
              return ["stop the window before line #{@number}: offset #{@offset} with limit at most #{stop}",
                      *STRUCTURAL]
            end
            return [outside_window, *STRUCTURAL] if @number >= 3

            LONG_LINE_NARROWER
          end

          # Names the window that CAN be served, and which line is in the way
          # -- the model did not ask to hear about that line.
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
        # this file you have not seen", and pulling exactly one is what decides
        # completeness without materialising the file a window exists to avoid
        # materialising. With no `limit` the window runs to EOF, so there is no
        # line past it and completeness rests on `offset` alone.
        #
        # `take(n).force` and NOT `first(n)`: `first` RESERVES an Array of n
        # slots before a single line is read (measured: 381 MB of address space
        # at n = 5*10^7), and n here is a number the MODEL chose. Under an
        # address-space cap that is a `NoMemoryError`, which is not a
        # StandardError -- so it escapes {Effect::Handler::Live}'s rescue and
        # propagates past the loop.
        #
        # `each_line`'s argument is a per-line BYTE limit, keeping {Budget} from
        # being handed something too big to weigh: a file with no separator is
        # ONE line, so an unlimited walk materialises the whole thing first --
        # measured at 512 MB peak RSS on a 512 MiB file, the same NoMemoryError
        # escape by another route.
        #
        # `+ 1` is what makes a split ALWAYS a refusal. The walk never returns
        # a chunk shorter than the limit except at EOF (it runs on to finish a
        # multibyte character rather than cutting one -- measured: 1002 bytes
        # for a limit of 1001 on UTF-8), so a split chunk is already over the
        # ceiling. {LongLine} turns that into the refusal, and must sit BEFORE
        # the `drop`, which is what would otherwise miscount.
        #
        # `encoding:` for {Whole#capped}'s reason: an untagged read takes
        # `Encoding.default_external`, so under `LC_ALL=C` a window over a good
        # UTF-8 file would be refused by {Read#committable?} the moment the
        # model passed an offset. Naming UTF-8 also makes the multi-byte
        # behaviour the `+ 1` relies on unconditional.
        #
        # The version comes from the open descriptor, for {Whole#read}'s
        # reason, and everything lazy is forced before the block closes it.
        def read(path)
          File.open(path, "r", encoding: Encoding::UTF_8) do |file|
            identity = Session::FileIdentity.from_stat(file.stat)
            watch = LongLine.new(WINDOW_BOUND.limit, offset: @offset)
            lines = watch.through(file.each_line(WINDOW_BOUND.limit + 1).lazy).drop(@offset - 1)
            read = @limit ? bounded(lines, path, identity) : to_eof(lines, path, identity)
            # Consulted AFTER the force, because the walk is lazy: nothing has
            # been read at the point the watcher is built. A long line inside the
            # window would also make Budget refuse, and this branch wins on
            # purpose -- its advice is the one that goes anywhere.
            (watch.found? ? watch.refusal(path) : read).settled(file)
          end
        end

        private

        def bounded(lines, path, identity)
          budget = Budget.new(WINDOW_BOUND.limit, keep: @limit).fill(lines.take(@limit + 1))
          return refused(budget, path) if budget.over?

          taken = budget.lines
          disclosed(taken.take(@limit), identity, eof: taken.size <= @limit)
        end

        def to_eof(lines, path, identity)
          budget = Budget.new(WINDOW_BOUND.limit).fill(lines)
          return refused(budget, path) if budget.over?

          disclosed(budget.lines, identity, eof: true)
        end

        # Names the span it MEASURED and that span's true size, so the sentence
        # stays true of a window the model may have asked to be far larger:
        # "the window over lines 1-16385 of x.log is 1048640 bytes" is a fact
        # about a prefix, where "the window is 1048640 bytes" would be a guess
        # about a tail nobody read.
        #
        # Getting here means at least TWO lines were charged -- one chunk over
        # the ceiling is {LongLine}'s case -- so "narrow the window with a
        # smaller limit" always has somewhere to go.
        def refused(budget, path)
          Refused.new(result: WINDOW_BOUND.refusal(
            subject: "the window over #{covered(budget.lines.size)} of #{path}",
            size: budget.size, narrower: WINDOW_NARROWER
          ))
        end

        # A complete window withheld nothing, so it says nothing -- and stays
        # byte-identical to the unwindowed read, which is what lets a full-cover
        # window stand in for one.
        #
        # The notice is added AFTER {Budget} weighed the lines, so a partial
        # window at the ceiling hands back the ceiling plus ~94 bytes. Charging
        # it would need the count the notice states, which is not known until
        # the count is final, so the overshoot is bounded and named rather than
        # chased.
        def disclosed(seen, identity, eof:)
          lines = eof ? (@offset..) : (@offset..(@offset + seen.size - 1))
          return Read.new(contents: seen.join, lines:, identity:) if eof && from_the_top?

          Read.new(contents: "#{terminated(seen.join)}#{notice(seen.size)}", lines:, identity:)
        end

        # Names the window and the fact of partialness, never a total: knowing
        # how many lines the file has would mean reading the whole file, the
        # cost a window exists to avoid.
        def notice(count)
          "... window only: #{covered(count)}; edit_file accepts this file only once " \
            "the windows you have read cover every line of it"
        end

        def covered(count)
          return "no lines at or after line #{@offset}" if count.zero?

          "lines #{@offset}-#{@offset + count - 1}"
        end

        # The notice needs a line of its own, and a file whose last line has no
        # terminator is the one case where that costs a byte the file does not
        # contain. Running the two together would be worse.
        def terminated(text) = text.empty? || text.end_with?("\n") ? text : "#{text}\n"

        def from_the_top? = @offset == 1
      end

      # Class-level because {Whole} is a shared frozen instance with no state,
      # and because the conditional half of the advice is a fact about the FILE
      # rather than about the reader.
      #
      # @param path [String] the resolved path, as the model spelled it back
      # @param size [Integer] `File.size`, measured before any open
      # @return [Refused]
      def self.too_large(path, size)
        Refused.new(result: WHOLE_BOUND.refusal(subject: path, size:, narrower: narrower_for(path, size)))
      end

      # Three answers, and only the third costs anything. "Read part of it" is
      # unfollowable for a file that IS one line, since `offset` and `limit`
      # count LINES, and the model spends a round trip discovering that -- QA
      # hit it on a 1,200,003-byte one-line JSON.
      #
      # The probe is here rather than in {Whole#read} because it is about what
      # to SAY, not what to decide: the decision above still costs a stat and
      # the {FULL_COVER} branch still costs nothing at all.
      #
      # @param path [String] the resolved path, opened only on the branch where
      #   the advice depends on the file's shape rather than on its size
      # @param size [Integer] `File.size`, measured before any open
      # @return [Array<String>] the actions that would work on a file this big
      def self.narrower_for(path, size)
        return [FULL_COVER, *STRUCTURAL] if WINDOW_BOUND.admits?(size)
        return LONG_LINE_NARROWER if one_long_line?(path)

        [PART_ONLY, *STRUCTURAL]
      end

      # Whether {Window} would refuse this file's first line however it is
      # windowed. Exact rather than heuristic, and the boundary is one byte off
      # its obvious reading.
      #
      # {Window#read} chunks at `WINDOW_BOUND.limit + 1` and {LongLine} refuses
      # any chunk strictly OVER the ceiling, so a first line of exactly
      # `limit + 1` bytes INCLUDING its newline arrives whole and IS refused.
      # That line's newline sits at byte index `limit`, so the question
      # agreeing with {LongLine} on every file is "is there a newline inside the
      # first `limit` bytes" -- one byte short of the chunk size. Asked over
      # `limit + 1`, that file is offered a window that then refuses it, which
      # is the round trip this exists to remove.
      #
      # @param path [String] a file already known to be over {WINDOW_BOUND}
      # @return [Boolean]
      def self.one_long_line?(path)
        File.open(path, "rb") { |file| !separator_within?(file, WINDOW_BOUND.limit) }
      end

      # Blocks, and never a slurp: the answer here is one Boolean, so
      # {Whole#capped}'s single `File.read(path, N)` would allocate a megabyte
      # per refusal on a tier-1 hot path -- the cost {Whole#read}'s stat-first
      # ordering exists to avoid, reintroduced one line below it. The ordinary
      # file costs one block; the worst case has read a megabyte while holding
      # 16 KiB.
      #
      # Binary, so a block is bytes and `\n` is a byte. `read` answers nil at
      # EOF, which ends the walk: a file that shrank out from under the stat has
      # no separator we can claim to have seen.
      #
      # The budget is counted in BYTES rather than blocks so it is exactly
      # `budget` whether or not the ceiling divides by the block size. A short
      # count would refuse a window that works; a long one would offer a window
      # that does not.
      #
      # ONE buffer, reused: `IO#read`'s second argument fills a String the
      # caller owns, taking the worst case from 64 16 KiB Strings of garbage
      # down to one allocation. Safe ONLY because the chain is LAZY end to end
      # -- each block is tested and discarded before the next `read` overwrites
      # it. An eager step anywhere in it (a `to_a`, a `select`, a non-lazy
      # `map`) would leave every element aliasing the same String, so keep it
      # lazy or give the buffer up.
      #
      # @param file [File] positioned at the start
      # @param budget [Integer] how many bytes may be looked at
      # @return [Boolean]
      def self.separator_within?(file, budget)
        block = +""
        Enumerator.produce(budget) { |left| left - PROBE_BLOCK }
                  .lazy
                  .take_while(&:positive?)
                  .map { |left| file.read([left, PROBE_BLOCK].min, block) }
                  .take_while { |filled| !filled.nil? }
                  .any? { |filled| filled.include?("\n") }
      end
      private_class_method :one_long_line?, :separator_within?

      # The SECOND check's refusal: the read came back one byte past the
      # ceiling, so the file is bigger than the stat claimed by an unknown
      # amount. Both halves answer to that -- the subject names the PREFIX
      # measured rather than asserting a total nobody read, and the advice
      # offers only a partial window, because this branch has just learned it
      # cannot trust a size.
      #
      # @param path [String] the resolved path
      # @param size [Integer] bytes actually read, always the ceiling plus one
      # @return [Refused]
      def self.grew_past(path, size)
        Refused.new(result: WHOLE_BOUND.refusal(subject: "the first #{size} bytes of #{path}", size:,
                                                narrower: [PART_ONLY, *STRUCTURAL]))
      end

      # `Canonical` asks this same question later and answers it with a raise
      # naming no file; asked here it names the file, and what comes back is
      # committable, so the ask continues instead of being interrupted.
      #
      # Unlike {too_large} and {grew_past} it returns the {Tool::Result}
      # directly: the branch that refuses is already inside {Read#deliver} and
      # has no reader left to answer to.
      #
      # @param path [String] the resolved path, as the model spelled it back
      # @return [Tool::Result] an error carrying the verdict and none of the bytes
      def self.not_text(path)
        Tool::Result.error("#{path} is not valid UTF-8, so its contents cannot be recorded as part of this " \
                           "conversation -- instead, #{NOT_TEXT_NARROWER.join(", or ")}")
      end

      def name = "read_file"

      def description
        "Reads a text file at the given path. Reads the whole file by default; pass offset " \
          "(1-based line number) and/or limit (number of lines) to read one window of it instead. " \
          "A window that does not cover the whole file is labelled as partial; windows add up, so " \
          "edit_file's read-before-write requirement is met once the windows you have read cover " \
          "every line of one version of the file. A read is refused rather than truncated when it would hand back " \
          "more than #{WHOLE_BOUND.limit} bytes whole or #{WINDOW_BOUND.limit} bytes through a " \
          "window, and the refusal names what to do instead. Returns an error result if the path " \
          "does not exist, is a directory, cannot be read, or holds bytes that are not valid UTF-8 " \
          "text and so could not be recorded."
      end

      # Audited: reads the filesystem and appends to the Session's read-set,
      # whose `record_read` is fiber-safe (no yield between its check and its
      # mutate). No process-global state -- WorkerEnv#cwd is read, never
      # chdir'd.
      def parallel_safe? = true

      protected

      def perform(input, invocation)
        path = target(invocation, input.path)
        # `:regular_file` and not `:file`: the extra rule is a MEMORY guard,
        # and this is the only tool that bounds a read by SIZE. See
        # {Tool::FileTarget::IRREGULAR}.
        problem = problem_with(path, expecting: :regular_file)
        return Tool::Result.error(problem) if problem

        failing("read", path) do
          window_for(input).read(path).deliver(session_of(invocation), path, invocation&.tool_use_id)
        end
      end

      private

      # A window from line one with no limit IS the whole file. Not merely
      # wasteful to route it through {Window}: since the unwindowed read is
      # bounded by SIZE, that spelling would be a one-keyword bypass of the
      # bound, at the highest memory cost of the three rather than the lowest.
      def window_for(input)
        return Whole.instance if input.limit.nil? && (input.offset.nil? || input.offset == 1)

        Window.new(offset: input.offset, limit: input.limit)
      end
    end
  end
end
