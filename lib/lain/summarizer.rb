# frozen_string_literal: true

module Lain
  # The free tier of result compaction: PURE, SYNCHRONOUS summarizers a project
  # declares in a `.lain/summarizers.rb` Ruby DSL (the `.lain/` convention, like
  # {Skill::Catalog} and {Isolation::Services}). A summarizer takes a tool
  # result and returns shorter text -- no provider, no model, no IO -- so it
  # costs neither tokens nor latency, which is exactly why it is tried before
  # any model-backed summarization.
  module Summarizer
    # The loaded summarizers, in declaration order: a frozen, enumerable,
    # session-fixed snapshot rather than a mutable registry (the posture
    # {Skill::Catalog} and {Isolation::Services} take). An absent file is an
    # EMPTY catalog, never an error -- a project that declares no summarizers is
    # the common case, Null-Object by an empty enumeration rather than a nil
    # check.
    class Catalog
      include Enumerable

      # The project-scoped DSL file, on the `.lain/` convention (like `.git/`).
      DSL_PATH = File.join(".lain", "summarizers.rb")

      # Read and evaluate `<root>/.lain/summarizers.rb`. `root` is explicit and
      # never read at require time, so a spec (and a bench arm) can load a
      # catalog from a throwaway tree.
      def self.load(root: Dir.pwd)
        path = File.join(root, DSL_PATH)
        new(File.exist?(path) ? Builder.build(File.read(path), path) : [])
      end

      def initialize(summarizers)
        @summarizers = summarizers.freeze
        freeze
      end

      def each(&block) = @summarizers.each(&block)

      def empty? = @summarizers.empty?

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
