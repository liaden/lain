# frozen_string_literal: true

require "vcr"

# What `LAIN_RECORD` asks for, WHICH CASSETTES it therefore records, and what it
# requires to do so.
#
# Recording used to be one bit: `LAIN_RECORD=1` meant "record", and "record"
# meant Anthropic, so tags.rb demanded an ANTHROPIC_API_KEY for any recording at
# all. A local ollama recording needs no key -- there is no account behind it --
# and that guard was the first of the plan's five blockers to recording one.
#
# Naming the provider is NOT enough on its own, and getting that wrong is the
# expensive mistake this module exists to prevent. `record:` is a GLOBAL cassette
# option, so a version of this that used the provider only to pick a CREDENTIAL
# left `LAIN_RECORD=ollama` arming `:new_episodes` on the committed,
# secret-filtered Anthropic cassette, in a process with no key. Measured with a
# socket tripwire: a real connection to api.anthropic.com:443, held off by
# nothing but the fact that the one request happened to match. A 401 recorded
# into that cassette is the failure that was one prompt edit away.
#
# So a cassette states an OWNER and a record mode is only ever earned by the
# owner `LAIN_RECORD` names. An ollama pass cannot arm an Anthropic cassette,
# which is what makes the keyless case safe rather than merely lucky.
#
# Every method takes its input as an argument, defaulting to the environment.
# That is what lets spec/lain/vcr_ollama_posture_spec.rb read this without
# mutating a process-wide ENV -- a recording flag left behind in a parallel
# worker would flip a later example from replay to record.
module VcrRecording
  # `1` is kept as a spelling of `anthropic` because that is what it has always
  # meant, and it is in the README, in Gemfile's comment, and in whatever
  # anybody has in their shell history.
  PROVIDERS = { "anthropic" => :anthropic, "ollama" => :ollama, "1" => :anthropic }.freeze

  # Ollama is local and keyless, so it is absent by design rather than by
  # omission -- a provider missing from this map needs no credential.
  CREDENTIALS = { anthropic: "ANTHROPIC_API_KEY" }.freeze

  # The owner of a cassette whose example does not declare one. Every cassette
  # committed before owners existed is Anthropic's, and `LAIN_RECORD=1` has
  # always meant "re-record those" -- so this default is precisely what keeps
  # that invocation meaning what it did.
  DEFAULT_OWNER = :anthropic

  # How an example declares its cassette's owner, beside the `:vcr` tag:
  #
  #     it "...", vcr: { cassette_name: "ollama_chat" }, records: :ollama do
  OWNER_KEY = :records

  def self.requested
    ENV.fetch("LAIN_RECORD", nil)
  end

  # An unrecognised value RAISES rather than reading as "not recording". A typo
  # that quietly replayed would end a recording pass with a green suite and no
  # new cassette, which looks exactly like success -- and recording is the one
  # act in this suite whose whole point is a file appearing on disk.
  def self.provider(requested = self.requested)
    return nil if requested.nil? || requested.empty?

    PROVIDERS.fetch(requested) do
      raise ArgumentError, "LAIN_RECORD=#{requested.inspect} names no provider. " \
                           "Use one of: #{PROVIDERS.values.uniq.join(", ")} (or the historical 1)."
    end
  end

  # The mode a cassette OWNED BY `owner` opens with. `:new_episodes` only when
  # this pass named that owner; `:none` for every other cassette in the run.
  def self.record_mode(owner: DEFAULT_OWNER, requested: self.requested)
    provider(requested) == owner ? :new_episodes : :none
  end

  # The modes that can write to a cassette file. `:once` counts: it records
  # whenever the file is absent, which is exactly the state a new cassette is in.
  RECORDING_MODES = %i[all new_episodes once].freeze

  # The `:vcr` options an example's metadata should carry, with the record mode
  # its declared owner earns filled in.
  #
  # An explicit `record:` still wins -- an example pinning `:none` is stating
  # something this cannot know, and it is how every replay-posture example keeps
  # its footing under a recording pass. But a pinned RECORDING mode is refused
  # unless this pass named that cassette's owner, because it is otherwise the one
  # remaining way to open unscoped egress with no flag set at all: a bare
  # `vcr: { record: :all }` records against whatever host it names, on an
  # ordinary `bundle exec rspec`, with no credential in front of it. That is the
  # same hole B1 closed for the global default, and leaving it open in the
  # per-example path would have made the global fix a formality.
  def self.cassette_options(metadata, requested = self.requested)
    declared = metadata[:vcr]
    options = case declared
              when Hash then declared.dup
              when String then { cassette_name: declared }
              else {}
              end
    owner = metadata.fetch(OWNER_KEY, DEFAULT_OWNER)
    refuse_unearned_recording(options[:record], owner, requested)
    options[:record] ||= record_mode(owner:, requested:)
    options
  end

  def self.refuse_unearned_recording(pinned, owner, requested)
    return unless RECORDING_MODES.include?(pinned)
    return unless record_mode(owner:, requested:) == :none

    raise ArgumentError,
          "a cassette owned by #{owner.inspect} pins record: #{pinned.inspect}, but this run records " \
          "#{provider(requested).inspect}. Recording is scoped to the provider LAIN_RECORD names -- run " \
          "`LAIN_RECORD=#{owner} …`, or declare the cassette's real owner with `records:`."
  end
  private_class_method :refuse_unearned_recording

  # The name of the credential this recording needs and does not have, or nil.
  def self.missing_credential(requested = self.requested, env = ENV)
    required = CREDENTIALS[provider(requested)]
    required if required && env[required].to_s.empty?
  end
