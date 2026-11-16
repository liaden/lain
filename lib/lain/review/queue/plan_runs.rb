# frozen_string_literal: true

module Lain
  module Review
    class Queue
      # Plan runs worth reviewing, read from the plan files themselves: a run
      # that recorded a `base:` line is the one the executing skill started,
      # so no other state says which commits a run produced.
      class PlanRuns
        # Any value: one that is not a sha is named in a note rather than dropped unseen.
        BASED = "^base: [^[:space:]]+$"
        REASONS = { "done" => "plan done", "in-progress" => "plan in progress" }.freeze
        private_constant :BASED, :REASONS

        # The header lines of one plan file, read once.
        Plan = Data.define(:path, :title, :status, :base, :head) do
          # @param path [String]
          # @param text [String]
          def self.parse(path, text)
            new(path:, title: text[/^# (.+)$/, 1], status: text[/^status:\s*(\S+)/, 1],
                base: text[/^base: (\S+)$/, 1], head: text[/^head: (\S+)$/, 1])
          end
        end
        private_constant :Plan

        # @param checkout [Isolation::Checkout] the repository whose plans are read
        # @param notes [#puts] where a plan a request refuses is named
        # @param shell_out_factory [#call] builds the subprocess runner
        def initialize(checkout:, notes:, shell_out_factory: Shell::Out.public_method(:new))
          @checkout = checkout
          @listing = Listing.new(notes:, shell_out_factory:)
        end

        # @return [Array<Row>]
        def call
          @root = @listing.top_of(@checkout.dir)
          plan_files.filter_map { |path| read(path)&.then { |plan| row(plan) } }
        end

        private

        # --untracked finds plans not yet committed; ignored files stay out by default.
        # Exit 1 is "no match", so only stdout is read. quotePath off, or a
        # non-ASCII name comes back quoted and octal-escaped.
        def plan_files
          found = @checkout.run("grep", "--untracked", "-l", "-E", BASED, "--", "planning",
                                pins: ["core.quotePath=false"]).stdout
          String.new(found, encoding: Encoding::UTF_8).lines(chomp: true)
        end

        def read(path)
          return @listing.skip("plan:#{path.scrub}", "its path is not UTF-8") unless path.valid_encoding?

          Plan.parse(path, File.read(File.join(@checkout.dir, path)))
        rescue SystemCallError => e
          @listing.skip("plan:#{path}", e.message)
        end

        def row(plan)
          reason = REASONS[plan.status]
          head = head_of(plan)
          build(plan, reason, head) if reason && head
        end

        # A finished run without a head line has no range to offer.
        def head_of(plan) = plan.status == "done" ? plan.head : plan.head || @checkout.out("rev-parse", "HEAD").strip

        def build(plan, reason, head)
          @listing.row("plan:#{plan.path}",
                       { "kind" => "range", "base" => plan.base, "head" => head, "repo_root" => @root },
                       rank: :plan_run, reason: "#{reason}: #{plan.title}", head_sha: head)
        end
      end
    end
  end
end
