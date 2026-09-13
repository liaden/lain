# frozen_string_literal: true

require "yaml"

module Lain
  module Bench
    class Altitude
      # The fixture suite, read and validated: the tasks an altitude run
      # compares its arms over, grouped onto the size axis the report is built
      # around.
      #
      # Every refusal here fires BEFORE any arm runs, which is the point of
      # doing this work in one place: a malformed suite must cost nothing, and
      # on a bench whose arms spend real money "nothing" is a hard requirement
      # rather than a nicety.
      #
      # Its own file for {Subject}'s reason -- a nested class's lines count
      # toward the enclosing class under Metrics/ClassLength, which is the split
      # {ArmSweep} already makes for {ArmSweep::Recordings}. The error classes
      # stay on {Altitude}, because they are what a caller rescues.
      class Suite
        include Enumerable

        # @param path [String] the committed suite
        def initialize(path:)
          @path = path
        end

        # @yield [Task] each task, in fixture order
        def each(&block)
          return to_enum(:each) unless block_given?

          tasks.each(&block)
        end

        # Grouped in FIXTURE ORDER, so the report reads smallest-declared first
        # rather than in whatever order a Hash happened to yield.
        #
        # @return [Hash{String=>Array<Task>}]
        # @raise [Error] naming a size that cannot fold a distribution
        def by_size
          grouped = group_by(&:size)
          thin = grouped.find { |_size, tasks| tasks.size < MINIMUM }
          # A size carrying too few tasks to fold a distribution from.
          raise Error, too_few(*thin) unless thin.nil?

          grouped
        end

        private

        def tasks = @tasks ||= unique!(raw_tasks.each_with_index.map { |raw, index| build_task(raw, index) })

        def too_few(size, tasks)
          "the #{size.inspect} size carries #{tasks.size} task (#{tasks.map(&:id).join(", ")}) and a " \
            "distribution needs at least #{MINIMUM}: one run is a point, not a distribution"
        end

        # Three distinct failure modes at the root, each named and located rather
        # than left to leak: a document that is not a mapping at all (a sequence
        # answers no `#fetch` for a String key), one carrying no `tasks:`, and one
        # declaring it empty. The last would otherwise fall through and be
        # reported as a SIZE being too thin, which tells the operator about a
        # size when the problem is the file.
        def raw_tasks
          document = YAML.safe_load_file(existing!)
          raise MalformedTask, rooted("is not a mapping, so it declares no `tasks:` key") unless document.is_a?(Hash)

          declared!(document.fetch("tasks") { raise MalformedTask, rooted("is missing the top-level `tasks:` key") })
        end

        def declared!(tasks)
          return tasks unless Array(tasks).empty?

          raise MalformedTask, rooted("declares no tasks at all, so there is nothing to compare")
        end

        def rooted(complaint) = "altitude fixture at #{@path} #{complaint}"

        # Every `#fetch` a malformed task could trip happens inside the one
        # rescue, so every shape of malformed task is named and located alike.
        def build_task(raw, index)
          mapping!(raw, index)
          declared = FIELDS.to_h { |field| [field.to_sym, -raw.fetch(field).to_s] }
          Task.new(**declared, project: project_for(declared))
        rescue KeyError => e
          raise MalformedTask, "altitude task #{raw["id"].inspect} at #{@path} is missing #{e.key.inspect}"
        end

        # RESOLVED IN THE PRE-FLIGHT, not inside the run. It is pure path work,
        # and doing it lazily meant a suite whose second task named a missing
        # project took the whole report down with the first task's arms already
        # spent -- while this class's whole promise is that a malformed suite
        # costs nothing.
        #
        # Against the FIXTURE's own directory, so a suite is relocatable and a
        # caller can name a project absolutely.
        def project_for(declared)
          path = File.expand_path(declared.fetch(:subject), File.dirname(@path))
          return path if Dir.exist?(path)

          # A task naming a subject project that is not on disk. Refused by name:
          # an arm with nothing to work in would be graded on an empty directory,
          # and an empty directory grades as a suite that failed.
          raise Error, "altitude task #{declared.fetch(:id).inspect} names the subject project " \
                       "#{declared.fetch(:subject).inspect}, and there is no directory at #{path}"
        end

        # Its own guard because a YAML entry that parses to a bare String has no
        # `#fetch` at all, so it would surface as a NoMethodError rather than as
        # the named, located refusal every other malformed task gets.
        def mapping!(raw, index)
          return if raw.is_a?(Hash)

          raise MalformedTask, rooted("entry #{index} is not a mapping: #{raw.inspect}")
        end

        # Ids are how a run is matched back to the task it was given, so a silent
        # duplicate would make the second unreachable rather than loud.
        def unique!(built)
          duplicates = built.map(&:id).tally.select { |_id, count| count > 1 }.keys
          return built if duplicates.empty?

          raise MalformedTask, rooted("has duplicate task id(s): #{duplicates.join(", ")}")
        end

        def existing!
          raise MissingFixture, "no altitude fixture at #{@path}" unless File.file?(@path)

          @path
        end
      end
    end
  end
end
