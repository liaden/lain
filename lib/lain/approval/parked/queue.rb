# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "active_support/core_ext/string/filters"
require "active_support/core_ext/string/inflections"
require "async"
require "async/queue"

module Lain
  module Approval
    module Parked
      # {Middleware::Gate}'s policy seam, backed by a queue instead of a
      # terminal prompt: {#call} enqueues a {Pending} and PARKS the calling FIBER,
      # never the reactor, until a surface fiber decides it or the window expires.
      # Decoupling ask from answer is what lets any number of surfaces watch one
      # queue, and what makes every decision observable -- on a study bench "who
      # approved what, and how long the human took" is evidence.
      #
      # An expired window settles the pending through the injected
      # {Approval::Silence} rule, the same {Pending#decide} a surface answers
      # through, so Gate returns the refusal Result an interactive "n" or
      # "hold" produces. Bare, the rule denies; a chat's comes from its config.
      # {Gate::DenyAll} remains the default policy everywhere; this queue exists
      # only where a frontend wires it.
      class Queue
        include Enumerable

        # No surface made it: the window expired and the clock decided. A name,
        # not a nil, so journal readers never guard.
        TIMEOUT_SURFACE = "timeout"

        # The REQUESTER vanished -- the gated fiber was stopped while parked --
        # so nobody awaits the verdict and the only honest one is a denial signed
        # by the cancellation itself.
        ABANDONED_SURFACE = "abandoned"

        Remembered = Data.define(:reason, :authority, :contained, :secrets)

        # What the queue holds of an exact repeat, and whose answer it was, so a
        # refusal from memory journals the clock's no as the clock's. A denial
        # keeps the words the model is told; an allow keeps whether it ran
        # contained and what of the call's reads bore secrets when the human said yes.
        class Remembered
          def initialize(authority:, reason: nil, contained: false, secrets: []) = super
        end

        # What a human's yes to a call was shown of its secrets: each file holding a region, and each read not
        # scanned whole.
        #
        # @param disclosure [Disclosure]
        # @return [Array<String>] sorted, each once
        def self.secrets_of(disclosure)
          [*disclosure.holdings.select { _2.positive? }.keys, *disclosure.unscanned].uniq.sort.freeze
        end

        # Who stood behind an answer. Declared by the surface that gave it, never
        # read off the surface's name, so a surface nobody classified is a machine.
        AUTHORITIES = %i[automatic human].freeze

        # Generous because the answerer is a human at a terminal: a bound, not a
        # hurry -- an abandoned session must eventually refuse.
        DEFAULT_TIMEOUT = 300

        # Takes the text alone for a {Pending}'s mask and the text and its context for the queue's.
        UNMASKED = ->(text, _context = nil) { text }

        # Who a gated call is asked on behalf of when neither the call nor the
        # session names anyone: the parent's own turn.
        REQUESTER = Requester.main

        BASH = "bash"

        # A yes or no wanted on something that is not a tool call, so it never
        # passes for one: the secret oracle and the judge read tool calls.
        # `digest` is the bytes' hash and correlates the journal records.
        Decision = Data.define(:requester, :kind, :summary, :digest)

        # Lets a {Decision} ride the same Pending machinery without being an
        # Effect::ToolCall, which the secret oracle and the judge would read.
        Asked = Data.define(:name, :tool_use_id, :input)
        private_constant :Asked

        Outstanding = Data.define(:path, :regions)

        DECISIONS = { Verdict::Approve => :approve, Verdict::Hold => :postpone, Verdict::Deny => :deny }.freeze
        FACES = { approve: "approved", postpone: "postponed" }.freeze

        REASON_LIMIT = 400
        REASON_POINTER = "the full call is in lain://approval]"
        CUT_TAIL = Regexp.escape(REASON_POINTER)
        REASON_CUT = /\A.{#{REASON_LIMIT}}\[cut at #{REASON_LIMIT} of \d+ characters; #{CUT_TAIL}\z/m
        private_constant :REASON_LIMIT, :REASON_POINTER, :CUT_TAIL, :REASON_CUT

        # One line of why a call was parked. `own` marks lain's words, which a
        # surface shows plain; any other may carry a model-influenced path, so it
        # shows `inspect`ed and cannot open a line of its own.
        Reason = Data.define(:text, :own) do
          def self.own(text) = new(text:, own: true)

          def self.of(note) = note.is_a?(self) ? note : new(text: note, own: false)

          def initialize(text:, own: false) = super(text: -bounded(text.to_s), own: own == true)

          def own? = own

          def to_s = own? ? text : text.inspect

          private

          def bounded(text)
            return text if text.length <= REASON_LIMIT || REASON_CUT.match?(text)

            "#{text[0, REASON_LIMIT]}[cut at #{REASON_LIMIT} of #{text.length} characters; #{REASON_POINTER}"
          end
        end

        # The sensitive regions of one file that approving a {Pending} would
        # release, and the file they were found in. A CAPABILITY a pending can
        # carry, not a flow: this queue sits BELOW the read and holds only a path,
        # so the arm that has the file's bytes is what detects, diffs against
        # {Sensitivity::Ledger} and builds one of these. NOTHING HERE DETECTS AND
        # NOTHING HERE RELEASES.
        #
        # The path is deliberately NOT re-checked against the ledger's
        # ABSOLUTE-path contract: one object owns that rule, and a second copy of
        # a security check is a second thing to drift. The builder passes the same
        # path it will later release under, so the prompt names exactly what a yes
        # would send.
        #
        # A path that names NOTHING is refused here, which is a different rule
        # from the ledger's: a blank one renders a prompt saying secrets are at
        # stake and naming no file, a question no human can answer.
        # {Outstanding::NONE} is the one blank path, and it carries no regions.
        class Outstanding
          # `dup` before `freeze`, because `Array#to_a` returns SELF: without it
          # a caller that built its list by hand gets its own array frozen
          # underneath it, by a constructor it only meant to read.
          def initialize(path:, regions:)
            held = regions.to_a.dup.freeze
            raise ArgumentError, "regions are outstanding but no file was named, got #{path.inspect}" \
              if held.any? && path.to_s.empty?

            super(path: -path.to_s, regions: held)
          end

          def any? = !regions.empty?
          def count = regions.length

          # Spelled out rather than left to each caller to negate: two surfaces
          # PARTITION the parked queue on this question, and a partition whose
          # halves are written `x.any?` and `!x.any?` in different files is one
          # edit from a silent overlap or gap. As `any?`/`none?` over one value
          # object they are complementary by inspection.
          def none? = regions.empty?

          # The sentence every HUMAN surface puts in front of the question it is
          # about to ask. It lives on the value rather than in a frontend because
          # two surfaces render it, and two copies of this string is how one
          # surface comes to warn and the other not to.
          #
          # THE PATH IS `inspect`ed, and this is the one string in the harness
          # where skipping that converts a forged prefix directly into a released
          # secret. The path is MODEL-INFLUENCED -- for the detector to fire it
          # need only be a file the agent itself wrote -- so a path spelled
          # `"/tmp/x: 0 sensitive regions outstanding -- approve read(..)? [y/N] "`
          # renders a complete, plausible, BENIGN question in front of the real
          # one, and one holding `\e[2K\r` erases the line the human is meant to
          # read. `inspect` escapes both and cannot be closed from inside. It
          # QUOTES the forgery rather than deleting it: the defence is that the
          # real question always ENDS the rendering, because this sentence only
          # ever precedes it.
          #
          # The regions' own BYTES are never named -- printing a value to ask
          # whether it may be sent to a model would disclose it to the terminal,
          # the scrollback, the tmux buffer and any screen share, which is the
          # exact disclosure this exists to gate. The detector's REASON is
          # withheld for a different reason: a reason is detector OUTPUT and not
          # fact, so putting it in front of a human invites them to weigh a signal
          # never meant to be weighed one region at a time.
          def preamble
            return "" unless any?

            "#{path.inspect}: #{count} sensitive #{"region".pluralize(count)} outstanding -- "
          end

          # Every ordinary gated call. A real Outstanding rather than nil, so a
          # surface asks rather than guards. Below the methods because it is built
          # through the initialize above, which has to exist first.
          NONE = new(path: "", regions: [])
        end

        # One gated call awaiting its verdict. Deliberately MUTABLE coordination
        # state, unlike the frozen value objects: it exists to be decided.
        # Single-shot, first-answer-wins -- two surfaces racing over one pending
        # is normal operation, so the loser's answer is a quiet no-op here and NOT
        # the coordination bug {Promise::AlreadyResolved} names.
        #
        # `identity` is who asked, whole; `requester` is its name, the key a denial
        # is held under and what the journal keeps, and `label` is what a surface shows.
        class Pending
          attr_reader :identity, :tool, :tool_use_id, :input, :outstanding, :surface, :decision, :latency, :cwd,
                      :within, :timeout, :reason, :authority, :spawn, :containment

          # Defaulting here is NOT the ledger's no-default rule bent: a defaulted
          # LEDGER lets a forgotten injection become a second ledger whose
          # releases nobody sees, and there is no second anything here -- a
          # missing one renders the ordinary prompt and still releases nothing.
          #
          # An EXPLICIT nil resolves to the same {Outstanding::NONE}, and that is
          # not belt-and-braces: `outstanding:` is public on {Queue#adjudicate},
          # every surface dereferences it, and a surface fiber that raises
          # silently stops watching for the rest of the session. This is the one
          # constructor that can enforce "Null Object over nil" for every reader
          # at once.
          #
          # `humans_only` is a call whose automatically approved output was
          # withheld: only a person may decide it, so a machine surface is not
          # offered it.
          #
          # `cwd` is where the parked call's relative path resolves, so a surface
          # judging that path lands it where the gate did; absent, it is the
          # process's, as for a call made with no session. `within` is where the
          # gate counted directory names from, see {Sensitivity::Policy.base_of}.
          # `file_facts` is what the path's landing is read off at construction.
          # `named` is the paths a bash call names, as its stack read them; absent,
          # they are read off the command when first asked. `containment` is what
          # a plain approval of this call does when it reads secrets; a call that
          # reads none is handed the unstated one, and is offered no network answer.
          # `mask` takes the face's text alone and returns it with known secrets masked. `secrets` is what of the
          # call's reads bore secrets when it parked, which a human's yes was shown, as {Queue.secrets_of} names it.
          # `files` is every file it read, by absolute path and digest, as {Disclosure#whole_files} names them.
          def initialize(effect:, identity:, clock:, timeout: DEFAULT_TIMEOUT,
                         outstanding: Outstanding::NONE, humans_only: false, cwd: ::Lain::Session.cwd_of(nil),
                         within: cwd, wall: -> { Time.now }, notes: [], file_facts: ::Lain::FileFacts::LIVE,
                         silence: Silence::DENY, spawn: nil, named: nil,
                         containment: ::Lain::Confine::Sandbox::Containment::NONE, mask: UNMASKED, secrets: [],
                         files: [])
            held(secrets, files)
            @mask = mask
            @spawn = spawn
            @containment = containment
            @timeout = timeout
            @silence = silence
            @reasons = notes.map { Reason.of(_1) }.freeze
            @notes = @reasons.map(&:text).freeze
            @wall = wall
            @humans_only = humans_only == true
            take(effect, named)
            place(cwd, within, file_facts)
            @outstanding = outstanding || Outstanding::NONE
            @identity = identity
            begin_asking(clock)
          end

          def held(secrets, files)
            @secrets = secrets.dup.freeze
            @files = files.dup.freeze
          end
          private :held

          def begin_asking(clock)
            @clock = clock
            @asked_at = clock.call
            @promise = Promise.new
            @offered = nil
            @network = false
            @unmasked = false
          end
          private :begin_asking

          # @return [String, nil] where the path this call names lands when that
          #   differs, read off the facts the queue was built over at park time
          attr_reader :landing

          # @return [String] the asking identity's name
          def requester = identity.name

          # @return [String] the asking identity as a surface shows it
          def label = identity.to_s

          def take(effect, named)
            @named = named
            @tool = effect.name
            @tool_use_id = effect.tool_use_id
            @input = effect.input
            @input_digest = tool_call? ? ::Lain::Effect.input_digest(input) : nil
          end
          private :take

          def place(cwd, within, file_facts)
            @cwd = cwd
            @within = within
            @landing = path && ::Lain::Landing.redirect(path, cwd:, facts: file_facts)
          end
          private :place

          # A decision's `tool_use_id` is already the digest of what it asks.
          #
          # @return [String, nil] what the journal names the input's bytes by
          attr_reader :input_digest

          # Answers whether THIS answer won; a later answer returns false and
          # changes nothing. Latency is stamped decision-side, so it measures how
          # long the verdict took, not how long the woken fiber waited to be
          # scheduled.
          #
          # Releasing an {Outstanding}'s regions to {Sensitivity::Ledger} is the
          # SETTLING CALLER's move, never this method's, and the invariant is this
          # method's own: single-shot resolution is safe WITHOUT A LOCK only
          # because the `decided?` guard and the resolve below it are
          # straight-line with no yield point between them. A ledger write is
          # IO-shaped and would open exactly that gap. This queue holds no ledger
          # at all, which is how that stays true.
          #
          # A deny's or a hold's note is the human's own words, which the model
          # reads as the last clause of its tool result; an approval's is kept
          # apart, for the journal only. Flattened to one line with no control
          # bytes, so it cannot open a line or a sequence of its own.
          #
          # `authority` defaults to automatic so that a surface which forgets to
          # declare fails safe: its allow is suppressed over a fault like any
          # machine's. Only a surface a person answers passes `:human`.
          #
          # @param verdict [Verdict::Approve, Verdict::Hold, Verdict::Deny]
          # @param surface [#to_s] the surface that answered
          # @param authority [Symbol] one of {AUTHORITIES}
          # @return [Boolean] whether this answer won
          # @raise [ArgumentError] for an authority outside {AUTHORITIES}, or anything but a verdict
          def decide(verdict, surface:, authority: :automatic)
            verdict = Verdict.coerce(verdict)
            raise ArgumentError, "unknown authority #{authority.inspect}" unless AUTHORITIES.include?(authority)
            return false if decided?

            resolve(verdict, surface, authority)
            true
          end

          def resolve(verdict, surface, authority)
            @surface = surface.to_s
            @authority = authority
            @decision = DECISIONS.fetch(verdict.class)
            @network = verdict.network?
            @unmasked = verdict.secrets? && authority == :human && offers_secrets?
            @reason = flattened(verdict.note) unless verdict.approved?
            @approval_note = flattened(verdict.note) if verdict.approved?
            @latency = @clock.call - @asked_at
            @promise.resolve(@decision)
          end
          private :resolve

          def humans_only? = @humans_only

          # @return [Array<String>] what of the call's reads bore secrets when it parked
          attr_reader :secrets

          # @return [Array<Array(String, String)>] each file the call read when it parked, absolute, with its digest
          attr_reader :files

          # @return [Boolean] whether a surface offers the network answer: the call reads secrets and the
          #   session confines such a call
          def offers_network? = containment.confines?

          # @return [Boolean] whether the approval chose network
          def network? = @network

          # Only where the call can run contained, since its secrets are read only with the network closed.
          #
          # @return [Boolean] whether a surface offers the secrets answer
          def offers_secrets? = containment.able?

          # A machine's secrets answer is no person's choice, so it unmasks nothing.
          #
          # @return [Boolean] whether a human's approval chose to run the call with the project's masks lifted
          def unmasked? = @unmasked

          # Any surface's, since a machine's approval is no more consent to network than a person's plain one.
          #
          # @return [Boolean] whether an approval is to run the call contained, with no network beyond a build
          #   tool's granted ports
          def contained? = approved? && offers_network? && !network?

          # The row's file list goes through the row's mask, as the call does, since a file's name can hold a token.
          # Both are masked as 1 text, so 2 values on 1 row never share a placeholder's number.
          #
          # @param call [String] how the answer names the call
          # @return [String, nil] what y, network and secrets do, masked; nil where no answer beyond y is offered
          def choice_face(call = "it")
            containment.choice(call)&.then { @mask.call("#{call_text}\n#{_1}").split("\n", 2).last }
          end

          # @param text [String]
          # @return [String] the text with the row's known secrets masked, as {#call_face} is
          def masked(text) = @mask.call(text)

          # @return [String] what the journal and the surfaces call this pending's kind
          def kind = "tool"

          def tool_call? = true

          # @return [String] the question a surface asks, in its own words
          def call_face = @mask.call(call_text)

          def call_text = ["#{tool}(#{input.inspect})", cwd_face].compact.join(" ")
          private :call_text

          # The command is masked before the cut, and the journal keeps this line instead of the input.
          #
          # @return [String] the tool and, for a shell call, its command, in one bounded line
          def summary_face
            command = input["command"] if input.is_a?(Hash)
            ::Lain::Frontend::TTY::Notifier.plain([tool, (command if command.is_a?(String))].compact.join(" "),
                                                  mask: @mask)
          end

          # Where a relative path in the call lands, so a surface says it beside the call.
          #
          # @return [String, nil] nil when the call names no relative path
          def cwd_face = ("in #{cwd.inspect}" if relative_path?)

          # @return [String] the rest of "asks ..." in a surface's sentence
          def ask_face = "to run #{call_face}"

          # @return [Array<Reason>] why the ladder parked this call, in order
          attr_reader :reasons

          # @return [Array<String>] the words of each reason, for the journal
          attr_reader :notes

          # A surface that asks one call at a time says when this one reached the
          # front, and the queue's window then runs from there, not from the park.
          def drawn = @drawn ||= @clock.call

          # @return [Numeric, nil] the clock reading at the first {#drawn}
          def drawn_at = @drawn

          # Seconds until the queue settles this call unasked. The window runs from
          # the draw when a surface drew it and from the park otherwise, which is
          # the queue's own rule in {Queue#await_decision}. It reads the clock
          # the queue was built with, so a view showing it stays a projection.
          #
          # @return [Numeric]
          def remaining = [(drawn_at || @asked_at) + @timeout - @clock.call, 0].max

          # @return [String] {#remaining} as minutes and seconds, rounded up
          def remaining_face = Queue.face(remaining)

          # The wall-clock moment the call settles unasked. {#remaining_face} is true
          # only at the instant it is read, and a view that does not redraw would
          # keep showing it; this does not move, so a stale render stays true.
          #
          # @return [String] HH:MM:SS on the injected wall clock
          def fires_at_face = (@wall.call + remaining).strftime("%H:%M:%S")

          # @return [String] {#fires_at_face}'s moment, whole, for the journal
          def deadline = ::Lain::Telemetry::AwaitingHuman.deadline(remaining, from: @wall.call)

          # @return [String] the whole window, in {#remaining_face}'s spelling
          def window_face = Queue.face(@timeout)

          # The sentence every surface says when the clock, and nobody, decided.
          # Here for the reason {Outstanding#preamble} is on its value: two
          # surfaces word it, and two copies are how they come to disagree.
          def lapse = "#{@silence.past} after #{window_face} with no answer"

          # @return [String] what the model reads of this call while it waits for a human
          def told = @silence.told(self)

          # @return [String] what the window's close will do, as a prompt warns of it
          def silence_face = "#{@silence.warning} in #{window_face}"

          # @return [String] what the window's close will do, and the {#fires_at_face} moment it does it
          def settles_at_face = "#{@silence.warning} at #{fires_at_face}"

          # The clock's verdict, settled through {#decide} so a surface that
          # answered in the same tick still wins.
          #
          # @return [Boolean] whether the clock's verdict won
          def lapsed = decide(@silence.verdict(@timeout), surface: TIMEOUT_SURFACE)

          # The path this call's input names, read from the table
          # {Sensitivity::Policy} classifies by, and only a String: a value the
          # policy would coerce is one no surface is shown.
          #
          # @return [String, nil]
          def path
            field = ::Lain::Sensitivity::Policy::PATH_FIELDS[@tool.to_s]
            value = field && @input.is_a?(Hash) && (@input[field] || @input[field.to_sym])
            value if value.is_a?(String)
          end

          # @return [Shell::Named, nil] the paths a bash call names; nil for any other tool
          def named
            return unless tool == BASH

            @named ||= ::Lain::Shell::Named.for_input(input, cwd:, home: Dir.home)
          end

          def relative_path?
            return path.present? && !path.start_with?("/", "~") unless tool == BASH

            named.paths.any? { !_1.absolute? && !_1.word.start_with?("-") }
          end
          private :relative_path?

          def approve(surface:, authority: :automatic) = decide(Verdict::Approve.new, surface:, authority:)

          def deny(surface:, authority: :automatic, reason: nil)
            decide(Verdict::Deny.new(note: reason), surface:, authority:)
          end

          # A reason the human gave before answering, as `/deny <reason>` does,
          # for the length of the block; an offering inside another gives the
          # outer one back as it ends. It is held here rather than on one
          # prompt because the human's `n` may land at any prompt asking about
          # this call, the watcher's included.
          #
          # @param reason [String, nil]
          # @return [Object] the block's value
          def offering(reason)
            outer = @offered
            @offered = reason
            yield
          ensure
            @offered = outer
          end

          # @return [String, nil] the reason {#offering} holds, while it holds one
          def offered_reason = @offered

          def human? = authority == :human
          def decided? = @promise.resolved?
          def approved? = @decision == :approve

          # A hold: the human will answer this call later, so it is refused now
          # without being a judgement against it.
          def postponed? = @decision == :postpone

          # The decision as every surface says it in a sentence, so two never word it apart.
          #
          # @return [String] "approved", "postponed" or "denied"
          def verdict_face = FACES.fetch(@decision, "denied")
          def timed_out? = @surface == TIMEOUT_SURFACE
          def abandoned? = @surface == ABANDONED_SURFACE

          # What a surface says of a call nobody answered: the clock's sentence,
          # or the stop's, so a stopped requester is never reported as a decision.
          def closure = abandoned? ? "closed: its requester was stopped" : lapse

          # Whether the call left the parked set with no answer to report.
          def unanswered? = timed_out? || abandoned?

          # Park the calling fiber until decided (see Promise#await).
          def await = @promise.await

          # `outstanding` is ABSENT and must stay absent, and `input` with it.
          # This pending may hold the sensitive regions a yes would release, bytes
          # included, and the only thing keeping them off disk is that this
          # hand-maintained list does not name them. Adding the field writes real
          # credentials into the Journal with no test to notice, since every test
          # here asserts the fields that ARE listed.
          # {Telemetry::AwaitingHuman.approval} carries the identical note, and
          # the command's text reaches the record only as its masked, cut `summary`.
          #
          # `tool_use_id` is what pairs this decision with its `awaiting_human`:
          # parallel calls park together and are decided in any order, so a count
          # pairs the wrong ones. It is not unique: one `read_file` can park twice
          # under one id, at the path gate and again at the release, one after the
          # other, so within an id the records pair IN ORDER. Who released a
          # secret is `read_released`'s `surface`, not a join onto a decision.
          #
          # `reason` is written only when a human gave one, so a session recorded
          # before reasons existed reads the same as a bare denial does now.
          def to_journal
            { "type" => "approval_decision", "tool_use_id" => tool_use_id, "requester" => requester,
              "tool" => tool, "surface" => surface, "verdict" => decision.to_s, "timed_out" => timed_out?,
              "latency" => latency }.merge(reason ? { "reason" => reason } : {}, digest_entry, kind_entry,
                                           network? ? { "network" => true } : {},
                                           unmasked? ? { "secrets" => true } : {},
                                           @approval_note ? { "note" => @approval_note } : {})
          end

          private

          def flattened(words) = words.to_s.gsub(/[[:cntrl:]]/, " ").squish.presence

          def kind_entry = tool_call? ? {} : { "kind" => kind }

          def digest_entry = input_digest ? { "input_digest" => input_digest } : {}
        end

        # Reuses Pending's park, journal and surface machinery so no surface
        # needs a second queue; `tool` is the kind and `tool_use_id` the digest
        # so the journal pairs it as it pairs a call.
        class DecisionPending < Pending
          attr_reader :kind

          def initialize(decision:, **)
            super(effect: Asked.new(decision.kind, decision.digest, decision.summary), humans_only: true, **)
            @kind = decision.kind
            @summary = decision.summary
          end

          def tool_call? = false

          # `inspect`ed because the summary can carry model-influenced text.
          def call_face = "#{kind}: #{@summary.inspect}"

          def ask_face = call_face
        end

        # The queue of a run with nobody to ask: every decision is refused at
        # once and the refusal journaled, so the record still shows it was asked.
        class Unattended
          REASON = "no human is attached to answer"
          SURFACE = "unattended"

          def initialize(journal:, clock: RunClock::MONOTONIC)
            @journal = journal
            @clock = clock
          end

          # @return [Boolean] false
          def ask_decision(decision, timeout: nil)
            pending = DecisionPending.new(decision:, identity: Requester.of(decision.requester), clock: @clock,
                                          timeout: timeout || DEFAULT_TIMEOUT)
            pending.deny(surface: SURFACE, reason: REASON)
            @journal.record(pending.to_journal)
            false
          rescue StandardError
            false
          end
        end

        # @param journal [#record] where decisions land as evidence; required,
        #   not defaulted, because silently unjournaled approvals would be a hole
        #   in the experiment record
        # @param requester [Requester, String] who a gated call is asked on behalf of when
        #   the call itself names nobody -- the SESSION's default, not the fleet's
        #   answer; see {.identity_for}
        # @param timeout [Numeric] seconds an unanswered pending waits before the
        #   silence rule settles it
        # @param clock [#call] monotonic seconds, injectable so specs pin latency
        # @param wall [#call] the time of day, as a Time, for naming when a call fires
        # @param home [String, nil] what `~` means in a denied command, from
        #   {Sensitivity::Policy#home}; with none, a command spelling a path
        #   with `~` is not remembered
        # @param file_facts [FileFacts::Live, FileFacts::Recorded] where a denied path lands, from
        #   {Sensitivity::Policy#file_facts}
        # @param silence [Silence::Hold, Silence::Deny] what an unanswered window settles as
        # @param containment [Confine::Sandbox::Containment, Confine::Sandbox::Containment::Deferred]
        #   whether the session can run a call that reads secrets
        #   contained, which a plain approval of one does; unstated, the row says nothing of it
        # @param mask [#call] `(text, context)` to the text with the session's known secrets masked; it only
        #   changes what a surface shows, never what the call runs
        # @param verdict [Shell::Verdict] the session's one shell verdict, which decides whether bash runs a call
        #   as argv, so whether a build tool's ports could be granted
        def initialize(journal:, requester: REQUESTER, timeout: DEFAULT_TIMEOUT, clock: RunClock::MONOTONIC,
                       wall: -> { Time.now }, home: nil, file_facts: FileFacts::LIVE, silence: Silence::DENY,
                       containment: Confine::Sandbox::Containment::NONE, verdict: ::Lain::Shell::Verdict.new(home:),
                       mask: UNMASKED)
          @mask = mask
          @journal = journal
          @containment = containment
          @verdict = verdict
          @silence = silence
          @home = home
          @file_facts = file_facts
          @requester = Requester.of(requester)
          @timeout = timeout
          @clock = clock
          @wall = wall
          @arrivals = Async::Queue.new
          # A plain Array with NO LOCK, on purpose: every @parked mutation is
          # straight-line Ruby with no yield point, and a fiber only interleaves
          # at an IO yield -- the parks in #call/#dequeue sit BETWEEN mutations,
          # never inside one. So N gated fibers admit N independent pendings. If
          # queue_concurrency_spec.rb can only pass by adding a lock here, the
          # claim has failed -- escalate, don't patch.
          @parked = []
          remember_nothing
        end

        # @param seconds [Numeric]
        # @return [String] minutes and seconds, a part second rounded up so a
        #   face never reads out of time while the call still has some
        def self.face(seconds)
          whole = seconds.ceil
          format("%<minutes>d:%<seconds>02d", minutes: whole / 60, seconds: whole % 60)
        end

        # Gate's policy seam. Parking here is safe inside tool dispatch because
        # the surface that answers runs as a SIBLING fiber in the same reactor.
        def call(effect, context) = adjudicate(effect, context).approved?

        # The same lifecycle, answering the SETTLED {Pending} instead of its
        # Boolean. A caller that has to attribute the verdict needs the SURFACE
        # that made it, and the authority that surface declared -- the ladder
        # honours a human's allow over a fault and suppresses a machine's -- and
        # a Boolean cannot carry that. {#call} is the Boolean for a caller that
        # needs only the answer.
        #
        # `outstanding:` is how the one arm holding a file's bytes tells the
        # surfaces what a yes would release. Answering the settled {Pending} is
        # what lets that caller write the ledger itself.
        def adjudicate(effect, context, outstanding: Outstanding::NONE)
          pending = admit(effect, context, outstanding)
          settle(pending)
          pending
        end

        # @param decision [Decision]
        # @param timeout [Numeric, nil] seconds before the silence rule settles it; the queue's own when nil
        # @return [Boolean] true to proceed
        def ask_decision(decision, timeout: nil)
          pending = DecisionPending.new(decision:, identity: Requester.of(decision.requester), clock: @clock,
                                        timeout: timeout || @timeout, wall: @wall, silence: @silence)
          park(pending)
          settle(pending)
          pending.approved?
        end

        # ONE queue serves the whole fleet, so a queue-level constant journals and
        # renders every pending identically -- which is how a researcher
        # subagent's `bash` prompt came to be indistinguishable from the human's
        # own agent's. The CALL says so instead, through the context the policy
        # seam already threads.
        #
        # `fallback` is the SESSION's answer for contexts that name nobody, so
        # nothing asking here journals a blank. Public, because a read guard with
        # no queue to park on still has to say whom its release was for.
        #
        # @param context [Object, nil] the context a call is judged in
        # @param fallback [Requester] who is asking when the context names nobody
        # @return [Requester]
        def self.identity_for(context, fallback = REQUESTER)
          context.respond_to?(:identity) ? context.identity : fallback
        end

        # The reason a human gave when they denied this requester a call on
        # `path`, on where it lands, or on a directory above either; "" when
        # they gave none.
        #
        # @param requester [String] as {.identity_for} names it
        # @param path [String] absolute and resolved, see {Shell::Named.resolved}
        # @return [String, nil] nil when no such denial was given
        def denied(requester:, path:)
          held = @denials.fetch(requester, {})
          return if held.empty?

          [path, *landings(path)].lazy.filter_map { |asked| held.find { |denied, _| at_or_below?(asked, denied) } }
                                 .first&.last
        end

        # The denial of this requester's exact call, run from the same
        # directory: a human's, in their words ("" when they gave none), or the
        # silence rule's, in the words the model was told.
        #
        # @param requester [String] as {.identity_for} names it
        # @param tool [String] as the call named it
        # @param input [Object] the call's input, compared whole
        # @param cwd [String] absolute; the session's directory for the call
        # @return [Remembered, nil] nil when no such denial was given
        def denied_call(requester:, tool:, input:, cwd:) = @calls.fetch(requester, {})[[tool, input, cwd]]

        # A human's plain allow of this requester's exact call, run from the same
        # directory: never a network answer or a released secret, and gone once
        # the human denies the same call.
        #
        # @param requester [String] as {.identity_for} names it
        # @param tool [String] as the call named it
        # @param input [Object] the call's input, compared whole
        # @param cwd [String] absolute; the session's directory for the call
        # @return [Remembered, nil] nil when no such allow was given
        def allowed_call(requester:, tool:, input:, cwd:) = @allows.fetch(requester, {})[[tool, input, cwd]]

        # Each human secrets answer to this requester's calls whose every file was read whole, as the files it
        # was shown. The queue holds no ledger, so the one rung that replays a release records these into the run's.
        #
        # @param requester [String] as {.identity_for} names it
        # @return [Array<Array<Array(String, String)>>] in the order answered
        def released_files(requester:) = @releases.fetch(requester, []).dup.freeze

        # A human's line is the answer the silence rule's denials lacked, so
        # each of them parks again when resent. A human's own denial stays.
        #
        # @return [void]
        def forget_lapsed
          @calls.each_value { |calls| calls.delete_if { |_call, remembered| remembered.authority == :automatic } }
        end

        # Async::Queue is buffered, so a pending enqueued before any surface
        # watched is delivered, never missed. Already-decided arrivals -- an
        # abandoned pending cannot be removed from the arrival queue itself -- are
        # skipped, so a surface never prompts a human for a call nobody awaits.
        def dequeue
          pending = @arrivals.dequeue
          pending.decided? ? dequeue : pending
        end

        # Oldest first -- what a second surface, or the bench, inspects without
        # draining the arrival queue.
        def each(&block) = @parked.each(&block)

        # @return [FileFacts::Live, FileFacts::Recorded] what a remembered denial's landing is read off
        attr_reader :file_facts

        # @return [Confine::Sandbox::Containment, Confine::Sandbox::Containment::Deferred]
        #   what a plain approval of a call that reads secrets does
        attr_reader :containment

        private

        def remember_nothing
          @denials = {}
          @calls = {}
          @allows = {}
          @releases = {}
        end

        # Journaled BEFORE the pending is parked, never between the two mutations
        # below: the record is a write, a write can yield the fiber, and @parked's
        # lock-freedom rests on `<<` and `enqueue` staying straight-line with no
        # yield point between them.
        def admit(effect, context, outstanding)
          disclosure = Disclosure.in(context)
          containment = containment_for(effect, context, disclosure)
          pending = Pending.new(effect:, identity: Queue.identity_for(context, @requester), clock: @clock,
                                timeout: @timeout, wall: @wall, outstanding:,
                                humans_only: context.respond_to?(:automatic_approval_barred?) &&
                                             context.automatic_approval_barred?,
                                notes: notes_of(context, disclosure), named: named_of(effect, context),
                                cwd: ::Lain::Session.cwd_of(context),
                                within: ::Lain::Sensitivity::Policy.base_of(context),
                                file_facts: @file_facts, silence: @silence,
                                spawn: context.respond_to?(:spawn) ? context.spawn : nil, containment:,
                                secrets: Queue.secrets_of(disclosure), files: disclosure.whole_files,
                                mask: ->(text) { @mask.call(text, context) })
          park(pending)
        end

        # The containment stays off the reasons: the phone shows them and cannot answer network.
        def notes_of(context, disclosure)
          [*(context.parked_because if context.respond_to?(:parked_because)), *disclosure.notes]
        end

        # Under the root a bash call runs under, as the sandbox reads it, so the row names the files the run would
        # lift.
        def containment_for(effect, context, disclosure)
          return Confine::Sandbox::Containment::NONE unless disclosure.secret_bearing?

          checkout = context.worker_env.checkout if context.respond_to?(:worker_env)
          @containment.over(term_argvs(effect, context), root: checkout)
        end

        # Bash runs argv only for a term the session's verdict allows, and a build grant needs argv, so this
        # decides as {Tools::Bash} does, off the same verdict and the same parse.
        def term_argvs(effect, context)
          command = effect.input["command"] if effect.name == BASH
          return [] unless command.is_a?(String)

          parsed = ::Lain::Middleware::ParsedCommand.carried(command, context)
          decision = parsed ? @verdict.of(parsed) : @verdict.call(command)
          decision.allow? ? decision.term.stages.map(&:argv) : []
        end

        def named_of(effect, context)
          ::Lain::Middleware::ParsedCommand.named_in(effect, context, home: @home) if effect.name == BASH
        end

        def park(pending)
          record_evidence(Telemetry::AwaitingHuman) { Telemetry::AwaitingHuman.approval(pending) }
          @parked << pending
          @arrivals.enqueue(pending)
          pending
        end

        # `ensure`, because the requester can be STOPPED while parked: Ctrl-C
        # unwinds this fiber with Async::Stop, which the timeout rescue never
        # sees, and the pending must still leave the parked list, still journal,
        # and still end up decided. The abandonment deny is a no-op on the normal
        # path, and is what makes a late surface answer harmless.
        def settle(pending)
          await_decision(pending, pending.timeout)
        ensure
          pending.deny(surface: ABANDONED_SURFACE)
          @parked.delete(pending)
          remember(pending)
          retire_arrivals
          record_evidence(Pending) { pending }
        end

        # Straight-line with no yield, as every @parked mutation is, so it can
        # sit in {#settle}'s `ensure` without opening a gap between fibers; a
        # realpath is a plain syscall, not a scheduler hook. A declined release
        # is a no about a file's regions, not about its path.
        #
        # A silence deny holds only the exact call, in the words the model was
        # told: nobody judged its paths, but resending it would only wait again.
        def remember(pending)
          return unless pending.outstanding.none?

          if human_allow?(pending)
            remember_allow(pending)
          elsif human_release?(pending)
            remember_release(pending)
          elsif human_denial?(pending)
            reason = pending.reason.to_s
            denied_paths(pending).each { (@denials[pending.requester] ||= {})[_1] = reason }
            remember_call(pending, reason)
          elsif silence_denial?(pending)
            remember_call(pending, pending.told)
          end
        end

        def remember_call(pending, reason)
          @allows.fetch(pending.requester, {}).delete(call_key(pending))
          (@calls[pending.requester] ||= {})[call_key(pending)] = Remembered.new(reason:, authority: pending.authority)
        end

        def remember_allow(pending)
          (@allows[pending.requester] ||= {})[call_key(pending)] =
            Remembered.new(authority: :human, contained: pending.contained?, secrets: pending.secrets)
        end

        def remember_release(pending)
          (@releases[pending.requester] ||= []) << pending.files unless pending.files.empty?
        end

        def call_key(pending) = [pending.tool, pending.input, pending.cwd]

        # A command's file word that is a link to a directory names a file to
        # the human, so the tree it lands on is not held against later calls.
        def denied_paths(pending)
          if pending.tool == BASH
            named_files(pending).flat_map { |path| [path, *landings(path).reject { @file_facts.directory?(_1) }] }
          else
            lexical = pending.path && ::Lain::Shell::Named.resolved(pending.path, pending.cwd, home: @home)
            lexical ? [lexical, *landings(lexical)] : []
          end
        end

        # A link to nothing keeps only its own name: its target could be
        # created anywhere later, and a guess at it would refuse the wrong file.
        def landings(path)
          Landing.of(path, cwd: File::SEPARATOR, home: @home, facts: @file_facts) - [path]
        rescue ::Lain::Error, SystemCallError, ArgumentError, EncodingError
          []
        end

        # The directory a command runs in, anything above it, a `cd` target and
        # a glob's or a search's root are each only where the files it touched
        # live, so remembering one would refuse a whole tree the human was never
        # asked about. A word starting with a dash is an option, whatever value
        # it was read as carrying.
        def named_files(pending)
          directory = ::Lain::Shell::Named.directory_of(pending.input, cwd: pending.cwd, home: @home)
          named = pending.named
          return [] if named.opaque?

          places = [directory, *named.paths.select(&:directory).map(&:resolved)]
          named.paths.select { file_word?(_1) }.map(&:resolved).reject { |path| places.any? { at_or_below?(_1, path) } }
        end

        def file_word?(path) = !(path.directory || path.pattern || path.word.start_with?("-"))

        def at_or_below?(place, path) = place == path || place.start_with?(below(path))

        # A machine's no, the clock's, or one a fault forced, is not a person's
        # judgement about a path, and a hold is a person's "not yet", so none of
        # these is held against a later call's paths.
        def human_denial?(pending) = pending.tool_call? && pending.human? && pending.decision == :deny

        # A network or secrets answer is consent for that run only, so neither is replayed as given; a secrets
        # answer's files are kept instead, for a later read of them with the masks standing.
        def human_allow?(pending)
          pending.tool_call? && pending.human? && pending.approved? && !pending.network? && !pending.unmasked?
        end

        def human_release?(pending) = pending.tool_call? && pending.human? && pending.approved? && pending.unmasked?

        def silence_denial?(pending) = pending.tool_call? && pending.timed_out? && pending.decision == :deny

        def below(path) = path.end_with?("/") ? path : "#{path}/"

        # Only undecided work stays buffered. A surface that observes the parked
        # set rather than consuming arrivals -- all a cockpit has -- would
        # otherwise leave every decided pending, input and all, referenced here
        # for the rest of the session. Non-blocking pops and pushes with no
        # yield between them, so no park or settle interleaves, and a live
        # pending keeps its place in line.
        def retire_arrivals
          buffered = Array.new(@arrivals.size) { @arrivals.dequeue(timeout: 0) }
          @arrivals.enqueue(*buffered.compact.reject(&:decided?))
        end

        # Evidence about a turn must never COST the turn. Both writes sit on
        # {Gate}'s policy seam, ABOVE {Effect::Handler::Live} -- nothing below is
        # left to turn an exception into a {Tool::Result}, so a closed Journal
        # would unwind through the agent loop and hand the user a dead turn
        # instead of the denial an unanswerable approval is owed. On the settle
        # path the raise would land inside `ensure` and REPLACE the verdict, which
        # is the same defect one step worse.
        #
        # Loud therefore means a denial plus a recorded reason, wearing the
        # Journal's own `journal_error` shape so a reader has one failure record
        # to know rather than two.
        #
        # The entry is BUILT IN THE BLOCK, never passed as an argument: an
        # argument is evaluated before control enters this method, so a record
        # whose own construction raises would escape past the very protection this
        # exists to give. `kind` names what was being recorded, because a raise
        # mid-construction leaves no instance to name.
        def record_evidence(kind, &entry)
          @journal.record(yield)
        rescue StandardError => e
          degrade(kind, e)
        end

        # When even the degraded write fails the journal is gone and there is
        # nowhere left to be honest to. Swallowing is the only option that still
        # refuses rather than wedging.
        def degrade(kind, error)
          @journal.record("type" => "journal_error", "error" => "#{error.class}: #{error.message}",
                          "entry_class" => kind.name)
        rescue StandardError
          nil
        end

        # The expired window IS a decision, routed through the same single-shot
        # {Pending#decide}, so a surface that answered in the same tick still wins
        # and a later answer is a no-op. A hold settles as a postpone, so the
        # abandonment deny in {#settle}'s ensure finds it decided.
        #
        # A pending drawn after it parked is owed the rest of a whole window from
        # the draw, so a call queued behind a slow answer is not denied unasked.
        def await_decision(pending, window = @timeout)
          Async::Task.current.with_timeout(window) { pending.await }
        rescue Async::TimeoutError
          left = pending.drawn_at ? pending.drawn_at + pending.timeout - @clock.call : 0
          left.positive? ? await_decision(pending, left) : pending.lapsed
        end
      end
    end
  end
end
