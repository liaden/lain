# frozen_string_literal: true

module Lain
  module CLI
    module Exe
      # WHO answers a turn, and how it samples: the provider, its endpoint, the
      # model, the token ceiling, the two sampler knobs that ride `Request#extra`,
      # and the two ollama runner knobs. Its own module on {CompactionFlags}' rule
      # -- one question, flags that only make sense read together, and one object in
      # lib that already owns the whole resolution ({Lain::CLI::Backend}), so this
      # band and that object have the same boundary.
      #
      # ONE band for every command that asks a model -- chat, `bench record`,
      # `bench arms`, `epic submit`, `consolidate` and `improve` -- declared above
      # the subcommand classes so each of them can reach it. A command that read
      # its own subset of these dropped the rest in silence: `bench arms` never
      # sent LAIN_NUM_BATCH, and every one of its requests reloaded a runner the
      # chat beside it had just loaded.
      #
      # Thor accumulates `method_option` onto the command declared NEXT, so each
      # `.declare` sits immediately above the command it belongs to.
      module ModelFlags
        # The rule a chat's profile flags state: an untyped one takes what the
        # resumed or forked session's header recorded, ahead of the environment.
        RECORDED = "a resumed or forked chat defaults to what its session recorded"

        # The same rule for a pass over a recorded session.
        REVIEWED = "defaults to what the session under review recorded"

        # WHICH endpoint answers, HOW it samples, the runner it keys, and how long
        # that runner stays loaded: one question per method.
        #
        # @param thor [Class] the Thor class the flags accumulate onto
        # @param max_tokens [Integer, nil] this command's default ceiling; nil takes the model's own
        # @param ceiling [String, nil] why this command's ceiling is the one it is
        # @param recorded [String, nil] where an untyped profile flag's default comes
        #   from before the environment, for a command that reads one
        def self.declare(thor, max_tokens: nil, ceiling: nil, recorded: nil)
          endpoint(thor, recorded)
          sampling(thor, max_tokens, ceiling)
          throughput(thor, recorded)
          residency(thor)
          reasoning(thor)
          price_tier(thor)
          effort(thor)
        end

        def self.effort(thor)
          thor.method_option :effort, type: :string, enum: %w[low medium high xhigh max],
                                      desc: "Effort sent as output_config.effort (Anthropic); unset sends none " \
                                            "and the model's own default applies"
        end

        # Every command that builds a Backend can reach an Anthropic client, so
        # each one says what happens at a price tier. Only chat can ask.
        def self.price_tier(thor)
          thor.method_option :confirm_price_tier, type: :string, enum: %w[ask allow refuse], default: "ask",
                                                  desc: "Before a request crosses its model's prompt-size price " \
                                                        "tier: ask the human, allow, or refuse. Where no human " \
                                                        "is attached, ask refuses"
        end

        # The six {Lain::CLI::RunProfile} flags carry NO Thor `default:`. A default
        # makes a typed `--provider anthropic` and silence the same parse, and a
        # resumed or forked chat must know which fields the human typed before it
        # lets the recorded profile answer the rest. {profile} supplies the
        # environment's answer instead, under the same variable names, so a
        # project still pins its endpoint in a direnv `.envrc`.
        # See EnvDefaults for what is deliberately NOT env-configurable, and why.
        def self.endpoint(thor, recorded)
          thor.method_option :provider, type: :string,
                                        desc: "Model provider: #{Lain::CLI::Backend::PROVIDERS.join(", ")} " \
                                              "#{help("$LAIN_PROVIDER, else #{Lain::CLI::RunProfile::DEFAULT_PROVIDER}",
                                                      recorded)}"
          thor.method_option :api_base, type: :string,
                                        desc: "Override the Ollama API base (ollama arms only; https " \
                                              "required on ollama-cloud) #{help("$LAIN_API_BASE", recorded)}"
          thor.method_option :model, type: :string,
                                     desc: "Model id; defaults to the selected provider's own default when unset " \
                                           "#{help("$LAIN_MODEL", recorded)}"
        end

        # The run's profile: what was typed, then the environment, then the
        # built-in provider. A resumed or forked chat, and a pass over a recorded
        # session, lays this over the profile that session recorded, which is why
        # the typed fields travel with it.
        #
        # @param options [Hash] Thor's parse of a command declaring this band
        # @option options [String] :provider the model provider
        # @option options [String] :model the model id
        # @option options [String] :api_base the provider endpoint
        # @option options [Integer] :num_ctx the ollama context length
        # @option options [Integer] :num_batch the ollama prompt batch size
        # @option options [String] :keep_alive how long ollama keeps the runner loaded
        # @option options [String] :effort the reasoning effort
        # @return [Lain::CLI::RunProfile]
        def self.profile(options)
          Lain::CLI::RunProfile.from_options(options).with_defaults(
            provider: Lain::CLI::EnvDefaults.string("LAIN_PROVIDER", Lain::CLI::RunProfile::DEFAULT_PROVIDER),
            api_base: Lain::CLI::EnvDefaults.string("LAIN_API_BASE"),
            model: Lain::CLI::EnvDefaults.string("LAIN_MODEL"),
            num_ctx: Lain::CLI::EnvDefaults.numeric("LAIN_NUM_CTX"),
            num_batch: Lain::CLI::EnvDefaults.numeric("LAIN_NUM_BATCH")
          )
        end

        def self.sampling(thor, max_tokens, ceiling)
          thor.method_option :max_tokens, type: :numeric, default: max_tokens,
                                          desc: "max_tokens per model turn#{"; #{ceiling}" if ceiling} " \
                                                "[default #{max_tokens || "the model's own ceiling"}]"
          thor.method_option :temperature, type: :numeric,
                                           desc: "Sampler temperature, threaded into Request#extra (ollama honors it)"
          thor.method_option :seed, type: :numeric,
                                    desc: "Sampler seed, threaded into Request#extra (ollama honors it)"
        end

        # Both are profile flags, so neither has a Thor `default:` ({endpoint}
        # says why), and {profile} reads their variables. The property that
        # reading must hold: they RESOLVE TO nil when the variable is unset.
        # {Lain::CLI::Backend}'s sampler loop keeps `num_ctx` only when its value
        # is non-nil, so an unset `--num-ctx`/`LAIN_NUM_CTX` still leaves the
        # payload byte-identical. `num_batch` no longer holds that property, on
        # purpose: {Lain::CLI::Backend::DEFAULT_NUM_BATCH} fills it in at 2048
        # when this resolves to nil, because ollama's own server default costs
        # prefill time measurably and nothing should have to opt into not paying
        # it. `backend_spec.rb`'s and `cli_spec.rb`'s num_ctx-only no-options
        # examples are what fail if `num_ctx`'s half stops holding.
        def self.throughput(thor, recorded)
          thor.method_option :num_batch, type: :numeric,
                                         desc: "Ollama prompt batch size; ollama's own default of 512 costs ~1.31x " \
                                               "prefill on this box, 2048 is the measured setting. A local-SERVER " \
                                               "knob: it is sent on ollama-cloud too, where its effect is " \
                                               "unmeasured #{help("$LAIN_NUM_BATCH", recorded)}"
          thor.method_option :num_ctx, type: :numeric,
                                       desc: "Ollama context length for the request; unset serves the model's own. " \
                                             "A local-SERVER knob: it is sent on ollama-cloud too, where its effect " \
                                             "is unmeasured; a value above the model's trained maximum is " \
                                             "refused there as well #{help("$LAIN_NUM_CTX", recorded)}"
        end

        # Residency rather than throughput: how long ollama keeps the runner loaded
        # once it has answered, which changes nothing about the answer. A profile
        # flag on {endpoint}'s rule, so no Thor `default:` -- and the only RUNNER
        # knob whose value is not a number, since `-1`, `0` and `5m` are one knob
        # with two JSON types ({Lain::CLI::Backend} sorts out which).
        #
        # It takes no `recorded`: it is the one profile flag a resumed or forked
        # chat does NOT inherit, because a pin is server state that outlives the
        # process and re-pinning with no flag typed is not a default anyone chose.
        # {Lain::CLI::RunProfile::HEADER_FIELDS} excludes it for that reason, and
        # `cli_spec` fails if this help line claims otherwise.
        def self.residency(thor)
          thor.method_option :keep_alive, type: :string,
                                          desc: "How long ollama keeps the model loaded after a turn: -1 pins it " \
                                                "resident, 0 releases it as soon as the turn is answered, otherwise " \
                                                "a duration such as 5m or 90s. Unset leaves ollama's own 5m timer " \
                                                "alone. A 30B reload costs 16-20s and discards the prefix cache with " \
                                                "it. The pin OUTLIVES this process -- the model stays resident after " \
                                                "lain exits until `ollama stop` releases it -- and a resumed or " \
                                                "forked chat does not inherit it. A local-SERVER knob: it is sent on " \
                                                "ollama-cloud too, where its effect is unmeasured"
        end

        # Checked against the model's own `/api/show` list at launch, so no Thor
        # `default:` or `enum:` names levels here; unset leaves the project's `think`.
        def self.reasoning(thor)
          thor.method_option :think, type: :string,
                                     desc: "Reasoning level to send, such as low or high; refused at launch unless " \
                                           "the model lists it. Unset uses the config.rb `think`, else the model's own"
        end

        # A flag's defaults, in the order they answer.
        def self.help(variable, recorded) = "[#{[variable, recorded].compact.join("; ")}]"
      end
    end
  end
end
