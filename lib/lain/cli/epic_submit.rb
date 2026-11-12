# frozen_string_literal: true

require "async"

module Lain
  module CLI
    # `lain epic submit STAGE [SLUG]`: put one stage's artifact in front of its
    # gate, and report the verdict.
    #
    # Everything here is assembly: this class picks the epic, reads the artifact,
    # wires {Epic::Submission}, {Lain::Epic::Gate::Policies},
    # {Lain::Epic::Gate}, {Lain::Epic::Gate::Policy::Boundary} and
    # {Epic::Scribe} together, and turns what comes back into a String. It prints
    # nothing.
    #
    # == Wiring is resolved before anything is decided
    #
    # {Lain::Epic::Gate::Policies.for_all} resolves EVERY stage's policy, not just
    # the one being submitted, which is what makes an unbuildable policy a startup
    # refusal naming the stage, the policy and the seam, rather than a
    # NoMethodError on the first overnight gate with nobody watching.
    #
    # The refusal is raised, not returned: `exe/lain` renders a {Lain::Error} as a
    # message with a nonzero exit, where a message returned as normal output would
    # exit 0 and read as a decision.
    #
    # == Draining is journaling, here too
    #
    # Nothing here holds state between invocations. A verdict is a journaled
    # {Lain::Epic::GateDecision}; a deferral is that record plus a park the next
    # fold rebuilds; what an approval advances is {Epic::Advance}'s to write.
    #
    # == Every constant from the epic tier is spelled in full
    #
    # A bare `Epic` resolves to the sibling {CLI::Epic}, so every
    # `Lain::Epic::...` reference below is spelled out (see {CLI::Epic}'s header).
    class EpicSubmit
      # An implementation is built to an approved plan, so its gate refuses to
      # open until the issue's plan AS IT STANDS -- criteria included -- carries
      # an approval. Its own class because the remedy is a different command.
      class PlanNotApproved < Error
        include RefusedBeforeActing
      end

      # The y/n prompt this command owns, on the streams it was handed. Both are
      # INJECTED and neither defaults to the process's own, because only the
      # frontend may touch `$stdout`/`$stderr`.
      #
      # `#ask` writes the question and returns an UNRESOLVED promise: the read
      # runs on a fiber of its own, so {Lain::Epic::Gate#await}'s clock -- which
      # starts once `#ask` returns -- spans the actual wait rather than a wait
      # already over. Resolving synchronously, as this used to, made every
      # journaled latency read as instant no matter how long a human took to
      # answer. The fail-closed default still holds for every reply that is
      # not affirmative, EOF included -- and EOF is journaled as
      # {Lain::Epic::GateReply::EOF}, because nobody typed the denial it
      # stands for.
      class Prompt
        # Spelled the way {CLI::EpicQueue} already spells a human sign-off: one
        # string, no second constant to drift.
        SURFACE = EpicQueue::HUMAN

        # Why a session on these streams has nobody to ask, in the words the
        # refusal of an interactive stage says it.
        NO_TERMINAL = "stdin is not a terminal"
        NO_OUTPUT = "there is nowhere to write the gate's question"
        # For a caller that handed over working streams and no asker anyway.
        NO_ASKER = "this session wired no asker"

        # Said after every question, a wave's included, so it promises no
        # grammar of its own: the question names its words, and a blank denies.
        CUE = "[reply; blank denies]"

        # nil for a session with no terminal, and the nil is the CONTRACT rather
        # than a missing Null Object: {Lain::Epic::Gate::Policies::Deps} reads a nil
        # asker as "this session cannot ask anybody", which turns a stage
        # configured `interactive` in a non-interactive session into a named
        # wiring-time refusal instead of a prompt nobody can answer.
        #
        # BOTH streams are judged, because an asker that cannot speak is not an
        # asker. Guarding only the TTY let a half-wired session build a Prompt
        # that reached `nil.write` inside the reactor -- a NoMethodError, so it
        # escaped `exe/lain`'s rescue and printed a backtrace at a user standing
        # at a half-asked gate.
        def self.on(input:, output:)
          new(input:, output:) if unheard(input:, output:).nil?
        end

        # @return [String, nil] why these streams cannot carry a question, or
        #   nil when they can
        def self.unheard(input:, output:)
          return NO_TERMINAL unless input.respond_to?(:tty?) && input.tty?

          NO_OUTPUT unless output.respond_to?(:write)
        end

        def initialize(input:, output:)
          @input = input
          @output = output
        end

        # @param question [String] the artifact's own rendering
        # @return [Lain::Promise] resolves with the {Lain::Epic::Gate::Said} words
        #   once the read returns
        def ask(question)
          task = Async::Task.current
          promise = Promise.new
          cancelled = drawn_whole(task) do
            @output.write("#{question} #{CUE} ")
            task.async { promise.resolve(answer(@input.gets)) }
          end
          task.stop(true) if cancelled
          promise
        end

        # @return [Lain::Epic::Gate::Window] no reactor timer is armed for this
        #   wait: the person reading the question has nobody else to hand the
        #   reactor to, and an unattended wait here ends only by Ctrl-C.
        def window = Lain::Epic::Gate::Window::Unbounded

        private

        # A stop landing while the write is parked arrives after the bytes are
        # out, so the human is already looking at the question. A cancel raised
        # inside ask journals nothing, so it is held until the reader exists and
        # re-queued for the gate's park, which does journal it.
        def drawn_whole(task, &block)
          task.defer_stop(&block)
          false
        rescue Async::Cancel
          true
        end

        def answer(reply) = Lain::Epic::Gate::Said.new(words: reply, surface: SURFACE)
      end

      # The asker the chat lends this command, heard in the words its gate's
      # question names. That asker resolves with what the human WROTE -- bare
      # words at `human>` and `:LainReply`, a rendered answer set carrying them
      # from lain://question -- and {Lain::Epic::Gate} reads verdicts, not words.
      # So the reading happens here, where the question's vocabulary and the
      # chat's asker meet, and the gate stays blind to which surface spoke.
      #
      # It forwards `#withdraw` and, through {Hearing}, `#digest`, so the gate
      # still frees the asker and still retires the question it asked.
      class Heard
        # nil stays nil: {Lain::Epic::Gate::Policies::Deps} reads a nil asker as
        # "nobody can be asked", and wrapping it would hide exactly that.
        def self.over(asker) = asker && new(asker)

        def initialize(asker)
          @asker = asker
        end

        def ask(question) = Hearing.of(@asker.ask(question))

        def withdraw(hearing)
          @asker.withdraw(hearing.promise) if @asker.respond_to?(:withdraw)
        end
      end

      # One asked question's promise, awaited as the human's words for the gate
      # to read. A value that is already a verdict passes through untouched: a
      # standing answer.
      class Hearing
        # Only a promise naming its question answers `#digest`, because the gate
        # retires exactly the questions that do.
        def self.of(promise) = promise.respond_to?(:digest) ? Named.new(promise) : new(promise)

        attr_reader :promise

        def initialize(promise)
          @promise = promise
        end

        def await = verdict(@promise.await)

        private

        def verdict(resolved)
          return resolved if resolved.respond_to?(:approved?)

          Lain::Epic::Gate::Said.new(words: resolved.respond_to?(:words) ? resolved.words : resolved,
                                     surface: Prompt::SURFACE)
        end

        # A hearing whose question is in the record.
        class Named < Hearing
          def digest = promise.digest
        end
      end

      # WHICH artifact each stage submits. Two of the four are the epic's own
      # documents; the other two are about ONE issue, so they take what only the
      # caller can know and refuse BY NAME when it is missing -- rather than
      # letting {Epic::Submission} refuse in its own vocabulary, one frame away
      # from the flag to pass.
      class Artifacts
        def initialize(home:, root:, issue: nil, digest: nil, tests: nil)
          @home = home
          @root = root
          @issue = issue
          @digest = digest
          @tests = tests
        end

        # An `else` that RAISES: {Epic::STAGES}' closure is enforced over there,
        # not here, so a fifth stage added to the pipeline would otherwise be
        # absorbed by whichever branch happened to be last and gated as somebody
        # else's artifact.
        def submission(stage)
          case stage.name
          when "research"
            Lain::Epic::Submission.research(text: @home.research.read, slug: @home.slug, sources: @home.sources)
          when "epic_plan" then Lain::Epic::Submission.epic_plan(graph: @home.read_epic, slug: @home.slug)
          when "issue_plan" then issue_plan(stage)
          when "implementation" then implementation(stage)
          else raise Lain::Epic::UnknownStage, unnamed_artifact(stage)
          end
        end

        # What must already be approved before this stage's gate may open: an
        # implementation needs its issue's plan, rebuilt from the files as they
        # stand now, so an edited plan or criterion is caught here.
        def required(stage) = stage.name == "implementation" ? [plan_for(issue!(stage))] : []

        # What the stage boundary reads an earlier stage's approval against.
        #
        # @param stage [#to_s] an earlier stage than the one opening
        # @return [String, nil] the artifact's digest as it stands now; nil when the
        #   artifact is gone, or when an issue-scoped stage was asked with no issue,
        #   so the boundary reads either as not approved
        def digest(stage)
          stage = Lain::Epic::Stage.new(stage)
          return if stage.issue_scoped? && @issue.to_s.strip.empty?

          submission(stage).digest
        rescue Lain::Epic::Home::MissingArtifact
          nil
        end

        private

        def unnamed_artifact(stage)
          "the #{stage} stage is in the pipeline but `lain epic submit` knows no artifact for it -- " \
            "the stages it can submit are #{Lain::Epic::STAGES.join(", ")}"
        end

        def issue_plan(stage) = plan_for(issue!(stage))

        # The view refuses an issue the epic does not hold -- before anything
        # is decided.
        def plan_for(id)
          Lain::Epic::Submission.issue_plan(view: Lain::Epic::IssueView.read(@home, id), slug: @home.slug,
                                            issue_id: id)
        end

        def implementation(stage)
          id = issue!(stage)
          Lain::Epic::Submission.implementation(slug: @home.slug, issue_id: id, digest: implemented!(id, stage),
                                                tests: @tests, manual_commands: manual_commands(id))
        end

        def manual_commands(id)
          EpicDriver::Acceptance.of_issue(@home.read_epic.fetch(id)).manual_commands
        end

        # The red step's commit passes every gate a real changeset does, so an
        # approval of it would land failing tests as the issue's implementation.
        def implemented!(id, stage)
          digest = digest!(stage)
          red = Lain::Epic::RedCommit.new(git: checkout, base: "refs/heads/epic/#{@home.slug}")
          return digest unless red.only?(digest)

          raise Error, "that commit holds only #{id}'s failing tests; re-run the issue"
        end

        def issue!(stage)
          return @issue unless @issue.to_s.strip.empty?

          # Said apart from "the artifact is missing", because the remedies
          # differ: this one names no issue at all.
          raise Error, "the #{stage} stage gates one issue's work, and nothing named the issue -- " \
                       "#{Lain::Epic::Remedy.submit(stage, @home.slug, issue: "ISSUE_ID")}"
        end

        def commit!(digest)
          raise Error, not_a_commit(digest) unless digest.match?(/\A\h{4,64}\z/)

          found = verify(digest)
          return found.stdout.strip if Shell::Out.ok?(found)

          raise Error, "the implementation digest #{digest} is ambiguous in #{@root}; give more of the sha" if
            found.stderr.include?("ambiguous")

          raise Error, not_a_commit(digest)
        end

        def not_a_commit(digest) = "the implementation digest #{digest} is not a commit in #{@root}"

        # LC_ALL=C because "ambiguous" is read back from git's own stderr.
        def verify(digest)
          checkout.run("rev-parse", "--verify", "--end-of-options", "#{digest}^{commit}", env: { "LC_ALL" => "C" })
        end

        def checkout = Lain::Isolation::Checkout.of(@root)

        def digest!(stage)
          return commit!(@digest) unless @digest.to_s.strip.empty?

          # The implementation stage gates a CHANGESET, and no artifact in the epic
          # home addresses one. Nothing here re-hashes a working tree to invent it:
          # something else already computed that address, and a second opinion on the
          # same content is how two records of one thing start disagreeing.
          raise Error, "the #{stage} stage gates a changeset, and no artifact in the epic home addresses " \
                       "one -- #{Lain::Epic::Remedy.submit(stage, @home.slug, issue: "ISSUE_ID", digest: "ADDRESS")}"
        end
      end

      # Each epic's artifacts as they stand now, by slug: the digest source every
      # stage boundary of this project reads, whichever command asks it.
      class Digests
        # @param config [Config] says where the epics live
        # @param paths [Paths] the state home an XDG epic home resolves under
        # @param root [String] the project root
        def initialize(config:, paths:, root:)
          @config = config
          @paths = paths
          @root = root
        end

        # @param epic_slug [String] the epic
        # @param stage [#to_s] an earlier stage than the one opening
        # @param issue_id [String, nil] the issue, for an issue-scoped stage
        # @return [String, nil] see {Artifacts#digest}
        def digest(epic_slug, stage, issue_id)
          home = Lain::Epic::Home.resolve(config: @config, paths: @paths, root: @root, slug: epic_slug)
          Artifacts.new(home:, root: @root, issue: issue_id).digest(stage)
        end
      end

      # The decisions are folded per call, so an approval another chat gave is seen by an edit made here.
      #
      # @param journal [#record] where a reopen lands: the chat's own session record
      # @param root [String] the project root
      # @param paths [Paths] the state home the sessions directory resolves under
      # @param config [Config] says where epics live
      # @return [Lain::Epic::Reopen]
      def self.reopen(journal:, root:, paths:, config:)
        Lain::Epic::Reopen.new(
          journals: -> { SessionJournals.of(paths, root, types: [Lain::Epic::SignoffQueue::JOURNAL_TYPE]) },
          digests: Digests.new(config:, paths:, root:), journal:
        )
      end

      # A journal handed in belongs to its caller -- the driver runs this
      # command in-process over the chat's own -- so it is lent for one
      # decision and left open.
      Lent = Data.define(:journal) do
        def hold = yield(journal)
      end

      # Otherwise this command opens its own session journal around the
      # decision and closes it after. Nothing is lost: a Journal that CREATED
      # its file and wrote no record removes it on close.
      Owned = Data.define(:paths, :root) do
        def hold
          journal = Journal.open(paths:, root:)
          begin
            yield journal
          ensure
            journal.close
          end
        end
      end

      # One handle an adjudicated gate can write through AND read back, which
      # {Lain::Epic::Gate::Policy::Adjudicated} demands and a {Journal} cannot
      # give: it only writes. A read re-walks the session journals the
      # decision's journal lives among, so the terminal-verdict guard sees what
      # this command itself just wrote. That is also the contract on a lent
      # journal: it must live in that same sessions directory, as the chat's
      # does.
      class ReadBack
        include Enumerable

        # @param journal [#record] where decisions are written
        # @param readings [#call] a FRESH {SessionJournals} per call, which caches its walk
        def initialize(journal, readings)
          @journal = journal
          @readings = readings
          @decided = []
        end

        def record(entry)
          @decided << entry if entry.is_a?(Lain::Epic::GateDecision)
          @journal.record(entry)
          self
        end
        alias << record

        # @param digest [String] the submitted artifact's address
        # @return [Numeric, nil] the window, in seconds, that closed on this
        #   digest's gate with nobody answering; nil when somebody answered
        def expired(digest)
          decision = latest(digest)
          decision.latency if decision&.answered_by == Lain::Epic::Gate::TIMEOUT_SURFACE
        end

        # @param digest [String] the submitted artifact's address
        # @return [String, nil] the human's own words behind this command's latest decision on the
        #   digest; an adjudicator's evidence note is judge-side text and is not shown
        def reason(digest)
          decision = latest(digest)
          decision.reason if decision&.answered_by == Prompt::SURFACE || decision&.held?
        end

        # @param digest [String] the submitted artifact's address
        # @return [Boolean] whether the human answered this command's latest decision on the digest with a hold
        def held?(digest) = latest(digest)&.held? || false

        # @param digest [String] the submitted artifact's address
        # @return [Boolean] whether this command's own latest decision on the digest deferred it
        def deferred?(digest) = latest(digest)&.deferred? || false

        def each(&block) = @readings.call.each(&block)

        private

        def latest(digest) = @decided.reverse.find { |decided| decided.artifact_digest == digest }
      end

      HELD_NOTE_BYTES = 300

      # Nothing outside the chat answers a held gate yet, so the user decides when it is asked again.
      KEPT = "It is held: tell the user, and call epic_submit again only when they ask."

      # A hold, said like any verdict for a shell, and carrying the shorter words a
      # chat's agent is handed as the result that ends its turn.
      #
      # @!attribute [r] text
      #   @return [String] the words to print
      # @!attribute [r] status
      #   @return [Integer] the process exit status
      # @!attribute [r] wait
      #   @return [String] what the agent is told
      Held = Data.define(:text, :status, :wait) do
        # The chat shows the human only this line, and the human wrote the note,
        # so it is cut short; the whole note stays in the journal and in `text`.
        #
        # @param note [String, nil] the words after the hold word
        # @return [String]
        def self.waiting(note)
          return "the human asked you to wait" if note.nil?

          "the human asked you to wait: #{Lain::Epic::GateReply.clipped(note, limit: HELD_NOTE_BYTES)}"
        end

        # A gate whose window closed. Held, nothing yet answers it from outside
        # the chat, so the agent resubmits only when the user asks; denied, a
        # resubmit is how it reopens.
        #
        # @param head [String] the first line, naming what went unanswered
        # @param gate [String] the gate, as the second line names it
        # @param seconds [String] the window, spelled out
        # @param held [Boolean] whether the silence rule held it
        # @param resubmit [String] how a denied gate is reopened
        # @return [Held]
        def self.unanswered(head:, gate:, seconds:, held:, resubmit:)
          outcome = held ? "held for the human, nothing advanced" : "nothing advanced"
          new(text: "#{head}\n  nobody answered the #{gate} within #{seconds} -- #{outcome}", status: 1,
              wait: "the human was asked and did not answer in #{seconds}. The stage has not advanced. " \
                    "#{held ? KEPT : "To reopen the gate, #{resubmit}. Stop and tell the user."} " \
                    "Do not read lain's state to work out what happened.")
        end

        def initialize(text:, status:, wait:) = super(text: -text, status:, wait: -wait)
      end

      # One submission, decided and reported. Its own object because reaching a
      # verdict is a different job from resolving a home, a policy, a queue and a
      # journal: by the time this is built every one of those is settled.
      class Verdict
        def initialize(submission:, stage:, policy:, gate:, queue:, advance:, journal:)
          @journal = journal
          @submission = submission
          @stage = stage
          @policy = policy
          @gate = gate
          @queue = queue
          @advance = advance
        end

        # `Sync` because {Lain::Epic::Gate#call} parks on the asker's promise, and
        # EVERY policy inherits that precondition -- {Policy::HandsOff} included,
        # whose answer needs no human. No policy-shaped exception to remember.
        #
        # Ctrl-C is NOT caught here. {Lain::Epic::Gate} has already journaled the
        # fail-closed decision by the time its own `Async::Cancel` handling
        # re-raises, and once every task under this `Sync` has unwound, what
        # climbs out of it is the plain `Interrupt` the human sent -- the same
        # one every other command's `render` meets, not a translation only this
        # one command's caller would need to know to rescue.
        #
        # @return [Said, Held] status 1 for a denial, a hold or a closed window,
        #   0 otherwise: a deferral parks the artifact for a human and is not a failure
        # @raise [Epic::StageBlocked] before anything is journaled, when an
        #   earlier stage of this epic (or of this issue) still holds sign-offs
        #   parked
        def call
          decided = Sync do
            @policy.decide(@submission, gate: @gate, stage: @stage.name, epic_slug: slug,
                                        issue_id: @submission.issue_id, criteria_digest: @submission.criteria_digest)
          end
          decided ? approved : refused
        end

        private

        def slug = @submission.slug

        def approved
          Said.new(text: ["approved #{@submission.digest} by policy #{@policy.name}",
                          "  #{@stage} for epic #{slug} (#{@submission.fact})", "  #{@advance.call}"].join("\n"),
                   status: 0)
        end

        # The queue can still hold an item parked by an earlier command, so this
        # call's own decision says whether it deferred; the queue only supplies the item.
        def refused
          window = @journal.expired(@submission.digest)
          return unanswered(window) if window
          return held if @journal.held?(@submission.digest)

          parked = @journal.deferred?(@submission.digest) && parked_item
          parked ? deferred(parked) : failed { denied }
        end

        def failed = Said.new(text: yield, status: 1)

        def parked_item = @queue.parked(slug, @stage.name).find { |item| item.artifact_digest == @submission.digest }

        def deferred(item)
          Said.new(text: ["deferred #{item.artifact_digest}",
                          "  parked in #{item.partition} -- nothing advanced",
                          "  review it: #{Lain::Epic::Remedy.queue(item.epic_slug)}"].join("\n"),
                   status: 0)
        end

        # Nobody decided a closed window, so it is not said as a decision.
        def unanswered(window)
          Held.unanswered(head: "unanswered #{@submission.digest}", gate: "#{@stage} gate for epic #{slug}",
                          seconds: seconds(window), held: @journal.held?(@submission.digest),
                          resubmit: Lain::Epic::Remedy.resubmit(@stage.name, slug, issue: @submission.issue_id))
        end

        def seconds(window) = window == 1 ? "1 second" : "#{format("%g", window)} seconds"

        def denied
          reason = @journal.reason(@submission.digest)
          ["denied #{@submission.digest}", "  #{@stage} for epic #{slug} -- nothing advanced",
           *("  reason: #{reason.gsub("\n", "\n    ")}" if reason)].join("\n")
        end

        # Status 1 as for a denial: nothing advanced, and a script must not read on.
        def held
          note = @journal.reason(@submission.digest)
          Held.new(text: ["held #{@submission.digest}",
                          "  the human asked to wait at the #{@stage} gate for epic #{slug} -- nothing advanced",
                          *("  note: #{note.gsub("\n", "\n    ")}" if note)].join("\n"),
                   status: 1, wait: Held.waiting(note))
        end
      end

      # One wave of issue plans, decided with one question and reported issue by
      # issue. The wave holds only the issues whose plans carry no standing
      # approval; the others arrive already reported, in `standing`.
      class WaveVerdict
        def initialize(wave:, stage:, policy:, gate:, queue:, advances:, journal:, standing:)
          @wave = wave
          @stage = stage
          @policy = policy
          @gate = gate
          @queue = queue
          @advances = advances
          @journal = journal
          @standing = standing
        end

        # @return [Said, Held] status 1 when any issue was denied, held or unanswered
        def call
          outcome = Sync { @policy.decide(@wave, gate: @gate, stage: @stage.name, epic_slug: @wave.slug) }
          window = @journal.expired(first)
          return unanswered(window) if window
          return held if outcome.held.size == @wave.ids.size

          reported = @wave.submissions.map { |submission| report(submission, outcome) }
          Said.new(text: [heading(outcome), *@standing, *reported.map(&:first)].join("\n"),
                   status: reported.all? { _2 } ? 0 : 1)
        end

        private

        def first = @wave.submissions.first.digest

        def resubmit = Lain::Epic::Remedy.resubmit(@stage.name, @wave.slug, wave: @wave.number)

        def named = "wave #{@wave.number} of epic #{@wave.slug}"

        def heading(outcome)
          "#{@stage} for #{named}: #{outcome.approved.size} approved, #{outcome.held.size} held, " \
            "#{outcome.verdicts.size - outcome.approved.size - outcome.held.size} not, " \
            "by policy #{@policy.name}"
        end

        # @return [Array(String, Boolean)] the issue's lines, and whether it passed or parked
        def report(submission, outcome)
          id = submission.issue_id
          return ["approved #{id} #{submission.digest}\n  #{@advances.fetch(id).call}", true] if
            outcome.approved.include?(id)

          return [held_issue(submission, outcome.held.fetch(id)), false] if outcome.held.key?(id)

          parked = @journal.deferred?(submission.digest) && parked_item(submission)
          return ["deferred #{id} #{submission.digest}\n  parked in #{parked.partition} -- nothing advanced", true] if
            parked

          [denied(submission), false]
        end

        def held_issue(submission, note)
          ["held #{submission.issue_id} #{submission.digest} -- the human asked to wait, nothing advanced",
           *("  note: #{note.gsub("\n", "\n    ")}" if note)].join("\n")
        end

        def parked_item(submission)
          @queue.parked(@wave.slug, @stage.name, issue_id: submission.issue_id)
                .find { |item| item.artifact_digest == submission.digest }
        end

        def denied(submission)
          reason = @journal.reason(submission.digest)
          ["denied #{submission.issue_id} #{submission.digest} -- nothing advanced",
           *("  reason: #{reason.gsub("\n", "\n    ")}" if reason)].join("\n")
        end

        def held
          note = @journal.reason(first)
          Held.new(text: ["held #{named}", "  the human asked to wait at the #{@stage} gate -- nothing advanced",
                          *("  note: #{note.gsub("\n", "\n    ")}" if note), *@standing].join("\n"),
                   status: 1, wait: Held.waiting(note))
        end

        def unanswered(window)
          Held.unanswered(head: "unanswered #{named}", gate: "#{@stage} gate",
                          seconds: window == 1 ? "1 second" : "#{format("%g", window)} seconds",
                          held: @journal.held?(first), resubmit:)
        end
      end

      # `root:` defaults to the RESOLVED project's, not to `Dir.pwd`, for the
      # reason {CLI::Epic#initialize} states -- and asking `epics` is not enough
      # on its own, because this default is what that collaborator is BUILT with:
      # a `Dir.pwd` here makes the object it asks look somewhere else. Three
      # commands agreeing with the chat and one not is harder to diagnose than
      # four disagreeing together.
      #
      # @param root [String] the project root; the config file and a repo-mode
      #   home both resolve under it
      # @param paths [Paths] injected, so a spec resolves against a throwaway
      #   XDG state home
      # @param config [Config] `.lain/config.rb`, already read
      # @param input [IO, nil] the stream a human answers an interactive gate on;
      #   a non-TTY or nil means this session has no asker, which {Prompt.on}
      #   states as the fact {Policies::Deps} expects
      # @param output [IO, nil] where the gate question is written -- injected,
      #   because only the frontend may touch the process's own streams
      # @param asker [#ask, nil] who answers an interactive gate; by default the
      #   y/n {Prompt} over the two streams above, and handed in by a caller
      #   that answers some other way
      # @param journal [#record, nil] where verdicts land. nil opens this
      #   command's own session journal per decision; one handed in stays open,
      #   and must live in the sessions directory for {ReadBack}'s reason
      # @param role_spawn [#call, nil] the spawn seam an adjudicated gate runs
      #   its two roles through; nil means not wired, which such a stage refuses
      #   by name
      # @param brief [#call, nil] the adjudicated gate's spike prompt, from the
      #   artifact ({Adjudication::Brief}); nil means not wired, as above
      # @param spike_journal [Adjudication::Destination] where the pair's provider
      #   writes its own records; pointed at the decision's journal for the
      #   length of each decision, and the one the pair was built over
      # @param tool_guard [HomedGuard] the guard the pair's children run behind;
      #   pointed at the decided epic's home for the length of each decision,
      #   and the one the pair was built over
      # @param policies [#call] resolves the submitted stage's policy;
      #   {WholePipeline} unless a caller decides one stage alone
      # @param epics [CLI::Epic] answers WHICH epic a bare invocation means.
      #   Asked rather than reimplemented: two spellings of "the sole epic in the
      #   home" would disagree without either of them raising.
      def initialize(root: Project::Resolver.default_project.root, paths: Paths.new, config: Config.load(root:),
                     input: nil, output: nil, asker: Prompt.on(input:, output:), journal: nil, role_spawn: nil,
                     brief: nil, spike_journal: Adjudication::Destination.new, policies: WholePipeline,
                     tool_guard: HomedGuard.new(root:), epics: Epic.new(root:, paths:, config:))
        @root = root
        @paths = paths
        @config = config
        @asker = asker
        @unheard = Prompt.unheard(input:, output:) || Prompt::NO_ASKER
        @journal = journal ? Lent.new(journal) : Owned.new(paths, root)
        @role_spawn = role_spawn
        @brief = brief
        @spike_journal = spike_journal
        @tool_guard = tool_guard
        @epics = epics
        @policies = policies
      end

      # The exe's assembly seam: the command, plus the adjudication pair when a
      # stage is configured to need one. The assembly lives here, not in the
      # exe, so it carries specs.
      #
      # @param options [Hash] the invoked command's parsed flags, which the
      #   adjudication pair's {Backend} reads
      # @param profile [RunProfile] the provider, model, endpoint and runner
      #   knobs the model flag band resolved
      # @param input [IO, nil] as for {#initialize}
      # @param output [IO, nil] as for {#initialize}
      # @param root [String] as for {#initialize}
      # @param paths [Paths] as for {#initialize}
      # @param config [Config] as for {#initialize}, and what decides whether
      #   a pair is built at all
      # @param backend [#call] answers the {Backend} the pair spawns over;
      #   called only when some stage is adjudicated. The default checks its
      #   requests against the environment's secrets only, as no board exists here
      # @option options [String] :provider the model flag band's provider, which
      #   the profile was resolved from
      # @option options [String] :model the model flag band's model id
      # @return [EpicSubmit]
      def self.from_options(options, input:, output:, profile: RunProfile.from_options(options),
                            root: Project::Resolver.default_project.root, paths: Paths.new, config: Config.load(root:),
                            backend: -> { Backend.headless(options, profile:, root:) })
        spike_journal = Adjudication::Destination.new
        tool_guard = HomedGuard.new(root:)
        pair = Adjudication.pair(config:, paths:, root:, backend:, tool_middleware: tool_guard, journal: spike_journal)
        new(root:, paths:, config:, input:, output:, role_spawn: pair.role_spawn, brief: pair.brief, spike_journal:,
            tool_guard:)
      end

      # Which policy decides the submitted stage. The command resolves the
      # whole pipeline, so a stage configured wrong refuses before any is
      # decided.
      module WholePipeline
        def self.call(stage, config:, deps:)
          Lain::Epic::Gate::Policies.for_all(config:, deps:, asking: [stage]).fetch(stage)
        end
      end

      # A chat resolves the submitted stage alone: it cannot build the
      # adjudication spike prompt, and another stage's adjudicated gate must
      # not refuse this one.
      module SubmittedStage
        def self.call(stage, config:, deps:) = Lain::Epic::Gate::Policies.for(stage:, config:, deps:)
      end

      # A chat's submitter decides into the chat's own session journal, lent
      # as the epic driver lends it, so {ReadBack} sees this chat's earlier
      # decisions. The adjudication brief is not wired, so an adjudicated
      # stage refuses by name, as it does for the driver.
      #
      # @param chronicle [Chronicle, Chronicle::Null] the chat's record
      # @param root [String] as for {#initialize}
      # @param paths [Paths] as for {#initialize}
      # @param config [Config] as for {#initialize}
      # @param asker [#ask, nil] the chat's ask_human, heard through {Heard}
      # @param role_spawn [#call, nil] the chat's role spawn seam
      # @return [InChat]
      def self.in_chat(chronicle:, root:, paths:, config:, asker:, role_spawn:)
        InChat.new(chronicle:, command: new(root:, paths:, config:, asker:, journal: chronicle.record_journal,
                                            role_spawn:, policies: SubmittedStage))
      end

      # Refuses while the chat's session file would not keep a decision: a
      # decision no later reader sees lets the same stage be approved twice.
      # Asked per submit, so a --btw session kept with /keep mid-chat submits.
      class InChat
        NO_JOURNAL = "this chat was started with --no-journal, so a gate decision would land in no session " \
                     "journal; restart the chat without --no-journal, or run lain epic submit from a shell"
        EPHEMERAL = "this chat was started with --btw, and its session journal, gate decisions included, is " \
                    "deleted when the chat ends; keep the session with /keep first, or run lain epic submit " \
                    "from a shell"

        # @param chronicle [#journal_path] the chat's record
        # @param command [EpicSubmit] the submitter lent the chat's journal
        def initialize(chronicle:, command:)
          @chronicle = chronicle
          @command = command
        end

        # @return [Tool::Result] the verdict's words, as {EpicSubmit#submit} says
        #   them, with no exit status to carry; a hold ends the agent's turn
        # @raise [Lain::Error] when the session would not keep the decision
        def submit(stage, slug = nil, issue: nil, digest: nil, tests: nil, wave: nil, review: nil)
          refuse_unkept!
          case @command.submit(stage, slug, issue:, digest:, tests:, wave:, review:)
          in Held => held then Tool::Result.held(held.wait)
          in said then Tool::Result.ok(said.text)
          end
        end

        private

        def refuse_unkept!
          path = @chronicle.journal_path
          raise Lain::Error, NO_JOURNAL if path.nil?
          raise Lain::Error, EPHEMERAL if Paths.ephemeral?(path)
        end
      end

      # The pair's children borrow no chat's guard, so this command builds
      # one. It records nowhere, as their spawn seam's own journal does: the
      # decision's journal is opened per decision, after the pair exists.
      #
      # The pair is built before any epic is named, and under `epics home: :xdg`
      # an epic's files sit outside the project root, so the guard is pointed at
      # the decided epic's home for the length of one decision, as the spike's
      # journal is. Another epic's home is never in scope.
      class HomedGuard < SimpleDelegator
        # @param root [String] the project root, in scope for every child
        def initialize(root:)
          @root = root
          super(build([root]))
        end

        # The seam asks for each guard message through this object, and a copy
        # made now would keep the roots of whichever decision it was taken in.
        # @param home [Lain::Epic::Home] the epic the decision is about
        def within(home)
          outer = __getobj__
          __setobj__(build([@root, home.path]))
          yield
        ensure
          __setobj__(outer)
        end

        private

        def build(roots) = ToolGuard.detached(journal: Channel::Null.instance, roots:)
      end

      # @param stage [String] one of {Epic::STAGES}
      # @param slug [String, nil] the epic; omitted resolves to the sole one
      # @param issue [String, nil] which issue, for the issue-scoped stages
      # @param digest [String, nil] the changeset address, for `implementation`
      # @param tests [Telemetry::TestsRan, nil] what the suite did on that changeset, for `implementation`
      # @param wave [Integer, nil] a wave of {Lain::Epic::Graph#waves}, counted
      #   from 1, whose issue plans are asked about together; issue_plan only
      # @param review [Object, nil] a review result whose gate rendering the
      #   question shows beside it, or nil; never part of the gate's identity
      # @return [Said, Held] the verdict, rendered
      # @raise [Lain::Error] every refusal on this path: an unknown stage, an
      #   ambiguous home, a missing artifact, an unbuildable policy, or the
      #   stage boundary
      def submit(stage, slug = nil, issue: nil, digest: nil, tests: nil, wave: nil, review: nil)
        staged = Lain::Epic::Stage.new(stage)
        epic_home = home(slug)
        return decide_wave(staged, epic_home, wave_of(staged, epic_home, wave, issue).with(review:)) if wave

        decide(staged, epic_home, Artifacts.new(home: epic_home, root: @root, issue:, digest:, tests:), review:)
      end

      # The question an issue's launch asks before any work starts: is this
      # issue's plan, as it stands now, the one its partition's newest verdict
      # approved? The stage boundary reads that same verdict, so the two never
      # disagree. Read-only -- it decides and journals nothing.
      #
      # @param issue [String] the issue id
      # @param slug [String, nil] the epic; omitted resolves to the sole one
      # @return [String] the approved issue_plan digest
      # @raise [PlanNotApproved] naming the plan digest that carries no approval
      def ensure_plan_approved!(issue, slug = nil)
        plan = Artifacts.new(home: home(slug), root: @root, issue:).submission(Lain::Epic::Stage.new("issue_plan"))
        ensure_approved!(Lain::Epic::SignoffQueue.from_journal(journals.to_a), plan)
      end

      private

      def home(slug)
        Lain::Epic::Home.resolve(config: @config, paths: @paths, root: @root,
                                 slug: @epics.resolve_slug(slug, remedy: Lain::Epic::Remedy.submit("STAGE", "SLUG")))
      end

      # Held around the WHOLE decision, wiring refusal included, because
      # {Lain::Epic::Gate::Policies::Deps} carries a `journal` seam an adjudicating
      # policy needs before it is built.
      def decide(stage, epic_home, artifacts, review: nil)
        submission = artifacts.submission(stage).with(review:)
        required = artifacts.required(stage)
        recorded(epic_home) { |records, journal| settled(stage, submission, required, records, journal) }
      end

      def decide_wave(stage, epic_home, wave)
        issue_ids = epic_home.read_epic.issues.map(&:id)
        recorded(epic_home) { |records, journal| settled_wave(stage, wave, records, journal, issue_ids) }
      end

      def recorded(epic_home)
        records = journals.to_a
        @journal.hold do |journal|
          @spike_journal.within(journal) do
            @tool_guard.within(epic_home) { yield records, ReadBack.new(journal, -> { journals }) }
          end
        end
      end

      def wave_of(stage, epic_home, number, issue)
        raise Error, "only the issue_plan stage is submitted a wave at a time, not #{stage}" unless
          stage.name == "issue_plan"
        raise Error, "name an issue or a wave, not both" unless issue.to_s.strip.empty?

        Lain::Epic::Submission.wave(slug: epic_home.slug, number:,
                                    views: layer!(epic_home, number).map do |each|
                                      Lain::Epic::IssueView.read(epic_home, each.id)
                                    end)
      end

      def layer!(epic_home, number)
        waves = epic_home.read_epic.waves
        return waves[number - 1] if number.is_a?(Integer) && number.between?(1, waves.size)

        raise Error, "there is no wave #{number} -- epic #{epic_home.slug} has #{waves.size} waves"
      end

      # Only the issues without a standing approval are asked; the others are
      # reported already approved, and repaired as a lone re-submit is. So an
      # edit that reopens one issue's gate asks about that issue alone.
      def settled_wave(stage, wave, records, journal, issue_ids)
        queue = Lain::Epic::SignoffQueue.from_journal(records)
        standing, pending = wave.submissions.partition { |submission| standing?(queue, submission) }
        advances = wave_advances(stage, wave, journal)
        already = standing.map { |submission| repaired(stage, submission, queue, advances) }
        return Said.new(text: already.join("\n"), status: 0) if pending.empty?

        policy = policy_for(stage, queue, journal) { pending.each { ensure_open!(stage, _1, queue) } }
        asked = asked_wave(wave, pending, standing, queue, issue_ids)
        WaveVerdict.new(wave: asked, stage:, policy:, queue:, advances:, journal:, standing: already,
                        gate: gate_for(journal, policy)).call
      end

      def asked_wave(wave, pending, standing, queue, issue_ids)
        wave.with(submissions: reviewed(pending, wave.review), standing: standing.map(&:issue_id),
                  reopened: Lain::Epic::Reopen.stale(queue, digests, epic_slug: wave.slug, issue_ids:))
      end

      # Each submission is parked and journaled under its own question, so the wave's review has to ride on each.
      def reviewed(submissions, review) = submissions.map { _1.with(review:) }.freeze

      def gate_for(journal, policy)
        Lain::Epic::Gate.new(journal:, timeout: gate_timeout(policy), silence: ::Lain::Approval::Silence.from(@config))
      end

      def wave_advances(stage, wave, journal)
        wave.submissions.to_h do |submission|
          advance = Lain::Epic::Advance.new(epic_slug: submission.slug, stage:, issue_id: submission.issue_id)
          [submission.issue_id, advance_for(advance, journal)]
        end
      end

      def repaired(stage, submission, queue, advances)
        ensure_open!(stage, submission, queue)
        "already approved #{submission.issue_id} #{submission.digest}\n  #{advances.fetch(submission.issue_id).call}"
      end

      def settled(stage, submission, required, records, journal)
        queue = Lain::Epic::SignoffQueue.from_journal(records)
        open = -> { ensure_open!(stage, submission, queue) }
        policy = policy_for(stage, queue, journal, &open)
        gate = gate_for(journal, policy)
        advance = Lain::Epic::Advance.new(epic_slug: submission.slug, stage:, issue_id: submission.issue_id)
        ready = advance_for(advance, journal)
        return standing(submission, ready) { open.call if advance.moves? } if standing?(queue, submission)

        required.each { |plan| ensure_approved!(queue, plan) }
        Verdict.new(submission:, stage:, policy:, gate:, queue:, advance: ready, journal:).call
      end

      # The boundary a verdict meets inside {Lain::Epic::Gate::Policy#decide},
      # asked here only on the two routes that never reach it: a standing
      # approval's repair, and a policy that could not be built.
      def ensure_open!(stage, submission, queue)
        Lain::Epic::Gate::Policy::Boundary.new(queue, digests)
                                          .ensure_open!(stage.name, epic_slug: submission.slug,
                                                                    issue_id: submission.issue_id)
      end

      def digests = Digests.new(config: @config, paths: @paths, root: @root)

      # The ASKER says its own window ({Prompt#window}), never a type check
      # here: a chat's own asker also answers through the `interactive`
      # policy, and its window closing is how an abandoned inbox question
      # stops counting on the live feed, so only {Prompt} -- the bare CLI's
      # own terminal, which has nobody else to hand the reactor to while a
      # human reads and answers -- answers `#window` at all.
      def gate_timeout(policy)
        return Lain::Epic::Gate::DEFAULT_TIMEOUT unless policy.name == Lain::Epic::Gate::DEFAULT_POLICY

        @asker.respond_to?(:window) ? @asker.window : @config.approval_timeout
      end

      # Read BEFORE anything is decided, as the queue reads before it signs
      # off: a fold that refuses then refuses with nothing journaled, where
      # read after the verdict it left an approval that never moved the epic.
      def advance_for(advance, journal)
        ready = advance.read(@epics)
        -> { ready.call(journal) }
      end

      # Standing only while the partition's newest verdict approved THESE
      # bytes. An approval a later denial superseded is decided again when its
      # bytes come back, or the stage would read "already approved" here and
      # "not approved" at the boundary, with no verb left to move it.
      def standing?(queue, submission)
        queue.standing?(submission.digest, submission.slug, submission.stage, issue_id: submission.issue_id)
      end

      # Refused by NAME, before anything is decided or journaled, naming the
      # plan address that carries no standing approval: never approved, still
      # parked, denied since, or edited since.
      def ensure_approved!(queue, plan)
        return plan.digest if standing?(queue, plan)

        raise PlanNotApproved, "issue #{plan.issue_id.inspect} cannot open its implementation gate -- its " \
                               "issue_plan #{plan.digest} is not approved (never approved, still parked, " \
                               "denied since, or the issue, its file or its links changed since): " \
                               "#{Lain::Epic::Remedy.submit("issue_plan", plan.slug, issue: plan.issue_id)}"
      end

      # `for_all`, never `for`: resolving one stage at a time refuses LATE, and
      # late is exactly the failure the factory exists to prevent. Only the
      # asker is scoped to the submitted stage, because this command decides
      # that one stage and no other can ever ask it anything.
      # A missing asker is the wrong refusal to read while the stage could not
      # open anyway, so the yielded boundary check goes first.
      def policy_for(stage, queue, journal)
        deps = Lain::Epic::Gate::Policies::Deps.new(queue:, digests:, asker: Heard.over(@asker), journal:,
                                                    role_spawn: @role_spawn, brief: @brief)
        @policies.call(stage.name, config: @config, deps:)
      rescue Lain::Epic::Gate::Policies::Refusal => e
        raise unless e.seams == ["asker"]

        yield
        raise unattended(e, deps)
      end

      # The factory's sentence names a seam, which is the wiring's word for it.
      # A human who ran this from cron needs the reason and the line to change.
      def unattended(refusal, deps)
        first, *others = Lain::Epic::Gate::Policies.runnable(deps).map { |policy| ":#{policy}" }
        alternatives = others.empty? ? "" : " (or #{others.join(" or ")})"
        Lain::Epic::Gate::Policies::Refusal.new(
          "epic stage #{refusal.stage.inspect} is configured for the #{refusal.policy.inspect} gate policy, but " \
          "#{@unheard}, so nobody can answer it; add `gate :#{refusal.stage}, #{first}`#{alternatives} to the " \
          "`epics` block of .lain/config.rb to decide it unattended",
          kind: refusal.kind, stage: refusal.stage, policy: refusal.policy, seams: refusal.seams
        )
      end

      # Plural for {CLI::SessionJournals}' reason: an epic spans days and
      # sessions, so the newest-session shortcut would drop last week's approvals
      # and a standing sign-off would read as never given.
      #
      # FRESH per decision, never memoized. {SessionJournals} caches its own walk,
      # so one held here made a REUSED command fold the world as it was before its
      # own first decision: submitting twice through one instance approved the
      # same artifact twice, journaled two verdicts, and advanced the stage twice.
      # One object per process is a property of the executable, not of this class.
      def journals
        SessionJournals.of(@paths, @root, types: [Lain::Epic::SignoffQueue::JOURNAL_TYPE])
      end

      # A second verdict over the partition's standing approval of these bytes
      # could only add a record nobody asked for, with a latency for a wait
      # nobody waited. Reported, never decided.
      # The approval still runs {Epic::Advance}, which is how a re-submit
      # repairs an approval whose advance never landed; from the right state
      # only, so a standing approval that did advance writes nothing more, and
      # only past the yielded boundary check, which the caller skips for an
      # advance that writes nothing (an implementation's re-submit).
      def standing(submission, advance)
        yield
        Said.new(text: ["already approved #{submission.digest}",
                        "  #{submission.stage} for epic #{submission.slug} -- nothing was decided again",
                        "  #{advance.call}"].join("\n"),
                 status: 0)
      end

      # The adjudication pair: the role spawn an `adjudicated` gate sends its
      # evidence spike and its verdict through, and the brief that tells the
      # spike where to look. Out of chat there is no chat seam to borrow, so
      # this builds its own over the same backend flags a chat reads -- the
      # precedent is {CLI::Improve.from_options}.
      #
      # Built ONLY when some stage is configured `adjudicated`. Every other
      # policy spends no tokens, so a session that adjudicates nothing never
      # constructs a provider and never needs a key, while one that does is
      # refused for a missing key at wiring -- the same moment
      # {Lain::Epic::Gate::Policies.for_all} refuses everything else.
      #
      # Every constant is root-qualified: this sits inside {CLI}, whose own
      # classes shadow several top-level names.
      class Adjudication
        # A pair of nils is the "not wired" fact
        # {Lain::Epic::Gate::Policies::Deps} reads, so an `adjudicated` stage
        # handed it is refused by name rather than guessed at.
        Pair = Data.define(:role_spawn, :brief)
        NONE = Pair.new(role_spawn: nil, brief: nil)

        # @param config [#gate_policy_for]
        def self.wanted?(config)
          Lain::Epic::STAGES.any? do |stage|
            config.gate_policy_for(stage) == Lain::Epic::Gate::Policy::Adjudicated::NAME
          end
        end

        # @param config [#gate_policy_for] decides whether a pair is built at all
        # @param paths [Paths] resolves the epic home the brief points into
        # @param root [String] the project root, likewise
        # @param backend [#call] answers a {Backend}-shaped duck (`#provider`,
        #   `#context`, `#slots`), and is CALLED only when a stage is
        #   adjudicated -- which is what keeps the provider unbuilt otherwise
        # @param tool_middleware [#call] the guard the spawned children run
        #   behind, as the thunk {Tools::Subagent::Seam} carries. Required on
        #   every path, adjudicated or not: out of chat no guard reaches a child
        #   unless it is handed in here, and a default would be how one went
        #   without in silence.
        # @param journal [#<<] where the provider's own records land (a malformed
        #   answer, a wait); the backend's run journal is unbound out of chat, so
        #   without this a spike's failure message points at a record never written
        # @return [Pair]
        def self.pair(config:, paths:, root:, backend:, tool_middleware:, journal: Channel::Null.instance)
          return NONE unless wanted?(config)

          built = backend.call
          spawner = new(provider: built.provider(journal:), context_factory: -> { built.context }, slots: built.slots,
                        tool_middleware:, attachments: Lain::Attachment::Store.for(root:, paths:))
          Pair.new(role_spawn: spawner.role_spawn, brief: Brief.new(config:, paths:, root:))
        end

        # The decision's journal, resolved per RECORD: the provider is built
        # before any decision opens its journal, so it is handed this and the
        # command points it at the journal for the length of one decision.
        # Not thread-safe, because decisions in `epic submit` run sequentially.
        class Destination
          def initialize = @target = Channel::Null.instance

          def <<(event)
            @target << event
            self
          end

          def within(journal)
            outer = @target
            @target = journal
            yield
          ensure
            @target = outer
          end
        end

        # `attachments` is REQUIRED for `tool_middleware`'s reason: out of chat no
        # attachment store reaches a child unless it is handed in here, and the
        # Null the seam would otherwise default to raises from inside a child's
        # model phase -- where {Effect::Handler::Live#run} flattens it into a
        # `Tool::Result.error`, losing the class and journalling nothing. It is
        # the PROJECT's own directory, the one a chat in the same tree addresses,
        # so a picture a spike made is still there for a later session.
        def initialize(provider:, context_factory:, slots:, tool_middleware:, attachments:)
          # {Tools::Subagent::NoAskers} is NAMED here, not inherited from a
          # default: this command runs out of chat, so there is no queue a
          # child's escalation could reach and no directory an answer could
          # come back through. The refusal its asker gives says exactly that.
          @seam = Lain::Tools::Subagent::Seam.new(provider:, context_factory:, tool_middleware:, attachments:,
                                                  parent: Lain::Dag::Factory.timeline(store: Lain::Dag::Factory.store),
                                                  askers: Lain::Tools::Subagent::NoAskers,
                                                  twins: Lain::Tools::Subagent::Lineage::Twins.new)
          @slots = slots
        end

        # @return [Skill::RoleSpawn]
        def role_spawn = Lain::Skill::RoleSpawn.new(seam: @seam, toolset: union, slots: @slots)

        private

        # What both roles attenuate FROM: the researcher reads and searches,
        # the adjudicator only reads. {Toolset#only} refuses a role whose tools
        # the union lacks, so it holds every one either names.
        def union
          Lain::Toolset.new([Lain::Tools::ReadFile.new, Lain::Tools::ListFiles.new, Lain::Tools::Glob.new,
                             Lain::Tools::Grep.new, Lain::Tools::WebFetch.new, Lain::Tools::WebSearch.new])
        end

        # What the spike is told to read. The gate's artifact duck is `#digest`
        # and `#gate_question` and nothing more, so {Lain::Epic::Gate::Adjudicator}
        # deliberately maps no digest to a path; the submission knows its stage,
        # epic and issue, and this maps them onto the epic home.
        class Brief
          def initialize(config:, paths:, root:)
            @config = config
            @paths = paths
            @root = root
          end

          # @param artifact [Epic::Submission]
          # @return [String] the researcher's prompt
          def call(artifact)
            <<~PROMPT
              An approval gate is about to decide the #{artifact.stage} stage of epic #{artifact.slug.inspect}#{about(artifact)}.
              Gather the evidence it will be decided on. Do not judge it -- another reader decides.

              Read:
              #{sources(artifact).map { |source| "- #{source}" }.join("\n")}

              Report what the artifact establishes, what it leaves open, and anything in it that disagrees
              with the rest of the epic, citing the file for each finding.
            PROMPT
          end

          private

          def about(artifact) = artifact.issue_id ? " for issue #{artifact.issue_id}" : ""

          # An `else` that RAISES, for {Artifacts#submission}'s reason: a fifth
          # stage must not be briefed as somebody else's artifact.
          def sources(artifact)
            home = Lain::Epic::Home.resolve(config: @config, paths: @paths, root: @root, slug: artifact.slug)
            case artifact.stage
            when "research" then [home.research.path, *home.source_paths]
            when "epic_plan" then [home.epic.path, home.research.path]
            when "issue_plan" then issue_plan_sources(home, artifact.issue_id)
            when "implementation" then implementation_sources(home, artifact)
            else raise Lain::Epic::UnknownStage, "no brief for the #{artifact.stage} stage"
            end
          end

          def issue_plan_sources(home, id)
            [home.issue(id).path, "#{home.epic.path} (issue #{id}'s acceptance criteria and links)"]
          end

          def implementation_sources(home, artifact)
            ["the changeset #{artifact.changeset} in this project's git history",
             home.issue(artifact.issue_id).path]
          end
        end
      end
    end
  end
end
