# frozen_string_literal: true

module Lain
  class Response
    # A failed stop, raised where a caller asked for an answer. Without it a
    # caller reading `.text` gets a prose tool call or a cut-off sentence back as
    # though the model had answered.
    #
    # Not frozen, unlike the {Failure} it carries: `raise` writes the backtrace
    # onto the exception, and a frozen one is raised with none.
    class Failed < Error
      # @return [Response::Failure] why the reply is not an answer
      attr_reader :failure

      # @param response [Response] the reply a caller wants as an answer
      # @return [Response] the same response, when it is one
      # @raise [Failed] when its stop is a failure
      def self.refusing(response)
        failure = response.failure
        raise new(failure) if failure

        response
      end

      # @param failure [Response::Failure] the reading the message is taken from
      def initialize(failure)
        @failure = failure
        super(failure.message)
      end
    end
  end
end
