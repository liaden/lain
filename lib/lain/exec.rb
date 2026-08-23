# frozen_string_literal: true

module Lain
  # How a command becomes a process. The codebase already answered that question
  # twice without naming it -- {Tools::Bash} in process through
  # `Mixlib::ShellOut`, {Tools::CoreExec} out of process through the lain-core
  # daemon -- and a fact both answers need was written down in only one of them.
  #
  # That fact is {FRAMEWORK_ENV}: lain runs under `bundle exec`, so every child
  # it spawns inherits BUNDLE_GEMFILE, BUNDLER_SETUP, RUBYOPT and the rest,
  # naming LAIN's OWN toolchain. A model asking for `bundle exec rspec` in some
  # other project therefore ran lain's bundle in lain's tree.
  # {Grader::TestHarness} knew this and scrubbed; the tool the model actually
  # uses did not. Naming the seam is what gives that scrub one home, so a third
  # backend cannot be added without it.
  #
  # == The contract a backend answers
  #
  # `#call(command:, cwd:, env:, timeout:, stdout_sink:, stderr_sink:)` returns
  # a {Capture} for every command that ran, and raises {Timeout} for one that
  # outlived its deadline -- the distinction {Tools::Bash} already draws between
  # "the tool could not produce a result" and "the command exited non-zero".
  # `command` is a String (the shell's problem: `sh -c`, tier 3) or a TERM, an
  # Array of argv Arrays ({Shell::Pipeline}, no shell at all). One entry point,
  # so the arm a command took cannot change the environment it runs under.
  #
  # Two carve-outs, named here rather than left implicit, because a tool that
  # rescues this contract has to know everything that can come out of it:
  #
  # * **Not every backend takes both shapes.** {Core} has no wire shape for a
  #   TERM at all, and {Docker} none for a PIPED one -- a container takes one
  #   argv. Both refuse with {Unsupported}: loudly, and never by joining the term
  #   back into a string, which would hand `sh -c` the very command the term path
  #   exists to keep away from it.
  #
  #   ⚠️ THIS IS NOT A CALLER'S BUG, and an earlier edition of this paragraph
  #   said it was -- that no tool rescues it, because "a caller holding either
  #   shape must not offer a term to a string-only backend". {Tools::Bash} holds
  #   both shapes and offers whichever {Shell::Verdict} returns, and the verdict
  #   ALLOWS an ordinary pipeline (`grep -r foo . | wc -l`, pinned in
  #   `spec/lain/exec/docker_spec.rb`). So under `--exec docker` a perfectly
  #   ordinary command reaches a backend with no shape for it, through nobody's
  #   mistake. It degrades correctly rather than accidentally: a
  #   `rescue StandardError` in Effect::Handler::Live turns it into a
  #   `tool_result` with `is_error` naming the stages, which is the honest answer
  #   to "this backend cannot run that" -- but a blanket rescue is what is doing
  #   it, not a design.
  #
  #   What is missing is a MESSAGE: a backend cannot say which shapes it takes,
  #   so {Tools::Bash} cannot ask before it chooses an arm. A `#takes_term?`
  #   predicate on the three backends, consulted where the arm is chosen, is the
  #   fix; it touches {Local}, {Core} and {Tools::Bash}, so it belongs to a card
  #   that owns them. Until then this paragraph is the warning.
  # * **A backend can fail to enforce its own deadline**, which is a different
  #   fact from a command that hit one. {Unenforced} says which -- and it IS a
  #   {Timeout}, so a caller carrying the single `rescue Exec::Timeout` this
  #   contract advertises cannot be raised past. Only a caller that wants to tell
  #   the two apart in words rescues it separately.
  #
  # A BACKEND IS NOT A SANDBOX. Crossing a process, a socket or a container
  # boundary adds no confinement of its own -- the child runs on our uid, and
  # {WorkerEnv}'s posture carries over verbatim: the env map is an ADDITIVE
  # override with one removal lever, an explicit nil value. Real safety is the
  # tool's `#requires_approval?` plus Effect::Handler::Gate.
  module Exec
    # What ran, in the shape {Tools::Bash.render_output} reads. Both backends
    # return this rather than their transport's own object (mixlib's ShellOut,
    # the daemon's reply Hash), which is what keeps the rendering -- and so the
    # output ceiling -- one decision instead of one per transport.
    Capture = Data.define(:exit_status, :stdout, :stderr)

    # The command outlived its deadline and was killed. One type across the
    # backends, wrapping `Mixlib::ShellOut::CommandTimeout` and
    # {Shell::Pipeline::Timeout}, so a caller writes one rescue rather than one
    # per transport. The message carries whatever the command said before it
    # died: neither source discards the pre-kill capture, and neither does this.
    class Timeout < Lain::Error; end

    # The backend never learned whether the command finished: its OWN deadline
    # passed with no answer from whatever it delegates to. A {Timeout}, because a
    # caller that only needs "no result, and the clock is why" is right to treat
    # it as one; a subclass, because {Tools::CoreExec} says which happened.
    class Unenforced < Timeout; end

    # The backend has no shape for what it was handed -- {Core} given a TERM,
    # {Docker} given a PIPED one. NOT a caller's bug, and not a model's input:
    # {Tools::Bash} offers whichever shape {Shell::Verdict} returns, and the
    # verdict allows an ordinary pipeline. The carve-out above is the account of
    # what rescues this and what message is missing; this is not a second one.
    class Unsupported < Lain::Error; end

    # Inherited env whose presence binds a child to LAIN's OWN bundler / rspec
    # context. Scrubbed to nil so it is DELETED in the child (not merely
    # overridden), leaving the caller's own env and PATH/GEM_* intact.
    #
    # GEM_* is deliberately NOT here: the child still has to find its gems, and
    # widening this to `GEM_` changes which ones it can see.
    FRAMEWORK_ENV = /\A(?:BUNDLE_|BUNDLER_|RSPEC_|RUBYOPT\z)/

    # Every spawn mechanism here INHERITS this process's environment and applies
    # `env` per key onto it -- mixlib in its forked child, `Process.spawn` in
    # {Shell::Pipeline}, the daemon over the wire onto ITS own inherited copy.
    # So the scrub has to name every framework var actually present to inherit,
    # hence the union of the live ENV with the caller's own keys; a var the
    # caller merely OMITS still reaches the command.
    #
    # That union has a LIMITATION worth stating in the same breath, because it is
    # the converse and it is not obvious: the CALLER's keys are scrubbed too, so
    # a framework var the caller deliberately LENT is taken away as well. A
    # {WorkerEnv} carrying `"BUNDLE_GEMFILE" => "/other/project/Gemfile"` reaches
    # the child unset rather than redirected -- a child cannot be pointed at
    # another project's bundle through this hash. Inherited from
    # {Grader::TestHarness}, whose class doc records the same limitation and why
    # it is acceptable: per-subject dependency isolation belongs to an
    # out-of-process boundary, not to an env override.
    #
    # @param env [Hash] the caller's overrides ({WorkerEnv#env})
    # @return [Hash] those overrides plus an explicit nil for each framework var
    def self.child_env(env)
      polluted = (ENV.keys + env.keys).grep(FRAMEWORK_ENV).uniq
      env.merge(polluted.to_h { |key| [key, nil] })
    end
  end
end

require_relative "exec/local"
require_relative "exec/core"
require_relative "exec/docker"
