# frozen_string_literal: true

require_relative "backend/summarizer"

module Lain
  module CLI
    # Turns the CLI flags into the two collaborators a run needs a CHOICE about --
    # which Provider backend, and the Context carrying the model and the sampler
    # params (temperature/seed) that ride Request#extra. A plain object, not a bag
    # of methods on the Thor executable: the provider/model resolution is then
    # unit-testable without a Thor instance, and BOTH the chat and bench-record
    # paths resolve `--provider` through this one seam, so they agree on what a
    # provider name means (CLAUDE.md's Metrics rule -- extract, don't loosen).
    #
    # Errors here are Lain's, not Thor's: an unknown provider raises
    # {UnknownProvider} (a {Lain::Error}), which the exe layer maps to a
    # Thor::Error. Thor never crosses into lib/ (output/error discipline).
    class Backend
      # A missing key used to backtrace as {Provider::HTTP::ConfigurationError}
      # -- a plain StandardError, so it skipped the exe's `rescue Lain::Error`
      # and dumped a raw trace naming "Transport" (an internal collaborator, not
      # an operator-facing concept). Named refusal, checked BEFORE construction,
      # following {Bench::CLI::MissingAPIKey}'s precedent (same shape, not
      # reused -- Backend does not couple to Bench).
      class MissingAPIKey < Error; end

      # A memoized factory answers its FIRST caller's arguments forever. With
      # the one wiring site the run has that is a cache hit; a SECOND, differing
      # call would hand back a {Compaction::Source} still bound to the first
      # journal, and every per-turn decision would land in `Channel::Null` with
      # nothing raising and nothing missing from the record's shape -- the
      # precise silent degrade the whole compaction band exists to prevent.
      # Loud instead, per CLAUDE.md's unknown-state premise.
      class Rebound < Error; end

      # A summarizer ceiling of zero or less. Loud, because every other layer is
      # deaf to it: `0` is TRUTHY, so {#knob}'s `||` does not fall back for it;
      # `Request#max_tokens` only does `Integer()`, with no range check; the
      # provider 400s; and {Oracle::Eager}'s task boundary swallows that BY
      # DESIGN, leaving "compaction quietly stopped summarizing" as the only
      # symptom. A {Lain::Error}, not {Compaction::Head}'s bare ArgumentError,
      # for {MissingAPIKey}'s reason: a bad flag reaches the operator as a clean
      # Thor::Error only if the exe's `rescue Lain::Error` can see it.
      class InvalidCeiling < Error; end

      # The providers `--provider` selects between. The unknown-name guard names
      # this set, matching Capability::Policy.for's voice.
      PROVIDERS = %w[anthropic ollama bedrock].freeze

      # Which of those the SUMMARIZER tier defaults to. Local, because an eager
      # summary fires once per large tool result, off the turn's critical path,
      # and paying frontier-model tokens to compress a tool result costs more
      # than resending it. A default, not a law: `--summarizer-provider` buys a
      # local chat a better summarizer, or lets a frontier chat keep summarizing
      # for free -- which is exactly why the tier is journalled now.
      DEFAULT_SUMMARIZER_PROVIDER = "ollama"

      # Compaction's knobs, in {Compaction::Head}'s canonical-byte proxy. They
      # live HERE rather than as Thor defaults so there is one authority: an
      # unset flag arrives as nil and falls through to these.
      #
      # 256 KiB of droppable head is roughly 64k tokens -- big enough that a
      # working session is never rewritten for nothing, small enough that it is
      # the trigger that actually fires under Anthropic's 1M window (where
      # {Need::ApproachingWindow} would not fire until ~900k). The hard cap is
      # 4x that: below it a WARM cache defers, because a cache read costs ~0.1x
      # what the rewrite costs, and above it the history is large enough that
      # protecting the prefix is no longer the better trade.
      DEFAULT_BYTE_THRESHOLD = 262_144
      DEFAULT_HARD_CAP = 1_048_576

      # Trailing messages a compaction never touches. Twenty is about the last
      # ten exchanges: enough that the model keeps the thread of what it is
      # doing, since everything ahead of it survives only as summary or
      # attestation.
      DEFAULT_KEEP_LAST = 20

      # {Compaction::Scheduler} prices EVERY compacting turn, and the bench's
      # shared {PriceBook} raises on a model it has no list price for -- right,
      # where a silently-free model would corrupt a cost bench's headline
      # metric, and fatal here, where it would turn the first compaction of an
      # ollama chat into a crash mid-conversation. `--model` is a free-form
      # string, so this is not only the local-provider case.
      #
      # So compaction gets its own book: the same DEFAULTS, degrading to zero.
      # Nothing is being under-reported that a bench reads -- `cost_saved` and
      # `cost_spent` are annotations on a decision already made on BYTES -- and
      # zero is the honest figure for the local tier this most often means.
      # The degrading is not SILENT: {Telemetry::Compaction} carries the model
      # those figures are quoted in, so a zero beside a local model id reads as
      # the fallback it is rather than as a free compaction.
      #
      # No `.freeze`: PriceBook freezes itself and its map at construction.
      COMPACTION_PRICES = PriceBook.new(
        fallback: Price.per_mtok(input: 0, output: 0, cache_creation: 0, cache_read: 0)
      )

      # Both summarizer flags are refused HERE, at construction, rather than
      # where the tier is built. `--provider` refuses on every run because
      # {#provider} always runs; the summarizer's would not, because under
      # `--no-compact` {#tool_observer} answers the Null, {#summary_oracle} is
      # never built, and neither check ever ran -- so a typo was accepted in
      # exactly one configuration. An asymmetry a user meets in only one mode is
      # one they misread. Construction is the single path every command takes.
      def initialize(options)
        @options = options
        summarizer_name
        summarizer_max_tokens
      end

      # Anthropic reads its key from the environment; Ollama is local and takes an
      # optional `--api-base` override; Bedrock is also env-configured (the
      # Mantle client reads AWS_BEARER_TOKEN_BEDROCK / AWS_REGION itself, so no
      # flag threads through here). An unknown name fails loudly, naming the
      # valid set, as {UnknownProvider} (a bad flag is user error, surfaced by
      # the exe as a clean Thor::Error, not a bug with a backtrace).
      #
      # @param name [String] WHICH provider to build, already validated against
      #   PROVIDERS -- the chat's by default. {#summarizer_provider} passes its
      #   own name here rather than carrying a second copy of this case, so the
      #   two flags cannot come to disagree about what a provider name means.
      #
      # @param spool [#open_frame] the chronicle's response spool -- a real
      #   {Provider::ResponseWal} only when journaling is on ({CLI::Chronicle::Null}
      #   answers {Provider::Spool::Null}, never nil, so this is never an `if
      #   spool` guard). Threaded straight into {Provider::AnthropicRaw}, the
      #   only backend wired to tee to it: the Null spool -- no chronicle
      #   asked, e.g. bench (never passes spool: at all) or --no-journal chat
      #   -- just means nothing gets teed. Ollama and Bedrock never see the
      #   keyword at all: neither constructor accepts it, so nothing here
      #   risks handing it to them.
      #
      # "anthropic" always means {Provider::AnthropicRaw} here: uniform retry
      # telemetry and one spool-teeing transport regardless of --journal, same
      # call bench already made; {Provider::Anthropic} (the SDK client) stays
      # in the library as the #encode differential oracle, just not on this path.
      #
      # @param channel [Lain::Channel] where {Provider::AnthropicRaw}'s retry
      #   and CE-5 stream_started events land -- chat's live TTY Channel, so a
      #   stream start actually reaches the frontend. Like spool it defaults to
      #   the Null instance (headless/bench pass nothing, so their events land
      #   nowhere) and Ollama/Bedrock never receive the keyword.
      def provider(name: provider_name, spool: Provider::Spool::Null.new, channel: Channel::Null.instance)
        case name
        when "ollama" then Provider::Ollama.new(api_base: @options[:api_base])
        when "bedrock" then Provider::Bedrock.new
        else anthropic_provider(spool, channel)
        end
      end

      # The summarizer tier's provider, resolved through {#provider}'s validated
      # set. Deliberately handed neither the chat's spool nor its channel: an
      # oracle round trip is not a turn, so it belongs in neither the response
      # WAL a replay reads back as turns nor the live stream the frontend paints.
      def summarizer_provider = provider(name: summarizer_name)

      # `--summarizer-model`, defaulting to the SUMMARIZER provider's own
      # default rather than the chat's -- the two tiers are chosen separately,
      # so `--provider anthropic` must not silently name the local tier's model.
      def summarizer_model = @options[:summarizer_model] || default_model(summarizer_name)

      # `--summarizer-max-tokens`. A summary that runs out of ceiling is a
      # truncated summary, and a truncated summary REPLACES the result it
      # compressed, so the knob is worth exposing rather than inheriting the
      # chat's (which is sized for a turn, not for a paragraph).
      #
      # Non-positive is refused rather than measured, mirroring
      # {Compaction::Head#validated} line for line (see {InvalidCeiling} for
      # what stays silent otherwise).
      def summarizer_max_tokens
        ceiling = Integer(knob(:summarizer_max_tokens, Oracle::Model::DEFAULT_MAX_TOKENS))
        raise InvalidCeiling, "--summarizer-max-tokens must be positive, got #{ceiling}" unless ceiling.positive?

        ceiling
      end

      # Where this run's records land. Bound by the first {#pipeline_source}
      # call (the run has exactly one wiring site) and the Null channel until
      # then, so a path that never wires compaction -- bench, `--no-journal` --
      # reads a destination rather than a nil to guard.
      def journal = @journal || Channel::Null.instance

      # `--model` defaults to the SELECTED provider's own default (resolved here,
      # not in the Thor flag, whose default is fixed at load before `--provider`
      # is known). Sampler params ride Request#extra via the Context. The system
      # prompt renders from the loaded {#slots} unless a caller overrides it --
      # bench record's `--system` flag is the one caller that does.
      def context(system_override: nil)
        Context.new(model:, max_tokens: @options[:max_tokens], extra: sampler_extra,
                    system: system_override || slots.render)
      end

      # Which Context THIS turn renders through -- the live compaction source
      # by DEFAULT, since `lain chat` compacts unless `--no-compact` says
      # otherwise, and {Agent::PipelineSource::Null} when it does.
      #
      # MEMOIZED, unlike {#context}, which deliberately answers a fresh value at
      # six call sites. The source is RUN state: {Compaction::Cold} accumulates
      # the cache warmth it has observed and {Oracle::Eager} accumulates the
      # summaries it has fired, so a source rebuilt per call would silently
      # reset both every turn and the `:cold` decision path would never fire.
      # The first call therefore BINDS the journal and the cache profile -- the
      # run has exactly one wiring site ({CompactionMount}), which is where they
      # come from -- and a differing second call raises {Rebound} rather than
      # quietly answering the first binding.
      #
      # @param cache_profile [Lain::CacheProfile] the CHAT provider's own, so
      #   {Compaction::Cold} compares idle time against a TTL that exists (a
      #   TTL-less provider confirms cold off the zero cache-read alone)
      # @param journal [#<<] where the per-turn decision and the cold
      #   confirmation land
      # @raise [Rebound] on a second call with different arguments
      def pipeline_source(cache_profile:, journal: Channel::Null.instance)
        bind_once(:pipeline_source, cache_profile:, journal:)
        @journal = journal
        @pipeline_source ||= if compaction?
                               compaction_source(cache_profile:, journal:)
                             else
                               Agent::PipelineSource::Null
                             end
      end

      # The post-dispatch observer {Agent::ToolRunner} fires eager summaries
      # through. {Effect::Handler::Summarizing::Observer} is the PRODUCTION
      # mount and the {Effect::Handler::Summarizing} decorator is its
      # alternative -- never both against one {Oracle::Eager}, since `#fire`
      # consumes a digest before spawning, so whichever fires first spends it
      # and the other misses that content forever.
      #
      # The Null under `--no-compact`: nothing would ever read a summary, so
      # firing local model calls would be pure waste.
      def tool_observer
        @tool_observer ||= if compaction?
                             Effect::Handler::Summarizing::Observer.new(eager:)
                           else
                             Agent::ToolRunner::Observer::Null.new
                           end
      end

      # The run's ONE summary store, shared by {#tool_observer} (which fires
      # into it) and {#pipeline_source} (which snapshots it per turn). Two
      # instances would mean every fire landed somewhere no render reads.
      def eager = @eager ||= Oracle::Eager.new(oracle: summary_oracle)

      # @return [Boolean] whether this run compacts at all; on unless
      #   `--no-compact` turned it off
      def compaction? = @options.fetch(:compact, true)

      # The loaded prompt slots, memoized -- exposed (not just the rendered
      # String {#context} produces) so a caller can emit ONE Telemetry::SlotFills
      # built from the exact slots this Backend rendered, with no second disk
      # read.
      def slots
        @slots ||= Prompt::Slots.load
      end

      # RES4: the {Tool::SpawnPolicy} for a cataloged {Role}, resolved through
      # {Role::Catalog} rather than hand-assembled at the call site -- the same
      # "one seam decides" shape #provider gives `--provider` and #context
      # gives `--model`. A spawn seam names the ROLE it wants (`:researcher`);
      # the catalog is the one place that name's `only`-set can change, so a
      # role's capability set cannot drift between a spawn site and its
      # definition. An uncataloged name fails loudly as {Role::Catalog::Unknown}
      # (a {Lain::Error}), naming the catalog, exactly as {Role::Catalog.fetch}
      # already does -- there is no separate refusal to keep in sync.
      def spawn_policy(role_name) = Role::Catalog.fetch(role_name).spawn_policy

      private

      # Refuses BEFORE construction: {Provider::AnthropicRaw} validates the key
      # eagerly too, but as {Provider::HTTP::ConfigurationError}, which is not a
      # {Lain::Error} and so reaches the operator as a raw backtrace instead of
      # the exe's clean Thor::Error mapping. Checking here keeps that mapping
      # intact for the one refusal an anthropic chat run can hit before any
      # request goes out.
      def anthropic_provider(spool, channel)
        raise MissingAPIKey, "ANTHROPIC_API_KEY is not set; --provider anthropic needs it to build a client" \
          if ENV["ANTHROPIC_API_KEY"].to_s.empty?

        Provider::AnthropicRaw.new(spool:, channel:)
      end

      # Validated once, so #provider and #default_model both key off a name
      # already known to be in PROVIDERS.
      def provider_name = validated(@options[:provider], "provider")

      def summarizer_name = validated(knob(:summarizer_provider, DEFAULT_SUMMARIZER_PROVIDER), "summarizer provider")

      # `flag` names WHICH flag was wrong: `--provider` and
      # `--summarizer-provider` are two different mistakes to make, and a
      # refusal that named neither would send the operator to the wrong one.
      def validated(name, flag)
        return name if PROVIDERS.include?(name)

        raise UnknownProvider, "unknown #{flag} #{name.inspect}, expected one of #{PROVIDERS.inspect}"
      end

      def default_model(name)
        case name
        when "ollama" then Provider::Ollama::DEFAULT_MODEL
        when "bedrock" then Provider::Bedrock::DEFAULT_MODEL
        else Provider::AnthropicRaw::DEFAULT_MODEL
        end
      end

      # `--model` resolved once, so {#context} and the compaction book agree
      # about which model this run is.
      def model = @options[:model] || default_model(provider_name)

      # The context window is NOT resolved here: the Source derives it from the
      # live Context every turn, so a `/model` switch mid-session moves the
      # threshold with it (see {Compaction::Source#window_for}). What this
      # method still owns is the byte threshold and the priced model.
      def compaction_source(cache_profile:, journal:)
        Compaction::Source.new(
          need: Compaction::Need.new(byte_threshold: knob(:compact_bytes, DEFAULT_BYTE_THRESHOLD)),
          cold: Compaction::Cold.new(cache_profile:, journal:),
          hard_cap: knob(:compact_cap, DEFAULT_HARD_CAP), keep_last: knob(:compact_keep, DEFAULT_KEEP_LAST),
          eager:, journal:, model:, price_book: COMPACTION_PRICES
        )
      end

      # An unset numeric flag arrives as nil; the constant is the authority.
      def knob(flag, default) = @options[flag] || default

      # The binding half of a memoized factory (see {Rebound}). Same arguments
      # are a cache hit and pass silently; different ones name WHICH argument
      # moved, since "it was already built" is exactly the diagnosis a caller
      # cannot make from the wrong Source it would otherwise be handed.
      #
      # Argument CLASSES, never their `#inspect`: a journal is a live sink that
      # may be holding the whole session's events, and a diagnostic that dumps
      # it is a second way to corrupt the record it is complaining about.
      def bind_once(slot, **arguments)
        bound = (@bound ||= {})
        drifted = bound[slot]&.reject { |name, value| arguments.fetch(name) == value }
        raise Rebound, rebound(slot, drifted) unless drifted.nil? || drifted.empty?

        bound[slot] ||= arguments
      end

      def rebound(slot, drifted)
        moved = drifted.map { |name, was| "#{name.to_s.tr("_", " ")} (was a #{was.class})" }.join(", ")
        "#{slot} was already built and is memoized for the run; this call would have changed #{moved}, " \
          "and the first binding is what every turn would keep using"
      end

      # The eager tier ({Oracle::Summarize}), assembled by {Summarizer} out of
      # the summarizer's OWN provider, model and ceiling. It defaults to the
      # local tier and is no longer confined to it: `--summarizer-provider` may
      # point it at a paid model independently of `--provider`, which is why
      # every answer it gives is journalled -- an unrecorded model call is spend
      # the bench cannot see.
      #
      # Construction opens no connection, so an absent ollama still costs
      # nothing here: the fire fails inside {Oracle::Eager}'s task boundary and
      # the compaction renders an elision instead.
      #
      # {Oracle::RoutedSummarizer} goes OUTERMOST, above the journaling wrap
      # {Summarizer} builds: an answer the project's own `.lain/summarizers.rb`
      # produced cost no tokens, so it must not land on the record as a model
      # call, while a fallthrough still journals exactly once from inside.
      #
      # `Summarizer` here is {Backend::Summarizer} -- the flag resolution --
      # and `Lain::Summarizer` is the project's declared free tier. Two
      # different objects one lexical scope apart, hence the explicit root.
      def summary_oracle
        Oracle::RoutedSummarizer.new(inner: Summarizer.new(backend: self).oracle,
                                     catalog: Lain::Summarizer::Catalog.load)
      end

      # Only the sampler flags the caller actually set, String-keyed to match
      # Request's normalized `extra` and Ollama's `options`. `unless value.nil?`
      # (not `if value`) so `--temperature 0` -- the determinism recipe -- is kept.
      def sampler_extra
        %i[temperature seed].each_with_object({}) do |key, extra|
          value = @options[key]
          extra[key.to_s] = value unless value.nil?
        end
      end
    end
  end
end
