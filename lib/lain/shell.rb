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
  # making no claim at all. The verdict that reads these facts is a separate
  # object, and even it answers only "literal and understood", never "safe".
  module Shell
  end
end

require_relative "shell/parse"
