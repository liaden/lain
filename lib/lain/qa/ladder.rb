# frozen_string_literal: true

module Lain
  module QA
    # The model rungs of a QA pass, driven by lain rather than by a model: which
    # rung looks at which criterion, how many times, and when to stop.
    #
    # Lain owns this loop for the reason it owns the agent loop -- the loop is
    # the thing under study. Which rung found a defect, what each decision cost
    # and which rule produced it are all a bench wants to compare across tier
    # bindings, and a QA child choosing its own escalations would leave none of
    # it on the record.
    #
    # == ONE MODEL PER RUNG, and that is structural
    #
    # The measured evidence is that a rung which stopped mid-answer must climb to
    # a DIFFERENT model, never to the same model with a bigger budget: of the
    # models that produced nothing inside their cap, only one converted a doubled
    # budget into an answer, and that answer found 6% of the planted bugs. So two
    # rungs bound to one model are refused at construction rather than warned
    # about, which leaves a same-model retry unwritable rather than merely
    # discouraged. Two rungs that named NO model are refused too: silence cannot
    # be shown to be a second model.
    #
    # == BREADTH-FIRST BY RUNG
    #
    # Every criterion is asked at the cheap rung before any is asked at the
    # strong one. On a box that holds one large model at a time a swap costs the
    # better part of a minute, so a per-criterion climb would pay it twice per
    # escalation; taken rung by rung, a pass pays it once per rung.
    #
    # == WHAT BOUNDS A PASS AGAINST THE ADMISSION GATE
    #
    # Three things, and a wall clock is not among them. {Provider::Admission}
    # admits one caller per local endpoint, and its own deadline is a PER-ACQUIRE
    # wait -- the longest one legitimate holder's single attempt may take -- not a
    # budget for a whole pass. It also keeps no queue and is explicitly unfair, so
    # a pass merely staying under that number still holds the endpoint back to
    # back and refuses a concurrent caller no less often.
    #
    # What does bound it: ONE ask in flight, so a pass cannot queue against
    # itself; a per-rung ask budget, so one rung cannot spend the pass; and
    # {Provider::Admission::Busy} read as a rung that could not answer, so losing
    # the race on one criterion costs the other criteria nothing.
    #
    # A wall bound is therefore the CALLER's, defaulting to {UNBOUNDED}, because
    # only the caller knows the box and the models. Derived from the work it is
    # `rungs.sum(&:samples) * criteria.size * what one ask costs`; a number below
    # that silently converts a rung's whole spend into unsettled criteria --
    # at 10s an ask, a 300s bound over twelve criteria settles nothing at all.
    #
    # == NO MEDIA RUNG HERE, DELIBERATELY
    #
    # A visual criterion needs a rung that can look at a picture, and the axis
    # that says "something other than a text model judges this" is already
    # spelled once in the tree: {Gherkin::Scenario}'s `mechanical`, set by the
    # pinned `# rubric` marker. A second spelling on one axis is what this file
    # declines to add, because widening the marker moves
    # {Gherkin::Criteria#digest} -- a content address {Approval::Gate},
    # {Plan::Step} and {Epic::Issue} all cite. The two options, neither chosen
    # here: widen the marker and pay that blast radius, or give the ladder a rung
    # selector that READS `mechanical` and renames nothing.
    class Ladder
      # A ladder, rung or criterion that could not be built as asked. One class
      # for all three because it is one rule: this pass would have run in a shape
      # the measurement forbids, so it does not run at all.
      class Misbuilt < Error; end

      # No wall bound at all, which is what a caller that stated none gets. A
      # value rather than a nil, so nothing below asks whether one was set.
      UNBOUNDED = Float::INFINITY

      EMPTY_REPLY = "the rung's reply was empty"
      TRUNCATED = "the rung's reply stopped inside its ```%<fence>s block after %<chars>d characters, " \
                  "which is what a spent token budget looks like"
      REFUSED = "the endpoint refused the ask: %<reason>s"
      SPENT = "its ask budget for this pass is spent"
      OUT_OF_TIME = "the pass is past the %<deadline>gs deadline its caller set"
      NOBODY_LOOKED = "no rung of the ladder looked at it"
      SAME_MODEL = "two rungs are bound to the same model (%<models>s): a rung climbs to a DIFFERENT model, " \
                   "never to the same one with more room"
      DECLARED = "%<model>s, declared by %<by>s"
      UNNAMED_TWICE = "more than one rung named no model, and silence cannot be shown to be a second model: " \
                      "name what each rung climbs to, or run one rung"
      OUT_OF_ORDER = "rungs must be given in the ladder's own order, cheapest first, got %<tiers>s"
      TWICE = "a ladder names the %<tiers>s rung more than once"
      NO_RUNG = "a ladder with no rung settles nothing"
      NO_BRIEF = "a rung asked with no brief is asked nothing"
      UNSHAREABLE = "a criterion's scenario carries reachable mutable state, which would take the criterion " \
                    "and every climb quoting it with it"
      NOT_FINDINGS = "a climb's findings must all be findings, got %<got>s"

      # A reply that opened an answer block and never closed it. {Answer} states
      # in writing that it does not detect this and that a token cap is the
      # commonest way a small model stops; unnoticed, such a reply falls back to
      # an earlier block, which is the prompt's own template.
      OPENED = /^```#{Answer::FENCE}\b/
      private_constant :OPENED

      # One criterion to check: `id` is what a finding cites -- a card and its
      # scenario name -- and `risk` is the card's.
      Criterion = Data.define(:id, :scenario, :risk) do
        def initialize(id:, scenario:, risk:)
          super(id: cited(id), scenario: shareable(scenario), risk: known(risk))
        end

        private

        def cited(id)
          raise Misbuilt, "a criterion with no id is one no finding could cite" if Blankness.blank?(id)

          -id.to_s
        end

        # The one member no interning can repair, so it is REQUIRED shareable
        # rather than fixed up: {Gherkin::Scenario} already is, and anything else
        # standing in for one has to be.
        def shareable(scenario)
          raise Misbuilt, UNSHAREABLE unless Ractor.shareable?(scenario)

          scenario
        end

        def known(risk)
          word = risk.to_s
          raise Misbuilt, "risk #{word.inspect} is not one of #{RISKS.join("/")}" unless RISKS.include?(word)

          -word
        end
      end

      # What one pass came to. `escalations` is the DECISION LOG -- every rung's
      # decision with the rule that produced it and the model that answered,
      # accepts included, because a cheap accept is exactly the datum a
      # comparison of tier bindings is for.
      Climb = Data.define(:findings, :escalations, :tiers_run, :unsettled) do
        def initialize(findings:, escalations:, tiers_run:, unsettled:)
          super(findings: only_findings(findings), escalations: lines(escalations), tiers_run: lines(tiers_run),
                unsettled: lines(unsettled))
        end

        # @param subject [String] what was checked, for the report to head itself with
        # @return [Report]
        def report(subject:) = Report.new(subject:, findings:, tiers_run:, escalations:, unsettled:)

        private

        # A non-Finding is not merely wrong here, it is unshareable, and the
        # deep-frozen guarantee goes with it. {Report} refuses one for that
        # reason, and a climb that let one through would hand the report a value
        # it then has to refuse.
        def only_findings(findings)
          wrong = findings.grep_v(Finding).map(&:class).uniq
          raise Misbuilt, format(NOT_FINDINGS, got: wrong.join(", ")) unless wrong.empty?

          findings.dup.freeze
        end

        def lines(values) = values.map { |value| -value.to_s }.freeze
      end

      # One rung: the tier it occupies, the model bound to it, whether its voice
      # may settle a pass on its own, how many samples it takes of each
      # criterion, and what it may spend across the whole pass.
      #
      # `strong` is a DECLARATION and nothing here audits it. An earlier cut named
      # two measured-unfit models in this file and refused them: evadable by
      # capitalisation, by a registry prefix and by a GGUF tag, and unable to fire
      # at all where the model is not named, which is the default binding. The
      # measurement lives where the tier recommendations live ({SessionTiers}), so
      # a human binding one of them as a verdict rung is overruling it in writing.
      #
      # Not one of this namespace's frozen values -- it holds the callable that
      # does the asking, so it is a bound collaborator rather than a datum.
      class Rung
        # What the record says when nobody named a model, so a line about a rung
        # reads the same whether or not one was bound.
        UNNAMED = "the run's own model"

        attr_reader :tier, :samples, :budget

        # A rung that asks through the call-time role-selecting spawn, which is
        # the channel a model is bound over: the model rides beside the role, per
        # call, so one spawn serves every rung and the role stays
        # capability-shaped rather than strength-shaped.
        #
        # @param tier [String] the rung this occupies
        # @param role_spawn [Skill::RoleSpawn] the one spawn the run holds
        # @param role [Symbol] the persona every rung of one ladder shares
        # @param model [#model, #declared_by] the choice this rung is bound to
        # @param rest [Hash] the rest of a rung's own keywords, forwarded whole
        # @return [Rung]
        def self.spawning(tier:, role_spawn:, role:, model: Tools::Subagent::ModelChoice::Null, **rest)
          new(tier:, model:, **rest,
              ask: ->(prompt) { role_spawn.call(role, :fresh, prompt, model:).content.to_s })
        end

        # @param tier [String] one of {TIERS}, never its first -- the structural
        #   rung spends no model and is not the ladder's to run
        # @param ask [#call] `prompt -> String`, one whole reply
        # @param model [#model, #declared_by] the choice this rung is bound to
        # @param strong [Boolean] whether this rung's voice may settle a pass
        # @param samples [Integer] asks per criterion
        # @param budget [Numeric] asks this rung may spend across the whole pass
        # @raise [Misbuilt] for a tier that is not a rung, a sample count that
        #   asks nothing, or a budget that could never afford one criterion
        def initialize(tier:, ask:, model: Tools::Subagent::ModelChoice::Null, strong: false,
                       samples: 1, budget: Float::INFINITY)
          @tier = tiered(tier)
          @ask = ask
          @choice = model
          @strong = strong == true
          @samples = counted(samples)
          @budget = afforded(budget)
          freeze
        end

        def strong? = @strong

        # @return [String] the model's name, blank when nobody named one
        def model = @choice.model

        # @return [String] who named it, so a refusal cites the rung rather than
        #   the role every rung shares
        def declared_by = @choice.declared_by

        def named_a_model? = !Blankness.blank?(model)

        # @return [String] the model as a record names it
        def described = named_a_model? ? model : UNNAMED

        def call(prompt) = @ask.call(prompt)

        private

        def tiered(tier)
          word = tier.to_s
          raise Misbuilt, "#{word.inspect} is not a rung: name one of #{TIERS.join("/")}" unless TIERS.include?(word)
          raise Misbuilt, "#{word} spends no model, so it is not a rung this ladder runs" if word == TIERS.first

          -word
        end

        def counted(samples)
          count = Integer(samples)
          raise Misbuilt, "a rung taking #{count} samples asks nothing" unless count.positive?

          count
        end

        def afforded(budget)
          return budget if budget >= @samples

          raise Misbuilt, "a rung whose whole budget of #{budget} cannot afford one criterion's " \
                          "#{@samples} samples could never be asked"
        end
      end

      # @param rungs [Array<Rung>] cheapest first, one model each
      # @param brief [String] what every prompt opens with -- the rendered QA
      #   skill and the changeset under test
      # @param escalation [Escalation] the rule over one rung's samples
      # @param deadline [Numeric] seconds the whole pass may spend asking, the
      #   caller's own number; see this class's account of the admission gate
      # @param clock [#call] monotonic seconds, defaulted from
      #   {RunClock::MONOTONIC} as every `clock:` seam is -- that constant is the
      #   one place in `lib/` allowed to name the primitive, and `run_clock_spec`
      #   fails on a second. Injected so a pass can be timed
      # @raise [Misbuilt] for every shape the measurement forbids
      def initialize(rungs:, brief:, escalation: Escalation.new, deadline: UNBOUNDED, clock: RunClock::MONOTONIC)
        @rungs = ordered(rungs)
        @brief = briefed(brief)
        @escalation = escalation
        @deadline = bounded(deadline)
        @clock = clock
        freeze
      end

      # @param criteria [Array<Criterion>]
      # @return [Climb]
      def call(criteria)
        Pass.new(rungs: @rungs, brief: @brief, escalation: @escalation, deadline: @deadline, clock: @clock)
            .climb(criteria)
      end

      private

      def ordered(rungs)
        raise Misbuilt, NO_RUNG if rungs.empty?

        refuse_repeated_tier(rungs)
        refuse_same_model(rungs)
        places = rungs.map { |rung| TIERS.index(rung.tier) }
        raise Misbuilt, format(OUT_OF_ORDER, tiers: rungs.map(&:tier).join(", ")) unless places == places.sort

        rungs.dup.freeze
      end

      # Silence gets its own words: "the same model (the run's own model)" reads
      # as though the reader had bound something so named.
      def refuse_same_model(rungs)
        named, unnamed = rungs.partition(&:named_a_model?)
        raise Misbuilt, UNNAMED_TWICE if unnamed.size > 1

        repeated = named.group_by(&:model).select { |_model, group| group.size > 1 }
        raise Misbuilt, format(SAME_MODEL, models: declarers(repeated)) if repeated.any?
      end

      # WHO bound it and not only what: a ladder assembled from a project's table
      # and a skill's front matter has two places one duplicate could come from,
      # and the message that names neither sends the reader to look in both.
      def declarers(repeated)
        repeated.map { |model, group| format(DECLARED, model:, by: group.map(&:declared_by).uniq.join(" and ")) }
                .join("; ")
      end

      def refuse_repeated_tier(rungs)
        repeated = rungs.map(&:tier).tally.select { |_tier, count| count > 1 }.keys
        raise Misbuilt, format(TWICE, tiers: repeated.join(", ")) unless repeated.empty?
      end

      def briefed(brief)
        raise Misbuilt, NO_BRIEF if Blankness.blank?(brief)

        -brief.to_s
      end

      def bounded(deadline)
        seconds = Float(deadline)
        raise Misbuilt, "a pass whose deadline is #{seconds} could ask nothing" unless seconds.positive?

        seconds
      end

      # The mutable half of one climb: what each rung has left to spend, what has
      # been asked, and the decision log. Held apart from the Ladder so a second
      # pass over the same ladder starts with a full budget rather than a spent
      # one, and so the Ladder itself can be frozen.
      #
      # SEQUENTIAL BY CONSTRUCTION. One ask is in flight at a time, which is what
      # keeps a pass's own samples from queueing against each other at the
      # admission gate.
      class Pass
        Progress = Data.define(:pending, :findings)
        CLIMB = :climb
        private_constant :Progress, :CLIMB

        def initialize(rungs:, brief:, escalation:, deadline:, clock:)
          @rungs = rungs
          @brief = brief
          @escalation = escalation
          @deadline = deadline
          @clock = clock
          @left = rungs.to_h { |rung| [rung.tier, rung.budget] }
          @asked = []
          @log = []
          @reasons = {}
          @started = clock.call
        end

        # @param criteria [Array<Criterion>]
        # @return [Climb]
        def climb(criteria)
          final = @rungs.inject(Progress.new(pending: criteria, findings: [])) do |progress, rung|
            through(rung, progress)
          end
          Climb.new(findings: final.findings + final.pending.flat_map { |left| unsettled(left) },
                    escalations: @log, tiers_run: TIERS & @asked, unsettled: final.pending.map(&:id))
        end

        private

        def through(rung, progress)
          outcomes = progress.pending.map { |criterion| [criterion, decide(rung, criterion, asks(rung, criterion))] }
          settled, climbing = outcomes.partition { |_criterion, found| found != CLIMB }
          Progress.new(pending: climbing.map(&:first), findings: progress.findings + settled.flat_map(&:last))
        end

        # A rung that cannot afford a whole sample set, and a set the clock ran
        # out part way through, answer the same way: ONCE and unverified, rather
        # than half-scoring the criterion. A partial set would let one voice pass
        # for unanimity, which is the corroboration rule defeated by accident.
        def asks(rung, criterion)
          return [Answer.unverified(because: SPENT)] unless affordable?(rung)

          taken = sample_set(rung, criterion)
          taken.size == rung.samples ? taken : [Answer.unverified(because: out_of_time)]
        end

        # The clock between every sample and not once per set: one ask can itself
        # block for a whole acquire deadline, so a set of three read once could
        # overrun the pass bound three times over.
        def sample_set(rung, criterion)
          (1..rung.samples).inject([]) do |taken, _|
            time_left? ? taken + [ask(rung, criterion)] : taken
          end
        end

        def decide(rung, criterion, answers)
          samples = answers.map { |answer| Escalation::Sample.of(answer) }
          decision = @escalation.call(samples, risk: criterion.risk, strong: rung.strong?)
          record(criterion, rung, decision, answers)
          return [] if decision.accept?
          return reported(answers, criterion, rung) if decision.report?

          CLIMB
        end

        # The executed failure IS the evidence. If it will not stand as a finding
        # -- no evidence, no way to re-run it -- the stronger rung decides
        # instead, because an unfalsifiable fail is the weak-model false positive
        # this ladder exists to keep away from an implementer.
        def reported(answers, criterion, rung)
          executed = answers.find { |answer| answer.executed && answer.verdict == "fail" }
          found = executed.findings(criterion: criterion.id, tier: rung.tier, severity: severity(criterion))
          found.empty? ? CLIMB : found
        end

        # Carried as a minor finding AND named in the report's unsettled list: a
        # report that merely omitted it would read as a pass.
        def unsettled(criterion)
          [Finding.new(severity: "minor", criterion: criterion.id, tier: @rungs.last.tier,
                       summary: "unsettled: a manual pass is owed",
                       evidence: @reasons.fetch(criterion.id, NOBODY_LOOKED),
                       reproduction: criterion.scenario.render)]
        end

        def record(criterion, rung, decision, answers)
          line = [head(criterion, rung, decision), silences(answers)].compact.join(" -- ")
          @log << line
          @reasons[criterion.id] = line
        end

        def head(criterion, rung, decision) = "#{criterion.id}: #{rung.tier} [#{rung.described}] #{decision}"

        # What a rung that settled nothing actually said, kept verbatim: the
        # reason is the whole value of a climb nobody could otherwise explain.
        def silences(answers)
          said = answers.reject(&:settled?).map(&:evidence).uniq.reject { |word| Blankness.blank?(word) }
          said.empty? ? nil : said.join("; ")
        end

        # A busy endpoint is a rung that could not answer, not a dead pass: the
        # gate refuses whoever loses the race for its one local slot, and losing
        # it on one criterion may not cost the others.
        def ask(rung, criterion)
          @asked << rung.tier
          @left[rung.tier] -= 1
          read(rung.call(prompt(rung, criterion)))
        rescue Provider::Admission::Busy => e
          Answer.unverified(because: format(REFUSED, reason: e.message))
        end

        def read(reply)
          text = QA.readable(reply)
          return Answer.unverified(because: EMPTY_REPLY) if Blankness.blank?(text)
          return Answer.unverified(because: cut_short(text)) if text.match?(OPENED) && !text.match?(Answer::PATTERN)

          Answer.parse(text)
        end

        def cut_short(text) = format(TRUNCATED, fence: Answer::FENCE, chars: text.length)

        def prompt(rung, criterion)
          "#{@brief}\n\n## Rung #{rung.tier}: criterion #{criterion.id} (risk: #{criterion.risk})\n\n" \
            "```gherkin\n#{criterion.scenario.render}\n```\n"
        end

        def affordable?(rung) = @left.fetch(rung.tier) >= rung.samples

        def time_left? = (@clock.call - @started) < @deadline

        def out_of_time = format(OUT_OF_TIME, deadline: @deadline)

        def severity(criterion) = criterion.risk == "high" ? "blocker" : "major"
      end
      private_constant :Pass
    end
  end
end
