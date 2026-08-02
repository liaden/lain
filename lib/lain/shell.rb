# frozen_string_literal: true

module Lain
  # The shell triage layer: what a command *is*, kept strictly apart from what a
  # command is *allowed to do*.
  #
  # {Shell::Parse} is the mechanism half. It reports what tree-sitter's bash
  # grammar found -- stages, reconstructed argv, node kinds, operators, and which
  # bytes nothing accounted for -- and it makes NO safety judgement whatsoever.
  # That separation is the answer to the objection `Lain::Tool::Input` raises at
  # its own top: a validator claiming to "only permit safe commands" is a
  # comforting lie, but a parser reporting "I did not fully understand this" is
  # making no claim at all.
  #
  # {Shell::Verdict} is the judgement half, and it is a separate object because
  # the two answer different questions. Even it answers only "literal and fully
  # understood", never "safe", and it is free to abstain -- which is what lets
  # the pair be honest where a regex could not be.
  module Shell
  end
end

require_relative "shell/parse"
require_relative "shell/verdict"
