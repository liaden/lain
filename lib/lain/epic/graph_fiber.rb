# frozen_string_literal: true

module Lain
  module Epic
    # One revision of an epic's issue graph, as everything a later reader needs to
    # perform it again.
    #
    # Ids and digests alone cannot re-run `split(id, into:)` -- the parts an
    # author wrote are not derivable from the graph they left. So the arguments
    # are the REPLAY PAYLOAD and the digest pair is its ORACLE: {#replay} performs
    # the edit again from what the fiber carries, and {#reproduces?} says whether
    # it landed where the fiber claims. That is what makes a journal of these an
    # audit rather than a note, and why `discovered_from`'s one hop stops limiting
    # provenance -- the journal holds every fiber, so lineage is read from the
    # chain rather than from a field a later merge may orphan.
    #
    # Arguments go through {Canonical.normalize}, which is what will hash them: a
    # fiber that constructs is a fiber that journals and re-reads
    # byte-identically. Everything it holds is deeply frozen, so a fiber crosses a
    # Ractor boundary like every other value in this tier.
    #
    # It names no epic, deliberately: a {Graph} carries no slug, so naming the
    # epic is {Scribe}'s to do on the way to the journal ({GraphRevision}).
    GraphFiber = Data.define(:operation, :arguments, :preimage, :results, :before, :after) do
      def initialize(operation:, arguments:, preimage:, results:, before:, after:)
        operation = replayable(operation)
        super(operation:, arguments: payload(operation, arguments), preimage: ids(preimage, "preimage"),
              results: ids(results, "results"), before: address(before, "before"), after: address(after, "after"))
      end

      # The departing and arriving issues' ids ARE the preimage and the results,
      # so an operation names only what a fiber cannot derive for itself.
      def self.cut(operation:, arguments:, removed:, arriving:, from:, to:)
        new(operation:, arguments:, preimage: removed.map(&:id), results: arriving.map(&:id),
            before: from.digest, after: to.digest)
      end

      # A fiber read back out of a journaled record, by the String keys the
      # journal wrote. Keys it does not name (`ts`, `type`, `epic_slug`) are
      # IGNORED rather than refused, because a Journal's fd is shared with other
      # writers and a record type keeps growing; a MISSING one is refused, because
      # a fiber that cannot replay must not construct.
      def self.of(record)
        new(**members.to_h { |name| [name, journaled(record, name)] })
      end

      def self.journaled(record, name)
        record.fetch(name.to_s) do
          raise MalformedGraph, "a graph revision record must carry #{name}, and this one carries " \
                                "#{record.keys.map(&:to_s).sort.inspect}"
        end
      end
      private_class_method :journaled

      # Performed purely from what the fiber carries, which is the only reading
      # under which a replay proves the payload complete.
      #
      # A fiber denotes ONE arrow, `before -> after`, so replaying it over any
      # other graph is a question it cannot answer, and answering anyway is the
      # silent wrong graph this record exists to rule out: a merge unions its two
      # sides' edge sets, so a DIFFERENT graph can replay to a digest equal to
      # {#after}, and a spec carries that witness. The check is free, because
      # every legitimate replay already holds a graph at `before`.
      def replay(graph)
        unless graph.digest == before
          raise MalformedGraph, "a #{operation} revision replays only over the graph it was cut from " \
                                "(before #{before}), and #{graph.digest} is not it"
        end

        send(:"replay_#{operation}", graph)
      end

      # Whether +graph+ is the graph this fiber was cut from AND the replay lands
      # where the fiber claims, having moved exactly the ids it recorded. That
      # third question is what keeps `preimage` and `results` from being
      # unverified redundancy: the replay reads neither, so a record lying about
      # what left or arrived would otherwise pass on the digests alone.
      #
      # An id that both LEAVES and ARRIVES -- a split into a part bearing the
      # departing id, a merge into one of its own sides -- moves nothing in the
      # graph, so the claim is read over the ids that only left and only arrived.
      #
      # False rather than raising when the replay refuses: this is the audit's
      # predicate, and tampered bytes are what it exists to answer NO about.
      def reproduces?(graph)
        return false unless graph.digest == before

        replayed = replay(graph)
        replayed.digest == after && moved_as_recorded?(graph, replayed)
      rescue Error
        false
      end

      private

      # See {#reproduces?} for why the two lists are read through each other
      # rather than whole.
      def moved_as_recorded?(before_graph, replayed)
        (before_graph.ids - replayed.ids) == (preimage - results) &&
          (replayed.ids - before_graph.ids) == (results - preimage)
      end

      def replay_add(graph) = graph.add(arriving("issue"), discovered_from: argument("discovered_from"))

      def replay_split(graph) = graph.split(argument("id"), into: argument("into").map { |part| issue_of(part) })

      def replay_merge(graph) = graph.merge(argument("left"), argument("right"), as: arriving("as"))

      def arriving(key) = issue_of(argument(key))

      # {Issue#canonical}'s wire form has the constructor's own keywords for keys,
      # so a rebuild is the constructor with its whole validation, rather than a
      # second reader of the same bytes.
      def issue_of(canonical)
        unless canonical.is_a?(Hash)
          raise MalformedGraph, "a #{operation} fiber's issue must be a canonical Issue (got #{canonical.inspect})"
        end

        Issue.new(**canonical.transform_keys(&:to_sym))
      end

      def argument(key)
        arguments.fetch(key) do
          raise MalformedGraph, "a #{operation} fiber must carry the #{key.inspect} argument, and this one " \
                                "carries #{arguments.keys.sort.inspect}"
        end
      end

      def replayable(operation)
        name = -operation.to_s
        return name if REVISION_OPS.key?(name)

        raise MalformedGraph, "a graph revision names #{name.inspect}, which nothing can replay " \
                              "(expected #{REVISION_OPS.keys.join("/")})"
      end

      # Through Canonical for the reason {Issue} sends every String through it:
      # this payload will be hashed and journaled, so bytes it cannot encode are
      # refused here rather than later, out of a JSON writer nobody is watching.
      def payload(operation, arguments)
        unless arguments.is_a?(Hash)
          raise MalformedGraph, "a graph revision's arguments must be a Hash (got #{arguments.inspect})"
        end

        vocabulary(operation, Canonical.normalize(arguments))
      rescue Canonical::UnsupportedType => e
        raise MalformedGraph, "a graph revision's arguments cannot be content-addressed: #{e.message}"
      end

      # A fiber carrying another operation's vocabulary would construct, journal,
      # and only then fail at replay fetching a key it never held: a malformed
      # fiber that is representable is one somebody will read back.
      def vocabulary(operation, arguments)
        expected = REVISION_OPS.fetch(operation)
        return arguments if arguments.keys == expected

        raise MalformedGraph, "a #{operation} fiber's arguments are #{expected.inspect}, and this one " \
                              "carries #{arguments.keys.inspect}"
      end

      # Ids are asserted to BE ids rather than coerced, for the reason
      # {Issue#clean_edges} gives: `to_s` over `[["nested"]]` mints an "id" no
      # issue can match, and a blank one names nothing. Deduplicated and sorted,
      # because an id list is a SET here and {#reproduces?} reads it against a set
      # difference the graph answers in id order. `&:-@` is String#-@, the
      # interning unary minus, spelled the way Style/SymbolProc insists on.
      def ids(values, field) = checked_ids(values, field).uniq.sort.map(&:-@).freeze

      def checked_ids(values, field)
        unless values.is_a?(Array)
          raise MalformedGraph, "a graph revision's #{field} must be an Array of issue ids (got #{values.inspect})"
        end

        stranger = values.find { |id| !id.is_a?(String) || id.strip.empty? }
        return values if stranger.nil?

        raise MalformedGraph, "a graph revision's #{field} must all be issue ids (got #{stranger.inspect})"
      end

      def address(digest, field)
        raise MalformedGraph, "a graph revision must name the #{field} graph digest, got nil" if digest.nil?

        -digest.to_s
      end
    end
  end
end
