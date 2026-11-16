# frozen_string_literal: true

module Lain
  module CLI
    module Exe
      # The compaction band of `chat`'s flag surface: whether to compact at all, the
      # three byte knobs, what happens when no cut can make room, and the summarizer
      # TIER. Its own module because it is its own question -- "how does this run
      # manage a growing history", answered by eight flags that only make sense read
      # together, and `lain help chat` is where an operator meets them as a group.
      #
      # It stays in the exe rather than lib/ for a hard reason: the library does not
      # depend on Thor, and a lib object calling `method_option` would make it.
      #
      # Every default names its authority in lib -- Backend's constants, the oracle's
      # ceiling -- rather than restating a number, so `lain help chat` and the wiring
      # cannot come to disagree about what an unset flag means.
      #
      # The five --compact-* flags below carry NO Thor `default:`, and that is
      # load-bearing: Thor would materialize the key, so an unset flag could not be
      # told from a typed one and a resume could never inherit the recorded arm.
      # Unset reaches {Lain::CLI::Backend} as nil, and its constants answer.
      module CompactionFlags
        INHERITED = "a resumed or forked chat inherits what the session recorded"

        # Thor's `method_option` accumulates onto the command declared NEXT, so this
        # runs from the class body where the band belongs: after chat's other flags,
        # before `def chat`.
        def self.declare(thor)
          history(thor)
          fallback(thor)
          schedule(thor)
          strategy(thor)
          pipeline(thor)
          summarizer(thor)
        end

        # No Thor default: an untyped run still compacts, but only a typed value may override what a resume recorded.
        def self.history(thor)
          thor.method_option :compact, type: :boolean,
                                       desc: "Summarize the history's head as it grows; --no-compact opts out"
          thor.method_option :compact_bytes, type: :numeric,
                                             desc: "Droppable-head bytes above which a compaction is warranted " \
                                                   "(default #{Backend::DEFAULT_BYTE_THRESHOLD}; #{INHERITED})"
          thor.method_option :compact_trigger, type: :string, enum: Lain::CLI::CompactionProfile::TRIGGERS,
                                               desc: "Count only the droppable head (default) or the whole request " \
                                                     "against --compact-bytes (#{INHERITED})"
          thor.method_option :compact_cap, type: :numeric,
                                           desc: "History bytes that force a compaction even while the cache is warm " \
                                                 "(default #{Backend::DEFAULT_HARD_CAP}; #{INHERITED})"
          thor.method_option :compact_keep, type: :numeric,
                                            desc: "Trailing messages a compaction leaves verbatim " \
                                                  "(default #{Backend::DEFAULT_KEEP_LAST}; #{INHERITED})"
        end

        # What happens when no cut can make room, apart from {#history} only to
        # keep each method to one band of knobs.
        def self.fallback(thor)
          thor.method_option :compact_fallback, type: :string,
                                                desc: "What happens when no cut can make room " \
                                                      "(#{Backend::COMPACT_FALLBACKS.join(", ")}): handoff replaces " \
                                                      "the history before the current ask with one state document " \
                                                      "and answers the ask, after a refusal; early-handoff does the " \
                                                      "same at a clean break past half the window, before one; " \
                                                      "none lets the refusal stand " \
                                                      "(default #{Backend::DEFAULT_COMPACT_FALLBACK}; #{INHERITED})"
        end

        # NO `default:`, for the strategy flag's reason below: an unset schedule
        # must reach {Lain::CLI::CompactionProfile} as nil so a resume inherits it.
        def self.schedule(thor)
          profile = Lain::CLI::CompactionProfile
          thor.method_option :compact_schedule, type: :string,
                                                desc: "When a compaction runs (#{profile::SCHEDULES.join(", ")}): " \
                                                      "idle prepares the cut while the human is away, turn " \
                                                      "compacts at the next ask " \
                                                      "(default #{profile::DEFAULT_SCHEDULE}; #{INHERITED})"
        end

        # HOW a compacted span collapses, its own method for the same reason
        # {#history} and {#summarizer} already are one each: three questions that
        # only make sense read on their own. Names
        # {Lain::CLI::CompactionStrategy::STRATEGIES} rather than restating the
        # set, the rule the compact knobs and `--isolation` both follow: the
        # flag's help text and the resolver cannot come to disagree about what a
        # strategy name means.
        # NO `default:`, and that is load-bearing rather than an omission.
        # {Lain::CLI::CompactionStrategy}'s own header says the fallback is that
        # class's DEFAULT constant and "not a Thor default" -- and a Thor default
        # here does not merely duplicate it, it makes the flag's OFF STATE
        # unreachable: Thor materializes the key, so `options[:compact_strategy]`
        # is never nil in a real run, and {Lain::CLI::Backend::SpanSummarizer}'s
        # "no flag named a strategy" branch becomes dead code from the CLI. The
        # eager tier -- the control arm every `--compact-strategy` run is measured
        # against -- would then be selectable only from an options Hash the
        # executable cannot produce. Unset must reach the reader as nil.
        def self.strategy(thor)
          thor.method_option :compact_strategy, type: :string,
                                                desc: "How a compacted span collapses " \
                                                      "(#{Lain::CLI::CompactionStrategy::STRATEGIES.join(", ")}; " \
                                                      "unset keeps the eager tool-result tier; #{INHERITED})"
          thor.method_option :compact_provenance, type: :string, enum: %w[on off],
                                                  desc: "Check a summary's claims about the user against the " \
                                                        "user's own turns (needs --compact-strategy; #{INHERITED})"
        end

        # Beside `--compact-strategy` because it is the other render-strategy arm,
        # and with NO `default:` for that flag's reason above: a Thor default
        # materializes the key, so the unset arm -- the Context every recorded
        # session already renders under, whose header names no pipeline -- could
        # never reach {Lain::CLI::ContextPipeline.named} as nil. Names
        # {Lain::CLI::ContextPipeline::PIPELINES} rather than restating the set.
        def self.pipeline(thor)
          thor.method_option :context_pipeline, type: :string,
                                                desc: "Which context pipeline renders each request " \
                                                      "(#{Lain::CLI::ContextPipeline::PIPELINES.keys.join(", ")}, " \
                                                      "or several joined by +, applied left to right). A word " \
                                                      "REPLACES the default: prune alone sends no reminders and " \
                                                      "no cache breakpoints, prune+default keeps both. Unset " \
                                                      "renders the default and records no name"
        end

        # A TIER, chosen independently of the chat model: a frontier chat can
        # summarize locally for free, and a local chat can buy better summaries.
        # Ahead of both sits the deterministic tier of `.lain/summarizers.rb`, which
        # costs no tokens and takes no flag -- these three only decide what handles
        # what it declines.
        #
        # --summarizer-model carries no Thor default on purpose: like --model it
        # resolves to the SELECTED provider's own default, which is not knowable
        # until --summarizer-provider is parsed.
        # Split on {ModelFlags}' own rule: WHICH endpoint summarizes, then how big
        # a summary it may write.
        def self.summarizer(thor)
          summarizer_endpoint(thor)
          summarizer_budget(thor)
        end

        def self.summarizer_endpoint(thor)
          thor.method_option :summarizer_provider, type: :string,
                                                   desc: "Provider for the compaction summarizer; defaults to " \
                                                         "--provider: #{Lain::CLI::Backend::PROVIDERS.join(", ")}"
          thor.method_option :summarizer_model, type: :string,
                                                desc: "Model id for the compaction summarizer; defaults to the " \
                                                      "chat's --model when both tiers name one provider, else to " \
                                                      "the summarizer provider's own default"
        end

        def self.summarizer_budget(thor)
          thor.method_option :summarizer_max_tokens, type: :numeric,
                                                     default: Lain::Oracle::Model::DEFAULT_MAX_TOKENS,
                                                     desc: "max_tokens per summary; a truncated summary REPLACES the " \
                                                           "result it compressed, so this is sized for a paragraph"
        end
      end
    end
  end
end