end

# "Can the VCR context currently in force serve a GET of this path?"
#
# It lives here, beside the VCR configuration, because it is a question about
# VCR rather than about any one endpoint -- ollama_probe.rb is its first caller,
# not its owner. Three things make it harder than `current_cassette` suggests,
# and all three were found by measurement rather than by reading:
#
#   * Cassettes NEST, and `VCR.current_cassette` is only the innermost. An outer
#     cassette holding the path still answers the request, so the question is
#     asked of `VCR.cassettes` -- the whole stack.
#   * VCR DELETES an interaction from its list when it plays it. Reading the
#     remaining interactions therefore answers "yes" to the first request and
#     "no" to the second, which is exactly when a fallback stub must NOT come
#     back: it converts VCR's loud `already been played back` into a silent
#     wrong answer. Ownership is learned at LOAD, from `before_playback`, so it
#     survives playback.
#   * A cassette may have been recorded against a different host than this run
#     points at (`OLLAMA_API_BASE` is a spec-level knob). The PATH identifies the
#     endpoint; the exact URI does not.
module VcrCassetteStack
  @paths = ObjectSpace::WeakKeyMap.new
  @lock = Mutex.new

  # Recorded at load, before any interaction can be consumed. Keyed weakly on
  # the cassette itself, so an ejected cassette's entry goes when it does and
  # nothing has to remember to clean up.
  def self.note(cassette, uri)
    path = path_of(uri)
    @lock.synchronize { (@paths[cassette] ||= []) << path } unless path.nil?
  end

  def self.serves?(path)
    VCR.cassettes.any? { |cassette| serves_from?(cassette, path) }
  end

  # A RECORDING cassette answers yes for every path: the live request has to
  # reach the server or there is nothing to record, and a stub in front of it
  # would record the stub.
  # A path matches itself or a segment BELOW it -- never a longer sibling. A bare
  # `start_with?` would make `serves?("/api")` true for a recorded `/api/chat`,
  # which is latent with one caller and a trap for the second.
  def self.serves_from?(cassette, path)
    cassette.recording? ||
      recorded_paths(cassette).any? { |recorded| recorded == path || recorded.start_with?("#{path}/") }
  end
  private_class_method :serves_from?

  # Asking for the interactions is what forces deserialization, which is what
  # fires `before_playback` and fills the note. Reading the note without it
  # would answer "no" for a cassette nothing had touched yet.
  def self.recorded_paths(cassette)
    cassette.http_interactions
    @lock.synchronize { @paths[cassette]&.dup } || []
  end
  private_class_method :recorded_paths

  def self.path_of(uri)
    URI.parse(uri.to_s).path
  rescue URI::InvalidURIError
    nil
  end
  private_class_method :path_of
end

