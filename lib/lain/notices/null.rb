# frozen_string_literal: true

module Lain
  module Notices
    # The feed of a box with no `notify-feed`: no caller checks for it.
    class Null
      # @return [nil]
      def call(_source, _title, _body = "") = nil
    end
  end
end
