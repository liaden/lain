# frozen_string_literal: true

module Lain
  module CLI
    class Backend
      # The reasoning level a chat sends, checked against what the model says it
      # accepts. No level configured sends nothing and asks nothing, so the
      # model's own default still applies.
      #
      # Only a configured level makes the probe's answer required: a server that
      # could not list its levels refuses that level, but a launch configuring
      # none never depends on the probe.
      class Thinking
        # Refused at launch, naming the levels the model lists.
        class Invalid < Error; end

        # @param level [String, nil] the configured level
        # @param backend [#provider, #model] asked only when a level is configured, so
        #   a launch configuring none never resolves a provider for this
        def initialize(level:, backend:)
          @level = level
          @backend = backend
        end

        # @return [Hash{String => String}] the Request extra, empty when no level is configured
        # @raise [Invalid] when the model lists levels and this is not one
        def extra
          return {} if @level.nil?

          accepted = @backend.provider.thinking_levels(@backend.model)
          refuse(accepted) unless accepted&.include?(@level)
          { Provider::Ollama::Encoding::THINK_KEY => @level }
        end

        private

        def refuse(accepted)
          unless accepted
            raise Invalid,
                  "think #{@level.inspect} cannot be checked: no thinking metadata from #{@backend.model}"
          end

          raise Invalid,
                "think #{@level.inspect} is not accepted by #{@backend.model}; it accepts #{accepted.join(", ")}"
        end
      end
    end
  end
end