# Registered BEFORE `configure_rspec_metadata!` below, and that is the whole
# mechanism: VCR reads `metadata[:vcr]` from a `before(:each, :vcr)` hook, so the
# record mode an example's OWNER earns has to be in that hash before VCR looks.
# Derived metadata is computed at example-definition time, ahead of every hook,
# which sidesteps the registration-order question entirely.
#
# Filtered on `:vcr`, not on the owner key, and that is load-bearing rather than
# incidental: an example may pin a recording mode WITHOUT declaring an owner
# (`vcr: { record: :all }`), and filtering on `records:` would let exactly that
# shape past the guard in `cassette_options`. Every cassette-backed example goes
# through it; one that declares nothing resolves to DEFAULT_OWNER and the mode it
# already had.
RSpec.configure do |config|
  config.define_derived_metadata(:vcr) do |meta|
    meta[:vcr] = VcrRecording.cassette_options(meta)
  end
end

# Deliberately UNLIKE RubyLLM's VCR defaults. RubyLLM sets
# `allow_http_connections_when_no_cassette = true` and `record: :once`, so a
# spec with no cassette silently hits the live API. On a bench whose headline
# metric is token cost, that is a footgun, not a convenience.
VCR.configure do |config|
  config.cassette_library_dir = "spec/fixtures/vcr_cassettes"
  config.hook_into :webmock
  config.configure_rspec_metadata!

  # webmock/rspec (required from spec_helper.rb) already blocks outbound HTTP
  # for every example. VCR must not punch a hole in that by falling through to
  # a real request the moment a cassette is missing -- a spec with no cassette
  # and no cache of a real interaction has no business reaching the network.
  config.allow_http_connections_when_no_cassette = false

  config.default_cassette_options = {
    # Recording is an explicit act, never a side effect of running the suite --
    # and it reaches only the cassettes of the provider that was named. This is
    # the mode for a cassette that declares no owner, which by DEFAULT_OWNER is
    # Anthropic's: `LAIN_RECORD=anthropic` (or the historical `=1`) flips those
    # to :new_episodes, `LAIN_RECORD=ollama` leaves them at :none, and every
    # other run replays only what is already committed. See VcrRecording above
    # for why scoping this was worth an object.
    record: VcrRecording.record_mode,
    # VCR's own default, kept EXPLICIT rather than implied: matching only on
    # method + URI means a cassette replays against WHATEVER request body we
    # send, so replaying green can never catch a request-payload regression.
    # That job belongs to `forked.encode(req) == sdk.encode(req)`, the
    # dry-diff against the SDK oracle (see the plan's "Testing strategy" --
    # this is deliberate, not an oversight).
    match_requests_on: %i[method uri],
    # Also VCR's own default (it reads `options[:allow_playback_repeats]`, which
    # was simply absent), made explicit because the plan for ollama cassettes
    # assumed a multi-turn one could not replay and would have added an
    # ollama-only matcher to buy what VCR already gives for free.
    #
    # This buys EXHAUSTION, not ordering -- a distinction worth keeping straight,
    # because the two get conflated. MEASURED, VCR 6.4.0: `response_for` does
    # `@interactions.delete_at(index)` UNCONDITIONALLY, so recorded ORDER holds
    # whatever this is set to. What the flag decides is what happens to the
    # request after the last one is spent: `false` raises `already been played
    # back`, `true` would replay the last answer forever. Flipping this line reds
    # exactly one example in spec/lain/vcr_ollama_posture_spec.rb, and it is the
    # exhaustion one.
    allow_playback_repeats: false
  }

  # Fires once per recorded interaction as a cassette deserializes -- before any
  # of them can be played, which is what makes the note survive playback. See
  # VcrCassetteStack.
  config.before_playback { |interaction, cassette| VcrCassetteStack.note(cassette, interaction.request.uri) }

  # Copied from RubyLLM's filter list, which is thorough.
  config.filter_sensitive_data("<ANTHROPIC_API_KEY>") { ENV.fetch("ANTHROPIC_API_KEY", nil) }

  %w[Authorization Anthropic-Organization-Id Request-Id Cf-Ray].each do |header|
    config.filter_sensitive_data("<#{header.upcase.tr("-", "_")}>") do |interaction|
      interaction.request.headers[header]&.first || interaction.response.headers[header]&.first
    end
  end
end

# A cassette is committed YAML holding FULL request and response bodies. Never
# record one against real medical content -- it is permanent, replayable, and
# invisible once merged, which is the same rule as "PHI must never enter
# memory," and for the same reason. Synthetic prompts only.
