# frozen_string_literal: true

# Which specs are allowed to spend money, and which are allowed to touch the network.
#
# The default posture is offline and free. `webmock/rspec` blocks outbound HTTP for every
# example; a tag is the only way through. This file owns the gating for every such tag, so
# there is exactly one place to read the answer to "can this spec cost me money?"
#
#   :api_integration  hits the real API. Opt-in, requires BOTH env vars. Named for what it
#                 integrates WITH: :seam below is integration with the rest of lain, and
#                 calling both of them "integration" hid the distinction that matters --
#                 one costs money and can fail because somebody else's service is down.
#   :vcr          replays a recorded cassette. Free, offline. See vcr_configuration.rb.
#   :live         end-to-end differential run against the API. Opt-in, costs real money.
#   :spike        measurement experiments (spec/spikes/). Free and offline, but slow and
#                 environment-shaped -- they pin scheduler behavior, not lain behavior.

# :api_integration specs talk to the real Claude API. They cost money and are
# nondeterministic, so they are skipped unless BOTH are set. The env var keeps its
# name: `LAIN_` already says whose integration it is, and it is documented in the
# README, in docs/providers, and in whatever anybody has in their shell history.
#
#     LAIN_INTEGRATION=1 ANTHROPIC_API_KEY=sk-... bundle exec rspec
INTEGRATION_ENABLED = ENV["LAIN_INTEGRATION"] == "1" && !ENV["ANTHROPIC_API_KEY"].to_s.empty?

# Whether ONE example may take the blunt network permission -- which is a
# different question once a CASSETTE is in play.
#
# Three tags reach for `NetworkAccess.permit`: :api_integration and :live here,
# :ollama in ollama_tag.rb. All three register an `around`, all three are in
# files that sort before vcr_configuration.rb in `Dir[]` order, and VCR 6.4.0
# inserts a cassette from a `before(:each, :vcr)` -- NOT an `around`
# (vcr/test_frameworks/rspec.rb:36). So for a cassette-backed example in any of
# those tiers the permission ran FIRST, turned VCR off, and the later
# `insert_cassette` was **silently ignored**: nothing raised, the example
# passed, and the recording it was meant to make did not exist. Measured for
# :api_integration + :vcr -- `current_cassette=nil, turned_on?=false`, green.
#
# (The same call from INSIDE an inserted cassette raises `CassetteInUseError`
# and names it. `ignore_cassettes: true` does not mean "ignore the one already
# in use"; it means "ignore one inserted while VCR is off". Only the hook
# ordering above produces the silent version, which is why it survived.)
#
# This exists as an object rather than a rule because a rule three call sites
# can each forget is not a fix -- and spec/lain/vcr_ollama_posture_spec.rb
# asserts mechanically that nothing else under spec/support calls
# `NetworkAccess.permit` directly.
module ExampleNetwork
  # Truthiness, not presence: RSpec's filters and VCR's own
  # `when_tagged_with_vcr` both test `!!v`, so `vcr: false` is how an example
  # says "no cassette here" and must still get its permission.
  def self.cassette_backed?(metadata)
    !!metadata[:vcr]
  end

  # A cassette-backed example takes NO permission. It does not need one: inside
  # a recording cassette `VCR.real_http_connections_allowed?` is already true,
  # and a replaying one wants no network at all.
  def self.permit(metadata, &block)
    return yield if cassette_backed?(metadata)

    NetworkAccess.permit(&block)
  end
end

