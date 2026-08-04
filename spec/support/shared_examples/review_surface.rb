# frozen_string_literal: true

# What {Lain::Review::Surface} adapters -- {Surface::Null} here, {Surface::Text}
# (T9) and {Surface::Neovim} (T19) after it -- are held to in common. Say
# plainly what this is, because a review-panel pass on this card found the
# previous doc overclaimed it: this is a SIGNATURE check plus two BEHAVIOURAL
# laws, not "the port's contract" in full. It cannot and does not check that
# an adapter renders a changeset correctly or answers a verdict truthfully --
# those stay in each adapter's own spec. T19 still owes this group one law of
# its own as it lands (what a gesture actually reaches the session as).
# Three things are checked here:
#
# 1. the exact SHAPE of each message -- which arguments are positional,
#    which are required keywords -- read from {Lain::Review::Surface::MESSAGES},
#    the ONE place that shape is stated (also read by `Surface.check!`, so a
#    candidate that lies about its shape is refused at construction, not
#    only caught here). This is what would catch the port drifting toward
#    one adapter: an nvim-only parameter (a buffer number, a window id)
#    added to `#present` would fail this check for {Surface::Null} and
#    {Surface::Text} long before it ever reached a design review, because
#    neither has a legitimate use for it. It also catches the opposite
#    drift: `#refuse(message)` silently growing a default would let a caller
#    forget the sentence it must supply, the exact mistake
#    {Frontend::Neovim::RpcThread::RenderInlet}'s own refusal convention was
#    written to make impossible (see its `open_compose`/`open_question`/
#    `open_review` doc: "the argument is REQUIRED so it cannot be forgotten").
# 2. no message depends on another having been called first, checked against
#    a FRESH instance per order -- see the note above the `orders` Hash below
#    for why "fresh" is load-bearing and was not true of this group's first
#    cut. That freshness is INHERITED from the including spec, not enforced
#    here: it comes solely from `subject` being RSpec's per-example memoized
#    helper, invoked once per `it`. An including spec that instead writes
#    `subject { SOME_CONSTANT }` (one instance shared across every example)
#    or builds its instance in a `before(:all)`/`let!` (built once, reused
#    thereafter) silently restores the exact vacuity this group was fixed to
#    catch, and nothing here would detect it. T9 and T19: use a plain
#    `subject { described_class.new }` (or equivalent per-example
#    construction), not a shared/memoized-once instance.
# 3. a surface told to `#annotate`, `#mark`, or `#refuse` can SAY it was --
#    the law T9 owes this group (see below), HARDENED once by a fix-round
#    panel past its own first cut. That first cut checked only `#annotate`,
#    against an OPT-IN key that silently defaulted to "not configured, skip"
#    -- and the panel broke it two ways: a non-Null surface that drops every
#    message on the floor and simply never mentions the key passes cleanly
#    (11 examples, 0 failures, 1 pending -- declining costs nothing but
#    silence); and a surface that annotates HONESTLY but discards `#mark`'s
#    `state`, discards `#refuse`'s `message`, and answers `#verdict` at
#    random is FULLY GREEN (two thirds of the T4 counterexample still walks
#    through). Both reproduced against this file before the fix below, and
#    both are now caught.
#
#    Three changes, together:
#
#    a) the config key is `transcript:`, and it is now REQUIRED -- a MISSING
#       key raises `ArgumentError` at group-definition time (the same guard
#       `fixture` already used for a bad VALUE, extended to a bad ABSENCE).
#       {Surface::Null} declines EXPLICITLY, `transcript: :no_observation_channel`
#       -- a declaration, not a silence -- and only that literal Symbol skips
#       the checks below; every other surface must supply a real callable.
#    b) whether to skip is decided from that literal, at definition time --
#       never by calling the configured callable early to see what it
#       answers. T19's real transcript can legitimately raise before the
#       first gesture reaches nvim, and a group that invoked it eagerly to
#       decide "configured or not" would force T19 to fake one just to be
#       included here.
#    c) the callable is asserted against THREE messages, not one:
#       `#annotate` (as before), `#mark` (that its `state` argument -- not
#       merely that IT ran -- reached the transcript), and `#refuse` (same,
#       for `message`). `#verdict` stays uncovered: it is a QUERY with no
#       argument to echo back, and truthfulness is exactly the "renders
#       correctly" territory #1's own doc says stays in each adapter's own
#       spec, not this group's.
#
#    `transcript:` is resolved FRESH, via `resolve_review_fixture`, after
#    each call whose evidence it checks -- `Surface::Text`'s is
#    `-> { sink.string }`, reading the same `StringIO` its `subject` was
#    built with, so each read reflects whatever has accumulated so far.
#
# Include as `it_behaves_like "a review surface"` for a surface that is
# genuinely indifferent to its arguments (Null is) -- but even then,
# `transcript:` must be given explicitly (see #3a above):
#
#   it_behaves_like "a review surface", transcript: :no_observation_channel
#
# A surface that inspects what it is handed (Text, Neovim) passes real
# domain objects instead, ALWAYS AS CALLABLES, never bare values, and a real
# `transcript:` callable to be held to the hardened law:
#
#   it_behaves_like "a review surface",
#                   changeset: -> { real_changeset }, anchor: -> { real_anchor },
#                   transcript: -> { sink.string }
#
# every OTHER key optional; anything not given falls back to a generic
# stand-in. Callables, not values, because `config.fetch` below runs where this group
# is INCLUDED, at example-group DEFINITION time, with `self` bound to the
# group's CLASS -- a `let`-built fixture is an instance method and does not
# exist yet at that point (T19's fixtures come from a running nvim and can
# only exist as a `let`/`before`). `resolve_review_fixture` below resolves
# each callable later, inside a real example, via `instance_exec` -- the
# same shape `spec/support/shared_examples/monoid.rb`'s `#monoid_call` uses
# for the identical reason (`define_method(:monoid_call) { |callable, *args|
# instance_exec(*args, &callable) }`).
RSpec.shared_examples "a review surface" do |config = {}|
  # Guarded HERE, at fetch time, not left to fail wherever `resolve_review_fixture`
  # first calls it: a bare value fails in three different, all-unhelpful ways
  # depending on its type (Object/String/Integer: `TypeError: no implicit
  # conversion into Proc`; `nil`: `LocalJumpError`; a Symbol -- the likeliest
  # slip, since every default below IS one -- `ArgumentError: no receiver
  # given`, which is the most cryptic of the three because `Symbol#to_proc`
  # succeeds and the failure surfaces even later). None of those three name
  # the config key or the rule; this does.
  fixture = lambda do |key, default|
    value = config.fetch(key) { default }
    unless value.respond_to?(:call)
      raise ArgumentError, "config value for #{key} must be a callable: #{key}: -> { ... }"
    end

    value
  end

  changeset = fixture.call(:changeset, -> { Object.new })
  anchor = fixture.call(:anchor, -> { Object.new })
  hunk_key = fixture.call(:hunk_key, -> { "hunk-content-v1:deadbeef" })
  state = fixture.call(:state, -> { :reviewed })
  text = fixture.call(:text, -> { "looks fine" })
  kind = fixture.call(:kind, -> { :note })
  message = fixture.call(:message, -> { "not today" })

  # `transcript:` alone is NOT soft-defaulted like every key above -- see the
  # class doc's #3a/#3b. A missing key raises here, at definition time, naming
  # both ways to satisfy it; the literal `:no_observation_channel` is the
  # explicit opt-out and is checked WITHOUT calling anything. A local, not a
  # constant: this block body re-runs once per `it_behaves_like` inclusion,
  # and a top-level `CONST =` here would both warn on the second run and land
  # on the wrong namespace (no enclosing module/class lexically wraps it).
  no_observation_channel = :no_observation_channel

  transcript_config = config.fetch(:transcript) do
    raise ArgumentError,
          "config value for transcript is required: pass a callable (transcript: -> { ... }) that reads " \
          "back everything this surface has recorded so far, or the literal " \
          "transcript: :no_observation_channel to DECLARE -- not merely omit -- that it offers no way " \
          "to observe what happened"
  end
  transcript_declined = transcript_config == no_observation_channel
  if !transcript_declined && !transcript_config.respond_to?(:call)
    raise ArgumentError,
          "config value for transcript must be a callable (transcript: -> { ... }) or exactly " \
          ":no_observation_channel to decline"
  end
  transcript = transcript_config unless transcript_declined

  define_method(:resolve_review_fixture) { |callable| instance_exec(&callable) }

  Lain::Review::Surface::MESSAGES.each do |port_message, shape|
    it "answers ##{port_message} with exactly the port's shape" do
      expect(subject.method(port_message).parameters).to eq(shape)
    end
  end

  # One call of each, in the port's documented order, with valid arguments.
  it "accepts every message and never raises" do
    expect do
      subject.present(resolve_review_fixture(changeset), scope: :cumulative)
      subject.annotate(resolve_review_fixture(anchor), resolve_review_fixture(text), kind: resolve_review_fixture(kind))
      subject.mark(resolve_review_fixture(hunk_key), resolve_review_fixture(state))
      subject.thread(resolve_review_fixture(anchor))
      subject.verdict
      subject.refuse(resolve_review_fixture(message))
    end.not_to raise_error
  end

  # The hardened law (class doc's #3). Skipped, not vacuously green, when the
  # including spec DECLARES `transcript: :no_observation_channel` --
  # {Surface::Null} does, because discarding every message is its whole
  # point. Every other surface must supply a real callable (missing entirely
  # is now a definition-time `ArgumentError`, not a silent skip -- #3a).
  #
  # Each example checks that the ARGUMENT itself, not merely a generic "it
  # ran" marker, reached the transcript -- the probe that forced this
  # (`probe_partial_honesty.rb`) annotated honestly while discarding `#mark`'s
  # `state` and `#refuse`'s `message`, and a check for "did #mark run" alone
  # would have missed it.
  it "leaves evidence, in its transcript, that #annotate's text actually ran" do
    skip "transcript: :no_observation_channel -- this surface declares no observation channel" if transcript_declined

    note = resolve_review_fixture(text)
    subject.annotate(resolve_review_fixture(anchor), note, kind: resolve_review_fixture(kind))

    expect(resolve_review_fixture(transcript)).to include(note)
  end

  it "leaves evidence, in its transcript, that #mark's state actually reached it" do
    skip "transcript: :no_observation_channel -- this surface declares no observation channel" if transcript_declined

    # A word-boundary match, not `#include?`: Review::MARK_STATES's own
    # members are `reviewed`/`unreviewed`, and `"unreviewed".include?("reviewed")`
    # is true -- a plain substring check would pass a surface that echoed the
    # WRONG state back, which is exactly the defect this example exists to
    # catch.
    marked_state = resolve_review_fixture(state)
    subject.mark(resolve_review_fixture(hunk_key), marked_state)

    expect(resolve_review_fixture(transcript)).to match(/\b#{Regexp.escape(marked_state.to_s)}\b/)
  end

  it "leaves evidence, in its transcript, that #refuse's message actually reached it" do
    skip "transcript: :no_observation_channel -- this surface declares no observation channel" if transcript_declined

    reason = resolve_review_fixture(message)
    subject.refuse(reason)

    expect(resolve_review_fixture(transcript)).to include(reason)
  end

  # Three orders -- natural, fully reversed, and one scrambled -- rather than
  # an exhaustive permutation: this is a contract check, not a fuzzer, and
  # three orders already put every message both before and after every other
  # at least once.
  #
  # ONE EXAMPLE PER ORDER, each against its OWN fresh `subject`, is the fix a
  # review panel's probe forced (`probe_ordering.rb`). The first cut ran all
  # three orders inside a SINGLE `it`, against the ONE `subject` RSpec
  # memoizes for that example -- so the natural order's `#present` always ran
  # first and satisfied whatever precondition a later order's `#mark` needed,
  # and the law could not fail for ANY implementation: a surface that raises
  # when `#mark` runs before `#present` (`LifecycleSurface` in
  # `probe_contract.rb`, `Lifecycled` in `probe_ordering.rb`) passed it
  # cleanly. `subject` memoizes PER EXAMPLE, not across examples, so one `it`
  # per order is what actually gives each order a fresh instance -- no
  # separate construction needed.
  orders = {
    "natural order" => %i[present annotate mark thread verdict refuse],
    "fully reversed" => %i[refuse verdict thread mark annotate present],
    "scrambled" => %i[verdict thread mark refuse present annotate]
  }

  orders.each do |description, order|
    it "answers every message in #{description}, against a fresh instance" do
      calls = {
        present: -> { subject.present(resolve_review_fixture(changeset), scope: :cumulative) },
        annotate: lambda {
          note = resolve_review_fixture(text)
          subject.annotate(resolve_review_fixture(anchor), note, kind: resolve_review_fixture(kind))
        },
        mark: -> { subject.mark(resolve_review_fixture(hunk_key), resolve_review_fixture(state)) },
        thread: -> { subject.thread(resolve_review_fixture(anchor)) },
        verdict: -> { subject.verdict },
        refuse: -> { subject.refuse(resolve_review_fixture(message)) }
      }
      expect { order.each { |port_message| calls.fetch(port_message).call } }.not_to raise_error
    end
  end
end
