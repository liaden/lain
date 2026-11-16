# frozen_string_literal: true

module Lain
  module Review
    class Queue
      # Plan runs worth reviewing, read from the plan files themselves: a run
      # that recorded a `base:` line is the one the executing skill started,
      # so no other state says which commits a run produced.
      class PlanRuns
        BASED = "^base: [0-9a-f]{40}$"
        REASONS = { "done" => "plan done", "in-progress" => "plan in progress" }.freeze
        private_constant :BASED, :REASONS

        # The header lines of one plan file, read once.
        Plan = Data.define(:path, :title, :status, :base, :head) do
          # @param path [String]
          # @param text [String]
          def self.parse(path, text)
            new(path:, title: text[/^# (.+)$/, 1], status: text[/^status:\s*(\S+)/, 1],
                base: text[/^base: ([0-9a-f]{40})$/, 1], head: text[/^head: ([0-9a-f]{40})$/, 1])
          end
        end
        private_constant :Plan

        # @param checkout [Isolation::Checkout] the repository whose plans are read
        def initialize(checkout:)
          @checkout = checkout
        end

        # @return [Array<Row>]
        def call = plan_files.filter_map { |path| row(plan(path)) }

        private

        # --untracked finds plans not yet committed; ignored files stay out by default.
        # Exit 1 is "no match", so only stdout is read.
        def plan_files
          @checkout.run("grep", "--untracked", "-l", "-E", BASED, "--", "planning").stdout.lines(chomp: true)
        end

        def plan(path) = Plan.parse(path, File.read(File.join(@checkout.dir, path)))

        def row(plan)
          reason = REASONS[plan.status]
          head = head_of(plan)
          build(plan, reason, head) if reason && head
        end

        # A finished run without a head line has no range to offer.
        def head_of(plan) = plan.status == "done" ? plan.head : plan.head || @checkout.out("rev-parse", "HEAD").strip

        def build(plan, reason, head)
          Row.new(id: "plan:#{plan.path}", rank: :plan_run, reason: "#{reason}: #{plan.title}", head_sha: head,
                  request: { "kind" => "range", "base" => plan.base, "head" => head,
                             "repo_root" => File.realpath(@checkout.dir) })
        end
      end
    end
  end
end
