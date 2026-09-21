# frozen_string_literal: true

module Lain
  # The shell triage layer: what a command *is*, kept strictly apart from what a
  # command is *allowed to do*.
  #
  # {Shell::Parse} reports what tree-sitter's bash grammar found and makes NO
  # safety judgement. That is the answer to the objection `Lain::Tool::Input`
  # raises at its own top: a validator claiming to "only permit safe commands"
  # is a comforting lie, while a parser reporting "I did not fully understand
  # this" makes no claim at all.
  #
  # {Shell::Verdict} is the judgement half, separate because the two answer
  # different questions. Even it answers only "literal and fully understood",
  # never "safe", and it is free to abstain.
  #
  # {Shell::Pipeline} is what makes an allow sound rather than merely confident:
  # it runs the reconstructed argv and never the string the model wrote, so a
  # disagreement between this parser and a real shell degrades to a broken
  # command instead of an attacker-chosen one.
  #
  # {Shell::Out} is that machinery with no pipeline and no judgement: one argv,
  # spawned rather than forked.
  module Shell
  end
end
