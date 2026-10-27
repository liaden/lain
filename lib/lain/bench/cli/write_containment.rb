# frozen_string_literal: true

module Lain
  module Bench
    class CLI
      # THE PAIR THIS BENCH MAY NOT RUN: a capability set that can act outside
      # the run's own memory, with nothing isolating where it acts. {CLI} decides
      # which isolation a command runs under; this refuses the tools that would
      # write past it.
      #
      # {CLI#lease_options}'s shape, and deliberately so -- an operator meets one
      # idiom rather than two. That guard refuses a named isolation with nowhere
      # to record its leases; this one refuses tools with nowhere to contain
      # them. Both name the flags that fix them, and both fire at the door
      # rather than after a paid run.
      #
      # IT FIRES FIRST, uniformly, at all three assembly methods: a refusal that
      # a wiring mistake elsewhere could get in front of is not a guard. The one
      # thing that is deliberately NOT its business is a name outside the
      # advertised set; see {.uncontained?}.
      #
      # It is UNREPRESENTABLE rather than merely documented, which is the
      # standard this project already holds its secret boundary to: an
      # unisolated arm leases through {Arm::NoIsolation} and runs in the
      # operator's own checkout, and the floor's `bash` runs there behind a
      # gate that approves it, because no human is attached to ask.
      module WriteContainment
        module_function

        # Named once, so the commands that can offer it quote one sentence and the
        # help text cannot drift from the refusal.
        #
        # @return [String] the flags that contain a run's writes
        def flag = "--isolation #{CONTAINING_BACKENDS.join("|")} --journal PATH"

        # @param tools [#call] the capability factory the run would be built with
        # @param isolation [String, nil] the `--isolation` name; nil is UNSET
        # @param flag [String, nil] what the operator can type to fix it, or nil
        #   where the command offers no isolation at all
        # @raise [Refusal] on the unsafe pair
        def refuse!(tools, isolation:, flag: WriteContainment.flag)
          return unless uncontained?(isolation)
          # Asked of a BUILT set rather than of the factory: what a run may do is
          # a property of the tools, and a caller may inject a factory of its own.
          # Called with the FULL documented signature -- an injected factory that
          # honours the contract must not raise a bare ArgumentError from inside a
          # guard, where it would render as a backtrace instead of this method's
          # own clean Refusal.
          return unless Harness.writes?(tools.call(recorder: Memory::Recorder.new,
                                                   journal: Channel::Null.instance))

          raise Refusal, "this run's tools can write (#{Harness::WRITERS.join(", ")}) and " \
                         "#{uncontained(isolation)} where they write, so they would act in the working tree " \
                         "this command was run from#{remedy(flag)}"
        end

        # Unset, or an ADVERTISED backend that contains nothing. A name outside
        # the advertised set is deliberately NOT this guard's business:
        # {Lain::CLI::IsolationBackend::Unknown} names the whole set and is the
        # diagnosis a typo needs, so it has to speak first -- a safety refusal
        # quoting `--isolation nope does not isolate` would answer a question
        # nobody asked and hide the one they did.
        def uncontained?(isolation)
          return true if isolation.nil?

          Lain::CLI::IsolationBackend::BACKENDS.include?(isolation) && !CONTAINING_BACKENDS.include?(isolation)
        end

        # Says which of the two ways the run is uncontained, because "no
        # --isolation" and "--isolation none" are different mistakes and only one
        # of them looks like a typo.
        def uncontained(isolation)
          isolation.nil? ? "nothing isolates" : "--isolation #{isolation} does not isolate"
        end

        def remedy(flag) = flag.nil? ? "" : "; add #{flag}. #{WORKTREE_REACH}"

        private_class_method :uncontained?, :uncontained, :remedy
      end
    end
  end
end
