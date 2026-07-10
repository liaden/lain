# frozen_string_literal: true

# Split from streaming.rb -- see that file's header. A real, separate module:
# Faraday's `on_data` callback arity differs between major versions
# (`|chunk, size|` on 1, `|chunk, bytes, env|` on 2), and picking the right
# proc shape is a distinct concern from the SSE parsing the engine does with
# the bytes once they arrive. Extracting it also keeps `Streaming` itself
# under the default `Metrics/ModuleLength` without loosening the cop. Vendored
# verbatim from upstream's nested `RubyLLM::Streaming::FaradayHandlers`.

module Lain
  class Provider
    module HTTP
      module Streaming
        # Builds Faraday `on_data` procs for Faraday 1 vs 2.
        module FaradayHandlers
          module_function

          def build(faraday_v1:, on_chunk:, on_failed_response:)
            if faraday_v1
              v1_on_data(on_chunk)
            else
              v2_on_data(on_chunk, on_failed_response)
            end
          end

          def v1_on_data(on_chunk)
            proc do |chunk, _size|
              on_chunk.call(chunk, nil)
            end
          end

          def v2_on_data(on_chunk, on_failed_response)
            proc do |chunk, _bytes, env|
              if env&.status == 200
                on_chunk.call(chunk, env)
              else
                on_failed_response.call(chunk, env)
              end
            end
          end
        end
      end
    end
  end
end
