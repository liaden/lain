# frozen_string_literal: true

module Lain
  # The free tier of result compaction: PURE, SYNCHRONOUS summarizers a project
  # declares in a `.lain/summarizers.rb` Ruby DSL. A summarizer takes a tool
  # result and returns shorter text -- no provider, no model, no IO -- so it
  # costs neither tokens nor latency, which is why it is tried before any
  # model-backed summarization.
  #
  # == One uncontained failure mode: a predicate that does not TERMINATE
  #
  # A declaration that RAISES is contained twice over -- {Oracle::RoutedSummarizer}
  # rescues the scan and the compaction, {Oracle::Eager}'s task boundary rescues
  # the fire -- and both name `ScriptError` and `SystemStackError` beside
  # `StandardError`, because a half-written file is the state this DSL spends its
  # authoring life in.
  #
  # A declaration that SPINS is contained by nothing, and cannot be by a rescue.
  # {Oracle::Eager#fire} spawns onto an async task that runs eagerly until its
  # first yield point; a CPU loop has none, so `suitable?` runs to completion
  # INSIDE the observing call. Measured: an `observe` of a 17-byte result
  # returned after 0.637s against a predicate that spun, and
  # {Agent::ToolRunner#observe_all} pays that per block, with no timeout on the
  # path. The exposure is wide because the catalog is consulted for every tool
  # result, not only above {Oracle::RoutedSummarizer::MODEL_THRESHOLD_BYTES};
  # bounding it means moving the call off the observing fiber or onto a deadline,
  # which is a change to {Oracle::Eager}, not to a rescue list.
  module Summarizer
    # The loaded summarizers, in declaration order. {DslCatalog} owns what every
    # `.lain/*.rb` loader shares -- the exist-guard, the empty-is-not-an-error
    # posture, the frozen session-fixed enumeration -- so this class adds only
    # where its file is, who evaluates it, and the one lookup callers make.
    class Catalog < DslCatalog
      # The project-scoped DSL file, on the `.lain/` convention (like `.git/`).
      DSL_PATH = ProjectDir.summarizers

      # Resolved at CALL time: {Builder} loads after this class body (see the
      # note at the foot of this file), so a constant read here would NameError.
      def self.builder = Builder

      # The summarizer that handles `result`, or nil when none does.
      #
      # RAISES WHATEVER USER CODE RAISES. Finding a summarizer means CALLING user
      # `suitable?` predicates, so a raise propagates out of `#for` itself and no
      # later declaration is consulted -- rescuing here would hide a broken user
      # summarizer forever. The consequence for a caller is that BOTH this call
      # and the `compact` it leads to need the fallthrough to the model tier.
      #
      # DECLARATION ORDER decides between two suitable summarizers, first wins:
      # order is a lever the user already has and can see in their own file,
      # where a relevance score would be a second mechanism to explain and tune.
      #
      # nil, and not a Null Object: the caller's job on a miss is to FALL THROUGH
      # to the model-backed tier, and a null summarizer politely returning the
      # text unchanged would swallow that and silently disable compaction.
      def for(result) = find { |summarizer| summarizer.suitable?(result) }
    end
  end
end

# The value and the contract first; the evaluator subclasses {Base}, so it loads
# after it (the children-after-the-class-body order effect/handler.rb uses).
require_relative "summarizer/result"
require_relative "summarizer/base"
require_relative "summarizer/builder"
