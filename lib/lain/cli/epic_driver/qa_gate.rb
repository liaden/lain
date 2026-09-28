# frozen_string_literal: true

module Lain
  module CLI
    module EpicDriver
      # What the loop does when an {Epic::QaCheckpoint} becomes ready: run QA
      # over the cluster that just landed, and either release the checkpoint --
      # which is what makes the next cluster startable -- or hold it, filing
      # every holding finding as an issue of its own.
      #
      # A HELD CHECKPOINT HOLDS BY EDGES, NOT BY STATE. Each filed fix blocks the
      # checkpoint, so the checkpoint is not ready again until every fix has
      # landed, and whatever it blocks stays blocked all that time. The next run
      # re-folds, finds the checkpoint ready and runs QA again: the re-check is
      # the fold's, not a retry this object remembers.
      #
      # ONLY A CLEAN PASS RELEASES, which is three-valued because
      # {QA::Report#verdict} is. A report with holding findings holds; so does one
      # that merely left criteria UNSETTLED, and that second case is the one worth
      # stating. {QA::SessionTiers} -- the binding a run gets until its caller
      # lends another -- declares no rung whose voice may settle a pass, so a
      # criterion it looked at comes back unsettled. A gate reading `passed?`
      # would release on that and have abolished itself while reading green.
      #
      # WHAT THE DEFAULT BINDING CAN DO, at two layers, because the answer differs
      # at each. At the LADDER's layer a corroborated EXECUTED failure holds even
      # from a rung that is not strong, so a default pass can still accuse.
      # Whether it can in PRODUCTION is the bound ROLE's question rather than this
      # file's: `executed` is a sample's claim to have run something, so a QA role
      # holding no tool that runs anything can never set it and every criterion
      # comes back unsettled. Either way nothing here releases on an unsettled
      # report, and {OWING} is the line that says what to do about one.
      #
      # Findings become ISSUES rather than annotations or a refused gate because a
      # fix is work: it needs a plan, failing tests, an implementer and a landing,
      # which is exactly what an issue already gets and nothing else in an epic
      # does. `discovered_from` names the checkpoint, so the lineage says which
      # pass found it.
      class QaGate
        HELD = "QA held it: %<findings>s filed as %<ids>s, blocking this checkpoint -- plan and land them, and " \
               "the next run checks again"

        # QA RAN. That is what this line carries and a raise out of the gate
        # cannot: the work was checked and found wanting, and what failed was
        # lain's own filing of the findings. Nothing was written, so the operator
        # reads the findings here rather than re-running a pass that would do this
        # again -- and this reply is the only record they have, which is why the
        # summaries ride in it.
        UNFILED = "QA held it on %<findings>s (%<summaries>s) but could not file them as issues, so the " \
                  "checkpoint holds and %<written>s: %<why>s"

        NOTHING_WRITTEN = "nothing was written"

        PART_WRITTEN = "only %<ids>s reached the epic, which you must land or delete before the next pass files " \
                       "the same findings again"

        # Both halves of this name a mechanism that EXISTS. Marking the issue done
        # in `epic.md` is how a human records a manual pass -- {Epic::Progress}
        # folds the document's own status, so the next run reads it as released --
        # and the ladder is a keyword on {Factory}. There is no `[qa]` config table
        # and no command that moves a status, so neither is offered here.
        OWING = "QA found nothing that holds it but left %<criteria>s unsettled (%<ids>s), so the checkpoint " \
                "holds: settle them by hand and mark `%<id>s` done in epic.md, or run the epic with a ladder " \
                "whose rungs may settle a criterion"

        UNWIRED = "no QA is wired to this run, so the checkpoint holds everything it blocks"

        # What one pass came to, as the loop reports it.
        Verdict = Data.define(:issue_id, :passed, :line) do
          def initialize(issue_id:, passed:, line:)
            super(issue_id: -issue_id.to_s, passed: passed == true, line: -line.to_s)
          end
        end

        # No QA wired: a checkpoint holds its cluster, and says why. The loop's
        # Null, for a bench or a spec driving an epic with no QA -- in an epic QA
        # is not optional, so this never passes anything.
        module Unaudited
          def self.call(checkpoint, _graph) = Verdict.new(issue_id: checkpoint.id, passed: false, line: UNWIRED)
        end

        # What QA checks at a checkpoint: the acceptance criteria of every issue
        # the checkpoint waits on, which is exactly the cluster that has just
        # landed. An issue carries no risk of its own, so each criterion is the
        # middle arm of {QA::RISKS}.
        class ClusterQa
          NO_CLUSTER = "the checkpoint waits on no issue, so a pass would check nothing"
          NO_CRITERIA = "the cluster declares no acceptance criteria, so nothing could be measured"
          NOTHING = "nothing"

          # @param ladder [#call] `-> QA::Ladder`, built fresh per pass so each
          #   pass has its own budget
          def initialize(ladder:)
            @ladder = ladder
          end

          # @param checkpoint [Epic::Issue] whose blockers are the cluster
          # @param graph [Epic::Graph] the fold it became ready in
          # @return [QA::Report]
          def call(checkpoint, graph)
            cluster = graph.blocked_by(checkpoint.id).map { |id| graph.fetch(id) }
            criteria = cluster.flat_map { |issue| criteria_of(issue) }
            return unmeasured(checkpoint, cluster) if criteria.empty?

            @ladder.call.call(criteria).report(subject: subject(checkpoint, cluster))
          end

          private

          def subject(checkpoint, cluster)
            "#{checkpoint.id} over #{cluster.empty? ? NOTHING : cluster.map(&:id).join(", ")}"
          end

          # A pass with nothing to check is the silent release this gate exists to
          # refuse: no rung was asked anything, so a clean report would be a claim
          # with no method behind it. The structural rung is named as the one that
          # ran, because reading the graph is exactly what it does and a report
          # naming no rung at all would read as a pass nobody attempted.
          def unmeasured(checkpoint, cluster)
            Lain::QA::Report.new(subject: subject(checkpoint, cluster), tiers_run: [Lain::QA::TIERS.first],
                                 findings: [nothing_measured(checkpoint, cluster)])
          end

          # Two different defects wearing one verdict: a checkpoint nothing blocks
          # was authored wrong, while a cluster whose issues carry no scenarios has
          # criteria to write. Each names the edit that answers it.
          def nothing_measured(checkpoint, cluster)
            Lain::QA::Finding.new(severity: "major", criterion: checkpoint.id, tier: Lain::QA::TIERS.first,
                                  summary: cluster.empty? ? NO_CLUSTER : NO_CRITERIA,
                                  evidence: observed(checkpoint, cluster),
                                  reproduction: remedy(checkpoint, cluster))
          end

          def observed(checkpoint, cluster)
            return "no issue in this epic declares `Blocks: #{checkpoint.id}`" if cluster.empty?

            "#{subject(checkpoint, cluster)}: not one ```gherkin scenario in any issue it waits on"
          end

          def remedy(checkpoint, cluster)
            return "read epic.md: nothing blocks `#{checkpoint.id}`, so it became ready with no cluster" if
              cluster.empty?

            "read the criteria of #{cluster.map(&:id).join(", ")} in epic.md"
          end

          def criteria_of(issue)
            Lain::Gherkin::Criteria.parse(issue.criteria.to_s).map do |scenario|
              Lain::QA::Ladder::Criterion.new(id: "#{issue.id}/#{scenario.name}", scenario:, risk: "medium")
            end
          end
        end

        # @param check [#call] `(checkpoint, graph) -> QA::Report`
        # @param scribe [#issue_moved] the epic's {Epic::Scribe}
        # @param filing [#call] `issue ->` adds it to the epic's graph, written
        #   and journaled ({CLI::Epic#file})
        def initialize(check:, scribe:, filing:)
          @check = check
          @scribe = scribe
          @filing = filing
        end

        # @param checkpoint [Epic::Issue] a ready {Epic::QaCheckpoint}
        # @param graph [Epic::Graph] the fold it became ready in
        # @return [Verdict]
        def call(checkpoint, graph)
          report = @check.call(checkpoint, graph)
          return released(checkpoint, report) if report.clean?
          return held(checkpoint, report, graph) unless report.holding.empty?

          owing(checkpoint, report)
        end

        private

        def released(checkpoint, report)
          @scribe.issue_moved(checkpoint.id, from: checkpoint.status, to: Lain::Epic::DONE)
          Verdict.new(issue_id: checkpoint.id, passed: true,
                      line: "passed QA (#{ran(report)}, #{report.findings.size} minor findings carried)")
        end

        def ran(report) = report.tiers_run.empty? ? "no rung ran" : "rungs #{report.tiers_run.join(", ")}"

        # EVERY FIX IS BUILT BEFORE ANY IS FILED. Filing as it built would write
        # one fix, lose the findings after it, and report a shape lain refused as
        # though QA had never run -- and since the survivor blocks the checkpoint,
        # the next run would skip the gate, the operator would land it, and the
        # pass after that would file the same finding again under a fresh id,
        # forever. Built first, a refused shape costs nothing.
        def held(checkpoint, report, graph)
          written = []
          fixes = minted(checkpoint, report, graph)
          refused = fixes.flat_map { |_id, issue| issue.emittable_failures }
          return unfiled(checkpoint, report, refused.join("; "), written) unless refused.empty?

          fixes.each { |id, issue| written << filing(issue, id) }
          Verdict.new(issue_id: checkpoint.id, passed: false,
                      line: format(HELD, findings: findings(written.size), ids: written.join(", ")))
        rescue JournalUnreadable
          raise
        rescue StandardError => e
          unfiled(checkpoint, report, "#{e.class}: #{e.message}", written)
        end

        # The fixes this report would file, each paired with the id it takes.
        def minted(checkpoint, report, graph)
          ids = Lain::Epic::QaCheckpoint.fix_ids(checkpoint.id, graph.ids).first(report.holding.size)
          report.holding.zip(ids).map { |finding, id| [id, fix(checkpoint, finding, id)] }
        end

        # The write, answering the id so the caller records what actually reached
        # the epic rather than what it meant to write.
        def filing(issue, id)
          @filing.call(issue)
          id
        end

        # WHAT REACHED THE EPIC, counted rather than assumed. Building every fix
        # first makes the refusal above cost nothing, but two filings are two
        # writes and the second can still refuse -- so this says which is true
        # instead of claiming the tidy case.
        def unfiled(checkpoint, report, why, written)
          state = written.empty? ? NOTHING_WRITTEN : format(PART_WRITTEN, ids: written.join(", "))
          Verdict.new(issue_id: checkpoint.id, passed: false,
                      line: format(UNFILED, findings: findings(report.holding.size), why:, written: state,
                                            summaries: report.holding.map(&:summary).join("; ")))
        end

        # Nothing is filed for an unsettled criterion, and that is {QA::Finding}'s
        # rule rather than a gap here: a criterion nobody could settle carries no
        # evidence and no reproduction, so there is nothing an implementer could
        # be handed. The owing is a human's.
        def owing(checkpoint, report)
          Verdict.new(issue_id: checkpoint.id, passed: false,
                      line: format(OWING, criteria: criteria(report.unsettled.size), id: checkpoint.id,
                                          ids: report.unsettled.join("; ")))
        end

        def findings(count) = "#{count} holding #{"finding".pluralize(count)}"

        # ActiveSupport inflects "criterion" to "criterions", so both words are
        # named here rather than derived.
        def criteria(count) = "#{count} #{count == 1 ? "criterion" : "criteria"}"

        # ONE LINE PER FIELD, each opened with a bullet: the epic grammar reads a
        # line opening `###`, a fence, or `Word: value` as structure, and a
        # finding's evidence can hold any of the three. The title is bounded and
        # stripped of a trailing ` {...}` group for the same reason -- it is
        # model-authored text landing in a grammar with rules of its own.
        def fix(checkpoint, finding, id)
          Lain::Epic::Issue.new(id:, title: titled(finding, checkpoint), blocks: [checkpoint.id],
                                discovered_from: checkpoint.id, description: described(checkpoint, finding))
        end

        # A title may not END in a ` {...}` group -- it collides with the
        # criteria-digest grammar -- and stripping the last one can leave another,
        # so braces become parens instead and no brace can end a title at all. The
        # summary reaches the description verbatim either way. An empty title is
        # the other construction refusal, so a summary that flattened to nothing
        # gets words of ours.
        def titled(finding, checkpoint)
          said = one_line("fix: #{finding.summary}").tr("{}", "()")[0, 100].strip
          said.empty? ? "fix: a QA finding at #{checkpoint.id}" : said
        end

        # The summary rides in the body as well as in the title: the title is
        # bounded at 100 characters and has had its braces translated, so the
        # description is where the finding's own words survive whole.
        def described(checkpoint, finding)
          fields = %w[summary criterion evidence reproduction].map do |field|
            "- #{field} -- #{one_line(finding.public_send(field))}"
          end
          ["Found by QA at #{checkpoint.id} (#{finding.severity}, rung #{finding.tier}).", *fields].join("\n")
        end

        # The shared flattener rather than a fifth of its own: this text is
        # model-authored and reaches a terminal raw through `lain epic status`, so
        # the rule has to be the strongest of its surfaces' -- which is the one
        # that also strips an escape sequence and a NUL.
        def one_line(text) = Tools::AskHuman::InboxRow.one_line(text)
      end
    end
  end
end
