# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/introspect`: what this run knows about ITSELF, read off the run's own
      # live collaborators -- the human-facing half of the pair whose
      # model-facing half is {Lain::Tools::SessionUsage}.
      #
      # It exists because of a real failure: asked for its own session usage,
      # the agent invented a metrics table -- a model it was not running, plus
      # fabricated memory, CPU, round-trip and network figures -- while eight
      # `turn_usage` records carrying the true answer sat in the journal it had
      # just written. The defect was REACHABILITY: nothing could answer the
      # question, so it was answered from nowhere.
      #
      # A CONFIDENT FALSE NEGATIVE is that same fabrication with better manners:
      # "review none open" told to a human who is annotating one does the same
      # damage and is harder to catch, because a plausible number reads as a
      # measured one. So every row is written to be true of the run it
      # describes, and what this command cannot see is NAMED under `unreported`
      # rather than left out.
      #
      # No dollars: {Lain::Ledger} raises rather than pricing a model it has no
      # {Lain::PriceBook} entry for, and the ollama-cloud arm has no entry at
      # all -- so a cost would be guessed for exactly the runs a human is most
      # likely to ask about.
      #
      # The three it cannot see, each named rather than closed:
      #
      # * WHICH PROVIDER is serving the run -- {CLI::Backend#provider_name} is
      #   the only authority, and no command reaches a Backend.
      # * HOW LARGE the window is, and whether that size was published, probed
      #   or guessed. The run's one book is private to {Agent}, {StatusFeed} and
      #   {Compaction::Source}, which expose only `#occupancy`; resolving one
      #   here would be a SECOND book, the drift `Backend#context_window`'s memo
      #   exists to prevent. A window WAS resolved -- it is the occupancy row's
      #   denominator -- so nothing here implies none exists.
      # * A CHANGESET REVIEW THE AGENT OPENED FOR ITSELF. The outbox holds only
      #   what `/review` and `/survey` put in it, while {Tools::RequestReview}
      #   binds a session of its own straight to the editor, so an unqualified
      #   "none open" would be a false negative told to a human mid-annotation.
      #   The authority both rails bind, `bind_changeset_review`, is private to
      #   {CLI::HumanReplies} with no reader -- unreachable from a command.
      class Introspect
        # The one line that keeps a true number from being read as a false one.
        SPEND = "this run's own token spend -- not a plan or subscription quota, and never dollars"
        # Two bounds, because the totals are wrong in two directions if either is
        # missed: {Lain::Agent::Accounting} starts fresh over a Timeline that
        # does not, and it sums every model the run called.
        SCOPE = "this run only -- a --resume starts a fresh ledger, so spend before it is not counted " \
                "here; the totals cover every model this run called, not just the one named above"
        # ABSENCE, scoped to the run that can claim it: a resumed chat's
        # Accounting is fresh while its Timeline is not, so an unqualified "no
        # turn yet" is false about turns that are sitting right there.
        NO_TURN = "no turn yet in this run"

        # AS OF, not as of now: {Lain::Agent::Accounting#last_turn_usage} is
        # written only by `#observe`, so a `/rewind` that drops the turn this
        # measured leaves the reading where it stood. It names its denominator
        # so the two rows cannot be read as being about different windows.
        AS_OF = "%.1f%% at the last model response, of a window whose size is unreported below"

        # What the outbox can actually vouch for, named. See the class doc: an
        # unqualified "none open" is a false negative for an agent-opened round.
        NO_REVIEW = "none held by /review or /survey"

        # {CLI::Chronicle::Null} is what `--no-journal` wires AND what a
        # directly-constructed {CLI::ChatLaunch} defaults to, so naming the flag
        # would tell a bench arm a flag was passed that never was. The absence is
        # the part that cannot be wrong.
        NO_JOURNAL = "no journal is being written for this run"

        # {Lain::Usage#cache_hit_ratio} answers 0.0 when NOTHING was billed on
        # the way in, which is absence wearing a number -- and a hard 0.0% on the
        # bench's first-class cache metric invites the wrong conclusion about a
        # chat that has not spoken yet.
        NO_CACHE_READS = "nothing billed on the way in yet"

        # The gaps, in the vocabulary of the question a human is asking at
        # `you>`: naming a `Backend`, a `book` or an `Env` here would read as a
        # bug report about objects with no referent in front of them.
        UNREPORTED = "what this report cannot see -- missing from the report, not from the run"
        UNSEEN = {
          "provider" => "which provider is answering, and where it is running",
          "window" => "how large this run's context window is, and whether that size was measured or assumed",
          "reviews" => "a review the agent opened for itself -- only rounds from /review and /survey show above"
        }.freeze

        # @param outbox [Review::Submit::Outbox] the run's ONE open changeset
        #   review, shared with `/review`, `/survey` and `/review-submit`. A
        #   second outbox would report no review held while the human is looking
        #   at one.
        def initialize(outbox:)
          @outbox = outbox
          freeze
        end

        def name = "introspect"

        def usage = "/introspect -- this run's model, occupancy, token spend, review and journal"

        # A {Lain::Renderable}, not a String -- every label names `:label` so
        # the figures beside them read as content rather than as one flat colour.
        def call(_args, env)
          rows(env).inject(Lain::Renderable.new.with(:label, "introspect:")) do |rendered, (label, value)|
            rendered.plain("\n").with(:label, "  #{label} ").plain(value.to_s)
          end
        end

        private

        # The whole report as data, so {#call} owns rendering and nothing else.
        # The caveats are ROWS rather than a footnote: a figure and the sentence
        # bounding it must not be separable by a reader skimming for the number.
        def rows(env)
          [["model", env.model_switch.current], ["occupancy", occupancy(env.agent)],
           *review_rows, ["journal", env.journal_path || NO_JOURNAL], ["tokens", SPEND],
           *counts(env.agent.usage), ["scope", SCOPE], ["unreported", UNREPORTED], *unseen]
        end

        def unseen = UNSEEN.map { |label, sentence| ["  #{label}", sentence] }

        # One row with nothing held, two with a round open: the count is its own
        # labelled figure because it is the one number here a human might act on,
        # and because "3 annotations" would have to say "1 annotations" on the
        # round that most often exists.
        def review_rows
          return [["review", NO_REVIEW]] unless @outbox.open?

          [["review", "open over #{@outbox.target} (#{@outbox.held_source})"],
           ["  annotations", @outbox.annotation_count]]
        end

        # {Lain::Usage}'s own declaration order, then its two totals, then the
        # ratio -- read OFF the value rather than transcribed here, so a field
        # added to Usage cannot go unreported while SessionUsage names it.
        def counts(usage)
          usage.to_h.map { |field, count| ["  #{count_label(field)}", count] } +
            [["  total input", usage.total_input_tokens], ["  total", usage.total_tokens],
             ["  cache hit ratio", hit_ratio(usage)]]
        end

        def count_label(field) = field.to_s.delete_suffix("_input_tokens").delete_suffix("_tokens").tr("_", " ")

        def hit_ratio(usage)
          return NO_CACHE_READS if usage.total_input_tokens.zero?

          format("%.1f%%", usage.cache_hit_ratio * 100)
        end

        # The AGENT's own derivation, against the book the run measures against
        # everywhere else -- never a second book resolved here.
        def occupancy(agent)
          ratio = agent.occupancy
          ratio.nil? ? NO_TURN : format(AS_OF, ratio * 100)
        end
      end
    end
  end
end
