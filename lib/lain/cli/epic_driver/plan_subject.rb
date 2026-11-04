# frozen_string_literal: true

module Lain
  module CLI
    module EpicDriver
      PlanSubject = Data.define(:subject, :level, :acceptance)

      # What an issue declares about its failing tests: the one source file
      # they are written for, and optionally the level root they sit under.
      # {.of} reads them off the {Epic::Issue}, where `epic.md` carries them;
      # {.read} reads the same two lines out of free text, for {Arm::PlanOnly},
      # whose planner's answer has no issue to sit on.
      #
      # The path is never checked for existence. Tests are written before the
      # code they describe, so the file the layout mirrors from routinely does
      # not exist yet; only its placement under a declared source root is
      # checked. That check, and the level's, happen only when the project
      # declares a layout at all -- one with no `tests` table is refused by
      # the test step, naming `tests`, rather than here naming an empty list
      # of roots.
      class PlanSubject
        SUBJECT = "Subject"
        LEVEL = "Level"

        # Every refusal of a plan's declaration, so a caller degrading one to a
        # notice rescues a single family.
        class Refusal < Error; end

        class Undeclared < Refusal; end
        class NotCanonical < Refusal; end
        class OutsideSourceRoots < Refusal; end

        def initialize(subject:, level: nil, acceptance: Acceptance.of(level, scenarios: []))
          super(subject: -subject.to_s, level: level&.then { |name| -name.to_s }, acceptance:)
        end

        # @param plan [#read, #path] the planner's plan text and a
        #   name to cite in a refusal, as {Arm::PlanOnly} holds them in memory
        # @param layout [TestLayout] the project's declared layout
        # @return [PlanSubject]
        # @raise [Refusal] naming the plan and what it must say
        def self.read(plan, layout:)
          text = plan.read
          level = level_in(text, plan, layout)
          acceptance = Acceptance.of(level, scenarios: [])
          new(subject: subject_in(text, plan, layout, acceptance), level:, acceptance:)
        end

        # @param issue [Epic::Issue] the issue whose tests are to be written
        # @param layout [TestLayout] the project's declared layout
        # @return [PlanSubject]
        # @raise [Refusal] naming the issue and what it must carry
        def self.of(issue, layout:)
          where = "issue #{issue.id.inspect}"
          raise Undeclared, undeclared(where) if issue.subject.nil?

          level = issue.level&.then { |name| known(name, where, layout) }
          acceptance = Acceptance.of_issue(issue)
          new(subject: placed(canonical!(issue.subject, where), where, layout, acceptance), level:, acceptance:)
        end

        def self.subject_in(text, plan, layout, acceptance)
          found = declarations(text, SUBJECT)
          raise Undeclared, undeclared(plan.path) if found.empty?
          raise Refusal, ambiguous(plan, SUBJECT, found) if found.size > 1

          placed(canonical!(found.first, plan.path), plan.path, layout, acceptance)
        end

        # Shape before placement, and refused the way a `tests` source root
        # is: `app/../../etc/passwd.rb` passes any prefix test, and the layout
        # would then mirror a test file to a path outside the checkout
        # altogether -- which the write-time guard admits, since it lets a test
        # written before its class through by design.
        def self.canonical!(subject, where)
          return subject if TestLayout::Shapes::PathShape.canonical?(subject)

          raise NotCanonical, "#{where} names the subject #{subject.inspect}, which is not a plain relative " \
                              "path inside the project: a subject carries no \".\" or \"..\" segment, no doubled " \
                              "or trailing slash, and no leading \"/\", \"~\" or \"-\""
        end

        def self.level_in(text, plan, layout)
          found = declarations(text, LEVEL)
          raise Refusal, ambiguous(plan, LEVEL, found) if found.size > 1

          found.first&.then { |name| known(name, plan.path, layout) }
        end

        # A line whose first word is the keyword -- the markdown emphasis and
        # the backticks a human writes a path in aside.
        def self.declarations(text, keyword)
          pattern = /\A\*{0,2}#{keyword}:\*{0,2}[ \t]*(?<value>.+?)\z/
          prose(text).filter_map { |line| pattern.match(line)&.then { |found| clean(found[:value]) } }
        end

        # Only the lines outside fenced code: a plan SHOWING what a Subject
        # line looks like has not declared one.
        def self.prose(text)
          text.lines.map(&:strip).inject([false, []]) do |(fenced, kept), line|
            opening = fence?(line)
            [opening ? !fenced : fenced, kept + (fenced || opening ? [] : [line])]
          end.last
        end

        def self.fence?(line) = line.start_with?("```", "~~~")

        def self.clean(value) = value.delete("`").strip

        # A manual subject is a script, a manifest or a spike, which no
        # layout mirrors a test from.
        def self.placed(subject, where, layout, acceptance)
          return subject unless acceptance.placed_by_layout? && layout.in_force?
          return subject if layout.source_roots.any? { |root| subject == root || subject.start_with?("#{root}/") }

          raise OutsideSourceRoots, "#{where} names the subject #{subject.inspect}, which is under none of " \
                                    "this project's declared source roots (#{layout.source_roots.join(", ")}): " \
                                    "the layout mirrors a test path from a source under one of them"
        end

        # Asked of the declared set rather than through `Mapping#level`, which
        # raises {TestLayout::Unplaceable} for a name it does not hold: a level
        # a plan misspelled is this object's refusal to make, by its own name.
        def self.known(level, where, layout)
          return level unless Acceptance.of(level, scenarios: []).placed_by_layout? && layout.in_force?
          return level if layout.mapping.levels.any? { |declared| declared.name == level }

          raise Refusal, "#{where} names the level #{level.inspect}, which this project's `tests` config " \
                         "does not declare (#{layout.mapping.levels.map(&:name).join(", ")})"
        end

        def self.undeclared(where)
          "#{where} declares no test subject: add a line `Subject: <path>` naming the one source file this " \
            "issue's failing tests are written for, relative to the project root"
        end

        def self.ambiguous(plan, keyword, found)
          "#{plan.path} declares #{found.size} #{keyword} lines (#{found.join(", ")}), and an issue carries one " \
            "#{keyword.downcase}: name a single one"
        end

        private_class_method :subject_in, :level_in, :declarations, :prose, :fence?, :clean, :canonical!,
                             :placed, :known, :undeclared, :ambiguous
      end
    end
  end
end
