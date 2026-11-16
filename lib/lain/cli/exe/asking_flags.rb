# frozen_string_literal: true

module Lain
  module CLI
    module Exe
      # WHAT this chat is asked, and whether anyone is there to be asked back --
      # two flags naming one idea, so a declarer of their own on {SurfaceFlags}'
      # rule (the second one pushed the Thor class past Metrics/ClassLength, and
      # the rule is extract, never loosen).
      #
      # They are ORTHOGONAL and the pairing is not a coupling: `--prompt` alone
      # seeds a chat that then reads the terminal exactly as an unseeded one does,
      # which is what the `/btw` child is built on, and its exit status is
      # deliberately unchanged. `--non-interactive` is what says nobody will type
      # the next line -- so it NEEDS a seeded question ({CLI::ChatLaunch} refuses
      # the pair up front) and, having no human, it denies every gated call,
      # refuses `ask_human` by name, and finally makes the process exit status mean
      # something.
      module AskingFlags
        # The description is data, not computation, and hoisting it out of the
        # method is what keeps the paragraph an operator needs from arguing with
        # Metrics/MethodLength -- {Lain::Tools::AskHuman::DESCRIPTION}'s idiom, for
        # the same reason.
        HEADLESS = "Run --prompt's question and stop, reading nothing from the terminal: a gated tool call the " \
                   "rules leave open is refused under ask, decided by the judge under auto (a call it is unsure " \
                   "of is refused), and approved under bypass; ask_human refuses by name (no human is attached), a " \
                   "request that would cross its model's price tier is refused unless --confirm-price-tier allow, " \
                   "and the process exits non-zero when a turn could not finish. Needs --prompt. Run it " \
                   "DIRECTLY, not through `lain up` -- that puts the chat in a tmux pane whose exit status " \
                   "nothing reads, which is the whole of what this flag adds"

        # @param thor [Class] the Thor class to declare on
        # @return [void]
        def self.declare(thor)
          thor.method_option :prompt, type: :string,
                                      desc: "Seed the first question (the /btw child's side-question); the chat " \
                                            "then reads the terminal as usual"
          thor.method_option :non_interactive, type: :boolean, default: false, desc: HEADLESS
          thor.method_option :approval, type: :string, default: "auto", enum: %w[ask auto bypass],
                                        desc: "Who decides a gated call the rules left open: ask parks it for " \
                                              "a human, auto asks a model judge first, bypass approves it"
          thor.method_option :max_cost, type: :numeric, banner: "DOLLARS",
                                        desc: "Stop the run once its priced turns, children included, have cost this " \
                                              "many dollars; a model with no price counts nothing against it"
        end
      end
    end
  end
end
