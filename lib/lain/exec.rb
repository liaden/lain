# frozen_string_literal: true

module Lain
  # How a command becomes a process -- {Local} in process through
  # {Shell::Pipeline}, {Core} out of process through the lain-core daemon.
  # Naming the seam is what gives {FRAMEWORK_ENV} one home: lain runs
  # under `bundle exec`, so every child inherits BUNDLE_GEMFILE, BUNDLER_SETUP,
  # RUBYOPT and the rest, naming LAIN's OWN toolchain, and a model asking for
  # `bundle exec rspec` in some other project ran lain's bundle in lain's tree.
  # {Grader::TestHarness} knew that and scrubbed; the tool the model actually
  # uses did not.
  #
  # A backend answers `#call(command:, cwd:, env:, timeout:, stdout_sink:,
  # stderr_sink:)` with a {Capture} for every command that ran, and raises
  # {Timeout} for one that outlived its deadline -- {Tools::Bash}'s distinction
  # between "the tool could not produce a result" and "the command exited
  # non-zero". `command` is a String (the shell's problem: `sh -c`, tier 3) or a
  # TERM, an Array of argv Arrays ({Shell::Pipeline}, no shell at all). One entry
  # point, so the arm a command took cannot change the environment it runs under.
  # It answers one more message -- `#takes_term?(term)` -- and the first
  # carve-out below is what that is for.
  #
  # Two carve-outs a caller holding a term has to know about:
  #
  # * **Not every backend takes both shapes**, so every backend also answers
  #   `#takes_term?(term)` and a caller ASKS BEFORE IT OFFERS. {Core} takes no
  #   term at all -- the wire has one command shape; {Docker} takes a one-stage
  #   term and no piped one -- a container takes one argv; {Local} takes any.
  #
  #   THE PREDICATE TAKES THE TERM, not nothing. The three answers differ by
  #   SHAPE and not merely by backend, so an argument-less question could not
  #   express {Docker} at all. Each backend derives its {Unsupported} refusal
  #   from its own answer rather than restating the rule, which is what makes a
  #   disagreement between the two unrepresentable. A refusal is never a join
  #   back into a string: that would hand `sh -c` the very command the term
  #   path exists to keep away from it.
  #
  #   {Tools::Bash} asks, and falls back to the string the model itself wrote,
  #   which is why `--exec docker` no longer answers an ordinary pipeline
  #   (`grep -r foo . | wc -l`) with a tool error nobody wrote. A caller that
  #   does not ask still gets {Unsupported}, caught only by a blanket
  #   `rescue StandardError` in Effect::Handler::Live. That fallback trades the
  #   term arm's no-shell property for whatever confinement the backend has --
  #   {Docker} runs the string as `sh -c` INSIDE the container -- which
  #   {Tools::Bash} states at the allow bullet in its own class doc.
  # * **A backend can fail to enforce its own deadline**, a different fact from
  #   a command that hit one. {Unenforced} says which, and IS a {Timeout}, so the
  #   single `rescue Exec::Timeout` this contract advertises still holds.
  #
  # A BACKEND IS NOT A SANDBOX. Crossing a process, a socket or a container
  # boundary adds no confinement of its own -- the child runs on our uid, and
  # {WorkerEnv}'s posture carries over verbatim: the env map is an ADDITIVE
  # override with one removal lever, an explicit nil value. Real safety is the
  # tool's `#requires_approval?` plus Middleware::Gate.
  module Exec
    # The command outlived its deadline and was killed. One type wrapping
    # {Shell::Pipeline::Timeout} and the daemon's server-side kill, so a caller
    # writes one rescue rather than one per transport. The message carries
    # whatever the command said before it died, as far as the backend retained
    # it: neither source discards the pre-kill capture, and neither does this.
    class Timeout < Lain::Error; end

    # The backend never learned whether the command finished: its OWN deadline
    # passed with no answer from whatever it delegates to. A {Timeout}, so a
    # caller needing only "no result, and the clock is why" treats it as one; a
    # subclass, because a caller that cares can say which happened.
    class Unenforced < Timeout; end

    # The backend has no shape for what it was handed -- {Core} given a TERM,
    # {Docker} given a PIPED one. Not a caller's bug and not a model's input;
    # the carve-out above is the account.
    class Unsupported < Lain::Error; end

    # Inherited env whose presence binds a child to LAIN's OWN bundler / rspec
    # context. Scrubbed to nil so it is DELETED in the child (not merely
    # overridden), leaving the caller's own env and PATH/GEM_* intact.
    #
    # GEM_* is deliberately NOT here: the child still has to find its gems, and
    # widening this to `GEM_` changes which ones it can see.
    FRAMEWORK_ENV = /\A(?:BUNDLE_|BUNDLER_|RSPEC_|RUBYOPT\z)/

    # Every spawn mechanism here INHERITS this process's environment and applies
    # `env` per key onto it, so the scrub has to name every framework var
    # actually present to inherit -- hence the union of the live ENV with the
    # caller's own keys; a var the caller merely OMITS still reaches the command.
    #
    # The converse, and not obvious: the CALLER's keys are scrubbed too, so a
    # {WorkerEnv} carrying `"BUNDLE_GEMFILE" => "/other/project/Gemfile"` reaches
    # the child unset rather than redirected. A child cannot be pointed at
    # another project's bundle through this hash; per-subject dependency
    # isolation belongs to an out-of-process boundary, not to an env override.
    #
    # @param env [Hash] the caller's overrides ({WorkerEnv#env})
    # @return [Hash] those overrides plus an explicit nil for each framework var
    def self.child_env(env)
      polluted = (ENV.keys + env.keys).grep(FRAMEWORK_ENV).uniq
      env.merge(polluted.to_h { |key| [key, nil] })
    end
  end
end

require_relative "exec/capture"
require_relative "exec/local"
require_relative "exec/core"
require_relative "exec/docker"
