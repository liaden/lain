# frozen_string_literal: true

module Lain
  # The free tier of result compaction: PURE, SYNCHRONOUS summarizers a project
  # declares in a `.lain/summarizers.rb` Ruby DSL (the `.lain/` convention, like
  # {Skill::Catalog} and {Isolation::Services}). A summarizer takes a tool
  # result and returns shorter text -- no provider, no model, no IO -- so it
  # costs neither tokens nor latency, which is exactly why it is tried before
  # any model-backed summarization.
  module Summarizer
    # The loaded summarizers, in declaration order. {DslCatalog} owns everything
    # a `.lain/*.rb` loader shares -- the exist-guard, the empty-is-not-an-error
    # posture, and the frozen session-fixed enumeration rather than a mutable
    # registry -- so all this class adds is where its file is, who evaluates it,
    # and the one lookup its callers actually make.
    class Catalog < DslCatalog
      # The project-scoped DSL file, on the `.lain/` convention (like `.git/`).
      DSL_PATH = ProjectDir.join("summarizers.rb")

      # Resolved at CALL time: {Builder} loads after this class body (see the
      # note at the foot of this file), so a constant read here would NameError.
      def self.builder = Builder

      # The summarizer that handles `result`, or nil when none does.
      #
      # RAISES WHATEVER USER CODE RAISES. Finding the summarizer means CALLING
      # user `suitable?` predicates, so this method is as brittle as the file it
      # loaded: a predicate that raises propagates out of `#for` itself, and no
      # later declaration is consulted. That is deliberate -- rescuing here would
      # hide a broken user summarizer forever, and loud failure is the premise.
      # The consequence for a caller is that BOTH this call and the `compact` it
      # leads to need the fallthrough to the model-backed tier, not just
      # `compact`.
      #
      # DECLARATION ORDER decides between two suitable summarizers: the first
      # declared wins. Order is a lever the user already has and can see in
      # their own file, where a relevance score would be a second mechanism to
      # explain and to tune.
      #
      # nil, deliberately, and not a Null Object: the caller's job on a miss is
      # to FALL THROUGH to the next (model-backed) tier, and a null summarizer
      # that politely returned the text unchanged would swallow that fallthrough
      # and silently disable compaction.
      def for(result) = find { |summarizer| summarizer.suitable?(result) }
    end
  end
end

# The value and the contract first; the evaluator subclasses {Base}, so it loads
# after it (the children-after-the-class-body order effect/handler.rb uses).
require_relative "summarizer/result"
require_relative "summarizer/base"
require_relative "summarizer/builder"
