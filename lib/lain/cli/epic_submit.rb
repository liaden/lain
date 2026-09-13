# frozen_string_literal: true

require "async"

module Lain
  module CLI
    # `lain epic submit STAGE [SLUG]`: put one stage's artifact in front of its
    # gate, and report the verdict.
    #
    # Everything here is assembly: this class picks the epic, reads the artifact,
    # wires {Epic::Submission}, {Approval::Gate::Policies},
    # {Approval::Gate.from_journal}, {Approval::Gate::Policy::Boundary} and
    # {Epic::Scribe} together, and turns what comes back into a String. It prints
    # nothing.
    #
    # == Wiring is resolved before anything is decided
    #
    # {Approval::Gate::Policies.for_all} resolves EVERY stage's policy, not just
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
    # {Approval::GateDecision}; a deferral is that record plus a park the next
    # fold rebuilds; an epic-wide stage advance is two {Epic::StageTransition}
    # records, and an approved issue plan is one {Epic::IssueTransition}.
    #
    # == Every constant from the epic tier is reached at CALL time
    #
    # This unit loads BEFORE `lain/epic` (see {CLI::Epic}'s header), so every
    # `Lain::Epic::...` reference below sits inside a method body -- and is
    # spelled in full, because a bare `Epic` resolves to the sibling {CLI::Epic}.
    class EpicSubmit
      # Its own class so `exe/lain` and a spec can tell "you did not say which
      # issue" from "the artifact is missing" -- the remedies differ.
      class NeedsIssue < Error; end

      # The implementation stage gates a CHANGESET, and no artifact in the epic
      # home addresses one. Nothing here re-hashes a working tree to invent it:
      # something else already computed that address, and a second opinion on the
      # same content is how two records of one thing start disagreeing.
      class NeedsDigest < Error; end

      # An implementation is built to an approved plan, so its gate refuses to
      # open until the issue's plan AS IT STANDS -- criteria included -- carries
      # an approval. Its own class because the remedy is a different command.
      class PlanNotApproved < Error; end

      # The y/n prompt this command owns, on the streams it was handed. Both are
      # INJECTED and neither defaults to the process's own, because only the
      # frontend may touch `$stdout`/`$stderr`.
      #
      # `#ask` resolves the promise before it returns, so {Approval::Gate}'s
      # timeout window never opens here. Deliberate: the answerer is the person
      # who just typed the command, this process has no second fiber to hand the
      # reactor to while a `gets` blocks, and a bare CLI's refusal is Ctrl-C. The
      # fail-closed default still holds for every reply that is not affirmative,
      # EOF included.
      class Prompt
        AFFIRMATIVE = %w[y yes approve].freeze

        # Spelled the way {CLI::EpicQueue} already spells a human sign-off: one
        # string, no second constant to drift.
        SURFACE = EpicQueue::HUMAN

        # nil for a session with no terminal, and the nil is the CONTRACT rather
        # than a missing Null Object: {Approval::Gate::Policies::Deps} reads a nil
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
          return unless input.respond_to?(:tty?) && input.tty?
          return unless output.respond_to?(:write)

          new(input:, output:)
        end

        def initialize(input:, output:)
          @input = input
          @output = output
        end

        # @param question [String] the artifact's own rendering
        # @return [Lain::Promise] already resolved with an {Approval::Gate::Answer}
        def ask(question)
          @output.write("#{question} [y/N] ")
          Promise.new.tap { |promise| promise.resolve(answer(@input.gets)) }
        end

        private

        def answer(reply)
          Approval::Gate::Answer.new(approved: AFFIRMATIVE.include?(reply.to_s.strip.downcase), surface: SURFACE)
        end
      end

      # WHICH artifact each stage submits. Two of the four are the epic's own
      # documents; the other two are about ONE issue, so they take what only the
      # caller can know and refuse BY NAME when it is missing -- rather than
      # letting {Epic::Submission} refuse in its own vocabulary, one frame away
      # from the flag to pass.
      class Artifacts
        def initialize(home:, issue: nil, digest: nil)
          @home = home
          @issue = issue
          @digest = digest
        end

        # An `else` that RAISES: {Epic::STAGES}' closure is enforced over there,
        # not here, so a fifth stage added to the pipeline would otherwise be
        # absorbed by whichever branch happened to be last and gated as somebody
        # else's artifact.
        def submission(stage)
          case stage.name
          when "research" then Lain::Epic::Submission.research(text: @home.research.read, slug: @home.slug)
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

        private

        def unnamed_artifact(stage)
          "the #{stage} stage is in the pipeline but `lain epic submit` knows no artifact for it -- " \
            "the stages it can submit are #{Lain::Epic::STAGES.join(", ")}"
        end

        def issue_plan(stage) = plan_for(issue!(stage))

        # The criteria come from the issue in epic.md, which is also what
        # refuses an issue the epic does not hold -- before anything is decided.
        def plan_for(id)
          criteria_digest = @home.read_epic.fetch(id).criteria_digest
          Lain::Epic::Submission.issue_plan(text: @home.plan(id).read, slug: @home.slug, issue_id: id,
                                            criteria_digest:)
        end

        def implementation(stage)
          Lain::Epic::Submission.implementation(slug: @home.slug, issue_id: issue!(stage), digest: digest!(stage))
        end

        def issue!(stage)
          return @issue unless @issue.to_s.strip.empty?

          raise NeedsIssue, "the #{stage} stage gates one issue's work, and nothing named the issue -- " \
                            "lain epic submit #{stage} --issue ID"
        end

        def digest!(stage)
          return @digest unless @digest.to_s.strip.empty?

          raise NeedsDigest, "the #{stage} stage gates a changeset, and no artifact in the epic home addresses " \
                             "one -- lain epic submit #{stage} --issue ID --digest ADDRESS"
        end
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
      Owned = Data.define(:paths) do
        def hold
          journal = Journal.open(paths:)
          begin
            yield journal
          ensure
            journal.close
          end
        end
      end

      # One handle an adjudicated gate can write through AND read back, which
      # {Approval::Gate::Policy::Adjudicated} demands and a {Journal} cannot
      # give: it only writes. A read re-walks the session journals the
      # decision's journal lives among, so the terminal-verdict guard sees what
      # this command itself just wrote. That is also the contract on a lent
      # journal: it must live in that same sessions directory, as the chat's
      # does.
      class ReadBack
        include Enumerable

        def initialize(journal, dir:)
          @journal = journal
          @dir = dir
        end

        def record(entry)
          @journal.record(entry)
          self
        end
        alias << record

        def each(&block) = SessionJournals.new(dir: @dir, types: [Approval::SignoffQueue::JOURNAL_TYPE]).each(&block)
      end

      # One submission, decided and reported. Its own object because reaching a
      # verdict is a different job from resolving a home, a policy, a queue and a
      # journal: by the time this is built every one of those is settled.
      class Verdict
        def initialize(submission:, stage:, policy:, gate:, queue:, scribe:, in_flight:)
          @submission = submission
          @stage = stage
          @policy = policy
          @gate = gate
          @queue = queue
          @scribe = scribe
          @in_flight = in_flight
        end

        # `Sync` because {Approval::Gate#call} parks on the asker's promise, and
        # EVERY policy inherits that precondition -- {Policy::HandsOff} included,
        # whose answer needs no human. No policy-shaped exception to remember.
        #
        # @return [String]
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
          ["approved #{@submission.digest}", "  #{@stage} for epic #{slug} (#{@submission.fact})",
           "  #{advance}"].join("\n")
        end

        # An epic-wide verdict completes its stage and starts the next. An
        # issue-scoped one is ONE issue's, so it moves that issue alone and no
        # epic-wide stage: a plan puts its issue in flight, and an
        # implementation moves nothing until it lands.
        def advance
          return @in_flight.call if starts_issue?
          return awaiting_landing if @stage.issue_scoped?

          advance_epic
        end

        # {Epic::InFlight} owns the rule, so a verdict and a queue sign-off
        # cannot disagree about which approvals start an issue.
        def starts_issue?
          Lain::Epic::InFlight.starts?(approved: true, stage: @stage.name, issue_id: @submission.issue_id)
        end

        def awaiting_landing
          "issue #{@submission.issue_id}'s #{@stage} is approved -- nothing moves until it lands"
        end

        def advance_epic
          @scribe.stage_completed(@stage)
          @scribe.stage_started(@stage.next)
          "#{@stage} completed, #{@stage.next} started"
        end

        # Parked or plainly denied is read off the QUEUE, not off the policy's
        # name: a deferral IS a denial that left something for a human to sign
        # off, and reading the policy would be a second opinion on what
        # deferring means.
        def refused
          parked = @queue.parked(slug, @stage.name).find { |item| item.artifact_digest == @submission.digest }
          parked ? deferred(parked) : denied
        end

        def deferred(item)
          ["deferred #{item.artifact_digest}",
           "  parked in #{item.partition} -- nothing advanced",
           "  review it: lain epic queue #{item.epic_slug}"].join("\n")
        end

        def denied
          ["denied #{@submission.digest}", "  #{@stage} for epic #{slug} -- nothing advanced"].join("\n")
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
      # @param config [Config] `.lain/config.toml`, already read
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
      # @param epics [CLI::Epic] answers WHICH epic a bare invocation means.
      #   Asked rather than reimplemented: two spellings of "the sole epic in the
      #   home" would disagree without either of them raising.
      def initialize(root: Project::Resolver.default_project.root, paths: Paths.new, config: Config.load(root:),
                     input: nil, output: nil, asker: Prompt.on(input:, output:), journal: nil, role_spawn: nil,
                     brief: nil, epics: Epic.new(root:, paths:, config:))
        @root = root
        @paths = paths
        @config = config
        @asker = asker
        @journal = journal ? Lent.new(journal) : Owned.new(paths)
        @role_spawn = role_spawn
        @brief = brief
        @epics = epics
      end

      # The exe's assembly seam: the command, plus the adjudication pair when a
      # stage is configured to need one. The assembly lives here, not in the
      # exe, so it carries specs.
      #
      # @param options [Hash] the invoked command's parsed flags (`provider`, `model`)
      # @option options [String] :provider the backend provider for an adjudicated stage
      # @option options [String] :model the model for an adjudicated stage
      # @param input [IO, nil] as for {#initialize}
      # @param output [IO, nil] as for {#initialize}
      # @param root [String] as for {#initialize}
      # @param paths [Paths] as for {#initialize}
      # @param config [Config] as for {#initialize}, and what decides whether
      #   a pair is built at all
      # @param backend [#call] answers the {Backend} the pair spawns over;
      #   called only when some stage is adjudicated
      # @return [EpicSubmit]
      def self.from_options(options, input:, output:, root: Project::Resolver.default_project.root,
                            paths: Paths.new, config: Config.load(root:),
                            backend: -> { Backend.new(Adjudication.flags(options)) })
        pair = Adjudication.pair(config:, paths:, root:, backend:, tool_middleware: guard)
        new(root:, paths:, config:, input:, output:, role_spawn: pair.role_spawn, brief: pair.brief)
      end

      # The pair's children borrow no chat's guard, so this command builds
      # one. It records nowhere, as their spawn seam's own journal does: the
      # decision's journal is opened per decision, after the pair exists.
      def self.guard = ToolGuard.detached(journal: Channel::Null.instance)
      private_class_method :guard

      # @param stage [String] one of {Epic::STAGES}
      # @param slug [String, nil] the epic; omitted resolves to the sole one
      # @param issue [String, nil] which issue, for the issue-scoped stages
      # @param digest [String, nil] the changeset address, for `implementation`
      # @return [String] the verdict, rendered
      # @raise [Lain::Error] every refusal on this path: an unknown stage, an
      #   ambiguous home, a missing artifact, an unbuildable policy, or the
      #   stage boundary
      def submit(stage, slug = nil, issue: nil, digest: nil)
        staged = Lain::Epic::Stage.new(stage)
        decide(staged, Artifacts.new(home: home(slug), issue:, digest:))
      end

      # The question an issue's launch asks before any work starts: is this
      # issue's plan, as it stands now, approved? Read-only -- it decides and
      # journals nothing.
      #
      # @param issue [String] the issue id
      # @param slug [String, nil] the epic; omitted resolves to the sole one
      # @return [String] the approved issue_plan digest
      # @raise [PlanNotApproved] naming the plan digest that carries no approval
      def ensure_plan_approved!(issue, slug = nil)
        plan = Artifacts.new(home: home(slug), issue:).submission(Lain::Epic::Stage.new("issue_plan"))
        ensure_approved!(Approval::Gate.from_journal(journals.to_a, journal: Channel::Null.instance), plan)
      end

      private

      def home(slug)
        Lain::Epic::Home.resolve(config: @config, paths: @paths, root: @root,
                                 slug: @epics.resolve_slug(slug, command: "epic submit STAGE"))
      end

      # Held around the WHOLE decision, wiring refusal included, because
      # {Approval::Gate::Policies::Deps} carries a `journal` seam an adjudicating
      # policy needs before it is built.
      def decide(stage, artifacts)
        submission = artifacts.submission(stage)
        required = artifacts.required(stage)
        records = journals.to_a
        @journal.hold do |journal|
          settled(stage, submission, required, records, ReadBack.new(journal, dir: @paths.sessions_dir))
        end
      end

      def settled(stage, submission, required, records, journal)
        queue = Approval::SignoffQueue.from_journal(records)
        policy = policy_for(stage, queue, journal)
        gate = Approval::Gate.from_journal(records, journal:)
        scribe = Lain::Epic::Scribe.new(epic_slug: submission.slug, journal:)
        in_flight = in_flight_for(scribe, submission)
        return standing(submission, in_flight) if gate.approved?(submission.digest)

        required.each { |plan| ensure_approved!(gate, plan) }
        Verdict.new(submission:, stage:, policy:, gate:, queue:, scribe:, in_flight:).call
      end

      def in_flight_for(scribe, submission)
        Lain::Epic::InFlight.new(scribe:, progress: -> { @epics.progress(submission.slug) },
                                 issue_id: submission.issue_id)
      end

      # Refused by NAME, before anything is decided or journaled, naming the
      # plan address that carries no approval: never approved, still parked, or
      # edited since -- all three are the same address the registry never saw.
      def ensure_approved!(gate, plan)
        return plan.digest if gate.approved?(plan.digest)

        raise PlanNotApproved, "issue #{plan.issue_id.inspect} cannot open its implementation gate -- its " \
                               "issue_plan #{plan.digest} is not approved (never approved, still parked, or " \
                               "its plan or criteria changed since): lain epic submit issue_plan --issue " \
                               "#{plan.issue_id}"
      end

      # `for_all`, never `for`: resolving one stage at a time refuses LATE, and
      # late is exactly the failure the factory exists to prevent.
      def policy_for(stage, queue, journal)
        deps = Approval::Gate::Policies::Deps.new(queue:, asker: @asker, journal:, role_spawn: @role_spawn,
                                                  brief: @brief)
        Approval::Gate::Policies.for_all(config: @config, deps:).fetch(stage.name)
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
        SessionJournals.new(dir: @paths.sessions_dir, types: [Approval::SignoffQueue::JOURNAL_TYPE])
      end

      # The registry is add-only, so a second verdict over a standing approval
      # can neither revoke nor strengthen it -- only add a record nobody asked
      # for, with a latency for a wait nobody waited. Reported, never decided.
      # A standing PLAN still runs {Epic::InFlight}, for the repair its header
      # names.
      def standing(submission, in_flight)
        ["already approved #{submission.digest}",
         "  #{submission.stage} for epic #{submission.slug} -- nothing was decided or journaled again",
         *(starts_issue?(submission) ? ["  #{in_flight.call}"] : [])].join("\n")
      end

      def starts_issue?(submission)
        Lain::Epic::InFlight.starts?(approved: true, stage: submission.stage, issue_id: submission.issue_id)
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
      # {Approval::Gate::Policies.for_all} refuses everything else.
      #
      # Every constant is root-qualified: this sits inside {CLI}, whose own
      # classes shadow several top-level names.
      class Adjudication
        # A pair of nils is the "not wired" fact
        # {Approval::Gate::Policies::Deps} reads, so an `adjudicated` stage
        # handed it is refused by name rather than guessed at.
        Pair = Data.define(:role_spawn, :brief)
        NONE = Pair.new(role_spawn: nil, brief: nil)

        # `epic submit` exposes only the provider and the model, and every
        # model turn needs a ceiling.
        MAX_TOKENS = 4_096

        # @param config [#gate_policy_for]
        def self.wanted?(config)
          Lain::Epic::STAGES.any? do |stage|
            config.gate_policy_for(stage) == Lain::Approval::Gate::Policy::Adjudicated::NAME
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
        # @return [Pair]
        def self.pair(config:, paths:, root:, backend:, tool_middleware:)
          return NONE unless wanted?(config)

          built = backend.call
          spawner = new(provider: built.provider, context_factory: -> { built.context }, slots: built.slots,
                        tool_middleware:)
          Pair.new(role_spawn: spawner.role_spawn, brief: Brief.new(config:, paths:, root:))
        end

        # Read key by key, so a Thor options hash and a plain one both work.
        #
        # @param options [Hash] the invoked command's parsed flags
        # @option options [String] :provider the backend provider, when given
        # @option options [String] :model the model, when given
        # @option options [Integer] :max_tokens the per-turn ceiling; defaults to {MAX_TOKENS}
        # @return [Hash{Symbol=>Object}] what {Backend.new} reads
        def self.flags(options)
          { provider: options[:provider], model: options[:model],
            max_tokens: options[:max_tokens] || MAX_TOKENS }.compact
        end

        def initialize(provider:, context_factory:, slots:, tool_middleware:)
          # {Tools::Subagent::NoAskers} is NAMED here, not inherited from a
          # default: this command runs out of chat, so there is no queue a
          # child's escalation could reach and no directory an answer could
          # come back through. The refusal its asker gives says exactly that.
          @seam = Lain::Tools::Subagent::Seam.new(provider:, context_factory:, parent: Lain::Timeline.empty,
                                                  tool_middleware:, askers: Lain::Tools::Subagent::NoAskers)
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
        # and `#gate_question` and nothing more, so {Approval::Gate::Adjudicator}
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
            when "research" then [home.research.path]
            when "epic_plan" then [home.epic.path, home.research.path]
            when "issue_plan" then issue_plan_sources(home, artifact.issue_id)
            when "implementation" then implementation_sources(home, artifact)
            else raise Lain::Epic::UnknownStage, "no brief for the #{artifact.stage} stage"
            end
          end

          def issue_plan_sources(home, id)
            [home.plan(id).path, "#{home.epic.path} (issue #{id}'s acceptance criteria)"]
          end

          def implementation_sources(home, artifact)
            ["the changeset #{artifact.changeset} in this project's git history",
             home.plan(artifact.issue_id).path]
          end
        end
      end
    end
  end
end
