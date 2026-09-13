# frozen_string_literal: true

module Lain # rubocop:disable Style/Documentation -- doc lives on Lain's canonical reopen in lib/lain.rb
  # The toolset -- and often the tool that is a member of it -- is built
  # before every collaborator it will eventually need exists yet. Rather than
  # forcing construction order, the wiring hands the not-yet-live one a thunk
  # that reads the real value at CALL time; this is {Tools::AskHuman}'s
  # `parent:` idiom, and the reason it exists: the toolset is built before the
  # Agent.
  #
  # `.live` is the one place that distinction is resolved: anything `#call`-able
  # is called, anything else passes through unchanged. Not memoized -- called
  # again on every read, because "the value may be different by the time it is
  # next needed" is the same reason it was read lazily instead of once at
  # construction; a thunk that raises or returns nil is not rescued or
  # defaulted here either, for the same reason -- this is resolution, not
  # policy, and a caller that wants a Null Object still writes `Lain.live(x) ||
  # Something::Null` itself.
  #
  # Single-level, not recursive: `Lain.live(-> { -> { 7 } })` answers with the
  # inner Proc, still uncalled -- a second layer of laziness is a caller's own
  # decision to unwrap, not one this method makes for them by resolving until
  # the result stops responding to `#call`. And the callable it resolves takes
  # NO arguments -- one that requires any raises `ArgumentError` here, exactly
  # as it would have at any of the four sites this generalizes. That exposure
  # was already true of each of them; it is worth saying now that it is a
  # public, discoverable method rather than four narrow private call sites.
  def self.live(value) = value.respond_to?(:call) ? value.call : value
end
