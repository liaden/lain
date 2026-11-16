# frozen_string_literal: true

module Lain
  module Review
    class Queue
      # What the local readers share: where a work tree's top is, and how a
      # row is built from a request map, so 1 refused row is named and skipped
      # and the rest still list.
      class Listing
        # The local readers build no pull request, so no clone is ever looked up.
        NO_CHECKOUTS = Checkouts.new(roots: [])
        private_constant :NO_CHECKOUTS

        # @param notes [#puts] where a skipped row is named
        # @param shell_out_factory [#call] builds the subprocess runner
        def initialize(notes:, shell_out_factory:)
          @notes = notes
          @shell_out_factory = shell_out_factory
        end

        # Git answers in bytes; read as UTF-8, the top joins row ids and reasons.
        # @param dir [String] any directory inside a work tree
        # @return [String] the top of that work tree as git spells it
        def top_of(dir)
          top = Isolation::Checkout.of(dir, shell_out_factory: @shell_out_factory).out("rev-parse", "--show-toplevel")
          top.chomp.force_encoding(Encoding::UTF_8)
        end

        # @param id [String]
        # @param request [Hash{String => String}] checked by {Request.load}
        # @param fields [Hash] the row's other members: rank, reason, head_sha
        # @return [Row, nil] nil, with 1 note, when the request is refused
        def row(id, request, **fields)
          Row.new(id:, request: Request.load(request, checkouts: NO_CHECKOUTS, shell_out_factory: @shell_out_factory),
                  **fields)
        rescue Request::Refused => e
          skip(id, e.message)
        end

        # @param id [String]
        # @param why [String]
        # @return [nil]
        def skip(id, why)
          @notes.puts("skipped #{id}: #{why}")
          nil
        end
      end
    end
  end
end