RSpec.configure do |config|
  # Integration examples reach the real network for their duration only, then
  # isolation is restored even if the example raises. NetworkAccess.permit moves
  # BOTH the WebMock and the VCR switch -- flipping WebMock alone is not enough
  # once VCR has taken the hook, and that is exactly the trap NetworkAccess
  # exists to make un-re-breakable (see spec/support/network_access.rb).
  config.around(:each, :api_integration) do |example|
    ExampleNetwork.permit(example.metadata) { example.run }
  end

  unless INTEGRATION_ENABLED
    config.filter_run_excluding(:api_integration)

    config.before(:suite) do
      RSpec.configuration.reporter.message(
        "Skipping :api_integration specs. Set LAIN_INTEGRATION=1 and ANTHROPIC_API_KEY to run them."
      )
    end
  end

  # :vcr specs replay a committed cassette through VCR/webmock and are free and
  # offline BY DEFAULT -- no exclusion needed to run them; that is the whole
  # appeal. The one thing that needs guarding is RECORDING: LAIN_RECORD flips
  # vcr_configuration.rb's default from :none to :new_episodes, and recording
  # without a real key would either fail against the API or, worse, commit a
  # cassette holding a failed, keyless interaction. Refuse up front rather than
  # silently doing that.
  #
  # The requirement is derived from the PROVIDER being recorded, not from the
  # flag being set: a local ollama recording has no account behind it and no key
  # to supply, and demanding one blocked a recording it could never help. Which
  # providers need which credential is VcrRecording's to say, not this file's --
  # this file only decides that a recording missing one must not start.
  #
  # Referenced inside the hook, never at load: support files load in `Dir[]`
  # order and vcr_configuration.rb sorts AFTER this one, so the constant does
  # not exist yet when this file is read. It does by the time a suite starts.
  config.before(:suite) do
    missing = VcrRecording.missing_credential
    raise "LAIN_RECORD=#{VcrRecording.requested} requires #{missing} to record real interactions." if missing
  end
end

# :live specs run a full round trip against the real API with no cassette to
# fall back to -- real money on every single run, not just the first. Opt-in
# on exactly the same shape as :api_integration: BOTH env vars, or it is skipped.
#
#     LAIN_LIVE=1 ANTHROPIC_API_KEY=sk-... bundle exec rspec
LIVE_ENABLED = ENV["LAIN_LIVE"] == "1" && !ENV["ANTHROPIC_API_KEY"].to_s.empty?

# :spike specs are one-off measurements (the 5-0 concurrency spike). They cost no
# money and touch no network, but they take wall-clock seconds and assert facts about
# the runtime environment rather than about lain -- so they run only on request:
#
#     LAIN_SPIKE=1 bundle exec rspec spec/spikes
SPIKE_ENABLED = ENV["LAIN_SPIKE"] == "1"

RSpec.configure do |config|
  config.filter_run_excluding(:spike) unless SPIKE_ENABLED
end

# :nvim specs drive a REAL headless nvim over msgpack-RPC (spec/lain/frontend/neovim_spec.rb).
# They cost no money and touch no network. Opt-OUT, not opt-in: they run on a plain `rspec`,
# and `LAIN_NVIM=0` skips them.
#
#     LAIN_NVIM=0 bundle exec rspec        # skip them
#
# They were opt-in ("slow"), and the cost of that was that 97 examples -- whole files, including
# the 714-line neovim_runtime_spec and the 426-line neovim_request_spec -- never ran in any
# pre-commit or CI, so nothing but a manual run could catch a regression in them. Measured before
# flipping: the entire :nvim set is 13.3s wall, against a ~70s serial suite. That is not slow
# enough to buy invisibility with, and the tag stays only so a machine with no nvim, or a run that
# wants the fast path, can still say no.
#
# ⚠️ The missing-nvim guard is a FILTER, not a per-example `skip`, and it has to be. These specs
# spawn their editor in `around` hooks, and an `around` wraps every `before` -- including a
# config-level one -- so a `before(:each, :nvim) { skip }` never runs early enough: the spawn has
# already raised Errno::ENOENT, and the ensure that reaps the pid then dies a second time on
# `Process.kill("TERM", nil)`. Measured on a PATH with no nvim: 81 failures, zero skips. Excluding
# the tag outright is the only guard that fires before an `around` can.
NVIM_ENABLED = ENV["LAIN_NVIM"] != "0" &&
               system("nvim", "--version", out: File::NULL, err: File::NULL)

RSpec.configure do |config|
  config.filter_run_excluding(:nvim) unless NVIM_ENABLED
end

# :seam names a LEVEL, where every other tag in this file names a COST.
#
# The tags above answer "may this spend money, or touch the network?". None of
# them answers "how much of the app is under test?", so the tier between a unit
# spec and an end-to-end one had no name -- and it is the tier where this
# codebase's real defects have lived: a check-then-act across two threads, an
# index that compacted while a buffer still showed the old rows, a gesture that
# reached the rail and was silently dropped because nothing consumed it. None of
# those is visible to a spec that doubles its collaborators.
#
# A :seam spec wires TWO OR MORE real components together with NO test double
# between them, and may drive a real local resource -- git, an editor, the
# compiled extension, a live fd. It costs no money and touches no network, which
# is what separates it from :api_integration (the real API) and :live (a full
# differential run). `spec/lain/seams/` is the home for seams belonging to no
# single subject; a seam WITH an obvious subject stays at its mirror path and
# carries the tag instead, because a spec should sit where its subject does.
#
# Opt-OUT, for :nvim's reason: these are where the bugs are, so they run by
# default and the tag exists to buy a fast inner loop, not to hide them.
#
#     bundle exec rspec --tag '~seam'   # unit-only: the tight edit-run loop (QUOTE it -- zsh
#                                       # reads a bare ~seam as a home directory)
#     LAIN_SEAM=0 bundle exec rspec     # the same, for a whole run
SEAM_ENABLED = ENV["LAIN_SEAM"] != "0"

