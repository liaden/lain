# frozen_string_literal: true

require "zeitwerk"

# An agent harness built as a study bench: context strategies, tool designs, and
# orchestration tactics are swappable, observable, and comparable.
module Lain
  # The compiled extension's own namespace. THIS line defines it and magnus
  # reopens it to hang `init_tracing` on, so between here and the `require
  # "lain/lain"` below `loader.setup` there is a window where `Lain::Ext` is
  # defined and empty. Nothing tests `defined?(Lain::Ext)` for the extension's
  # presence, and nothing may start to: `Lain::Ext.respond_to?(:init_tracing)`
  # is the question that survives the window.
  module Ext; end

  # The startup-notice seam's null: a `notice:`/`notify:` keyword default
  # wherever a caller may not want to hear a component's non-fatal findings.
  # The protocol is one message, `#call(message)`, which is exactly what a
  # lambda already is -- so this stays a frozen Proc rather than a class
  # alongside {Sink::Null} and {Channel::Null}, whose protocols span several
  # methods standing in for a real collaborator (an I/O stream, an event
  # channel). One no-op, shared, so seven byte-identical definitions do not
  # drift out from under each other.
  #
  # It can live here, in a file the loader never autoloads on anyone's behalf,
  # because every reader in lib/ is a `notice:`/`notify:` keyword default or a
  # `|| SILENT` inside a method -- resolved when a caller calls, never while
  # the file naming it loads.
  SILENT = ->(_message) {}

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

  # The three spellings the loader's inflector cannot derive from a path. The
  # `version.rb` -> VERSION rule is not here because a gem loader already
  # carries it.
  LOADER_INFLECTIONS = { "cli" => "CLI", "http" => "HTTP", "tty" => "TTY" }.freeze

  # Named rather than local so spec/zeitwerk_spec.rb can ask IT which constant
  # each path is expected to yield, reading Zeitwerk's own answer instead of
  # restating its rules and agreeing with itself.
  LOADER = Zeitwerk::Loader.for_gem(warn_on_extra_files: false)
end

# The loader is the WHOLE of how lib/ loads: there is no require manifest, and
# no file under lib/ carries an internal require. A path and the constant it
# names therefore cannot disagree without saying so -- Zeitwerk raises at boot
# on the file that fails to define what its name promises, where a hand-written
# manifest would have loaded it silently and left the mismatch for a rename to
# find.
#
# The eager load below is kept deliberately and is not an optimisation to
# reclaim: hundreds of constants in lib/ are reachable only through the file
# that defines them, never through their own name, and they are harmless only
# because every file loads regardless. Dropping it converts each one into a
# load-order dependency that boots clean and raises from a method body in
# production.
#
# `warn_on_extra_files` is off because a Zeitwerk warning writes to $stderr, and
# only the frontend may do that.
loader = Lain::LOADER
loader.inflector.inflect(Lain::LOADER_INFLECTIONS)
loader.setup

# The compiled Rust extension. Defines Lain.hello and Lain::Ext.init_tracing.
#
# BELOW `loader.setup`, because magnus's init asks for `Lain::Error` as it runs:
# the autoloads have to be registered by then for that name to resolve at all.
# Zeitwerk did not remove that ordering constraint, it moved it.
#
# The rescue exists because the artifact is GITIGNORED (`*.so`, and it is 47MB),
# so a fresh clone, a fresh `git worktree`, and a fresh checkout on another
# machine have never had it -- and Ruby's own LoadError for it says only
# `cannot load such file -- lain/lain`, which names an internal path a human has
# no reason to recognise and no hint of what to do. Reported from a first-run on
# macOS, 2026-08-05, against `./exe/lain` and `bundle exec exe/lain --help`
# alike; CLAUDE.md already records the same trap biting fresh worktrees, where it
# surfaces as every spec failing at load.
#
# Re-raised as LoadError, not a Lain::Error: the failure is a missing build
# artifact rather than anything lain models, and a caller rescuing LoadError
# around an optional require must keep working.
begin
  require "lain/lain"
rescue LoadError => e
  raise LoadError, <<~SENTENCE.strip
    #{e.message}

    lain's compiled Rust extension is not built. It is gitignored, so a fresh
    clone or worktree never has it -- build it once with:

        bundle install && bundle exec rake compile

    (needs a Rust toolchain: https://rustup.rs). If that succeeded and this
    persists, the built artifact is for a different Ruby or platform than the
    one running now -- `bundle exec rake clean compile` rebuilds it.
  SENTENCE
end

loader.eager_load
