# frozen_string_literal: true

module Lain
  module CLI
    # What carries an epic's issues from the chat: each issue launched as an
    # actor in a checkout of its own, once its failing tests exist.
    module EpicDriver
    end
  end
end

require_relative "epic_driver/plan_subject"
require_relative "epic_driver/issue_tests"
require_relative "epic_driver/issue_actor"
