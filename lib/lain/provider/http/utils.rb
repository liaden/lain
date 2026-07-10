# frozen_string_literal: true

require "time"
require "date"

# Vendored from ruby_llm 1.16.0 (2cf34b9), lib/ruby_llm/utils.rb, verbatim
# apart from RubyLLM:: -> Lain::Provider::HTTP:: and adding the `time`/`date`
# requires `#to_time`/`#to_date` need -- upstream got them for free from its
# main entrypoint, which this slice does not vendor.

module Lain
  class Provider
    module HTTP
      # Small data-shape helpers shared by the vendored message/payload code.
      module Utils
        module_function

        def hash_get(hash, key)
          hash[key.to_sym] || hash[key.to_s]
        end

        def to_safe_array(item)
          case item
          when Array
            item
          when Hash
            [item]
          else
            Array(item)
          end
        end

        def to_time(value)
          return unless value

          value.is_a?(Time) ? value : Time.parse(value.to_s)
        end

        def to_date(value)
          return unless value

          value.is_a?(Date) ? value : Date.parse(value.to_s)
        end

        def deep_merge(original, overrides)
          original.merge(overrides) do |_key, original_value, overrides_value|
            if original_value.is_a?(Hash) && overrides_value.is_a?(Hash)
              deep_merge(original_value, overrides_value)
            else
              overrides_value
            end
          end
        end

        def deep_dup(value)
          case value
          when Hash
            value.each_with_object({}) { |(key, val), duped| duped[deep_dup(key)] = deep_dup(val) }
          when Array
            value.map { |item| deep_dup(item) }
          else
            safe_dup(value)
          end
        end

        # Symbols, Integers, and friends raise TypeError on #dup; passing them
        # through as-is is correct, since they are already immutable.
        def safe_dup(value)
          value.dup
        rescue TypeError
          value
        end
      end
    end
  end
end
