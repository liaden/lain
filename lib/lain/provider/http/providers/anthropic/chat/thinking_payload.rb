# frozen_string_literal: true

# Split from chat.rb -- see that file's header. Extended-thinking payload
# construction: Anthropic wants either a token `budget` (`thinking: {type:
# "enabled", budget_tokens:}`) or an `effort` level (`thinking: {type:
# "adaptive"}, output_config: {effort:}`), and which one a model accepts is
# itself a model capability this slice does not have a registry for, so it
# asks the duck-typed `model` object directly via `#reasoning_option`.

module Lain
  class Provider
    module HTTP
      module Providers
        class Anthropic
          # Reopened from chat.rb to add extended-thinking payload
          # construction; see that file's header.
          module Chat
            module_function

            def add_thinking_fields(payload, thinking, model)
              thinking_payload = build_thinking_payload(thinking, model)
              return unless thinking_payload

              payload[:thinking] = thinking_payload[:thinking] if thinking_payload[:thinking]
              return unless thinking_payload[:output_config]

              payload[:output_config] = payload.fetch(:output_config, {}).merge(thinking_payload[:output_config])
            end

            def build_thinking_payload(thinking, model)
              return nil unless thinking&.enabled?

              effort = resolve_effort(thinking)
              return nil if effort == "none"

              budget = resolve_budget(thinking)
              return budget_thinking_payload(budget, model) if budget

              raise ArgumentError, "Anthropic adaptive thinking requires an effort" if effort.nil?

              effort_thinking_payload(effort, model)
            end

            def budget_thinking_payload(budget, model)
              return enabled_thinking_payload(budget) if model.reasoning_option("budget_tokens")

              raise ArgumentError, "Anthropic thinking budget is not supported for #{model.id}"
            end

            def effort_thinking_payload(effort, model)
              return adaptive_thinking_payload(effort) if model.reasoning_option("effort")

              raise ArgumentError, "Anthropic thinking effort is not supported for #{model.id}"
            end

            def enabled_thinking_payload(budget)
              { thinking: { type: "enabled", budget_tokens: budget } }
            end

            def adaptive_thinking_payload(effort)
              { thinking: { type: "adaptive" }, output_config: { effort: effort } }
            end

            def resolve_effort(thinking)
              effort = thinking.respond_to?(:effort) ? thinking.effort : nil
              effort = effort.to_s if effort
              effort.nil? || effort.empty? ? nil : effort
            end

            def resolve_budget(thinking)
              budget = thinking.respond_to?(:budget) ? thinking.budget : thinking
              budget.is_a?(Integer) ? budget : nil
            end
          end
        end
      end
    end
  end
end
