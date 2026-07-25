# frozen_string_literal: true

module Lain
  module Summarizer
    # The evaluation context for `.lain/summarizers.rb`. The DSL surface itself:
    # one verb, `summarizer "<name>" do ... end`, appending a frozen declaration
    # and RETURNING it, in the same registration idiom {Isolation::Services::Builder}
    # uses.
    #
    # instance_eval'd against the user's file with NO sandbox (Rails-like): the
    # block's body is ordinary Ruby, so a user writes `def suitable?` and
    # `def compact` as plain methods rather than learning a second notation.
    #
    # Discovery is this VERB, not class-constant discovery. `Kernel.load` plus
    # diffing `Class#subclasses` was the obvious alternative and is measurably
    # broken: a second load of a same-named class REOPENS it, so the diff comes
    # back empty and the catalog silently loses every summarizer on reload;
    # `Class#subclasses` is also direct-only, so a user's own intermediate base
    # class hides the real summarizers behind it. An `inherited` hook or a global
    # registry fails differently -- both make load order observable, so one
    # spec's throwaway declaration leaks into the next.
    class Builder
      # The DSL verbs, which ARE the stable user surface. Named here so an
      # unknown verb's error can list them.
      VERBS = %i[summarizer].freeze

      # An unrecognized verb in `.lain/summarizers.rb`. The DSL is a stable
      # surface, so a typo fails LOUDLY and named rather than as a bare
      # NoMethodError.
      class Unknown < Error; end

      # A second declaration of a name already declared. The catalog answers with
      # the FIRST suitable summarizer, so a same-named second one is either a
      # copy-paste the user meant to edit or an override that will never run --
      # both refuse rather than resolve silently.
      class Duplicate < Error; end

      # A file that stopped early. `return if ENV["CI"]` is idiomatic in a config
      # file, and this DSL is the user's own Ruby -- but a top-level `return`
      # unwinds the evaluating frame, so every declaration above it is thrown
      # away. Left alone it surfaces arbitrarily later as a NoMethodError on nil
      # inside {Catalog}, naming lain's internals and never the user's file.
      class Unwound < Error; end

      # The value {.evaluate} hands back only when the file ran to its end.
      # Anything else means a top-level `return` unwound the evaluation, whatever
      # value it carried -- which is why this is a sentinel and not a type check
      # on the declarations.
      #
      # A bare Object, because the user's `return` can carry ANY value a user can
      # write. A Symbol sentinel is forgeable -- `return :completed` would have
      # been read as completion and silently truncated the catalog, which is the
      # exact bug this refusal exists to kill. An identity nothing outside this
      # file can name is not (`private_constant` hides the NAME from the eval'd
      # source, not the value from a lucky literal).
      COMPLETED = Object.new.freeze
      private_constant :COMPLETED

      # Evaluate `source` (read from `path`) and return the ordered summarizers.
      # `path` and line 1 give backtraces that point into the user's
      # `.lain/summarizers.rb`, not into this evaluator -- and, because each
      # block is defined there, they keep pointing there when a user's own
      # `compact` raises at run time.
      def self.build(source, path)
        builder = new
        refuse_unwound(evaluate(builder, source, path), path)
        builder.to_a
      end

      # The evaluation gets its OWN frame so a top-level `return` in the user's
      # file unwinds this method rather than {.build}, which is what makes the
      # early exit detectable at all: {.build} keeps running and sees a value
      # other than {COMPLETED}.
      def self.evaluate(builder, source, path)
        builder.instance_eval(source, path, 1)
        COMPLETED
      end
      private_class_method :evaluate

      def self.refuse_unwound(outcome, path)
        # `COMPLETED.equal?(outcome)`, not `outcome == COMPLETED`: the outcome is
        # a value the USER's `return` chose, so asking IT whether it is equal
        # hands a forger the answer -- an object with `def ==(other) = true`
        # would pass. Identity, asked from our side, cannot be redefined.
        return if COMPLETED.equal?(outcome)

        raise Unwound, "#{path} stopped early: a top-level `return` unwinds the whole file and " \
                       "discards every summarizer declared above it; guard declarations with " \
                       "`if`/`unless` instead"
      end
      private_class_method :refuse_unwound

      # `@declared`, not `@summarizers`: an unsandboxed instance_eval shares its
      # ivar namespace with the user's file, and `@summarizers` is a name a file
      # ABOUT summarizers is far more likely to reach for. This buys distance,
      # not safety -- nothing here confines user code, by design.
      def initialize
        @declared = []
      end

      def to_a = @declared.dup

      # One declaration. The block is `class_eval`'d into a FRESH anonymous
      # subclass of {Base}, so every load produces a distinct class object and a
      # second load of the same file can never reopen the first load's class.
      def summarizer(name, &block)
        declared_name = -name.to_s
        refuse_bodyless(declared_name, block)
        refuse_duplicate(declared_name)
        declare(build_class(declared_name, block).new(declared_name))
      end

      # An unknown top-level call in the DSL is a typo'd verb; name it and list
      # what IS known rather than surfacing a bare NoMethodError.
      def method_missing(name, *, **)
        raise Unknown, "unknown verb #{name.inspect} in .lain/summarizers.rb; " \
                       "known verbs: #{VERBS.join(", ")}"
      end

      def respond_to_missing?(name, include_private = false) = VERBS.include?(name) || super

      private

      def build_class(declared_name, block)
        Class.new(Base).tap do |declared|
          # A declared class is anonymous, so every message Ruby composes about
          # it -- an inspect, the FrozenError a user's `@memo ||=` earns -- would
          # otherwise print an object address instead of naming the declaration
          # at fault, which is the same reason {Base} names errors by `name`.
          declared.define_singleton_method(:to_s) { %(summarizer "#{declared_name}") }
          declared.define_singleton_method(:inspect) { to_s }
          # The instance prints by name too: Ruby composes Object#inspect from
          # the class's internal path, which a singleton `to_s` does not reach,
          # so the FrozenError above would still carry an address for its
          # subject. BEFORE class_eval, so a user's own `inspect` still wins --
          # this is cosmetic, unlike `name` below, which is identity.
          declared.define_method(:inspect) { %(#<summarizer "#{declared_name}">) }
          declared.class_eval(&block)
          # AFTER class_eval, deliberately: the declared name is the catalog's
          # identity for this summarizer, so a user's own `def name` shadowing it
          # would make both the NotImplementedError messages and the Duplicate
          # check quietly lie about which declaration they mean.
          declared.define_method(:name) { declared_name }
        end
      end

      # Freezing happens HERE and not only in {Base} because a user's own
      # `initialize` is defined on the declared subclass, which sits AHEAD of
      # Base's prepended {Freezable} in the MRO -- one that forgets `super` would
      # otherwise hand back a wholly unfrozen summarizer, and a summarizer that
      # remembers makes a bench arm non-reproducible.
      #
      # SHALLOW, and that is not the whole job: it stops new ivars (a `@memo ||=`
      # raises) but not mutation in place of an array a user's `initialize`
      # already assigned, which still accumulates across calls.
      # `Ractor.shareable?(summarizer)` is the bar that would say "no reachable
      # mutable state" outright, and it is false for exactly that instance --
      # the acceptance test for the deep-freeze follow-up, not something this
      # line delivers.
      def declare(declared)
        declared.freeze
        @declared << declared
        declared
      end

      def refuse_bodyless(declared_name, block)
        return if block

        raise ArgumentError, "summarizer #{declared_name.inspect} in .lain/summarizers.rb needs a " \
                             "block defining #suitable?(result) and #compact(result)"
      end

      def refuse_duplicate(declared_name)
        return unless @declared.any? { |summarizer| summarizer.name == declared_name }

        raise Duplicate, "duplicate summarizer #{declared_name.inspect} in .lain/summarizers.rb; " \
                         "the first suitable summarizer answers, so the second would never run"
      end
    end
  end
end
