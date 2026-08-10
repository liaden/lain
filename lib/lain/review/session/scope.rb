# frozen_string_literal: true

module Lain
  module Review
    class Session
      Scope = Data.define(:name, :strategy)

      # A grouping a round may be drawn at: the NAME a caller said, and the
      # strategy that name resolves to, as ONE value.
      #
      # == The pair is one value, and that is the whole reason this is an object
      #
      # It was two arguments, and that made a disagreeing pair CONSTRUCTIBLE:
      # a name from one scope beside a strategy from another refuses in a
      # sentence blaming the scope it never tested. That is this repo's "one
      # classifier, and disagreement is unrepresentable" rule at small scale, and
      # {.resolve} is the answer to it -- the only way to make one of these, and
      # it derives the strategy from the name.
      #
      # BOTH constructors are closed, which is a `Data` detail worth naming
      # because closing one reads as closing the value: `Data.define` mints `.[]`
      # beside `.new`, and `private_class_method :new` alone leaves `Scope[name:,
      # strategy:]` wide open. {Session} needs only `private_class_method :new`
      # because it is a plain class with no second door.
      #
      # == TWO refusals, and keeping them apart is deliberate
      #
      # {.resolve} says whether a NAME is a strategy at all; it has no
      # collaborators, so it cannot say whether THIS source can be grouped that
      # way. {#support!} asks that second question, where the changeset -- and so
      # the source -- is in hand. A typo and an inapplicable grouping are
      # different mistakes and deserve different sentences.
      #
      # It lives beside {Session} rather than in it because {Session} was at
      # `Metrics/ClassLength`, and this is a pair the aggregate's doc already
      # described as one topic: neither refusal reads a mark, a journal, a
      # surface or a verdict.
      class Scope
        # Resolve a name against the strategy registry.
        #
        # `#name` is a Symbol, and that is the contract every caller outside this
        # object depends on: {Bounds#check_presentation!} and every {Surface}
        # dispatch on it, and both CLI paths resolve once and hand the answer on.
        #
        # @param scope [Symbol, String] one of {Session::SCOPES}
        # @return [Scope]
        # @raise [UnknownScope] naming what was given, beside everything it could
        #   have been -- a typo is the case this exists for, and the correction
        #   is usually in that list
        def self.resolve(scope)
          candidate = scope.respond_to?(:to_sym) ? scope.to_sym : scope
          strategy = Partition::STRATEGIES.fetch(candidate) do
            raise UnknownScope, "scope must be one of #{SCOPES.inspect}, got #{scope.inspect}"
          end

          new(name: candidate, strategy:)
        end
        private_class_method :new, :[]

        # That THIS source can be grouped the way it has been asked to be.
        #
        # Asked of the CHANGESET, which is the only object holding the source --
        # a session is opened with the source's NAME, because that is what the
        # journal carries, so the caller supplies it for the sentence.
        #
        # The REMEDY half is what makes this actionable, and it is measured
        # rather than guessed: the scopes listed are the ones this source is
        # actually asked about, so the message cannot advertise a second grouping
        # it would also refuse. {UnknownScope} lists the whole registry for the
        # same reason -- a refusal naming only what failed leaves the reader to
        # guess what would not have.
        #
        # @param changeset [#supports?] the whole, unfiltered changeset
        # @param source [String] what produced the changeset
        # @return [nil]
        # @raise [UnsupportedScope]
        def support!(changeset, source:)
          return if changeset.supports?(strategy)

          offered = SCOPES.select { |scope| changeset.supports?(Partition::STRATEGIES.fetch(scope)) }
          raise UnsupportedScope, "scope #{name.inspect} is not available for the #{source} source -- it does " \
                                  "not answer what that grouping reads. #{offered.inspect} do present this one"
        end
      end
    end
  end
end
