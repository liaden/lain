# frozen_string_literal: true

require "active_support/number_helper"
require "faraday"

module Lain
  class Provider
    module HTTP
      # Asks before a request crosses its model's prompt-size price tier, since
      # a tier bills the WHOLE request at the dearer rate ({Price::Tier}).
      #
      # It sits in the configured-middleware seat: inside retry, so a retried
      # body meets its remembered answer instead of a second question, and
      # before `request :json`, so the body is still the caller's Hash. That
      # seat passes an entry's trailing Hash positionally, so this takes
      # Faraday's options Hash rather than keywords.
      #
      # Only a body whose canonical bytes over 4 reach 60% of a boundary is
      # counted, so an ordinary request never pays for a count_tokens call. The
      # margin is that wide because dense text runs nearer 3 bytes a token.
      class PriceTierGuard < Faraday::Middleware
        MODES = %i[ask allow refuse].freeze

        NEAR = Rational(3, 5)
        BYTES_PER_TOKEN = 4
        KIND = "price_tier"

        class Refused < Lain::Error; end

        # One chat's standing at the price tier, shared by every guard its
        # Backend builds: the chat's provider, its subagents' and judge's, the
        # summarizer's. Late-bound, because providers are built before the
        # approval queue and the chat's channel exist. Bound to no queue, as a
        # headless run is, it refuses.
        class Hold
          def initialize
            @approved = Set.new
            @notices = Channel::Null.instance
            @carry = true
          end

          # @param queue [#ask_decision, nil] nil when no human is attached
          # @param notices [#push] where a crossing sent under an earlier approval is shown
          # @param carry [Boolean] whether an approval covers later crossings on its model, as a
          #   chat's does; false asks the queue about every crossing, for a caller whose human
          #   approved a list of requests rather than a model
          # @return [void]
          def bind(queue, notices = Channel::Null.instance, carry: true)
            @queue = queue
            @notices = notices
            @carry = carry
          end

          # @param model [String]
          # @return [void]
          def approve(model) = (@approved << model if @carry)

          # @param model [String]
          # @return [Boolean] whether an earlier approval covers this model
          def carries?(model) = @carry && @approved.include?(model)

          # @return [Boolean] whether an approval will cover later crossings on its model
          def carrying? = @carry

          # @param record [Telemetry::PriceTierCrossed]
          # @return [void]
          def show(record) = @notices.push(record)

          # @param decision [Approval::Parked::Queue::Decision]
          # @return [Symbol] :approve, :deny, or :refuse when nobody can be asked
          def decide(decision)
            return :refuse if @queue.nil?

            @queue.ask_decision(decision) ? :approve : :deny
          end
        end

        # Counts through the provider a guard entry is built for, which does
        # not exist yet when its middleware list is assembled. An object rather
        # than a closure, so the guard holds the provider and not its builder.
        class LateCounter
          # @param provider [#count_wire]
          # @return [Object] the provider
          def bind(provider) = @provider = provider

          # @param body [Hash] a completion's wire body
          # @return [Integer]
          def call(body) = @provider.count_wire(body)
        end

        Crossing = Data.define(:model, :tokens, :standard, :tier, :digest, :decision, :carry) do
          def sends? = %i[approve carried allow].include?(decision)

          def carried? = decision == :carried

          def approved? = decision == :approve

          def boundary = tier.above_prompt_tokens

          def standard_cost = standard.input * tokens

          def tier_cost = tier.price.input * tokens

          def summary
            "#{crosses}, $#{Telemetry.fixed_point(standard_cost)} at the standard rate and " \
              "$#{Telemetry.fixed_point(tier_cost)} at the tier rate. #{reach}"
          end

          def refusal = "#{crosses}; not sent without approval (--confirm-price-tier allow sends it)"

          def record
            Telemetry::PriceTierCrossed.new(model:, prompt_tokens: tokens, boundary:, standard_cost:, tier_cost:,
                                            decision:)
          end

          def question
            Approval::Parked::Queue::Decision.new(requester: Requester.main, kind: PriceTierGuard::KIND, summary:,
                                                  digest:)
          end

          private

          def reach
            return "Approving sends this request alone; a later crossing is asked about again" unless carry

            "Approving sends this and every later request in this chat, its subagents included, on #{model} " \
              "at the tier rate"
          end

          def crosses
            "#{model}: #{delimited(tokens)} prompt tokens cross the #{delimited(boundary)}-token price tier"
          end

          def delimited(number) = ActiveSupport::NumberHelper.number_to_delimited(number)
        end

        # Shares the verdict duck with {Crossing}, so a body under every tier
        # needs no branch of its own.
        module Under
          def self.sends? = true

          def self.approved? = false
        end

        # A count that failed. Under `allow` the request goes out unchecked;
        # otherwise it is refused, since its tier is unknown.
        Uncounted = Data.define(:reason, :allowed) do
          def sends? = allowed

          def approved? = false

          def refusal = "could not count the prompt to check its price tier: #{reason}"
        end

        # @param app [#call] the rest of the stack
        # @param options [Hash] the guard's collaborators
        # @option options [PriceBook] :prices where a model's tiers are read
        # @option options [#call] :counter answers a counted body with its prompt tokens
        # @option options [Hold] :hold asked about a crossing under `:ask`, and keeps the approvals
        # @option options [#<<] :journal takes each {Telemetry::PriceTierCrossed}
        # @option options [Symbol, String] :mode one of {MODES}, `:ask` by default
        def initialize(app, options = {})
          super
          @prices = options.fetch(:prices)
          @counter = options.fetch(:counter)
          @hold = options.fetch(:hold)
          @journal = options.fetch(:journal)
          @mode = mode_of(options.fetch(:mode, :ask))
          @verdicts = {}
        end

        def call(env)
          admit(env.body) if messages_post?(env)
          @app.call(env)
        end

        private

        def mode_of(mode)
          return mode.to_sym if MODES.include?(mode.to_sym)

          raise ArgumentError, "unknown price tier mode #{mode.inspect}, expected one of #{MODES.join(", ")}"
        end

        def messages_post?(env) = env.method == :post && env.url.path.end_with?("/v1/messages") && env.body.is_a?(Hash)

        def admit(body)
          price = @prices.price(body[:model])
          return if price.tiers.empty?

          dumped = Canonical.dump(body)
          return if dumped.bytesize / BYTES_PER_TOKEN < price.tiers.first.above_prompt_tokens * NEAR

          digest = -"#{Canonical::DIGEST_ALGORITHM}:#{Ext.blake3_hex(dumped)}"
          verdict = @verdicts.fetch(digest) { remember(digest, judged(body, price, digest)) }
          raise Refused, verdict.refusal unless verdict.sends?
        end

        # A body that sends is kept, so a retry is neither asked about nor
        # shown again; a refused one is judged afresh. A human's approval
        # stands for its model across the whole chat, through the {Hold}.
        def remember(digest, verdict)
          @verdicts[digest] = verdict if verdict.sends?
          @hold.approve(verdict.model) if verdict.approved?
          verdict
        end

        # Only the failures {Provider::Anthropic#count_wire} wraps; anything
        # else is a defect, not an uncountable prompt.
        def judged(body, price, digest)
          tokens = Integer(@counter.call(body))
        rescue Lain::Error => e
          Uncounted.new(reason: e.message, allowed: @mode == :allow)
        else
          crossing(body, price, digest, tokens)
        end

        def crossing(body, price, digest, tokens)
          tier = price.tiers.reverse.find { |candidate| tokens > candidate.above_prompt_tokens }
          return Under if tier.nil?

          asked = Crossing.new(model: body[:model].to_s, tokens:, standard: price, tier:, digest:, decision: nil,
                               carry: @hold.carrying?)
          asked.with(decision: decide(asked)).tap { |crossing| told(crossing) }
        end

        def decide(crossing)
          case @mode
          when :allow, :refuse then @mode
          else @hold.carries?(crossing.model) ? :carried : @hold.decide(crossing.question)
          end
        end

        def told(crossing)
          record = crossing.record
          @journal << record
          @hold.show(record) if crossing.carried?
        end
      end
    end
  end
end
