# frozen_string_literal: true

require_relative "../../../sink"

# New code, not a port. RubyLLM's Connection hands Faraday's `:logger`
# middleware a real ::Logger (`RubyLLM.logger`) writing to $stdout by default
# (leak sites: connection.rb:17,89,90). Output discipline forbids that --
# `spec/output_discipline_spec.rb` parses every file under lib/ and fails on
# any $stdout/$stderr touch outside lib/lain/frontend/. Faraday's logger
# middleware only needs four methods (`#debug`/`#info`/`#warn`/`#error`/
# `#fatal`, block form) plus `#debug?` to decide whether to log bodies, so
# this is the whole surface: everything routes to an injected `Lain::Sink`,
# defaulting to `Sink::Null`.

module Lain
  class Provider
    module HTTP
      module Logging
        # Adapts a `Lain::Sink` to the Logger duck Faraday::Response::Logger's
        # formatter expects (`Formatter#def_delegators :@logger, :debug, :info,
        # :warn, :error, :fatal`).
        class SinkLogger
          LEVELS = %i[debug info warn error fatal].freeze

          # @param sink [Lain::Sink] destination for formatted log lines
          # @param level [Symbol] :debug enables request/response body logging
          def initialize(sink: Sink::Null.new, level: :info)
            @sink = sink
            @level = level
          end

          LEVELS.each do |level|
            define_method(level) { |msg = nil, &block| @sink.puts("#{level}: #{msg || block&.call}") }
          end

          def debug?
            @level == :debug
          end
        end
      end
    end
  end
end
