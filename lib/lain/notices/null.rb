# frozen_string_literal: true

module Lain
  module Notices
    # The feed of a box with no `notify-feed`: no caller checks for it.
    class Null
      # @return [Boolean] false: nothing was sent
      def call(_source, _title, _body = "") = false
    end
  end
end
