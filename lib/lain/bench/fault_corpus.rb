# frozen_string_literal: true

module Lain
  module Bench
    # Planted faults in the tasks a grader scores, one directory per class:
    # a task entry in {ArmTasks}' format, a trajectory written as the FILE...END
    # blocks an arm would answer with, and the verdict a sound grader owes it.
    # The report grades each planted trajectory with the grader `bench arms`
    # uses and says where the grader and the expectation part.
    class FaultCorpus
      # A fault directory that cannot be read as a fault is a bug in the corpus,
      # never one to skip.
      class MalformedFault < Lain::Error; end

      # What a class's disagreement MEANS, fixed per class: a cheat that passes
      # fools the grader, while a correct answer that fails shows a gold that
      # asks for more than the prompt says. A class with no entry cannot load.
      Meaning = Data.define(:label, :note)
      MEANINGS = {
        "cheatable" => Meaning.new("grader fooled", "cheat passed: gold check is cheatable"),
        "unstated_rule" => Meaning.new("gold too strict", "gold rejects a correct answer"),
        "ambiguous_prompt" => Meaning.new("gold too strict", "gold rejects a correct answer")
      }.freeze
      private_constant :MEANINGS

      CLASSES = MEANINGS.keys.freeze
      private_constant :CLASSES
      VERDICTS = %i[pass fail].freeze
      private_constant :VERDICTS

      FORMAT = "%-16s %-9s %-9s %-7s %s"
      private_constant :FORMAT

      Fault = Data.define(:klass, :task, :trajectory, :expected)

      # @param dir [String] a directory holding one subdirectory per {CLASSES} entry
      # @raise [MalformedFault] naming the fault directory that is incomplete
      def self.load(dir) = new(CLASSES.map { |klass| read(klass, File.join(dir, klass)) })

      def self.read(klass, path)
        Fault.new(klass:, task: task_in(path), trajectory: trajectory_in(path), expected: verdict_in(path))
      end
      private_class_method :read

      def self.task_in(path)
        tasks = ArmTasks.new(fixture_path: File.join(path, "task.yml")).load!.to_a
        raise MalformedFault, "fault #{path} must hold exactly 1 task, got #{tasks.size}" unless tasks.one?

        tasks.first
      rescue ArmTasks::MissingFixture, ArmTasks::MalformedTask => e
        raise MalformedFault, "fault #{path}: #{e.message}"
      end
      private_class_method :task_in

      def self.trajectory_in(path)
        ArmTasks::Trajectory.new(files: ArmSweep::FileBlocks.parse(file_in(path, "trajectory.txt")))
      end
      private_class_method :trajectory_in

      def self.verdict_in(path)
        word = file_in(path, "expected").strip
        VERDICTS.find { _1.to_s == word } ||
          raise(MalformedFault, "fault #{path} expects #{word.inspect}, not pass or fail")
      end
      private_class_method :verdict_in

      def self.file_in(path, name)
        File.read(File.join(path, name))
      rescue SystemCallError
        raise MalformedFault, "fault #{path} is missing its #{name}"
      end
      private_class_method :file_in

      attr_reader :faults

      def initialize(faults)
        @faults = faults.freeze
      end

      # @return [Array<ArmTasks::Task>] what a grader dispatching by prompt is built over
      def tasks = faults.map(&:task)

      # @param grader [#grade] takes a Timeline, as {Bench::CLI}'s suite grader does
      # @return [String]
      def report(grader:)
        rows = faults.map { |fault| Row.new(fault, grader.grade(timeline_for(fault)).pass) }
        [header, *rows.map(&:line), totals(rows)].join("\n")
      end

      private

      # The grader dispatches on the prompt a run was asked and reads the files
      # off its assistant turns, so a planted trajectory is replayed as that
      # 2-turn conversation.
      def timeline_for(fault)
        Dag::Factory.timeline(store: Dag::Factory.store)
                    .commit(role: :user, content: [{ "type" => "text", "text" => fault.task.prompt }])
                    .commit(role: :assistant, content: [{ "type" => "text", "text" => answer_for(fault) }])
      end

      def answer_for(fault)
        fault.trajectory.files.map { |path, body| "FILE #{path}\n#{body}\nEND" }.join("\n")
      end

      def header = format(FORMAT, "class", "expected", "observed", "agree?", "note")

      def totals(rows)
        split = MEANINGS.values.map(&:label).uniq.map do |label|
          "#{rows.count { !_1.agree? && _1.meaning.label == label }} #{label}"
        end
        "#{rows.size} faults: #{split.join(", ")}"
      end

      # One planted fault beside what the grader made of it.
      Row = Struct.new(:fault, :passed) do
        def observed = passed ? :pass : :fail

        def agree? = observed == fault.expected

        def line = format(FORMAT, fault.klass, fault.expected, observed, agree? ? "yes" : "no", note).rstrip

        def meaning = MEANINGS.fetch(fault.klass)

        def note = agree? ? "" : meaning.note
      end
      private_constant :Row
    end
  end
end
