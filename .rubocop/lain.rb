# frozen_string_literal: true

require "rubocop"

# The cops live outside lib/ because the gem's loader would map lib/rubocop/ to a
# Rubocop constant and eager-load it into every lain boot.
Dir[File.join(__dir__, "cops/lain/*.rb")].each { |cop| require cop }
