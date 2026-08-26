# frozen_string_literal: true

# The human-facing half. Asked what the session had spent, the agent
# invented a metrics table -- a model name it was not running, plus fabricated
# memory, CPU, round-trip and network figures -- while eight `turn_usage`
# records carrying the true answer sat in the journal it had just written.
# {Lain::Tools::SessionUsage} made that answer reachable to the MODEL; this
# command makes it reachable to the human at the prompt, off the same live
# collaborators, so neither side has to guess.
#
# Every example drives a REAL {Lain::Agent} over a scripted provider, because
# the claim is about what the run accrued: stubbing `#usage` or `#occupancy`
# would assert that this command formats whatever it is handed, and nothing
# about the seam that made the honest answer possible.
#
# == The honesty examples are the point of the file
#
# A confident FALSE NEGATIVE wears better manners: "review none open" told to
# a human who is annotating one, or a percentage over a denominator nobody
# vouched for, are the same defect as an invented metrics table. Every example
# below the `cannot know` banner came from a review probe that caught this
# command stating something it could not know, and each pins the qualification
# that made the statement true.
RSpec.describe Lain::CLI::Command::Introspect do
  let(:model) { "test-model" }
  # A small window, so an occupancy reads as a figure a human could check by
  # hand rather than as a rounding artefact against a million-token book.
  let(:book) { Lain::ContextWindow.new(windows: { model => 1_000 }, fallback: nil) }
  let(:outbox) { Lain::Review::Submit::Outbox.new }
  let(:command) { described_class.new(outbox:) }
  let(:fresh) { agent_over }
  let(:asked_twice) do
    agent_over(usage_response("one", input_tokens: 10, output_tokens: 5,
                                     cache_creation_input_tokens: 3, cache_read_input_tokens: 40),
               usage_response("two", input_tokens: 3, output_tokens: 2,
                                     cache_creation_input_tokens: 1, cache_read_input_tokens: 60))
      .tap do |agent|
        agent.ask("first")
        agent.ask("second")
      end
  end

  def agent_over(*responses, book: self.book, timeline: nil, model: self.model)
    Lain::Agent.new(provider: Lain::Provider::Mock.new(responses:), timeline:,
                    toolset: Lain::Toolset.new([]), context_window: book,
                    context: Lain::Context.new(model:, max_tokens: 64))
  end

  def usage_response(text, model: self.model, **fields)
    Lain::Response.new(content: [{ "type" => "text", "text" => text }],
                       stop_reason: :end_turn, model:, usage: Lain::Usage.new(**fields))
  end

  def env_for(agent, chronicle: Lain::CLI::Chronicle::Null.new, model_name: model)
    build_command_env(agent:, chronicle:,
                      model_switch: instance_double(Lain::Context::ModelSwitch, current: model_name))
  end

  def report(agent, **) = command.call("", env_for(agent, **)).text

  # ---- Scenario: introspect reports the session's real usage -----------------

  it "names the model actually in force, read from the slot /model writes" do
    expect(report(fresh)).to include("model test-model")
  end

  it "reports the cumulative token totals the Agent's own Accounting summed" do
    expect(report(asked_twice))
      .to include("input 13", "output 7", "cache creation 4", "cache read 100")
  end

  # Reported rather than left for the reader to add up: an arithmetic step
  # somebody takes is an arithmetic step somebody can get wrong, which is the
  # same fabrication in miniature.
  it "reports the totals Usage derives, and the bench's cache hit ratio" do
    expect(report(asked_twice)).to include("total input 117", "total 124", "cache hit ratio 85.5%")
  end

  # Against the run's OWN book -- the one the Agent was constructed with, never
  # a second one built here. 64 of 1,000 is the last turn's billed-on-the-way-in
  # tokens, which is what occupancy means.
  it "reports occupancy against the window the run itself measures against" do
    expect(report(asked_twice)).to include("occupancy 6.4%")
  end

  # ---- Scenario: introspect is honest about what it cannot know -------------

  it "labels the token figure as this run's own spend, never a plan or subscription quota" do
    rendered = report(asked_twice)

    expect(rendered).to include("this run")
    expect(rendered).to match(/not a plan or subscription quota/i)
  end

  # {Lain::Ledger} raises rather than pricing a model it has no {Lain::PriceBook}
  # entry for, and the ollama-cloud arm has no entry at all -- so a dollar
  # figure here would have to be guessed for exactly the runs a human is most
  # likely to ask about. That is the same fabrication with better manners.
  #
  # What this forbids is a FIGURE, not the word: the report says "never dollars"
  # out loud, and that sentence is the lever keeping a reader from reaching for
  # one -- a currency-shaped number is the half that could be wrong.
  it "names no dollar figure anywhere, and says out loud that it will not" do
    rendered = report(asked_twice)

    expect(rendered).not_to match(/\$\s*[\d.]|[\d.]+\s*(?:USD|dollars|cents)/i)
    expect(rendered).to include("never dollars")
  end

  # {Lain::Agent::Accounting} starts at zero while a resumed Timeline does not,
  # so the report says out loud that this is not lifetime spend.
  it "says out loud that a resumed session's earlier spend is not counted" do
    expect(report(asked_twice)).to include("--resume")
  end

  # PROBE 7. `model` is the slot `/model` WRITES; the token table is the monoid
  # sum over every response, the previous model's included. A run that switched
  # models mid-session would otherwise report the new model's name directly over
  # the old model's spend, with nothing saying so.
  it "says the totals cover every model this run called, not just the one named" do
    agent = agent_over(usage_response("one", model: "old-model", input_tokens: 100, output_tokens: 10))
    agent.ask("first")

    rendered = report(agent, model_name: "new-model")

    expect(rendered).to include("model new-model", "input 100")
    expect(rendered).to include("every model this run called")
  end

  # THE OTHER HALF OF HONESTY. The provider, the window's SIZE and its
  # provenance, and an agent-opened review are not reachable from a command, so
  # each is NAMED as something this report cannot see -- a reader who sees no
  # window size must be told none is reported, not left to assume none exists.
  it "lists what it cannot see, rather than leaving the gaps to be inferred" do
    rendered = report(asked_twice)

    expect(rendered).to include("unreported")
    expect(rendered).to include("which provider is answering")
    expect(rendered).to include("how large this run's context window is")
    expect(rendered).not_to match(/anthropic|ollama|bedrock/i)
    expect(rendered).not_to match(/window \d|\bpublished\b|\bprobed\b/i)
  end

  # The sentences are for a human at a prompt, not for the implementer:
  # `Backend`, `book` and "reaches no command" have no referent at `you>` and
  # read as a bug report nobody asked for.
  it "explains its gaps in the reader's vocabulary, not the harness's" do
    expect(report(asked_twice)).not_to match(/Backend|second book|reaches no command|Env\b/)
  end

  # ---- PROBE 2: the occupancy denominator may itself be a guess --------------
  #
  # The percentage is correct arithmetic over a window the run's own book
  # resolved -- and that book's answer can be {Lain::ContextWindow::GUESSED},
  # the conservative floor. So the occupancy row points at the same window the
  # `unreported` block describes, and nothing says a window "would be" a guess
  # while a guess is already the denominator.
  it "points its occupancy at the same window it says is unreported" do
    guessy = Lain::ContextWindow.new(windows: {}, fallback: 8_192)
    # Assert the premise rather than assume it: this example is only about
    # anything if the book really answers GUESSED for an unknown model.
    expect(guessy.resolve("mystery-model").provenance).to eq(Lain::ContextWindow::GUESSED)
    agent = agent_over(usage_response("one", model: "mystery-model", input_tokens: 4_096, output_tokens: 5),
                       book: guessy, model: "mystery-model")
    agent.ask("first")

    rendered = report(agent, model_name: "mystery-model")

    expect(rendered).to include("occupancy 50.0%")
    expect(rendered).to include("of a window whose size is unreported below")
    expect(rendered).not_to include("would be a second book's guess")
  end

  # ---- PROBE 3: occupancy is as-of the last response, not as-of now ----------
  #
  # {Lain::Agent::Accounting#last_turn_usage} is written only by `#observe`, so a
  # `/rewind` that drops the turn it measured leaves the reading where it was.
  # The row therefore says WHEN it was taken instead of implying "right now".
  it "stamps occupancy with the response it was taken at, so a rewind cannot make it lie" do
    agent = agent_over(usage_response("one", input_tokens: 640, output_tokens: 5))
    agent.ask("first")
    agent.rewind(2)

    expect(report(agent)).to include("occupancy 64.0% at the last model response")
  end

  # ---- PROBE 1: "no turn yet" is false on a resumed chat ---------------------
  #
  # {Lain::ContextWindow::Occupancy::None}'s own docstring names this hazard for
  # the value 0.0 -- "a resumed session's Accounting is fresh while its Timeline
  # is not" -- and unqualified prose reproduces it in words, because it makes a
  # claim ABOUT TURNS while the turns sit on the Timeline the Env already reaches.
  it "scopes the no-turn reading to THIS run, on a resumed chat whose timeline holds turns" do
    seeded = agent_over(usage_response("one", input_tokens: 500, output_tokens: 5),
                        usage_response("two", input_tokens: 600, output_tokens: 5))
    seeded.ask("first")
    seeded.ask("second")
    resumed = agent_over(timeline: seeded.timeline)

    expect(resumed.timeline.length).to be >= 4
    expect(report(resumed)).to include("occupancy no turn yet in this run")
  end

  # ---- Scenario: introspect reports review state ----------------------------

  # A REAL {Lain::Review::Submit::Outbox}, because the claim is about the round
  # `/review` and `/survey` actually opened: the session is doubled (a round is
  # minutes of editor work to build), the holder is not. The count's behaviour
  # over a REAL collection is pinned in `outbox_spec.rb`.
  def hold_round(annotations)
    outbox.hold(session: instance_double(Lain::Review::Session, source: "corpus", annotations:),
                number: nil, label: "survey planning/qa")
  end

  it "reports the open review, naming what it was opened over and its source" do
    hold_round([])

    expect(report(fresh)).to include("review open over survey planning/qa (corpus)")
  end

  # What motivated {Lain::Review::Submit::Outbox#annotation_count}:
  # "a review is open" is the cheap part, and "how many notes are in it" is the
  # number a human decides on.
  it "reports how many annotations the open round holds" do
    hold_round(Array.new(3) { instance_double(Lain::Review::AnnotationPlaced) })

    expect(report(fresh)).to include("annotations 3")
  end

  # Zero notes is a REAL round, not an absent one -- a human who has opened a
  # review and written nothing yet must see the round, and see the zero.
  it "reports an open round with nothing written yet as open, and as zero" do
    hold_round([])

    expect(report(fresh)).to include("annotations 0")
  end

  # ---- PROBE 4: the outbox is not the only opener of a review ----------------
  #
  # {Lain::Tools::RequestReview} opens a {Lain::Review::Session} of its own and
  # binds it straight to the human's editor without ever touching the outbox, so
  # an unqualified "review none open" is a confident false negative told to a
  # human who is annotating one. What the outbox can vouch for is exactly the
  # two commands that hold into it, and the report says only that.
  it "says WHICH reviews it can see when nothing is held, never an unqualified none" do
    rendered = report(fresh)

    expect(rendered).to include("review none held by /review or /survey")
    expect(rendered).not_to include("review none open")
    expect(rendered).not_to include("annotations")
  end

  it "names the agent's own reviews among the things it cannot see" do
    expect(report(fresh)).to match(%r{a review the agent opened for itself.*/review and /survey})
  end

  # THE TRIPWIRE UNDER THAT WORDING, and the reason it reads `lib/` rather than
  # trusting prose: "none held by /review or /survey" is true only while those
  # two are the only holders. A third command that holds a round, or a
  # {Lain::Tools::RequestReview} that starts using the outbox, has to move this
  # sentence -- and would otherwise narrow it silently, which is the confident
  # false negative this whole section exists to prevent.
  it "names every command that holds into the outbox, so the qualification cannot go stale" do
    lib = File.expand_path("../../../../lib", __dir__)
    # A WHOLE-LINE COMMENT IS EXEMPT, exactly as the review deletion-map sweep
    # exempts one -- and not hypothetically: the subject's own class doc quotes
    # the call this scans for, so a naive read makes the command its own holder.
    holders = Dir["#{lib}/**/*.rb"].select do |path|
      File.readlines(path).grep_v(/\A\s*#/).any? { |line| line.include?("outbox.hold(") }
    end

    # Paths, not basenames: `review.rb` is a duplicated basename in lib/
    # (`lain/review.rb` beside `lain/cli/command/review.rb`), so a basename
    # compare lets the call move between two same-named files and stay green.
    expect(holders.map { |path| Pathname(path).relative_path_from(lib).to_s })
      .to contain_exactly("lain/cli/command/review.rb", "lain/cli/command/survey.rb")
    expect(described_class::NO_REVIEW).to include("/review", "/survey")
    expect(File.read("#{lib}/lain/tools/request_review.rb")).not_to include("Outbox")
  end

  # ---- Scenario: introspect renders on a fresh chat -------------------------

  # The same defect as PROBE 1 in another row: {Lain::Usage#cache_hit_ratio}
  # documents 0.0 as "nothing was read on the way in", which is ABSENCE -- and a
  # hard 0.0% on the bench's first-class cache metric, on a chat that has not
  # spoken, invites exactly the wrong conclusion.
  it "renders on a chat with no turns and no review, reporting absence as absence" do
    rendered = report(fresh)

    expect(rendered).to include("occupancy no turn yet in this run",
                                "review none held by /review or /survey", "total 0")
    expect(rendered).to include("cache hit ratio nothing billed on the way in yet")
    expect(rendered).not_to include("cache hit ratio 0.0%")
  end

  it "names the journal this run writes, so the record is one copy-paste away" do
    chronicle = instance_double(Lain::CLI::Chronicle, journal_path: "/tmp/lain/session.ndjson")

    expect(report(fresh, chronicle:)).to include("journal /tmp/lain/session.ndjson")
  end

  # {Lain::CLI::Chronicle::Null} is what `--no-journal` wires AND what any
  # directly-constructed {Lain::CLI::ChatLaunch} defaults to, so naming the flag
  # would tell a bench arm a flag was passed that never was. The absence is the
  # part that cannot be wrong.
  it "reports the absent journal without blaming a flag that may not have been passed" do
    rendered = report(fresh)

    expect(rendered).to include("journal no journal is being written for this run")
    expect(rendered).not_to include("--no-journal")
  end

  it "answers a Renderable, never a String -- a command returns, it never prints" do
    expect(command.call("", env_for(fresh))).to be_a(Lain::Renderable)
  end

  it "announces itself for /help's listing" do
    expect(command.usage).to start_with("/introspect --")
  end
end
