# frozen_string_literal: true

module Lain
  # The structured plan value -- {Plan::Step} and {Plan::Document} -- and what
  # reads one: {Plan::Runner} executes it, {Plan::Closure} decides when a step
  # is done, {Plan::SeamPolicy} and {Plan::SeamDecision} decide where one is
  # cut.
  module Plan; end
end
