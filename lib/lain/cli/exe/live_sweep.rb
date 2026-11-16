# frozen_string_literal: true

module Lain
  module CLI
    module Exe
      # `bench compaction-sweep --live`'s options. The terminal is the exe's to read, so the prompt
      # is built here, over the command's own `say` and `yes?`.
      module LiveSweep
        # @param thor [Bench] the running command
        # @param input [IO] the terminal the confirmation reads
        # @return [Hash] empty without --live, so an offline sweep hands over exactly what it always did
        def self.options(thor, input:)
          options = thor.options
          return {} unless options[:live]

          confirm = prompt(thor, input:)
          backend = thor.model_backend(nil, options.merge("provider" => "anthropic", "model" => options[:live]))
          { live: options[:live], confirm:, live_backend: backend }
        end

        # @param thor [Bench] the running command
        # @param input [IO] the terminal the confirmation reads
        # @return [Lain::Bench::CompactionSweep::Live::Prompt] the confirmation both priced sweeps ask
        def self.prompt(thor, input:)
          Lain::Bench::CompactionSweep::Live::Prompt.new(yes: thor.options[:yes], terminal: input.tty?,
                                                         say: thor.method(:say), ask: thor.method(:yes?))
        end
      end
    end
  end
end
