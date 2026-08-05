# frozen_string_literal: true

# The suite is hermetic against the DEVELOPER'S OWN environment, and this is the
# file that makes it so for the endpoint variables.
#
# `Lain::CLI::EnvDefaults` exists so a project can pin its provider and model in a
# direnv `.envrc` -- which means anyone actually using that feature has
# `LAIN_PROVIDER`/`LAIN_MODEL`/`LAIN_MAX_TOKENS` exported in every shell in the
# repository, INCLUDING the one running `rake pspec`. Then
# `spec/lain/cli_spec.rb`'s "--provider defaults to anthropic" fails, because it
# reads Thor's declared default and the ambient env is what Thor declared. The
# spec is right and the suite was wrong: a green suite must not depend on the
# machine's exports. Observed on a macOS checkout whose `.envrc` pinned bedrock.
#
# This is {Lain::Notify}'s `LAIN_DESKTOP` lesson generalized -- "agent shells
# inherit the human's environment, so an env var in a profile is inherited by
# every spec run" -- with the same conclusion: the entry point is what differs.
# There, a CLI flag is the consent; here, `with_env` is. An example that wants one
# of these set says so IN AS MANY WORDS (`spec/lain/cli/env_defaults_spec.rb` is
# entirely `with_env` blocks), and gets it against a known-clean baseline rather
# than against whatever the developer happened to export.
#
# == Why deletion, and why HERE
#
# Deleted for the whole process, not saved and restored per example: there is no
# example that wants the ambient value, so restoring it would only hand the leak
# back to the next file. `with_env` still saves and restores correctly around
# this -- it distinguishes "was unset" from "was empty", and unset is now the
# truth.
#
# Load order is the reason this is a support file and not an `around` hook.
# `spec/lain/cli_spec.rb` does `load exe/lain` at SPEC-FILE LOAD TIME, and Thor
# evaluates every `default:` in the class body right then -- before any hook for
# any example has run. spec_helper's support glob is what still precedes that.
module EndpointEnv
  # Every variable `EnvDefaults` is consulted for in `exe/lain`, plus
  # `LAIN_DESKTOP`, which forces {Lain::Notify.for}'s consent in EITHER direction
  # and so could both fire notifications the suite must not fire and mask the
  # examples that pin the gate.
  #
  # Credentials are deliberately NOT in this list. `ANTHROPIC_API_KEY` and
  # `AWS_BEARER_TOKEN_BEDROCK` are what `:api_integration` runs ON, and
  # `spec/support/tags.rb` reads the key to decide whether those specs are enabled
  # at all -- scrubbing them here would silently disable the opt-in tier rather
  # than isolate anything. Every offline spec that wants one already injects it by
  # name through `with_env`.
  LEAKS = %w[
    LAIN_PROVIDER LAIN_MODEL LAIN_API_BASE LAIN_MAX_TOKENS LAIN_TEMPERATURE LAIN_SEED
    LAIN_SUMMARIZER_PROVIDER LAIN_SUMMARIZER_MODEL LAIN_SUMMARIZER_MAX_TOKENS
    LAIN_DESKTOP
  ].freeze

  LEAKS.each { |name| ENV.delete(name) }
end
