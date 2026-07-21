# frozen_string_literal: true

module Lain
  # The host-side execution context a {Session} lends its tools: the working
  # directory relative paths resolve against, and the environment a shelled-out
  # command runs under. Two fields, `cwd` and `env`, and nothing else -- this is
  # the surface a strategy OVERRIDES a run's env and cwd through.
  #
  # `env` is an OVERRIDE, not confinement -- and B3 must build on that reading.
  # Mixlib-shellout applies `environment:` per-key in the forked child
  # (`ENV[k] = v`) onto the ENV it already inherited, and never clears ENV first.
  # So a host var this `env` OMITS still reaches the command; overriding is
  # additive, and true confinement belongs to the out-of-process exec boundary
  # (M5/M6), never to this hash. There is ONE removal lever that does work
  # in-band: an explicit `nil` VALUE. Ruby's `ENV[k] = nil` deletes, so mapping a
  # key to `nil` here scrubs that var from the child (and the value object keeps
  # the nil marker -- it is frozen, so shareability holds). Absent key: leaks;
  # explicit nil: scrubs.
  #
  # Sent-not-stored, exactly like {Workspace}: it rides the Session (the run's
  # mutable scratch, never on the Timeline), so a secret in `env` never reaches a
  # turn's content and never enters a digest. Keeping it here is what keeps
  # `Ractor.shareable?(turn)` true and keeps host secrets out of the experiment
  # record.
  #
  # Deeply frozen and `Ractor.shareable?`: `Data` freezes the instance but not a
  # contained mutable String or Hash, so the constructor freezes `cwd` and makes
  # `env` a shareable (recursively frozen) Hash. There is a spec.
  WorkerEnv = Data.define(:cwd, :env) do
    # The default: the live process working directory plus a snapshot of its
    # environment. A run that injects no isolation therefore shells out under the
    # same `Dir.pwd` and `ENV` it would read directly -- byte-identical to the
    # pre-WorkerEnv behavior. Computed fresh (not a frozen constant) so a caller
    # that reads it after a `Dir.chdir` still sees the current directory, which
    # is how {Session::Null} preserves each tool's "defaults to the current
    # directory" contract.
    def self.default = new(cwd: Dir.pwd, env: ENV.to_h)

    def initialize(cwd:, env:)
      super(cwd: cwd.dup.freeze, env: Ractor.make_shareable(env.to_h))
    end

    # The ONE cwd-resolution rule both exec arms share (Tools::Bash in
    # process, Tools::CoreExec across the boundary), extracted so the two
    # transports cannot drift apart on it: a model-supplied path resolves
    # against this cwd -- a relative one lands under it, an absolute one is
    # honored as given (File.expand_path ignores the base for an absolute
    # path) -- and absent a path, this cwd is the working directory.
    def resolve(path)
      path ? File.expand_path(path, cwd) : cwd
    end
  end
end
