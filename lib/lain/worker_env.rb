# frozen_string_literal: true

module Lain
  # The host-side execution context a {Session} lends its tools: the working
  # directory relative paths resolve against, and the environment a shelled-out
  # command runs under. This is the surface a strategy overrides a run's env and
  # cwd through.
  #
  # `env` is an OVERRIDE, not confinement, and callers must build on that
  # reading. Mixlib-shellout applies `environment:` per-key in the forked child
  # onto the ENV it already inherited and never clears ENV first, so a host var
  # this `env` OMITS still reaches the command. True confinement belongs to the
  # out-of-process exec boundary, never to this hash. The ONE in-band removal
  # lever is an explicit `nil` VALUE: Ruby's `ENV[k] = nil` deletes, so mapping a
  # key to nil scrubs that var from the child. Absent key leaks; explicit nil
  # scrubs.
  #
  # Sent-not-stored, exactly like {Workspace}: it rides the Session, never the
  # Timeline, so a secret in `env` never reaches a turn's content or a digest --
  # which is what keeps `Ractor.shareable?(turn)` true and host secrets out of
  # the experiment record.
  #
  # `Data` freezes the instance but not a contained mutable String or Hash, so
  # the constructor freezes `cwd` and makes `env` recursively shareable.
  #
  # `checkout` is the root of the checkout an isolation lease cut for this
  # worker, and nil for the host's own environment. The lease sets it
  # ({Isolation::Lease}), because only the lease knows: a directory that looks
  # like a checkout proves nothing about whether this worker was given one.
  WorkerEnv = Data.define(:cwd, :env, :checkout) do
    # The live process working directory plus a snapshot of its environment, so a
    # run injecting no isolation shells out under the same `Dir.pwd` and `ENV` it
    # would read directly. Computed fresh, not a frozen constant, so a caller
    # reading it after a `Dir.chdir` still sees the current directory -- how
    # {Session::Null} preserves each tool's "defaults to the current directory".
    #
    # `ENV.to_h` hands back FRESH, unfrozen Strings every call, leaving
    # `Ractor.make_shareable` to walk and freeze all ~83 of them every time.
    # Interning with `-` lets the second and later calls reuse one frozen String
    # per key and value, with nothing left for make_shareable to do. This method
    # was 10.4% of the whole spec suite's allocations -- the largest single site
    # in lib/ after Canonical -- because `Session::Null` reaches for it on the
    # default path of every tool call. Measured against an 83-var ENV:
    # 55.9kB/334 objects -> 15.0kB/169, same content, still `Ractor.shareable?`.
    def self.default
      snapshot = {}
      ENV.each { |key, value| snapshot[-key] = -value }
      new(cwd: Dir.pwd, env: snapshot)
    end

    def initialize(cwd:, env:, checkout: nil)
      super(cwd: cwd.dup.freeze, env: Ractor.make_shareable(env.to_h), checkout: checkout&.dup&.freeze)
    end

    # The ONE cwd-resolution rule both exec arms share (Tools::Bash in process,
    # Tools::CoreExec across the boundary), extracted so the two transports
    # cannot drift: a relative model-supplied path lands under this cwd, an
    # absolute one is honored as given, and absent a path this cwd is it.
    def resolve(path)
      path ? File.expand_path(path, cwd) : cwd
    end
  end
end
