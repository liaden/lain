# frozen_string_literal: true

# The gh executor contract, once, for every interpretation of it.
#
# `Forge::Gh` shells out, `Forge::Gh::Recorded` replays a journal, and
# `Forge::Journaled` wraps either -- three objects that must be substitutable for
# one another, because T24's landing holds one of them and must not care which.
# Deliberate identity is what a shared group states MECHANICALLY: three copies of
# these cases could only stay identical by convention, and a fix applied to one
# would be a fix missing from the other two (the reasoning
# `exec_boundary_parity.rb` records).
#
# The host block supplies ONE thing, `let(:executor)`, arranged against the
# fixture below -- the same scenario every host answers:
#
#   pr_create(head: HEAD)          opens pull request NUMBER
#   pr_create(head: OPEN_HEAD)     is refused: one is open already, at OPEN_NUMBER
#   pr_create(head: REFUSED_HEAD)  is refused by GitHub
#   pr_merge(number: NUMBER)       merges
#   merge_state(number: NUMBER)    answers MERGE_STATE
#
# OPEN_HEAD is in the fixture because `observed` is the tier's own honesty flag --
# the difference between "we opened this" and "it was already there" -- and it is
# the one thing the executors could otherwise disagree about in silence. Before
# it was here, replacing `observed: recorded.observed?` with `observed: false` in
# Recorded#replay left the whole suite green (the panel's finding).
#
# The fixture is constants rather than prose so all three hosts arrange the same
# addresses mechanically. {GhParity.factory} is the live arrangement and
# {GhParity.recorded_journal} the replayed one -- the recording under test is a
# REAL recording, produced by running the live executor under `Forge::Journaled`,
# not a hand-written fixture that could drift from what the writer actually
# writes.
module GhParity
  EPIC_SLUG = "demo"
  ISSUE_ID = "a1"
  BASE = "main"
  HEAD = "epic/demo/a1"
  TITLE = "demo a1: the thing"
  BODY = "landed by lain"
  NUMBER = 4271
  URL = "https://github.com/acme/widgets/pull/#{NUMBER}".freeze
  MERGE_STATE = "CLEAN"

  # A head ref GitHub refuses a pull request for. Its wording is gh's own, kept
  # verbatim so the "structured error, never a raw exception" case is pinned
  # against something a real gh actually says.
  REFUSED_HEAD = "epic/demo/nothing-to-compare"
  REFUSAL = "pull request create failed: GraphQL: No commits between main and epic/demo/nothing-to-compare"

  # A head ref that ALREADY has an open pull request, and gh's own wording for
  # saying so. A distinct number from NUMBER, so an executor that answered the
  # ordinary success here would be caught rather than accidentally right.
  OPEN_HEAD = "epic/demo/already-open"
  OPEN_NUMBER = 3118
  OPEN_URL = "https://github.com/acme/widgets/pull/#{OPEN_NUMBER}".freeze
  ALREADY_OPEN = %(a pull request for branch "#{OPEN_HEAD}" into branch "#{BASE}" already exists: #{OPEN_URL}).freeze

  # The closed verb set, named once so the tier-2 example below can iterate it
  # rather than trusting three spec files to list the same four.
  VERBS = %i[pr_create pr_merge pr_view merge_state].freeze

  # The one duck a gh executor exercises on a Mixlib::ShellOut: #run_command,
  # #exitstatus, #stdout, #stderr. Named distinctly from up_spec.rb's
  # FakeShellOut and tmux_surface_spec.rb's FakeTmuxShellOut so the three
  # top-level constants never collide when the suite loads all of them.
  FakeGhShellOut = Struct.new(:exitstatus, :stdout, :stderr) do
    def run_command = self
  end

  # A `shell_out_factory` stand-in that answers a canned shell per argv and
  # RECORDS every argv it was handed -- which is what lets a spec pin the wire
  # (argv arrays, never `sh -c`, never a built string).
  class FakeGh
    attr_reader :argvs, :options

    def initialize(&answer)
      @answer = answer
      @argvs = []
      @options = []
    end

    def call(*argv, **options)
      @argvs << argv
      @options << options
      @answer.call(argv)
    end
  end

  class << self
    # A factory answering the fixture scenario. `argv[0]` is the binary and
    # `argv[2]` the gh subcommand, because the executor prepends "gh".
    def factory = FakeGh.new { |argv| reply(argv) }

    def reply(argv)
      case argv[2]
      when "create" then create_reply(argv)
      when "merge" then FakeGhShellOut.new(0, "", "")
      when "view" then viewed
      else FakeGhShellOut.new(1, "", "no fixture for #{argv.inspect}")
      end
    end

    def create_reply(argv)
      return refused_create if argv.include?(REFUSED_HEAD)

      argv.include?(OPEN_HEAD) ? already_open : created
    end

    def created = FakeGhShellOut.new(0, "#{URL}\n", "")
    def refused_create = FakeGhShellOut.new(1, "", REFUSAL)
    def already_open = FakeGhShellOut.new(1, "", ALREADY_OPEN)
    def viewed = FakeGhShellOut.new(0, %({"mergeStateStatus":"#{MERGE_STATE}"}\n), "")

    # The whole fixture scenario, journaled by running `executor` under
    # `Forge::Journaled`. Both refused and successful attempts are driven, so a
    # replay of these lines can answer every case the group asks about.
    #
    # @return [Array<String>] NDJSON lines
    def recorded_journal(executor)
      io = StringIO.new
      journaled = Lain::Forge::Journaled.new(executor, journal: Lain::Journal.new(io:),
                                                       epic_slug: EPIC_SLUG, issue_id: ISSUE_ID)
      journaled.pr_create(base: BASE, head: HEAD, title: TITLE, body: BODY)
      journaled.pr_create(base: BASE, head: OPEN_HEAD, title: TITLE, body: BODY)
      journaled.pr_create(base: BASE, head: REFUSED_HEAD, title: TITLE, body: BODY)
      journaled.pr_merge(number: NUMBER)
      io.string.lines
    end
  end
end

RSpec.shared_examples "a gh executor" do
  it "answers pr_create with the new pull request's number" do
    answer = executor.pr_create(base: GhParity::BASE, head: GhParity::HEAD,
                                title: GhParity::TITLE, body: GhParity::BODY)

    expect(answer).to be_ok
    expect(answer).not_to be_observed
    expect(answer.value).to eq(GhParity::NUMBER)
  end

  # `observed` is the tier's honesty flag: true means the effect was found
  # ALREADY IN PLACE and confirmed, rather than performed. It is the ONE fact a
  # replay could get wrong without changing ok, value or detail, so the contract
  # has to state it -- a resume that reads "we opened this" for a pull request
  # somebody else's run opened has lost the only distinction that made the
  # re-run safe.
  it "answers an effect already in place as an OBSERVED success, never a fresh one" do
    answer = executor.pr_create(base: GhParity::BASE, head: GhParity::OPEN_HEAD,
                                title: GhParity::TITLE, body: GhParity::BODY)

    expect(answer).to be_ok
    expect(answer).to be_observed
    expect(answer.value).to eq(GhParity::OPEN_NUMBER)
  end

  it "answers pr_merge with the number it merged" do
    answer = executor.pr_merge(number: GhParity::NUMBER)

    expect(answer).to be_ok
    expect(answer.value).to eq(GhParity::NUMBER)
  end

  it "answers merge_state with GitHub's own state string" do
    answer = executor.merge_state(number: GhParity::NUMBER)

    expect(answer).to be_ok
    expect(answer.value).to eq(GhParity::MERGE_STATE)
  end

  # The contract that keeps a landing legible: gh refusing is a VALUE, not an
  # exception, so a caller folds on it the same way whether the refusal was
  # heard live or read back out of a journal.
  it "answers a refused pr_create as a not-ok value carrying why, never raising" do
    answer = executor.pr_create(base: GhParity::BASE, head: GhParity::REFUSED_HEAD,
                                title: GhParity::TITLE, body: GhParity::BODY)

    expect(answer).not_to be_ok
    expect(answer.value).to be_nil
    expect(answer.detail["stderr"]).to include("No commits between")
  end

  it "answers deeply frozen, Ractor-shareable values" do
    answer = executor.pr_create(base: GhParity::BASE, head: GhParity::HEAD,
                                title: GhParity::TITLE, body: GhParity::BODY)

    expect(Ractor.shareable?(answer)).to be(true)
  end

  # Tier 2 by construction, stated mechanically rather than by convention: a
  # verb taking a positional String is a verb a model-built command could ride
  # in on, and no reading of the implementation would catch that as reliably as
  # counting the parameter kinds.
  it "takes keyword arguments only -- no verb accepts a command string" do
    GhParity::VERBS.each do |verb|
      kinds = executor.method(verb).parameters.map(&:first).uniq
      expect(kinds - %i[keyreq key]).to be_empty, "#{verb} takes #{kinds.inspect}, so a positional string fits"
    end
  end
end
