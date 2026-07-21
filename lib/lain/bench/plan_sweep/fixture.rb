# frozen_string_literal: true

require "yaml"

module Lain
  module Bench
    class PlanSweep
      # Loads the one fixed multi-step plan and its scripted runs from committed
      # files (explicit paths, no lib->spec fixture coupling -- the {ArmSweep}
      # discipline). One authored {Plan::Document} drives all three seam
      # densities: the file carries the "author-thinned" seams, and #document_for
      # DERIVES `every` and `none` from it with P1's `insert_seam`/`remove_seam`,
      # so a single plan spans the density axis and switching density changes zero
      # plan CONTENT -- only where the seams sit.
      class Fixture
        # A missing fixture file -- a checkout or packaging mistake, never user
        # input to refuse. Named and path-bearing like {ArmSweep::MissingFixture}.
        class MissingFixture < Lain::Error; end

        # A fixture that loaded but is structurally broken -- a plan that parsed
        # no steps, or a scripted run missing a plan-required step. Distinct from
        # {MissingFixture} (the file is absent): here the file is present and
        # wrong, and a silent pass would yield a plausible-looking VACUOUS report
        # (grader populated, every cost column zero, no signal). The named,
        # path/run/step-bearing sibling {ArmTasks::MalformedTask} is the precedent.
        class MalformedFixture < Lain::Error; end

        # The three seam densities the sweep sweeps. `thinned` is the plan as its
        # author placed the seams; `every` seams after every step (the finest
        # plan-shaped granularity); `none` removes all seams so the whole plan is
        # one chunk -- the reactive baseline's shape (no plan seam ever fires).
        DENSITIES = %i[every thinned none].freeze

        # One scripted run: the file each step produced, `step_id => {file,
        # content}`. What a step wrote depends only on the run, never on the arm
        # -- so the produced-work grade is arm-invariant and the shape signal
        # lives entirely in tokens and cache-writes.
        ScriptedRun = Data.define(:id, :steps) do
          def file_for(step_id) = step(step_id).fetch("file")
          def content_for(step_id) = step(step_id).fetch("content")

          # Every path=>content this run produced across its steps -- the union
          # the gold grader scores.
          def files = steps.values.to_h { |entry| [entry.fetch("file"), entry.fetch("content")] }

          def step(step_id) = steps.fetch(step_id.to_s)

          # Whether this run scripts an output for a plan step -- the coverage
          # check {Fixture} runs so a missing step fails loud at load, never as a
          # bare KeyError from {#step} deep in the driver.
          def covers?(step_id) = steps.key?(step_id.to_s)
        end

        # The per-file gold target: `path => substring that must appear`. Grades
        # the whole produced trajectory (ArmTasks-style {Grader::Fixture}) for the
        # sweep's score column, and a single file for a step's own closure grade.
        Gold = Data.define(:expectations) do
          def trajectory_grader
            Grader::Fixture.new("plan sweep gold") do |fixture|
              expectations.each do |path, needle|
                fixture.check("#{path} contains #{needle.inspect}") do |trajectory|
                  trajectory.content_at(path).include?(needle)
                end
              end
            end
          end

          # A step's own pass/fail against its file's gold. A file with no gold
          # expectation passes (the plan may touch scaffolding the gold ignores).
          def grade_file(path, content)
            needle = expectations[path]
            return Grader::Grade.new(score: 1.0, why: "#{path} has no gold expectation") if needle.nil?

            hit = content.include?(needle)
            Grader::Grade.new(score: hit ? 1.0 : 0.0, pass: hit,
                              why: hit ? "#{path} matched gold" : "#{path} missing #{needle.inspect}")
          end
        end

        # @param plan_path [String] the committed plan markdown
        # @param runs_path [String] the committed scripted-runs YAML (gold + runs)
        def initialize(plan_path:, runs_path:)
          @plan_path = plan_path
          @runs_path = runs_path
          @document = parse_plan
          @raw = YAML.safe_load_file(existing!(runs_path))
          runs # force the per-run coverage check loudly at load, not mid-driver
        end

        # The plan at one density, derived from the authored document.
        # @param density [Symbol] one of {DENSITIES}
        def document_for(density)
          documents.fetch(density) { raise ArgumentError, "unknown density #{density.inspect}" }
        end

        # @return [Array<ScriptedRun>] in fixture order
        def runs
          @runs ||= @raw.fetch("runs").map { |raw| checked_run(raw) }
        end

        def gold
          @gold ||= Gold.new(expectations: @raw.fetch("gold"))
        end

        private

        # An empty parse is a broken fixture, not a zero-step plan: a plan.md of
        # prose (or a stray path) parses to no steps and would otherwise drive a
        # vacuous sweep. Fail loud, naming the path.
        def parse_plan
          document = Plan::Document.parse_markdown(File.read(existing!(@plan_path)))
          return document if document.steps.any?

          raise MalformedFixture, "plan-sweep plan at #{@plan_path} parsed no steps (an empty or unparseable plan)"
        end

        # One run, refused loudly if it omits any plan step -- naming the run and
        # the missing step(s) so the fixture bug is legible at load, never a bare
        # KeyError surfacing later when the driver reaches for that step.
        def checked_run(raw)
          run = ScriptedRun.new(id: -raw.fetch("id").to_s, steps: raw.fetch("steps"))
          missing = required_step_ids.reject { |id| run.covers?(id) }
          raise MalformedFixture, missing_steps_message(run, missing) unless missing.empty?

          run
        end

        def missing_steps_message(run, missing)
          "scripted run #{run.id.inspect} in #{@runs_path} is missing plan step(s) #{missing.join(", ")} " \
            "(every run must cover all #{required_step_ids.size} plan steps)"
        end

        def required_step_ids = @document.steps.map(&:id)

        def documents
          @documents ||= { every: seam_every, thinned: @document, none: strip_seams }
        end

        # Seam after every step that could carry one and does not already -- the
        # finest density, built by editing the authored plan, never re-authored.
        def seam_every
          @document.steps[0...-1].map(&:id).reject { |id| @document.seam?(id) }
                                           .inject(@document) { |doc, id| doc.insert_seam(after: id) }
        end

        def strip_seams
          @document.seams.inject(@document) { |doc, id| doc.remove_seam(after: id) }
        end

        def existing!(path)
          raise MissingFixture, "no plan-sweep fixture at #{path}" unless File.file?(path)

          path
        end
      end
    end
  end
end
