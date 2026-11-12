# frozen_string_literal: true

module Lain
  module CLI
    # `lain todos`: drain the project's chore file through a {Chores::Runner}, say
    # where it stands, and append a line to it. Written `::Lain::Chores` because
    # this class would otherwise shadow a `Lain::Todos`.
    class Todos
      INTERRUPTED = 130
      DONE = %i[landed researched].freeze

      # @param project [Project] the project whose chore file is drained
      # @param paths [Paths]
      # @param lain [String] the `exe/lain` each chore's chat runs from
      # @param max_cost [Numeric] each chat's --max-cost, in dollars
      # @param sink [#puts] where a failing notify-feed is named
      # @return [Chores::Runner] confined in a clone lease per item, landing through the project's merge coordinator
      def self.runner(project:, paths:, lain:, max_cost:, sink:)
        ::Lain::Chores::Runner.new(
          queue: queue_for(project, paths),
          backend: IsolationBackend.resolve("worktree", root: project.root, paths:), lain:, max_cost:, paths:,
          land: ->(lease) { Land.new(cwd: lease, paths:) }, notices: ::Lain::Notices.for(env: ENV, notes: sink)
        )
      end

      # @return [Chores::Queue] the project's chore file, as its config names it
      def self.queue_for(project, paths)
        ::Lain::Chores::Queue.at(project.root, file: ::Lain::Config.load(root: project.root).todos.file, paths:)
      end

      # @param project [Project] whose root holds the chore file
      # @param paths [Paths] where the queue's lock lives
      # @param sink [#puts] where each outcome and the status are said
      # @param runner [Chores::Runner, #call] the runner, or a factory built only when a drain starts
      def initialize(project:, paths:, sink:, runner:)
        @project = project
        @paths = paths
        @sink = sink
        @runner = runner
      end

      # @param max_items [Integer, nil] how many items to take; all open ones when nil
      # @return [Integer] 0 when every outcome is landed or researched, 1 otherwise, 130 when interrupted
      def drain(max_items: nil)
        raise Error, "--max-items must be 0 or more, got #{max_items}" if max_items&.negative?

        outcomes = announced(max_items).to_a
        outcomes.all? { |outcome| DONE.include?(outcome.status) } ? 0 : 1
      rescue Interrupt
        @sink.puts("interrupted")
        INTERRUPTED
      end

      # @return [String] the counts, then each claimed line with its pid, host and whether the pid is live
      def status
        items = queue.items
        counts = %i[open claimed abandoned done failed].map { |state| "#{state} #{items.count { _1.state == state }}" }
        [counts.join(", "), *items.select(&:claim).map { |item| claim_line(item) }].join("\n")
      end

      # @return [String] the line appended to the chore file
      # @raise [Lain::Error] for text with nothing in it
      def add(text)
        text = text.to_s.gsub(/\s+/, " ").strip
        raise Error, "the chore text is empty" if text.empty?

        queue.append(text)
      end

      private

      def announced(max_items)
        runner = @runner.respond_to?(:call) ? @runner.call : @runner
        stream = max_items ? runner.lazy.take(max_items) : runner.lazy
        stream.map do |outcome|
          outcome.tap do
            @sink.puts("#{outcome.status} #{outcome.item.text}: #{outcome.summary}")
          end
        end
      end

      def claim_line(item)
        liveness = item.state == :claimed ? "live" : "not live"
        "~ #{item.text} (pid #{item.claim.pid} on #{item.claim.host}, #{liveness})"
      end

      def queue = @queue ||= self.class.queue_for(@project, @paths)
    end
  end
end
