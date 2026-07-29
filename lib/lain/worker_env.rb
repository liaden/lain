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
    #
    # `ENV.to_h` hands back FRESH, unfrozen Strings every call, so the
    # `Ractor.make_shareable` below then has to walk and freeze all ~83 of them,
    # every time. Interning with `-` instead means the second and later calls
    # reuse one frozen String per key and per value, and make_shareable finds
    # nothing left to do. This method was 10.4% of the whole spec suite's
    # allocations -- the largest single site in lib/ after Canonical -- because
    # `Session::Null` reaches for it on the default path of every tool call.
    # Measured against an 83-var ENV: 55.9kB/334 objects -> 15.0kB/169, same
    # content, still `Ractor.shareable?`.
    def self.default
      snapshot = {}
      ENV.each { |key, value| snapshot[-key] = -value }
      new(cwd: Dir.pwd, env: snapshot)
    end

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
