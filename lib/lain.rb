# frozen_string_literal: true

require "zeitwerk"

# THE load-order manifest. Internal requires live here and in each unit's own
# index file (foo.rb requires foo/**), never in leaf files -- so the dependency
# order below is the one place a cycle would have to show itself. Entries are
# in topological order of the real require graph: a unit may reference, at load
# time, only constants from lines above it. New files join their unit's index;
# new units join this list where their dependencies place them.
#
# `Lain`'s OWN members are the exception, and they sit BELOW this list rather
# than in it -- `SILENT` and `.live` are the module's, not any unit's, and the
# module body is where they belong. Nothing here may read one at load time; a
# unit that tried would raise a `NameError` at boot, loudly and immediately.
require_relative "lain/version"
require_relative "lain/error"
require_relative "lain/paths"
require_relative "lain/project_dir"
require_relative "lain/dsl_catalog"
# A `declare` block subclasses Carrier as the class body evaluates, so this has
# to load before the first value class declares. The real bound is `question`
# (the FIRST unit whose class body declares -- not `config`, which declares
# nothing); anywhere above that would load, and nothing else about the position
# is forced.
require_relative "lain/declarative"
require_relative "lain/config"

# A dependency-free leaf that names no Lain constant, moved AHEAD of the value
# classes that want it: {Freezable::Fields} is the one owner of "intern a
# String field, keep nil as the absence it signals", and a Data value built at
# class-body time (TestLayout::None) needs it loaded by then.
require_relative "lain/freezable"
require_relative "lain/test_layout"
require_relative "lain/cache_profile"
require_relative "lain/proxy_bytes"
require_relative "lain/canonical"
require_relative "lain/content_addressed"
require_relative "lain/prompt"
require_relative "lain/inspectable"
require_relative "lain/interval_partition"
require_relative "lain/blankness"
require_relative "lain/markdown_identifier"
require_relative "lain/question"
require_relative "lain/telemetry"
require_relative "lain/mode"
require_relative "lain/improvement"
require_relative "lain/channel"
require_relative "lain/request"
require_relative "lain/workspace"
require_relative "lain/context"
require_relative "lain/compaction"
require_relative "lain/worker_env"
require_relative "lain/exec"
require_relative "lain/project"
require_relative "lain/session"
require_relative "lain/tool"
require_relative "lain/effect"
require_relative "lain/journal"
require_relative "lain/toolset"
require_relative "lain/role"
require_relative "lain/skill"
require_relative "lain/summarizer"
require_relative "lain/credential_patterns"
require_relative "lain/sensitivity"
require_relative "lain/middleware"
require_relative "lain/usage"
require_relative "lain/stop_reason"
require_relative "lain/response"
require_relative "lain/store"
require_relative "lain/event"
require_relative "lain/run_clock"
require_relative "lain/status_feed"
require_relative "lain/dag"
require_relative "lain/timeline"
require_relative "lain/liveness"
require_relative "lain/session_record"
require_relative "lain/agent"
require_relative "lain/supervisor"
require_relative "lain/promise"
require_relative "lain/core"
require_relative "lain/approval"
require_relative "lain/capability"
require_relative "lain/price_book"
require_relative "lain/context_window"
require_relative "lain/ledger"
require_relative "lain/memory"
require_relative "lain/sink"
require_relative "lain/provider"
require_relative "lain/oracle"
require_relative "lain/renderable"
require_relative "lain/cli"
require_relative "lain/embedder"
require_relative "lain/compare"
require_relative "lain/bench"
require_relative "lain/frontend"
require_relative "lain/grader"
require_relative "lain/gherkin"
require_relative "lain/plan"
require_relative "lain/epic"
require_relative "lain/forge"
require_relative "lain/review"
require_relative "lain/survey"
require_relative "lain/friction"
require_relative "lain/structural"
require_relative "lain/shell"
require_relative "lain/isolation"
require_relative "lain/arm"
require_relative "lain/tools"
require_relative "lain/consolidation"

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
  # It was the manifest's third entry before it was {Lain}'s own member, and it
  # can sit below the whole list instead because every reader in lib/ is a
  # `notice:`/`notify:` keyword default or a `|| SILENT` inside a method --
  # resolved when a caller calls, never while the file naming it loads.
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

  # The loader is kept rather than dropped on the floor: spec/zeitwerk_spec.rb
  # asks IT which constant each path is expected to yield, so the equivalence
  # check reads Zeitwerk's own answer instead of restating its rules and
  # agreeing with itself.
  LOADER = Zeitwerk::Loader.for_gem(warn_on_extra_files: false)
end

# Zeitwerk beside the manifest above, loading nothing the manifest already
# loaded: every constant is defined by the time this runs, so each file is
# shadowed and the eager load is a no-op -- EXCEPT where a path and its constant
# disagree, which is the one thing the two cannot both be right about. Those
# raise here, at boot, which is what makes this a check and not decoration.
#
# `warn_on_extra_files` is off because a Zeitwerk warning writes to $stderr, and
# only the frontend may do that.
loader = Lain::LOADER
loader.inflector.inflect(Lain::LOADER_INFLECTIONS)
loader.setup

# The compiled Rust extension. Defines Lain.hello and Lain::Ext.init_tracing.
#
# BELOW `loader.setup`, because magnus's init asks for `Lain::Error` as it runs:
# the autoloads have to be registered by then for that name to resolve without
# the manifest above having already defined it.
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
