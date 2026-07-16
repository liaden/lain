# frozen_string_literal: true

module Lain
  module CLI
    # Turns the CLI flags into the two collaborators a run needs a CHOICE about --
    # which Provider backend, and the Context carrying the model and the sampler
    # params (temperature/seed) that ride Request#extra. A plain object, not a bag
    # of methods on the Thor executable: the provider/model resolution is then
    # unit-testable without a Thor instance, and BOTH the chat and bench-record
    # paths resolve `--provider` through this one seam, so they agree on what a
    # provider name means (CLAUDE.md's Metrics rule -- extract, don't loosen).
    #
    # Errors here are Lain's, not Thor's: an unknown provider raises
    # {UnknownProvider} (a {Lain::Error}), which the exe layer maps to a
    # Thor::Error. Thor never crosses into lib/ (output/error discipline).
    class Backend
      # The providers `--provider` selects between. The unknown-name guard names
      # this set, matching Capability::Policy.for's voice.
      PROVIDERS = %w[anthropic ollama bedrock].freeze

      def initialize(options)
        @options = options
      end

      # Anthropic reads its key from the environment; Ollama is local and takes an
      # optional `--api-base` override; Bedrock is also env-configured (the
      # Mantle client reads AWS_BEARER_TOKEN_BEDROCK / AWS_REGION itself, so no
      # flag threads through here). An unknown name fails loudly, naming the
      # valid set, as {UnknownProvider} (a bad flag is user error, surfaced by
      # the exe as a clean Thor::Error, not a bug with a backtrace).
      #
      # @param spool [#open_frame] the chronicle's response spool -- a real
      #   {Provider::ResponseWal} only when journaling is on ({CLI::Chronicle::Null}
      #   answers {Provider::Spool::Null}, never nil, so this is never an `if
      #   spool` guard). Threaded only into the ONE backend that can actually
      #   tee to it today: a real spool switches the "anthropic" branch from
      #   the official SDK client onto {Provider::AnthropicRaw}'s vendored
      #   transport, which is the transport the spool tee is wired into; the
      #   Null spool -- meaning no chronicle asked, e.g. bench (never passes
      #   spool: at all) or --no-journal chat -- keeps constructing the exact
      #   SDK client this method has always returned there, unchanged. Ollama
      #   and Bedrock never see the keyword at all: neither constructor
      #   accepts it, so nothing here risks handing it to them.
      def provider(spool: Provider::Spool::Null.new)
        case provider_name
        when "ollama" then Provider::Ollama.new(api_base: @options[:api_base])
        when "bedrock" then Provider::Bedrock.new
        else anthropic_provider(spool)
        end
      end

      # `--model` defaults to the SELECTED provider's own default (resolved here,
      # not in the Thor flag, whose default is fixed at load before `--provider`
      # is known). Sampler params ride Request#extra via the Context. The system
      # prompt renders from the loaded {#slots} unless a caller overrides it --
      # bench record's `--system` flag is the one caller that does.
      def context(system_override: nil)
        Context.new(model: @options[:model] || default_model,
                    max_tokens: @options[:max_tokens], extra: sampler_extra,
                    system: system_override || slots.render)
      end

      # The loaded prompt slots, memoized -- exposed (not just the rendered
      # String {#context} produces) so a caller can emit ONE Telemetry::SlotFills
      # built from the exact slots this Backend rendered, with no second disk
      # read.
      def slots
        @slots ||= Prompt::Slots.load
      end

      private

      # A real (non-Null) spool is the one signal that journaling is on --
      # {CLI::Chronicle}'s spool and {CLI::Chronicle::Null}'s are both real
      # objects, never nil, so presence alone cannot distinguish them. The
      # type check IS the decision this method exists to make (which backend
      # class to build), not a guard the Null Object idiom is meant to erase.
      #
      # This split is a DELIBERATE STOPGAP, not the resting design: the honest
      # end state is "anthropic" always means {Provider::AnthropicRaw} for chat
      # (bench already made that call for its own "anthropic" arm), and this
      # branch collapses to one line. Converging is a separate, larger decision
      # (default request envelope, error classes, live-429 behavior all move
      # for --no-journal chat too) -- tracked as a follow-up ticket, not done in
      # this round.
      def anthropic_provider(spool)
        return Provider::Anthropic.new if spool.is_a?(Provider::Spool::Null)

        Provider::AnthropicRaw.new(spool:)
      end

      # Validated once, so #provider and #default_model both key off a name
      # already known to be in PROVIDERS.
      def provider_name
        name = @options[:provider]
        return name if PROVIDERS.include?(name)

        raise UnknownProvider, "unknown provider #{name.inspect}, expected one of #{PROVIDERS.inspect}"
      end

      def default_model
        case provider_name
        when "ollama" then Provider::Ollama::DEFAULT_MODEL
        when "bedrock" then Provider::Bedrock::DEFAULT_MODEL
        else Provider::Anthropic::DEFAULT_MODEL
        end
      end

      # Only the sampler flags the caller actually set, String-keyed to match
      # Request's normalized `extra` and Ollama's `options`. `unless value.nil?`
      # (not `if value`) so `--temperature 0` -- the determinism recipe -- is kept.
      def sampler_extra
        %i[temperature seed].each_with_object({}) do |key, extra|
          value = @options[key]
          extra[key.to_s] = value unless value.nil?
        end
      end
    end
  end
end
