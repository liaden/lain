# frozen_string_literal: true

require "fileutils"

module Lain
  module CLI
    module Command
      # `/qa PLAN --base REF` at `you>`: check a landed change against its plan's
      # acceptance criteria and write the report the implementer fixes from. The
      # optional step after `/execute-plan` on a large plan.
      #
      # The rungs are {::Lain::QA}'s -- the structural check with no model, then
      # {::Lain::QA::Ladder} over the criteria -- and this is the door onto them:
      # it reads the plan and the changeset, binds the rungs, and says where the
      # report went. It is also the only place in `lib/` that builds a ladder, so
      # until it existed every one of those objects was unreachable from a
      # keystroke.
      #
      # It never writes the source tree, and that is structural rather than
      # promised: the one file it writes is the report, and the `qa` role its
      # rungs spawn as holds nothing that could write anything else.
      #
      # Every `::Lain::QA` below is root-qualified because this class is named
      # for that namespace, and inside it a bare `QA` is this class.
      class QA
        USAGE = "/qa PLAN --base REF -- QA the change since REF against PLAN's acceptance criteria " \
                "(reports, never fixes)"
        FLAGS = %w[--base].freeze

        # The reply's first word, per {::Lain::QA::Report#verdict}. Three, not
        # two: a pass with criteria nothing settled is neither a hold nor a clean
        # pass, and a reply that called it PASS would be the silence the whole
        # ladder exists to abolish.
        WORDS = { hold: "HOLD", unsettled: "PASS, with a manual pass owed", pass: "PASS" }.freeze

        SUMMARY = "QA %<verdict>s: %<findings>d findings, %<holding>d holding, %<unsettled>d unsettled, " \
                  "rungs %<rungs>s -- report at %<report>s"

        NO_CRITERIA = "%<plan>s states no acceptance criteria, so QA would hold the work to nothing: " \
                      "a card is held to the gherkin scenarios under it"

        # @param root [String] the project root, where the plan and the report
        #   path resolve
        # @param renderer [Skill::Renderer] renders the `qa` skill as the brief
        # @param tiers [#call] `role_spawn -> Array<::Lain::QA::Ladder::Rung>`, which
        #   model each rung runs on. A project's table arrives here; the default
        #   is one rung on the session's own model, whose voice settles nothing
        # @param changeset [#call] `root:, base: -> ::Lain::QA::Changeset`
        def initialize(root:, renderer:, tiers: ::Lain::QA::SessionTiers,
                       changeset: ::Lain::QA::Changeset.method(:read))
          @root = root
          @renderer = renderer
          @tiers = tiers
          @changeset = changeset
        end

        def name = "qa"

        def usage = USAGE

        # @param args [String] the line after the verb
        # @param env [Env] the run's collaborators; its role spawn runs the rungs
        # @return [String] the verdict, the counts and where the report is
        # @raise [Lain::Error] for a missing plan or base, a plan with no
        #   criteria, or a changeset git will not read
        def call(args, env)
          plan, base = parsed(args)
          changes = @changeset.call(root: @root, base:)
          cards = ::Lain::QA::PlanCards.read(File.read(plan))
          report = judged(plan, changes, cards, env)
          summary(report, written(plan, changes, report))
        end

        private

        # The free rung runs first and its findings go into the brief, so no rung
        # spends a model re-deriving what a path comparison already knows.
        def judged(plan, changes, cards, env)
          found = structural(cards, changes).findings
          climb = ladder(changes, found, env).call(criteria!(plan, cards))
          climb.report(subject: "#{relative(plan)} @ #{changes.range}").prepend(found)
        end

        def structural(cards, changes)
          ::Lain::QA::ClaimCheck.new(claims: cards.claims, changed: changes.changed, range: changes.range)
        end

        # No deadline and no per-rung budget of this command's own: both are
        # numbers only whoever bound the rungs can derive, and one invented here
        # would silently convert a project's spend into unsettled criteria.
        def ladder(changes, found, env)
          ::Lain::QA::Ladder.new(rungs: @tiers.call(env.role_spawn), brief: brief(changes, found))
        end

        # One prefix for the whole pass, carrying what only this command knows: a
        # rung holds no `bash`, so the range it is judging is unreadable to it
        # unless the paths arrive in words.
        def brief(changes, found)
          [@renderer.render("qa"), "## Under test", under_test(changes),
           "## Already found at t0, without a model", already(found)].join("\n\n")
        end

        def under_test(changes)
          ["`#{changes.range}`, which changed #{changes.changed.size} paths:",
           *changes.changed.map { |path| "- #{path}" }].join("\n")
        end

        def already(found)
          return "Nothing: every card's claimed paths are in the range." if found.empty?

          found.map { |finding| "- [#{finding.severity}] #{finding.summary}" }.join("\n")
        end

        # A plan whose cards state no criteria would climb an empty ladder and
        # report a clean pass over nothing -- the one reading of a plan that
        # looks exactly like success.
        def criteria!(plan, cards)
          criteria = cards.flat_map { |card| card_criteria(card) }
          raise Error, format(NO_CRITERIA, plan: relative(plan)) if criteria.empty?

          criteria
        end

        def card_criteria(card)
          card.criteria.map do |scenario|
            ::Lain::QA::Ladder::Criterion.new(id: "#{card.id}/#{scenario.name}", scenario:, risk: card.risk)
          end
        end

        # Named for the plan and the WHOLE RANGE, because the write is a bare
        # `File.write` and the name is the only thing keeping two reports apart.
        # The head alone is not enough: re-checking one wave against a narrower
        # ref is an ordinary thing to type, and two passes at one head over
        # different bases would then have the second silently overwrite the
        # first -- a PASS landing on top of a HOLD's blocker with nothing said.
        # Two passes over the SAME range still replace each other, which is the
        # one collision where both reports answer the same question -- though not
        # necessarily with the same answer, since three samples at a nonzero
        # temperature can disagree with themselves. Deliberate: never replacing
        # would grow a file per re-run with no way to say which is current.
        #
        # From the plan's PATH and not its basename, separators flattened: a tree
        # with `planning/<epic>/plan.md` twice is the ordinary shape, and this
        # repo's own `planning/` already carries three duplicated basenames.
        def written(plan, changes, report)
          path = File.join(ProjectDir.new(root: @root).qa, "#{slug(plan)}-#{stamp(changes)}.md")
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, report.to_markdown)
          path
        end

        def stamp(changes) = "#{changes.base[0, 7]}..#{changes.head[0, 12]}"

        # `Pathname#relative_path_from` rather than a prefix strip, so a plan named
        # by an absolute path outside the root still yields something stable.
        def slug(plan)
          Pathname.new(File.expand_path(plan)).relative_path_from(Pathname.new(@root)).to_s
                  .delete_suffix(File.extname(plan)).gsub(%r{[/\\]}, "-").delete_prefix("-")
        rescue ArgumentError
          File.basename(plan, ".*")
        end

        def summary(report, path)
          format(SUMMARY, verdict: WORDS.fetch(report.verdict), findings: report.findings.size,
                          holding: report.holding.size, unsettled: report.unsettled.size,
                          rungs: report.tiers_run.join("/"), report: relative(path))
        end

        # One refusal per missing half, never one sentence for both: telling
        # somebody who typed a plan doc that they need one sends them to re-read
        # the word that was right.
        def parsed(args)
          parsed = Args.parse(args, name:, usage: USAGE, flags: FLAGS, positionals: 1)
          plan = parsed.positionals.first
          raise Error, "#{name} needs a plan doc to check against -- #{USAGE}" if plan.nil?

          [readable(plan), based(parsed.pairs["base"])]
        end

        # `--base --width` is a base nobody named: {Args} hands the next word back
        # whatever it is, and {Args} says the noun belongs to the command.
        def based(base)
          raise Error, "#{name} needs --base REF, the revision the work started from -- #{USAGE}" if
            base.nil? || base.start_with?("--")

          base
        end

        def readable(plan)
          path = File.expand_path(plan, @root)
          raise Error, "#{name} cannot read the plan at #{path}" unless File.file?(path)

          path
        end

        def relative(path) = path.delete_prefix("#{@root}/")
      end
    end
  end
end
