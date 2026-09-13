# frozen_string_literal: true

require "async"

module Lain
  module Frontend
    class Neovim
      # The editor's surface on {Lain::Approval::Queue}: lain://approval lists
      # what is parked, and `y`/`n` on a row answers it -- the second surface
      # {Frontend::ApprovalPolicy} coexists with, first answer winning.
      #
      # IT OBSERVES, IT DOES NOT CONSUME, which is {Approval::AutoSurface}'s
      # rule and not a detail: the arrival queue hands each pending to exactly
      # ONE `dequeue` caller, and that caller is {Frontend::ApprovalPolicy} --
      # the surface that can ask a person. A second one here would STEAL
      # pendings the terminal then never asks about. Not hypothetical: the
      # desktop-notification surface (since deleted) drained it too until it was
      # made an observer, and from the second gated call of a turn onward the
      # terminal got nothing, which on `--no-nvim` is a session with no approval
      # surface at all. {#sweep}
      # walks the PARKED set instead, and {Pending#decide}'s first-answer-wins
      # makes the loser's answer a quiet no-op by construction.
      #
      # A TWO-KEY GESTURE, NOT A COMPOSE BUFFER. {QuestionView} is the
      # precedent for everything else here, but a question is free text with no
      # clock on it. An approval is a CLOSED BINARY CHOICE UNDER A TIMEOUT --
      # nothing to compose, one bit of answer, and a window that expired
      # mid-typing would have to tell the human their text was wasted.
      #
      # THE VERDICT RIDES THE WIRE, one command per verdict, for the reason
      # `46_sidebar.lua`'s MARK_KEYS states: a decision computed from a
      # rendering that has since moved answers the WRONG call, silently,
      # because both values are legal. What the human pressed is what is sent.
      #
      # ACKED, NEVER ANSWERED, and the whole wiring follows from it. Deciding a
      # pending resolves a {Lain::Promise}, which must happen on the REACTOR, so
      # the gesture cannot be served on the RPC thread the way a question's `:w`
      # is. It rides the command inbox to the editor-command consumer fiber
      # ({CLI::HumanReplies::Gestures}), which is on the reactor.
      #
      # THREAD CONTRACT, AND WHY THERE IS NO LOCK. Both callers -- {#sweep} from
      # the watch fiber, {#decide} from the editor-command consumer -- are
      # fibers of the SAME reactor thread, and neither method has a yield point
      # between reading this object's state and writing it: the editor post is
      # the non-blocking {RenderInlet} path, which refuses a full queue rather
      # than parking on it. {Approval::Queue}'s own argument for its lock-free
      # `@parked`, with the same warning -- a caller reaching this from the RPC
      # thread would break it, which is precisely why the gesture is acked.
      class ApprovalView
        # Absent from the runtime's BUFFERS set (00_constants.lua) like
        # {Compose::BUFFER} and {QuestionView::BUFFER}, because that set is what
        # the User LainAttach payload publishes and the runtime creates this one
        # itself -- but UNLIKE those two it IS primed at attach ({#prime}).
        # `runtime/62_approval.lua` opens a window only `if rows > 0`, so a
        # prime carrying no rows creates the buffer and takes no screen; compose
        # and question have no such guard and would each open on nothing.
        BUFFER = "lain://approval"

        # DISTINCT from {Frontend::ApprovalPolicy::SURFACE}, and the distinction
        # is the evidence: a shared name would make an editor keypress and a
        # terminal `y` indistinguishable in a transcript.
        SURFACE = "nvim"

        # Its own line rather than an empty buffer, for {InboxView::EMPTY}'s
        # reason: a blank projection reads as broken.
        EMPTY = ["(no approvals pending)"].freeze

        # The only discoverability this surface has: the buffer takes focus when
        # an approval lands, and a human who has never read `:help lain-approval`
        # has to learn what to press FROM the thing in front of them.
        HINT = "-- y approve, n deny  (:LainApprove / :LainDeny)"

        # A FOLD's measurement rather than a terminal's: a closed item shows
        # this line plus `10_folds.lua`'s "  (+N lines)" marker on ONE screen
        # line, and the cockpit's nvim pane measures 110 columns. Generous at
        # the other end on purpose -- {Approval::Queue::Outstanding#preamble}
        # runs to ~84 columns on its own, and a bar cutting into that would hide
        # the one sentence a `y` on this row is most about.
        #
        # {Fold}'s own, not a second measurement of the same pane: {InboxView}
        # draws the same width and both used to spell it out independently,
        # which is the duplication {Fold}'s doc explains.
        WIDTH = Fold::WIDTH

        # The whole of the runtime's boundary test: `05_records.lua`'s
        # CONTINUATION pattern is this string anchored, so "does this line start
        # a record" is answerable there without parsing the call's own text.
        # {Fold}'s own, pinned against the Lua there.
        INDENT = Fold::INDENT

        # ASCII, `65_review.lua`'s SENTINEL spelling, so a font with no ellipsis
        # glyph shows a cut rather than a replacement box. {Fold}'s own.
        ELISION = Fold::ELISION

        # An item's body: the row, hard-wrapped, NEVER at a word boundary. What
        # the human is asked to approve is a COMMAND, and a wrap that moved bytes
        # around -- swallowing a run of spaces at a break -- would show them
        # something other than what a `y` releases. `/m` so a newline is CARRIED
        # rather than silently dropped; `input.inspect` is what keeps a raw one
        # unreachable, and it has to, because nothing downstream re-checks
        # ({RenderQueue#checked_lines} guards `post_view`, and this view posts
        # through `post_approval`).
        #
        # ONE MODE, RULED. Word-wrapping the PREAMBLE (lain's own prose) while
        # hard-wrapping the CALL (bytes that must survive) was considered and
        # rejected: a mid-sentence break is legibility only -- the human reading
        # the opened fold has the whole sentence either way -- and two modes
        # would be two code paths over one buffer whose seam falls exactly at
        # the elision point. One mode keeps {#lines_for}'s summary a cut PREFIX
        # of the body, a property checkable by reading. {Fold}'s own regex.
        BODY = Fold::BODY

        # None attached, dead, or no longer draining -- one sentence for all
        # three, because they are one fact from the human's side.
        DETACHED = "showing a parked approval needs an attached editor"

        # The wire's two words, against the Booleans {Approval::Queue::Pending}
        # takes. A CLOSED map and never a truthiness test: an unknown word is
        # REFUSED, because the one thing an approval surface must never do is
        # let a value nobody recognises fall toward approve.
        VERDICTS = { "approve" => true, "deny" => false }.freeze

        # A sibling fiber on the reactor, so this is a scheduler yield rather
        # than a wall-clock stall.
        DEFAULT_POLL_INTERVAL = 0.05

        # How many renderings stay resolvable: a memory bound, not a correctness
        # one. A rendering still held resolves exactly and one forgotten is
        # refused BY NAME, so this only says how far behind the screen may be
        # before a keypress has to be pressed again.
        HELD = 8

        # The Null editor, and the default: an unwired view refuses the render
        # honestly rather than pretending it landed. Nothing is ever posted, so
        # no rendering is handed out, so every gesture citing one is refused.
        module Detached
          module_function

          def set_approval(_lines, _generation, _rows, _calls, _call_index) = DETACHED
        end

        # A keypress turned into a decided pending, or into the sentence saying
        # why none was decided: this object touches neither nvim nor stdio, so
        # "report the failure" can only mean "hand it back".
        Decided = Data.define(:pending, :report) do
          def decided? = !pending.nil?
        end

        # One rendering of the parked set: the lines the editor took, and WHICH
        # parked call each of the LEADING lines belongs to -- one entry per
        # LINE, never one per call.
        #
        # THE MAP IS THE ADDRESS, replacing position addressing. `rendering[line
        # - 1]` is the same answer only while every item is exactly one line;
        # the moment one is not it broke in two places at once -- Ruby answered
        # the NEIGHBOURING call, and the editor's own inert test
        # (`line <= b:lain_approval_rows`) made every continuation line a
        # keypress about nothing. One value fixes both, because {#rows} is
        # `owners.size`.
        #
        # BUILT IN ONE PASS with the lines it maps, so an index built by a
        # second walk cannot disagree with the rendering the first one drew.
        #
        # `calls` AND `call_index` exist for a reader OUTSIDE Ruby -- `owners`
        # already answers "which pending" for every caller in this file, so
        # these two are for the editor, and specifically for the wrap
        # `#body_for` draws HARD, mid-token: every continuation line opens
        # with {INDENT}, so a reader who reassembles a command by
        # concatenating rendered lines puts two spaces in the middle of what
        # was one contiguous run of bytes, and a substring match against the
        # ORIGINAL command misses (measured live -- the runtime spec's
        # `buffer_lines(...).join` is exactly that reader). `calls` is
        # {#call_of}'s unwrapped string, ONE PER PARKED CALL rather than one
        # per line: an item's `.inspect` runs once here no matter how many
        # rows it wraps into, and the msgpack payload this crosses stays
        # linear in the number of parked calls rather than quadratic in one
        # call's length times its row count -- object sharing does not dedupe
        # msgpack, so a duplicate-per-line array re-serializes the same bytes
        # on every wire crossing. `call_index` is `owners`' own shape (one
        # entry per LINE) holding not the pending but WHICH member of `calls`
        # names it, 1-based for the lua table that indexes it, so a cursor on
        # any of an item's rows still resolves the identical unbroken copy --
        # at the cost of one small integer per line instead of the string
        # itself.
        Rendering = Data.define(:lines, :owners, :calls, :call_index) do
          # The 1-based/0-based seam is guarded here rather than at the call
          # site: line 0 would index -1, the LAST answerable line, so a cursor
          # nvim never reports would silently answer the wrong call. An
          # unreadable line answers no call rather than raising on the
          # consumer's fiber.
          def at(line)
            index = Integer(line, exception: false)
            index&.positive? ? owners[index - 1] : nil
          end

          # How many of the leading lines answer a call, which is what
          # `b:lain_approval_rows` means -- not how many calls there are.
          def rows = owners.size
        end

        # The four ways a keypress decides nothing, four sentences because four
        # different things happened.
        #
        # EACH IS ONE MESSAGE LINE, a hard constraint rather than a style: all
        # four are echoed through one `nvim_echo` into the MESSAGE AREA, and a
        # sentence that does not fit raises `Press ENTER or type command to
        # continue`, which blocks RPC on the very gesture it is refusing. The
        # bar is 80 columns INCLUDING `65_review.lua`'s `"lain: "` prefix --
        # inside the cockpit nvim pane's 110 and inside an ordinary terminal.
        #
        # MEASURED RENDERED, NEVER AS THE TEMPLATE: `%<verdicts>s` expands to
        # "approve/deny" and `%<generation>s` to digits, so a bar checked
        # against the format string measures far less than what the editor
        # receives -- these ran to 145, 196 and 241 characters before they were
        # cut. Each keeps the CONDITION and the REMEDY; the reasoning behind
        # them lives in {#decide}'s own comments.
        UNSHOWN = "#{BUFFER} has re-rendered since rendering %<generation>s -- press again".freeze
        NO_ROW = "no parked approval on #{BUFFER} line %s".freeze
        UNKNOWN = "%<given>s is not a verdict lain has -- answer %<verdicts>s; still parked"
        SETTLED = "%<surface>s %<decision>s #{BUFFER} line %<line>s first, and that stands".freeze

        # @param rpc [#set_approval] the editor's render inlet ({RpcThread}):
        #   takes the lines, the stamp to write onto the buffer, how many of
        #   those lines are rows, the unwrapped call per PARKED CALL, and the
        #   row->call index that resolves one from a cursor line, and answers
        #   why the rendering did not land
        # @param poll_interval [Numeric] seconds between sweeps of the parked
        #   set
        def initialize(rpc: Detached, poll_interval: DEFAULT_POLL_INTERVAL)
          @rpc = rpc
          @poll_interval = poll_interval
          @renderings = {}
          @generation = 0
          # Deliberately nil rather than []: the FIRST sweep must render, even
          # of an empty queue, so `:buffer lain://approval` is somewhere to
          # look from the moment a session can be gated at all.
          @shown = nil
        end

        # One fiber beside the TTY prompt, spawned per ask and stopped with it.
        #
        # THE ENSURE IS THE POINT, not tidiness. The surfaces are stopped the
        # moment an ask settles, which can land between a pending being decided
        # and the next poll -- leaving a row on screen that claims to be
        # answerable for the whole of the human's next `you>`. The last sweep
        # cannot park (the post is non-blocking) and cannot raise (a refusal is
        # its answer), so it is safe inside an `Async::Stop` unwind.
        def watch(queue)
          loop do
            sweep(queue)
            Async::Task.current.sleep(@poll_interval)
          end
        ensure
          sweep(queue)
        end

        # The at-rest projection, posted at attach. Without it a human looking
        # for the approval surface on an idle cockpit finds no buffer and
        # `:buffer lain://approval` answers E94.
        #
        # IT DOES NOT TOUCH `@shown`: the nil {#initialize} leaves there is what
        # makes the FIRST sweep render even an empty queue, and recording the
        # empty list here as "what the screen shows" would make that sweep skip.
        # The cost is one extra whole-buffer replace of the same line, at attach.
        #
        # Safe on the drain thread where the sweeps are on the reactor (the
        # class doc's thread contract), because it runs strictly BEFORE either
        # fiber exists: {Neovim#initialize} builds this view, then {Surfaces},
        # and only {Neovim#run} starts the thread that primes.
        # @return [void]
        def prime
          posted([])
          nil
        end

        # The snapshot is taken with NO yield point (the block reads a flag), so
        # the enumeration cannot mutate under a concurrent park or settle.
        #
        # It renders only when the set MOVED: at 20Hz a re-post per poll would
        # be twenty whole-buffer replaces a second for a screen nobody is
        # changing, each minting a stamp that retires the one the human's cursor
        # is sitting in.
        # @return [void]
        def sweep(queue)
          parked = queue.reject(&:decided?)
          render(parked) unless parked == @shown
          nil
        end

        # The `y`/`n` gesture from lain://approval, resolved against the
        # rendering it came from and handed to
        # {Approval::Queue::Pending#decide}, whose single-shot answer is the
        # whole of the race.
        #
        # THERE IS NO `decided?` PRE-CHECK, and its absence is deliberate: a
        # check-then-act would be a window in which the terminal, an oracle
        # or the clock answers between the test and the decision, and this
        # surface would report a verdict that never landed. `decide` answers
        # whether THIS answer won, atomically.
        #
        # KNOWN, OPEN, AND NOT WHAT THE STAMP CATCHES -- the stationary cursor.
        # The stamp answers "which rendering is this line a line OF", never "is
        # this still the call the human AIMED at". Cursor on item B; the
        # terminal answers A; the list re-renders under a cursor that did not
        # move; `y` carries the CURRENT stamp, nothing refuses, and whichever
        # item took those lines is approved. Everything is behaving as
        # specified, which is why no check in this method can see it.
        #
        # Multi-line items WIDENED it: while every item was one line a shifted
        # cursor usually landed past `rows`, in the inert trailer, where the
        # keypress died. Closing it needs identity on the wire (which this
        # transport deliberately does not carry -- see {Rendering}) or a diffing
        # write in `set_approval` so nvim's own line adjustment carries the
        # cursor with its item. Neither is contained in this file.
        #
        # @param line [Integer] 1-based, as nvim's cursor reports it
        # @param verdict [String] one of {VERDICTS}' keys, as the human's key
        #   sent it
        # @param generation [Integer] the stamp on the buffer they are looking
        #   at (b:lain_view_generation)
        # @return [Decided]
        def decide(line, verdict, generation:)
          # It does not guess: the list has moved since that rendering was
          # drawn, so this line could name two different calls and both values
          # are legal. "Press again" is the whole of what the human has to do --
          # the rows under their cursor now are a rendering this view holds.
          return undecided(format(UNSHOWN, generation: generation.inspect)) unless @renderings.key?(generation)

          pending = @renderings.fetch(generation).at(line)
          return undecided(format(NO_ROW, line.inspect)) if pending.nil?

          answer = VERDICTS[token(verdict)]
          return undecided(unknown(verdict)) if answer.nil?

          settled(pending, answer, line)
        end

        private

        # `to_s` armors a non-String that crossed msgpack into something
        # {VERDICTS} misses BY NAME rather than something a lookup crashes on.
        def token(verdict) = verdict.to_s.strip.downcase

        def settled(pending, answer, line)
          return lost(pending, line) unless pending.decide(answer, surface: SURFACE)

          Decided.new(pending:, report: "#{pending.tool} #{outcome(pending)}")
        end

        # The race this surface lost, reported with the winner NAMED: "denied"
        # reading as the human's own no is the confusion
        # {Command::Approve#outcome_line} already guards against at the terminal.
        def lost(pending, line)
          undecided(format(SETTLED, line: line.inspect, surface: pending.surface, decision: outcome(pending)))
        end

        # Not the Symbol {Pending#decision} carries: "deny" reads as an
        # instruction where the sentence is about something already done.
        def outcome(pending) = pending.approved? ? "approved" : "denied"

        # A word this surface does not recognise decides NOTHING rather than
        # falling toward approve, and the pending it leaves alone is still the
        # clock's -- which is what "still parked" tells the human.
        def unknown(verdict)
          format(UNKNOWN, given: verdict.inspect, verdicts: VERDICTS.keys.join("/"))
        end

        def undecided(report) = Decided.new(pending: nil, report:)

        # Recorded only for a rendering that reached the screen, so a refused
        # post leaves `@shown` alone and the next sweep RETRIES rather than
        # treating the lost rendering as the state of the editor.
        def render(parked)
          @shown = parked if posted(parked)
        end

        # The ONE rule that keeping a rendering needs: a stamp is handed out
        # only once the editor has TAKEN the lines it names. A refused post is a
        # rendering nobody can see, so remembering one would let a gesture citing
        # a number nothing ever wrote resolve against rows the human is not
        # looking at.
        #
        # Separate from {#render} because {#prime} needs exactly this half and
        # must not have the other.
        # @return [Integer, nil] the stamp the editor took, or nothing when it
        #   refused the post
        def posted(parked)
          rendering = rendering_of(parked)
          generation = @generation + 1
          return nil unless @rpc.set_approval(rendering.lines, generation, rendering.rows, rendering.calls,
                                              rendering.call_index).nil?

          @generation = generation
          @renderings[generation] = rendering
          @renderings.shift if @renderings.size > HELD
          generation
        end

        # Rows FIRST and nothing above them, which is what lets the editor's
        # keys be inert outside the list from a COUNT alone rather than from a
        # pattern match on rendered text kept in step with this method.
        #
        # `calls` IS COMPUTED ONCE PER PENDING, here, and threaded into
        # {#lines_for}/{#summary_for} rather than re-derived from the rendered
        # text: {#call_of} runs `.inspect` over a tool's whole input, and
        # calling it again per LINE a wrapped item spans -- once measured at a
        # 64KB heredoc wrapping to 699 rows -- is 699 allocations of a string
        # that size for one command nobody asked to see re-cut.
        def rendering_of(parked)
          return Rendering.new(lines: EMPTY.dup, owners: [], calls: [], call_index: []) if parked.empty?

          calls = parked.map { |pending| call_of(pending) }
          items = parked.zip(calls).map { |pending, call| lines_for(pending, call) }
          Rendering.new(lines: items.flatten(1) + ["", HINT], owners: owners_for(items, parked),
                        calls:, call_index: call_index_for(items))
        end

        # One entry per LINE, the pending it belongs to -- {Rendering#at}'s
        # own lookup, and never sent across the wire itself.
        def owners_for(items, parked)
          items.zip(parked).flat_map { |lines, pending| Array.new(lines.size, pending) }
        end

        # {#owners_for}'s shape, holding not the pending but its 1-based
        # position in `calls` -- the lua side's own resolution; {Rendering}'s
        # doc derives why it rides separately from `owners`.
        def call_index_for(items)
          items.each_with_index.flat_map { |lines, index| Array.new(lines.size, index + 1) }
        end

        # A summary line and -- only where it had to be cut -- the call in full
        # beneath it, foldable away, so the ordinary list is still one line per
        # call and stays quiet at rest.
        def lines_for(pending, call)
          Fold.lines(summary_for(pending, call))
        end

        # THE WHOLE ROW, never just the call. A body carrying only `call_of`
        # reads fine until the summary is cut INSIDE
        # {Approval::Queue::Outstanding#preamble} -- a deep enough path does it
        # on its own -- and then "4 sensitive regions outstanding" is in the
        # buffer NOWHERE, on the one surface whose premise is that a human reads
        # what they approve. Wrapping the summary makes the fold's first line a
        # cut PREFIX of what is underneath it.
        def body_for(summary) = Fold.wrap(summary)

        def call_of(pending) = "#{pending.tool}(#{pending.input.inspect})"

        # {Frontend::ApprovalPolicy#prompt_for}'s facts in the terminal's own
        # spelling, so a human who has answered one of these at the prompt reads
        # the same call here. The release sentence is the terminal's own
        # ({Approval::Queue::Outstanding#preamble}) rather than a second spelling
        # of it: `y` on a row is a FULL approval signing `surface: "nvim"`, so a
        # row omitting it would let a human release a file's secrets from the
        # editor having been shown no warning at all.
        #
        # The requester LEADS: with a fleet running, "who is asking" is what
        # separates two identical-looking rows. The release sentence sits between
        # it and the call rather than at the end, because `input.inspect` is
        # unbounded and a warning past the edge of a nomodifiable window is a
        # warning nobody read. That ordering keeps the warning on SCREEN for the
        # common row; it is NOT what makes {WIDTH}'s cut safe -- a long enough
        # path puts the cut inside the warning itself, and what makes THAT safe
        # is {#body_for} carrying this whole sentence.
        #
        # A summary must never OPEN with {INDENT}, which is why the `lstrip` is
        # here and not a tidying: that prefix is the runtime's whole test for a
        # continuation line, so a context naming NOBODY would draw a summary the
        # fold surface reads as part of the item above it.
        #
        # `call` arrives COMPUTED rather than being `call_of(pending)` again --
        # {#rendering_of} calls {#call_of} exactly once per pending and threads
        # the result through here and through {#lines_for}, so an item that
        # wraps into many rows still runs `.inspect` on its input once.
        def summary_for(pending, call)
          "#{pending.requester}  #{pending.outstanding.preamble}#{call}".lstrip
        end
      end
    end
  end
end
