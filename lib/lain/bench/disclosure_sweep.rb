# frozen_string_literal: true

require "yaml"

module Lain
  module Bench
    # T14: a Compare-style report comparing the {Toolset::Disclosure} arms --
    # {Toolset::Disclosure::Upfront} (T12) and {Toolset::Disclosure::Deferred}
    # (T13) -- on two axes over a committed fixture of tool-selection tasks:
    # upfront-disclosure cost in tokens, and correct-call rate (does the arm's
    # RECORDED pick match the task's gold tool).
    #
    # Zero network by construction, {Sweep}'s posture: there is no live model
    # anywhere in this loop. Each fixture task carries a RECORDED pick per arm
    # -- what a prior run actually called under that arm's disclosure -- the
    # same "committed answer standing in for a live call" shape
    # {Sweep::Embeddings} uses for the vector arm. {Grader::Fixture} then
    # scores each recorded pick as a hard assertion (did it match gold?),
    # never a model judgment.
    #
    # This is a Compare-STYLE report, not a {Compare}: like {Sweep}, the
    # metrics here (tokens, correct-call rate) do not fit {Compare::Run}'s
    # usage/cost/score shape -- there is no {Ledger}-priced Timeline here --
    # so this reuses only {Compare::Distribution} and {Compare::Table} and
    # renders its own two-arm table, the same reuse boundary {Sweep}'s own
    # comment documents.
    #
    # == The code-API arm is OUT OF SCOPE, on purpose, and said so in the report
    #
    # A third disclosure arm -- code-API, where the model writes code against
    # tool bindings instead of emitting tool_use blocks -- needs the code-mode
    # exec boundary (M6), which does not exist yet. Leaving it out of the
    # table with no comment would read as "these two arms are the whole
    # axis"; {NOTE} says otherwise on every report.
    #
    # == No task is ever dropped
    #
    # Every task in the fixture is scored, on every arm -- there is no
    # sampling or cap here, and no code path that skips a task. A two-arm
    # sweep that silently dropped tasks would be exactly the anti-pattern
    # this card's own escalation trigger names.
    class DisclosureSweep
      # Raised when the fixture path does not exist -- a checkout or
      # packaging mistake, never user input to refuse. Named and path-bearing
      # like {Sweep::MissingCorpus}.
      class MissingFixture < Lain::Error; end

      # Raised when a fixture task is missing a required field -- a malformed
      # fixture is a bug in the fixture to surface loudly, never a task to
      # silently skip.
      class MalformedTask < Lain::Error; end

      # name => arm, in report order. An ordinary Hash is fine here (unlike
      # {Toolset#to_schema}'s Canonical.normalize): this orders REPORT ROWS,
      # never bytes headed for a model or a prompt cache.
      ARMS = { "upfront" => Toolset::Disclosure::Upfront, "deferred" => Toolset::Disclosure::Deferred }.freeze

      NOTE = "code-API arm (M6, exec boundary) is OUT OF SCOPE for this sweep -- " \
             "not measured, not implied by the two rows below."

      COLUMNS = ["arm", "n", "tokens mean", "tokens median", "tokens min", "tokens max",
                 "correct-call rate"].freeze
      private_constant :COLUMNS

      # One fixture task: its declared tool catalog, the gold (correct) tool,
      # and the RECORDED pick per arm.
      Task = Data.define(:id, :tools, :gold_tool, :recorded)

      # A minimal Tool built from fixture data, so the real {Toolset::Disclosure}
      # arms render a real {Toolset} -- never a hand-rolled stand-in for their
      # output. Never routed through {Tool#call}: this sweep renders
      # disclosure and scores RECORDED picks, it never executes a tool.
      class FixtureTool < Tool
        attr_reader :name, :description

        def initialize(name:, description:)
          super()
          @name = name
          @description = description
        end
      end
      private_constant :FixtureTool

      # @param fixture_path [String] a committed YAML fixture of tasks (see
      #   spec/fixtures/bench/disclosure/*.yml for the shape)
      def initialize(fixture_path:)
        @fixture_path = fixture_path
      end

      # A Compare-style report as a String -- never printed (output
      # discipline). Memoized so "report twice" is byte-identical for free.
      def report
        @report ||= render(measured)
      end

      private

      def measured
        ARMS.map { |name, klass| [name, distributions_for(name, klass.new)] }
      end

      def distributions_for(name, disclosure)
        { tokens: Compare::Distribution.new(tasks.map { |task| tokens_for(disclosure, task) }),
          correct: Compare::Distribution.new(tasks.map { |task| correct_call(name, task).score }) }
      end

      # A word-or-punctuation-run token proxy -- no BPE tokenizer lives
      # in-process, so this is deterministic and offline, which is what the
      # eval needs (the same reasoning behind {Sweep#recall_tokens}'s
      # whitespace proxy). Plain `#split` does NOT work here the way it does
      # for {Sweep}: {Canonical.dump} emits COMPACT JSON with no whitespace
      # around punctuation, so `input_schema`'s braces, colons, and commas
      # would silently count as zero extra tokens against prose that split
      # only on spaces -- exactly the gap that made Upfront and Deferred read
      # as byte-for-byte equal in tokens before this was written. Splitting
      # each punctuation character out as its own token is what lets the
      # schema Upfront carries and Deferred withholds actually show up.
      #
      # This is the cost of what each arm discloses UPFRONT ONLY -- a later
      # {Tools::ToolSearch} fetch a deferred-arm agent makes is a real,
      # separate cost this column does not fold in, matching the axis these
      # two Disclosure arms actually differ on.
      def tokens_for(disclosure, task)
        Canonical.dump(disclosure.render(toolset(task))).scan(/\w+|[^\w\s]/).size
      end

      def correct_call(arm_name, task)
        Grader::Fixture.new("#{task.id} correct call (#{arm_name})") do |f|
          f.check("recorded pick matches gold tool") { |t| t.recorded.fetch(arm_name) == t.gold_tool }
        end.grade(task)
      end

      def toolset(task)
        Toolset.new(task.tools.map do |tool|
          FixtureTool.new(name: tool.fetch("name"), description: tool.fetch("description"))
        end)
      end

      def tasks
        @tasks ||= YAML.safe_load_file(existing!(@fixture_path)).fetch("tasks").map { |raw| build_task(raw) }
      end

      # `tools`/`gold_tool`/`recorded` are run through {Canonical.normalize}
      # regardless of source, the same {Grader::ToolCallIndex::Call} precedent
      # for a value object built from plain YAML/JSON-parsed data: it must
      # stay deeply frozen (`Ractor.shareable?`) even though `YAML.safe_load_file`
      # freezes nothing.
      #
      # Every `#fetch` a malformed fixture could trip -- the task's own
      # top-level fields, EACH tool entry's `name`/`description`, and EACH
      # arm's per-task recorded pick -- happens IN THIS METHOD, inside the one
      # `rescue KeyError`, so every shape of malformed task gets the same
      # named-and-located {MalformedTask}. Scattering a `#fetch` into
      # {#toolset} or {#correct_call} instead would let a malformed nested
      # field raise a bare, task-less `KeyError` at SCORE time -- or worse,
      # inside a {Grader::Fixture} predicate, whose `rescue StandardError`
      # (fixture.rb's own `#evaluate`) would swallow it into an ordinary
      # FAILED criterion: a fabricated wrong-guess score indistinguishable
      # from a real one.
      def build_task(raw)
        Task.new(id: -raw.fetch("id").to_s, tools: Canonical.normalize(validated_tools(raw)),
                 gold_tool: Canonical.normalize(raw.fetch("gold_tool")),
                 recorded: Canonical.normalize(validated_recorded(raw)))
      rescue KeyError => e
        raise MalformedTask, "fixture task #{raw["id"].inspect} at #{@fixture_path} is missing #{e.key.inspect}"
      end

      def validated_tools(raw)
        raw.fetch("tools").map { |tool| { "name" => tool.fetch("name"), "description" => tool.fetch("description") } }
      end

      # Every arm this sweep measures ({ARMS}) must have a recorded pick for
      # THIS task -- a task recorded for one arm but not the other cannot
      # score the missing arm at all, and letting it try is exactly the
      # `KeyError`-into-fabricated-score hazard this method exists to close.
      def validated_recorded(raw)
        recorded = raw.fetch("recorded")
        ARMS.each_key.to_h { |arm| [arm, recorded.fetch(arm)] }
      end

      def existing!(path)
        raise MissingFixture, "no disclosure sweep fixture at #{path}" unless File.file?(path)

        path
      end

      def render(measured_arms)
        rows = measured_arms.map { |name, dists| row_for(name, dists) }
        [header, "", NOTE, "", Compare::Table.new(headers: COLUMNS, rows:).to_s].join("\n")
      end

      def header
        "Disclosure sweep — #{tasks.size} tasks, #{ARMS.size} arms (#{ARMS.each_key.to_a.join(" vs ")})"
      end

      def row_for(name, dists)
        tokens = dists.fetch(:tokens)
        correct = dists.fetch(:correct)
        [name, tokens.n.to_s,
         *[tokens.mean, tokens.median, tokens.min, tokens.max].map { |value| format("%.1f", value) },
         format("%.3f", correct.mean)]
      end
    end
  end
end
