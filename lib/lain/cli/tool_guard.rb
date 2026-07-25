# frozen_string_literal: true

module Lain
  module CLI
    # The tool phase's one guard, lifted out of {Wiring} the way {BaseTools},
    # {Switchboard}, {Command::Surface}, {Chronicle} and {ChatLaunch} were:
    # "what a chat refuses to let a tool write, and where that refusal is
    # recorded" is its own question, and both arms of the construction are
    # load-bearing in a way the one-liner it replaced could not show.
    #
    # {Middleware::RefuseSecretWrites} sits in the TOOL phase so a
    # credential-shaped memory_write is withheld before it ever reaches the
    # recorder: a memory, once indexed, replays into every future context, and
    # there is no un-indexing it.
    module ToolGuard
      module_function

      # @param chronicle [CLI::Chronicle] resolves where a refusal is recorded
      # @return [Middleware::Stack] the tool-phase stack, ready for `Agent.new`
      def stack(chronicle) = Middleware::Stack.new([Middleware::RefuseSecretWrites.new(**kwargs(chronicle))])

      # `.slice(:journal)` must OMIT the key under --no-journal so
      # RefuseSecretWrites' own Channel::Null default applies -- passing an
      # explicit `journal: nil` crashes on `<<` at refusal time, the worst
      # possible moment.
      #
      # The `oracle:` arm is a CONTENTLESSNESS FLOOR, not a second secret
      # detector ({Oracle::MemorySave}): it declines a save with nothing in it
      # and journals that as a decline rather than under a PATTERNS name. It
      # abstains entirely for a guarded tool carrying no `body` at all, which
      # is what keeps improvement_write from being refused wholesale.
      def kwargs(chronicle)
        { oracle: Oracle::MemorySave::Gate.new, **chronicle.telemetry_kwargs.slice(:journal) }
      end
    end
  end
end
