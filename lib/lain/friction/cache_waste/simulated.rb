# frozen_string_literal: true

module Lain
  module Friction
    class CacheWaste
      # Cache waste for requests that were re-rendered rather than sent, so no provider ever
      # billed them. Each consecutive pair is compared as one byte string in cache order (tools,
      # system, then messages); a later request that differs before the end of the earlier one
      # re-buys everything after the first differing byte as a cache write.
      #
      # The tokens are an estimate through {ProxyBytes}, and no {Usage} is built for them: a
      # made-up usage would read as recorded to every other consumer of one. The cause comes from
      # {BreakCause}, the classifier {CacheWaste} names its own breaks with.
      class Simulated
        include Enumerable

        # One simulated re-billing. `offset_bytes` is where the later prefix first differs, counted in
        # bytes of the cache-order prefix: there is no recorded chain here to give a message position.
        Rebill = Data.define(:model, :offset_bytes, :rebilled_tokens, :cost, :cause)

        # What {Price#rate_for} reads to choose a prompt-size tier, and nothing more.
        Prompt = Data.define(:total_input_tokens)
        private_constant :Prompt

        # @param requests [Enumerable<Request>] one model's requests, in send order
        # @param price_as [String] the model whose cache-write rate prices every rebill
        # @param price_book [PriceBook]
        def initialize(requests, price_as:, price_book: PriceBook.default)
          @price_as = -price_as.to_s
          @price_book = price_book
          @rebills = requests.map { |request| Rendered.new(request) }.each_cons(2)
                             .filter_map { |before, after| rebill_between(before, after) }.freeze
          freeze
        end

        # @yieldparam rebill [Rebill]
        # @return [Enumerator<Rebill>, self]
        def each(&block)
          return @rebills.each unless block

          @rebills.each(&block)
          self
        end

        # @return [Integer] estimated tokens re-bought because a prefix broke
        def rebilled_tokens = @rebills.sum(&:rebilled_tokens)

        # @return [Dollars] incomplete when the model has no price
        def rebilled_cost = @rebills.sum(Dollars.zero) { |rebill| rebill.cost || Dollars.unknown }

        # @return [Hash{Symbol => Integer}] rebills per cause, in {BreakCause::CAUSES} order
        def causes
          tally = @rebills.map(&:cause).tally
          BreakCause::CAUSES.filter_map { |cause| [cause, tally[cause]] if tally.key?(cause) }.to_h
        end

        private

        # A later request that is a strict prefix of the earlier one re-buys nothing, so it is no rebill.
        def rebill_between(before, after)
          offset = before.diverges_from(after)
          return if offset.nil?

          tokens = ProxyBytes.new(count: after.bytesize - offset).to_tokens
          return if tokens.zero?

          Rebill.new(model: @price_as, offset_bytes: offset, rebilled_tokens: tokens, cost: cost(tokens, after),
                     cause: BreakCause.between(before.shape, after.shape, cold: false))
        end

        # nil is the refusal {Dollars.unknown} stands for, as in {CacheWaste}.
        def cost(tokens, after)
          prompt = Prompt.new(total_input_tokens: ProxyBytes.new(count: after.bytesize).to_tokens)
          Dollars.of(@price_book.price(@price_as).rate_for(prompt).cache_creation * tokens)
        rescue PriceBook::UnknownModel
          nil
        end

        # One request as the cache sees it: its prefix bytes with the moving markers stripped,
        # and the shape {BreakCause} reads off a `request_sent` payload.
        class Rendered
          CHUNK = 4096

          attr_reader :shape

          def initialize(request)
            messages = Request.strip_cache_markers(request.messages)
            @bytes = [request.tools, request.system, *messages].map { |part| Canonical.dump(part) }.join
            @shape = BreakCause.shape_of("payload" => Canonical.normalize(request.cache_payload))
          end

          def bytesize = @bytes.bytesize

          # @return [Integer, nil] where `later` first differs, or nil when it only extends this one
          def diverges_from(later)
            offset = common_prefix(later.bytes)
            offset < @bytes.bytesize ? offset : nil
          end

          protected

          attr_reader :bytes

          private

          # Compared a chunk at a time, so a megabyte prefix is a few hundred slices and not a search
          # that copies the whole prefix at every probe.
          def common_prefix(other)
            limit = [@bytes.bytesize, other.bytesize].min
            chunk = (0...limit).step(CHUNK).find { |at| @bytes.byteslice(at, CHUNK) != other.byteslice(at, CHUNK) }
            return limit if chunk.nil?

            (chunk...[chunk + CHUNK, limit].min).find { |at| @bytes.getbyte(at) != other.getbyte(at) } || limit
          end
        end
        private_constant :Rendered
      end
    end
  end
end
