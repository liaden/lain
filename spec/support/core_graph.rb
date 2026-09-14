# frozen_string_literal: true

# The core object graph a spec needs before it can say anything: a provider, a
# toolset, a context, a store, a journal -- and the Agent, Subagent and Scribe
# assembled from them. Hand-built, that graph is five to nine constructor calls
# restated at every example that varies ONE of them, so the thing under test is
# the smallest part of what the reader has to read.
#
# Called fully qualified (`CoreGraph.context`) and never included into the
# example group. Not because an include could shadow RSpec's `context` -- these
# are private INSTANCE methods and the group DSL is class-level, so it could
# not -- but for the reverse: `context`, `toolset`, `store` and `journal` are
# all live `let` names in the specs this serves, so an included `toolset` would
# be silently shadowed in the groups that define one, and would hand back a
# fresh un-memoized object in the groups that do not. Two spellings, two
# meanings, one name. Qualified, the call site says which it meant.
#
# Two rules hold it together:
#
# * Every default is BUILT FRESH per call. A memoized Store or Toolset shared
#   between examples is a cross-example leak. Exactly two defaults are shared,
#   and both are stateless and frozen: {Lain::Channel::Null}'s singleton, and
#   `ToolRegistry::UNGUARDED`, a frozen lambda that returns a FRESH
#   {Lain::Middleware::Stack} on each call rather than closing over one.
# * The default graph touches nothing outside the process. The provider is
#   {Lain::Provider::Mock} (no socket) and the journal is a Null channel (no
#   fd), so a spec that asks for the defaults cannot write to disk by accident.
#   Anything real -- a {Lain::Journal} over a file, a live provider -- is named
#   at the call site, which is where a reader looks for it. The measured form
#   of that claim is agent_spec's "holds no file descriptor of its own".
#
# WHERE THE DEFAULTS ARE PINNED, and why it is worth saying out loud: that same
# agent_spec example IS this file's spec. A helper earns one exactly when its
# breakage is QUIET, and three of these four defaults are loud -- flip `journal`
# to a real one, or `MODEL`, and specs redden immediately. `toolset` is the
# exception: emptied, it left three of the four converted files fully green and
# reddened only supervisor_spec, once by hanging rather than failing. So a fifth
# default gets asserted THERE, beside the other four, rather than trusted to be
# noticed -- and if this grows past a handful, it wants a support spec of its
# own like the matchers and the watchdog have.
module CoreGraph
  # The spelling the converted specs already shared. It resolves in the
  # default {Lain::ContextWindow} book, so occupancy is computable without a
  # spec having to name a book -- one that wants a SMALL window names it.
  MODEL = "claude-opus-4-8"
  MAX_TOKENS = 1024

  # The child half of a spawn, distinct from the parent's so a rendered request
  # says which side it came from.
  CHILD_MODEL = "child"
  CHILD_MAX_TOKENS = 128

  module_function

  def store = Lain::Store.new

  def timeline(store: CoreGraph.store) = Lain::Timeline.empty(store:)

  def context(model: MODEL, max_tokens: MAX_TOKENS, **rest) = Lain::Context.new(model:, max_tokens:, **rest)

  # A thunk, because Subagent takes its context as one: each child gets its own.
  def context_factory(model: CHILD_MODEL, max_tokens: CHILD_MAX_TOKENS, **rest)
    -> { context(model:, max_tokens:, **rest) }
  end

  # Echo is the capability most mock-driven specs script against; `[]` for the
  # ones asserting on a toolset's absence.
  def toolset(tools = [EchoTool.new]) = Lain::Toolset.new(tools)

  # No responses at all is the honest default: a provider a spec never expects
  # to be called raises if it is. `flatten` is full-depth, so a caller holding
  # an Array of responses may pass it bare -- but a fixture that is ITSELF
  # array-shaped would be silently reshaped by it, so call sites splat.
  def provider(*responses) = Lain::Provider::Mock.new(responses: responses.flatten)

  def journal = Lain::Channel::Null.instance

  def spawn_policy(**) = Lain::Tool::SpawnPolicy.new(**)

  def agent(provider: CoreGraph.provider, toolset: CoreGraph.toolset, context: CoreGraph.context, **seam)
    Lain::Agent.new(provider:, toolset:, context:, **seam)
  end

  # `parent:` has no default: a spawn with no lineage is a spawn whose whole
  # point is missing, and every caller has a timeline in hand already.
  def subagent(parent:, provider: CoreGraph.provider, toolset: CoreGraph.toolset,
               context_factory: CoreGraph.context_factory, policy: CoreGraph.spawn_policy,
               journal: CoreGraph.journal, tool_middleware: ToolRegistry::UNGUARDED, **seam)
    Lain::Tools::Subagent.new(
      parent:, provider:, toolset:, context_factory:, policy:, journal:, tool_middleware:, **seam
    )
  end

  def scribe(journal: CoreGraph.journal, context: CoreGraph.context, toolset: CoreGraph.toolset, **rest)
    Lain::SessionRecord::Scribe.new(journal:, context:, toolset:, **rest)
  end
end