RSpec.configure do |config|
  config.filter_run_excluding(:seam) unless SEAM_ENABLED
end

# :services specs provision REAL Postgres/Redis for the DB-index isolation
# strategy (spec/lain/isolation/db_index_spec.rb). They cost no money and touch
# no network -- they shell out to createdb/dropdb/redis-cli against a local
# server -- but they need that server running, so they are opt-in like :nvim,
# run only with LAIN_SERVICES=1. When opted in but the CLI tools are absent, an
# example SKIPS (never fails): a missing server is an environment gap, not a
# lain regression. Kept separate from :api_integration precisely because it needs no
# ANTHROPIC_API_KEY.
#
#     LAIN_SERVICES=1 bundle exec rspec spec/lain/isolation/db_index_spec.rb
SERVICES_ENABLED = ENV["LAIN_SERVICES"] == "1"

RSpec.configure do |config|
  config.filter_run_excluding(:services) unless SERVICES_ENABLED
end

# :core specs drive the REAL compiled lain-core daemon over its Unix socket
# (spec/lain/core/client_spec.rb). They cost no money and touch no network, but
# they need the compiled binary, so they are excluded by default. Unlike the
# env-gated tags above, the way in is the tag itself: a command-line `--tag core`
# takes priority over this config-level exclusion (rspec-core 3.13, verified),
# so no LAIN_* variable is needed:
#
#     bundle exec rake core:build && bundle exec rspec --tag core
#
# When opted in but the binary is absent, an example SKIPS (never fails),
# mirroring :nvim: a missing build artifact is an environment gap, not a lain
# regression -- and the skip message names the rake task that fills it.
RSpec.configure do |config|
  config.filter_run_excluding(:core)

  config.before(:each, :core) do
    unless File.executable?(Lain::Core::Child::BINARY)
      skip("lain-core binary not built -- run `bundle exec rake core:build` to run :core specs")
    end
  end
end

# :vsock specs drive the REAL compiled lain-core daemon over AF_VSOCK. They cost
# no money and touch no network beyond the kernel's loopback vsock transport, but
# they need BOTH a host that can bind AF_VSOCK and the compiled binary, so they
# are excluded by default. The way in is the tag itself, exactly as for :core:
#
#     bundle exec rake core:build && bundle exec rspec --tag vsock
#
# :vsock examples carry ONLY that tag, never :core as well. A command-line --tag
# lifts the config-level exclusion for the tag it names and no other, so an
# example tagged `:vsock, :core` would stay excluded under `--tag vsock` -- and the
# run would pass GREEN having executed nothing. That failure is silent, which is
# why it is spelled out here and reproduced in spec/support_vsock_availability_spec.rb.
#
# When opted in but a precondition is missing, an example SKIPS (never fails),
# mirroring :core -- and the message names WHICH precondition, because "no vsock"
# and "no binary" have completely different fixes.
RSpec.configure do |config|
  config.filter_run_excluding(:vsock)

  config.before(:each, :vsock) do
    skip("host cannot bind AF_VSOCK -- the kernel's vsock_loopback transport is unavailable") unless
      VsockAvailability.available?
    unless File.executable?(Lain::Core::Child::BINARY)
      skip("lain-core binary not built -- run `bundle exec rake core:build` to run :vsock specs")
    end
  end
end

RSpec.configure do |config|
  config.around(:each, :live) do |example|
    ExampleNetwork.permit(example.metadata) { example.run }
  end

  unless LIVE_ENABLED
    config.filter_run_excluding(:live)

    config.before(:suite) do
      RSpec.configuration.reporter.message(
        "Skipping :live specs. Set LAIN_LIVE=1 and ANTHROPIC_API_KEY to run them."
      )
    end
  end
end
