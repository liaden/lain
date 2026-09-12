# frozen_string_literal: true

module Lain
  module CLI
    module EpicDriver
      PlanSubject = Data.define(:subject, :level)

      # What an issue's plan declares about its failing tests: the one source
      # file they are written for, and optionally the level root they sit
      # under. Read from `plans/<id>.md`, because where an issue's tests go is
      # a fact about how that issue is to be carried out -- it belongs with the
      # plan, not on the {Epic::Issue}, whose every digest and whose markdown
      # round-trip would change to carry it.
      #
      # WHAT IS DECLARED IS APPROVED. The `issue_plan` gate's digest covers the
      # plan's content, so the subject line is approved along with the plan
      # carrying it, and editing that line changes the digest and reopens the
      # gate. Nothing here re-checks the approval; it reads a plan the caller
      # has already had approved.
      #
      # The path is never checked for existence. Tests are written before the
      # code they describe, so the file the layout mirrors from routinely does
      # not exist yet; only its placement under a declared source root is
      # checked. That check, and the level's, happen only when the project
      # declares a layout at all -- one with no `[tests]` table is refused by
      # the test step, naming `[tests]`, rather than here naming an empty list
      # of roots.
      class PlanSubject
        SUBJECT = "Subject"
        LEVEL = "Level"

        # Every refusal of a plan's declaration, so a caller degrading one to a
        # notice rescues a single family.
        class Refusal < Error; end

        class Undeclared < Refusal; end
        class Ambiguous < Refusal; end
        class NotCanonical < Refusal; end
        class OutsideSourceRoots < Refusal; end
        class UnknownLevel < Refusal; end

        def initialize(subject:, level: nil)
          super(subject: -subject.to_s, level: level&.then { |name| -name.to_s })
        end

        # @param plan [#read, #path] the issue's plan artifact, as
        #   {Epic::Home#plan} answers
        # @param layout [TestLayout] the project's declared layout
        # @return [PlanSubject]
        # @raise [Refusal] naming the plan and what it must say
        def self.read(plan, layout:)
          text = plan.read
          new(subject: subject_in(text, plan, layout), level: level_in(text, plan, layout))
        end

        def self.subject_in(text, plan, layout)
          found = declarations(text, SUBJECT)
          raise Undeclared, undeclared(plan) if found.empty?
          raise Ambiguous, ambiguous(plan, SUBJECT, found) if found.size > 1

          placed(canonical!(found.first, plan), plan, layout)
        end

        # Shape before placement, and refused the way a `[tests]` source root
        # is: `app/../../etc/passwd.rb` passes any prefix test, and the layout
        # would then mirror a test file to a path outside the checkout
        # altogether -- which the write-time guard admits, since it lets a test
        # written before its class through by design.
        def self.canonical!(subject, plan)
          return subject if TestLayout::PathShape.canonical?(subject)

          raise NotCanonical, "#{plan.path} names the subject #{subject.inspect}, which is not a plain relative " \
                              "path inside the project: a subject carries no \".\" or \"..\" segment, no doubled " \
                              "or trailing slash, and no leading \"/\", \"~\" or \"-\""
        end

        def self.level_in(text, plan, layout)
          found = declarations(text, LEVEL)
          raise Ambiguous, ambiguous(plan, LEVEL, found) if found.size > 1

          found.first&.then { |name| known(name, plan, layout) }
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

        def self.placed(subject, plan, layout)
          return subject unless layout.in_force?
          return subject if layout.source_roots.any? { |root| subject == root || subject.start_with?("#{root}/") }

          raise OutsideSourceRoots, "#{plan.path} names the subject #{subject.inspect}, which is under none of " \
                                    "this project's declared source roots (#{layout.source_roots.join(", ")}): " \
                                    "the layout mirrors a test path from a source under one of them"
        end

        # Asked of the declared set rather than through `Mapping#level`, which
        # raises {TestLayout::Unplaceable} for a name it does not hold: a level
        # a plan misspelled is this object's refusal to make, by its own name.
        def self.known(level, plan, layout)
          return level unless layout.in_force?
          return level if layout.mapping.levels.any? { |declared| declared.name == level }

          raise UnknownLevel, "#{plan.path} names the level #{level.inspect}, which this project's [tests] table " \
                              "does not declare (#{layout.mapping.levels.map(&:name).join(", ")})"
        end

        def self.undeclared(plan)
          "#{plan.path} declares no test subject: add a line `Subject: <path>` naming the one source file this " \
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
