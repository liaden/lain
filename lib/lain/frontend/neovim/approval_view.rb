# frozen_string_literal: true

require "async"

module Lain
  module Frontend
    class Neovim
      # The editor's surface on {Lain::Approval::Queue} (T36): lain://approval
      # lists what is parked, and `y`/`n` on a row answers it.
      # {Frontend::ApprovalPolicy}'s own class comment named this consumer --
      # "which is what lets a second surface (a Neovim view) coexist, first
      # answer winning" -- and it was the one surface that had never been
      # written, so a cockpit user got the editor for questions and the
      # TERMINAL for approvals, with no sign in the editor that a parked agent
      # was waiting on them.
      #
      # IT OBSERVES, IT DOES NOT CONSUME, which is {Approval::AutoSurface}'s
      # rule and not a detail: the arrival queue hands each pending to exactly
      # ONE `dequeue` caller, and that caller is {Frontend::ApprovalPolicy} --
      # the surface that can ask a person. A second one here would STEAL
      # pendings the terminal then never asks about. That is not hypothetical:
      # {Lain::Notify} drained it too until T15, and from the second gated call
      # of a turn onward the terminal got nothing, which on `--no-nvim` is a
      # session with no approval surface at all (manual-QA round 4, F18).
      # {#sweep} walks the PARKED set ({Queue#each}) and renders it;
      # {Pending#decide}'s first-answer-wins is what makes the race safe, and
      # the loser's answer is a quiet no-op by construction rather than by a
      # check this object performs.
      #
      # A TWO-KEY GESTURE, NOT A COMPOSE BUFFER, and the difference is the
      # shape of the thing being answered. {QuestionView} is the precedent for
      # everything else here, but a question is free text with no clock on it:
      # the human types, `:w`, and the parse can refuse. An approval is a
      # CLOSED BINARY CHOICE UNDER A TIMEOUT -- there is nothing to compose,
      # the answer is one bit, and a window that expires mid-typing would have
      # to tell the human their text was wasted. So the buffer is nomodifiable
      # like every other projection, and the answer is one keystroke.
      #
      # THE VERDICT RIDES THE WIRE, and there is one command per verdict for
      # the reason `46_sidebar.lua`'s MARK_KEYS states: a decision computed
      # from a rendering that has since moved answers the WRONG call, silently,
      # because both values are legal. What the human pressed is what is sent.
      #
      # ACKED, NEVER ANSWERED, and this is the constraint the whole wiring
      # follows from. Deciding a pending resolves a {Lain::Promise}, which must
      # happen on the REACTOR ({QuestionView}'s own note) -- so the gesture
      # cannot be served on the RPC thread the way a question's `:w` is. It
      # rides the command inbox to the editor-command consumer fiber
      # ({CLI::HumanReplies::Gestures}), which is on the reactor, and this
      # object is only ever touched from there and from its own watch fiber.
      #
      # THREAD CONTRACT, AND WHY THERE IS NO LOCK. Both callers -- {#sweep}
      # from the watch fiber, {#decide} from the editor-command consumer -- are
      # fibers of the SAME reactor thread, and neither method has a yield point
      # between reading this object's state and writing it: the editor post is
      # the non-blocking {RenderInlet} path, which refuses a full queue rather
      # than parking on it. That is {Approval::Queue}'s own argument for its
      # lock-free `@parked`, and it holds here for the same reason and with the
      # same warning: a caller that reached this from the RPC thread would
      # break it, which is precisely why the gesture is acked.
      class ApprovalView
        # The one lain:// buffer that lists parked approvals. Absent from the
        # runtime's BUFFERS set (00_constants.lua) like {Compose::BUFFER} and
        # {QuestionView::BUFFER}, because that set is what the User LainAttach
        # payload publishes for a human's own config to iterate and the runtime
        # creates this one itself -- but UNLIKE those two it IS primed at attach
        # ({#prime}), and the earlier argument against that ("it would put an
        # empty window on screen at every attach") was wrong about this buffer.
        # `runtime/62_approval.lua` opens a window only `if rows > 0`, so a
        # prime carrying no rows creates the buffer and takes no screen; compose
        # and question have no such guard and would each open on nothing.
        BUFFER = "lain://approval"

        # The name this surface signs its decisions with in the Journal.
        # DISTINCT from {Frontend::ApprovalPolicy::SURFACE}, and the distinction
        # is the evidence: "who approved this, at which surface" is the whole
        # reason {Approval::Queue} records one, and a shared name would make an
        # editor keypress and a terminal `y` indistinguishable in a transcript.
        SURFACE = "nvim"

        # The rendering with nothing on it. Its own line rather than an empty
        # buffer, for {InboxView::EMPTY}'s reason: a blank projection reads as
        # broken.
        EMPTY = ["(no approvals pending)"].freeze

        # The keys, in the buffer, under the rows. One line of upkeep on every
        # rendering, and it buys the only discoverability this surface has: the
        # buffer takes focus when an approval lands, and a human who has never
        # read `:help lain-approval` has to learn what to press FROM the thing
        # that just appeared in front of them.
        HINT = "-- y approve, n deny  (:LainApprove / :LainDeny)"

        # No editor took the rendering: none is attached, or the one that was
        # has died, or it has stopped draining. One sentence for all three,
        # because they are one fact from the human's side ({Compose::DETACHED}'s
        # reason).
        DETACHED = "showing a parked approval needs an attached editor"

        # The wire's two words, against the Booleans {Approval::Queue::Pending}
        # actually takes. A CLOSED map and never a truthiness test: an unknown
        # word is REFUSED (see {#decide}), because the one thing an approval
        # surface must never do is let a value nobody recognises fall toward
        # approve. The pending it leaves alone is still the clock's, and the
        # clock denies.
        VERDICTS = { "approve" => true, "deny" => false }.freeze

        # Between sweeps of the parked set. A sibling fiber on the reactor, so
        # this is a scheduler yield rather than a wall-clock stall
        # ({AutoSurface::DEFAULT_POLL_INTERVAL}'s shape and its value).
        DEFAULT_POLL_INTERVAL = 0.05

        # How many renderings stay resolvable. A memory bound, not a
        # correctness one -- {InboxView::Renderings::HELD}'s distinction: a
        # rendering still held resolves exactly, and one forgotten is refused
        # BY NAME, so this number only says how far behind the screen may be
        # before a keypress has to be pressed again.
        HELD = 8

        # The Null editor, and the default: an unwired view refuses the render
        # honestly rather than pretending it landed ({QuestionView::Detached}'s
        # duck). It is what makes "constructed with no editor attached" a safe
        # state rather than a hazard -- nothing is ever posted, so no rendering
        # is ever handed out, so every gesture citing one is refused.
        module Detached
          module_function

          def set_approval(_lines, _generation, _rows) = DETACHED
        end

        # A keypress turned into a decided pending, or into the sentence saying
        # why none was decided ({InboxView::Opened}'s shape, for its reason:
        # this object touches neither nvim nor stdio, so "report the failure"
        # can only mean "hand it back").
        Decided = Data.define(:pending, :report) do
          def decided? = !pending.nil?
        end

        # The four ways a keypress decides nothing, and four sentences because
        # four different things happened: the buffer the human is holding is
        # not a rendering this view still identifies; the line names no row in
        # it; the word sent is not a verdict lain has; or the call on that row
        # was answered by somebody else first.
        #
        # EACH IS ONE MESSAGE LINE, and that is a hard constraint rather than a
        # style. All four come back as a {Decided#report} and are echoed by
        # {CLI::HumanReplies::Gestures} through `review_refused`, which is one
        # `nvim_echo` into the MESSAGE AREA -- `&columns` wide over `&cmdheight`
        # lines, never the window a cockpit split narrows (see
        # {Review::Surface::Neovim::MARKED} for the measurement against a real
        # embedded UI). A sentence that does not fit raises `Press ENTER or type
        # command to continue`, which blocks RPC on the very gesture it is
        # refusing. The bar is 80 columns INCLUDING `65_review.lua`'s `"lain: "`
        # prefix: inside the cockpit nvim pane's 110 and inside an ordinary
        # terminal too.
        #
        # MEASURED RENDERED, NEVER AS THE TEMPLATE. `%<verdicts>s` expands to
        # "approve/deny" and `%<generation>s` to digits, so a bar checked against
        # the format string measures something far shorter than what the editor
        # receives -- these four ran to 145, 196 and 241 characters rendered
        # before they were cut. What the cut had to keep is the CONDITION and
        # the REMEDY; the reasoning each dropped (why an ambiguous line is not
        # guessed at, why an unknown word cannot fall toward approve) is
        # explained where reasoning belongs, in {#decide}'s own comments.
        UNSHOWN = "#{BUFFER} has re-rendered since rendering %<generation>s -- press again".freeze
        NO_ROW = "no parked approval on #{BUFFER} line %s".freeze
        UNKNOWN = "%<given>s is not a verdict lain has -- answer %<verdicts>s; still parked"
        SETTLED = "%<surface>s %<decision>s #{BUFFER} line %<line>s first, and that stands".freeze

        # @param rpc [#set_approval] the editor's render inlet ({RpcThread}):
        #   takes the lines, the stamp to write onto the buffer, and how many
        #   of those lines are rows, and answers why the rendering did not land
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

        # The surface loop: sweep the parked set, then yield until the next
        # poll. One fiber beside the TTY prompt and the notifier, spawned per
        # ask by {CLI::Repl::ApprovalSurfaces} and stopped with it.
        #
        # THE ENSURE IS THE POINT, not tidiness. The surfaces are stopped in
        # {Repl#respond}'s ensure the moment an ask settles, which can land
        # between a pending being decided and the next poll -- leaving a row on
        # screen that claims to be answerable for the whole of the human's next
        # `you>`. One last sweep on the way out is what makes the buffer agree
        # with the queue at the exact moment nobody is watching it any more.
        # It cannot park (the post is non-blocking) and cannot raise (a refusal
        # is its answer), so it is safe inside an `Async::Stop` unwind.
        def watch(queue)
          loop do
            sweep(queue)
            Async::Task.current.sleep(@poll_interval)
          end
        ensure
          sweep(queue)
        end

        # The at-rest projection, posted at attach by {Surfaces#prime} (UX4).
        # {EMPTY} was always this view's rendering of nothing; it was simply
        # unreachable until a call was gated, so a human looking for the
        # approval surface on an idle cockpit found no buffer at all and
        # `:buffer lain://approval` answered E94.
        #
        # IT DOES NOT TOUCH `@shown`, and that is the whole of the care this
        # needs: the nil {#initialize} leaves there is what makes the FIRST
        # sweep render even an empty queue, and recording the empty list here as
        # "what the screen shows" would make that sweep skip -- putting the
        # buffer back to being one only a gated session ever gets. The cost is
        # one extra whole-buffer replace of the same line, once, at attach.
        #
        # It is safe on the drain thread where the sweeps are on the reactor
        # (the class doc's thread contract), because it runs strictly BEFORE
        # either fiber exists: {Neovim#initialize} builds this view, then
        # {Surfaces}, and only {Neovim#run} starts the thread that primes.
        # @return [void]
        def prime
          posted([])
          nil
        end

        # One pass over the parked set. The snapshot is taken with NO yield
        # point (the block reads a flag), so the enumeration cannot mutate
        # under a concurrent park or settle -- {AutoSurface#sweep}'s rule.
        #
        # It renders only when the set MOVED. At 20Hz a re-post per poll would
        # be twenty whole-buffer replaces a second for a screen nobody is
        # changing, and every one of them would mint a stamp that retires the
        # one the human's cursor is sitting in.
        # @return [void]
        def sweep(queue)
          parked = queue.reject(&:decided?)
          render(parked) unless parked == @shown
          nil
        end

        # The `y`/`n` gesture from lain://approval, once the rendering it came
        # from is identified. Resolves the line against THAT rendering, then
        # hands the verdict to {Approval::Queue::Pending#decide} -- whose
        # single-shot answer is the whole of the race.
        #
        # THERE IS NO `decided?` PRE-CHECK, and its absence is deliberate. A
        # check-then-act here would be a window in which the terminal, the
        # notifier or the clock answers between the test and the decision, and
        # this surface would then report a verdict that never landed. `decide`
        # answers whether THIS answer won; that Boolean is the only honest
        # source for what to tell the human, and it is atomic by construction.
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
          # are legal. The sentence says "press again" because that is the whole
          # of what the human has to do -- the rows under their cursor now are a
          # rendering this view does hold.
          return undecided(format(UNSHOWN, generation: generation.inspect)) unless @renderings.key?(generation)

          pending = row_at(line, generation)
          return undecided(format(NO_ROW, line.inspect)) if pending.nil?

          answer = VERDICTS[token(verdict)]
          return undecided(unknown(verdict)) if answer.nil?

          settled(pending, answer, line)
        end

        private

        # The verdict as this surface reads it off the wire: stripped of
        # whatever a wire added, and never coerced further. `to_s` armors a
        # non-String that crossed msgpack into something {VERDICTS} misses BY
        # NAME rather than something a lookup crashes on.
        def token(verdict) = verdict.to_s.strip.downcase

        def settled(pending, answer, line)
          return lost(pending, line) unless pending.decide(answer, surface: SURFACE)

          Decided.new(pending:, report: "#{pending.tool} #{outcome(pending)}")
        end

        # The race this surface lost, reported with the winner NAMED. "denied
        # (timeout)" reading as the human's own no is the confusion
        # {Command::Approve#outcome_line} already guards against at the
        # terminal; the same fact is owed here.
        def lost(pending, line)
          undecided(format(SETTLED, line: line.inspect, surface: pending.surface, decision: outcome(pending)))
        end

        # {Command::Approve#outcome_line}'s two words, and not the Symbol
        # {Pending#decision} carries: "deny" reads as an instruction and the
        # sentence is about something that already happened.
        def outcome(pending) = pending.approved? ? "approved" : "denied"

        # A word this surface does not recognise decides NOTHING rather than
        # falling toward approve, and the pending it leaves alone is still the
        # clock's -- which is what "still parked" is telling the human: nothing
        # was spent, and the call refuses itself when its window closes.
        def unknown(verdict)
          format(UNKNOWN, given: verdict.inspect, verdicts: VERDICTS.keys.join("/"))
        end

        def undecided(report) = Decided.new(pending: nil, report:)

        # The 1-based/0-based seam, guarded here rather than at the call site
        # ({InboxView::Renderings::Rendering#at}'s rule): line 0 would index
        # -1, which is the LAST row -- a cursor nvim never reports would
        # silently answer the wrong call. An unreadable line answers no row at
        # all rather than raising on the consumer's fiber.
        def row_at(line, generation)
          index = Integer(line, exception: false)
          index&.positive? ? @renderings.fetch(generation)[index - 1] : nil
        end

        # What the screen shows, recorded only for a rendering that reached the
        # screen -- so a refused post leaves `@shown` alone, which is what makes
        # the next sweep RETRY rather than treat the lost rendering as the state
        # of the editor.
        def render(parked)
          @shown = parked if posted(parked)
        end

        # The post, and the ONE rule that keeping a rendering needs: a stamp is
        # handed out only once the editor has TAKEN the lines it names. A
        # refused post (a dead RPC thread, an editor that stopped draining, no
        # editor at all) is a rendering nobody can see, so remembering one would
        # let a gesture citing a number nothing ever wrote resolve against rows
        # the human is not looking at.
        #
        # Separate from {#render} because {#prime} needs exactly this half and
        # must not have the other (see its own note on `@shown`).
        # @return [Integer, nil] the stamp the editor took, or nothing when it
        #   refused the post
        def posted(parked)
          generation = @generation + 1
          return nil unless @rpc.set_approval(lines_of(parked), generation, parked.size).nil?

          @generation = generation
          @renderings[generation] = parked
          @renderings.shift if @renderings.size > HELD
          generation
        end

        # Rows FIRST and nothing above them, which is what lets the editor's
        # keys be inert outside the list from a count alone (`lain_approval_rows`)
        # rather than from a pattern match on rendered text that would have to
        # be kept in step with this method.
        def lines_of(parked)
          return EMPTY.dup if parked.empty?

          parked.map { |pending| row_for(pending) } + ["", HINT]
        end

        # {Frontend::ApprovalPolicy#prompt_for}'s THREE facts in the terminal's
        # own spelling -- what a yes would release, then `tool(input.inspect)`
        # -- so a human who has answered one of these at the prompt reads the
        # same call here. The release sentence is the terminal's own
        # ({Approval::Queue::Outstanding#preamble}) rather than a second
        # spelling of it: `y` on a row is a FULL approval signing
        # `surface: "nvim"`, so a row that omitted it would let a human release
        # a file's secrets from the editor having been shown no warning at all.
        #
        # The requester still LEADS, {InboxView#line_for}'s shape: with a fleet
        # running, "who is asking" is what separates two identical-looking rows.
        # The release sentence sits between it and the call rather than at the
        # end, because `input.inspect` is unbounded and a warning past the edge
        # of a nomodifiable window is a warning nobody read.
        def row_for(pending)
          "#{pending.requester}  #{pending.outstanding.preamble}#{pending.tool}(#{pending.input.inspect})"
        end
      end
    end
  end
end
