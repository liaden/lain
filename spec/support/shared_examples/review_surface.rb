# frozen_string_literal: true

# What {Lain::Review::Surface} adapters -- {Surface::Null} here, {Surface::Text}
# (T9) and {Surface::Neovim} (T19) after it -- are held to in common. Say
# plainly what this is, because a review-panel pass on this card found the
# previous doc overclaimed it: this is a SIGNATURE check plus four BEHAVIOURAL
# families of law, not "the port's contract" in full. It cannot and does not check that
# an adapter renders a changeset correctly or answers a verdict truthfully --
# those stay in each adapter's own spec.
# Five things are checked here:
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
#    {Frontend::Neovim::RenderInlet}'s own refusal convention was
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
#    c) the callable is asserted against FIVE messages now, and the last two
#       were added by a T19 review panel that broke the three:
#       `#annotate`'s TEXT (as before) and its `kind` (a probe annotated
#       honestly and dropped `kind:` on the floor -- and `kind` is what tells
#       a blocker from a passing remark, the one member a verdict policy
#       reads); `#mark`'s `state`, not merely that it ran; `#refuse`'s
#       `message`; and `#thread`'s POSITION, which had no law at all until a
#       probe whose `#thread` wrote nothing stayed green. `#thread` is a query
#       with no argument to echo except where it is, so both halves of the
#       position are checked -- a surface naming the file and losing the line
#       points at the top of a diff rather than at the note.
#
#       `#verdict` stays uncovered: it is a QUERY with no argument to echo
#       back at all, and truthfulness is exactly the "renders correctly"
#       territory #1's own doc says stays in each adapter's own spec.
#
#    `transcript:` is resolved FRESH, via `resolve_review_fixture`, after
#    each call whose evidence it checks -- `Surface::Text`'s is
#    `-> { sink.string }`, reading the same `StringIO` its `subject` was
#    built with, so each read reflects whatever has accumulated so far.
#
# 4. `#present` RENDERS WHAT IT WAS GIVEN, and the two scopes render
#    differently -- T19's law, closing the largest hole #3 left: `#present`
#    had no evidence check at all, so a surface that drew NOTHING, or that
#    drew the same rows whatever `scope:` it was handed, was fully green.
#    Checked against the duck {Lain::Review::Surface}'s own class doc states
#    for `present`'s argument and against nothing else -- at `:cumulative`
#    every `changeset.files`' `#path` reaches the transcript and no
#    `changeset.by_commit`'s `#subject` does; at `:commits` every subject
#    does. That pair is what makes `scope:` carry weight rather than decorate:
#    a surface ignoring it fails one half or the other, whichever single
#    rendering it settled on.
#
#    TWO MORE HALVES, from the same T19 panel, and both close the gap between
#    what the first three checked and what the doc claimed. They checked only
#    that an IDENTIFIER appears, never the STATE beside it -- which is the
#    surface's entire purpose -- so a probe that flattened every tri-state to
#    one marker was green; and they checked a commit's subject without its
#    FILES, so a probe that dropped every nested row at `:commits` was green
#    too. The state half compares a DISTINCTION rather than any particular
#    glyph, since the glyph is each adapter's own: strip the path out of the
#    line it was rendered on, and two files in different states must not be
#    left saying the same thing.
#
#    A surface with a real `transcript:` therefore needs a real `changeset:`
#    too (the generic `Object.new` stand-in answers neither message), and is
#    told so by NAME rather than by `NoMethodError` on a fixture three
#    indirections away. It must be NON-EMPTY on both collections, because
#    every law here is an `all` and `[].all?` is `true`; it must carry files in
#    at least two states, or the state half compares nothing; and its commit
#    subjects must not be substrings of its own file paths, which is the one
#    way the `:cumulative` half could read as a failure for a surface that is
#    behaving. All four are refused by name at resolve time.
#
# 5. WHAT A MESSAGE ANSWERS WHEN IT LANDED -- T19's other law, and the port
#    decision behind it. {Frontend::Neovim::RenderInlet} answers a
#    refusal SENTENCE rather than raising when no editor is taking the post,
#    and T19's adapter hands that sentence straight up, so the port's five
#    COMMANDS answer a `String` for "this reached nobody, here is why" and
#    anything-but-a-String for "taken". `nil` ({Surface::Null}), a byte count
#    ({Surface::Text}, whose `Sink#write` answers one) and the sentence are
#    then three distinguishable facts, with no second channel invented to
#    carry the refusal.
#
#    Only the LANDED half is checkable here: neither Null nor Text has a
#    detached mode to drive, and a config key every surface without one opts
#    out of is the silent-default shape a fix-round panel already broke this
#    group over (#3a). The REFUSING half is pinned in T19's own spec, against
#    a real {RenderInlet} whose queue has been closed -- which is what RPC
#    thread death actually leaves behind.
#
#    `#verdict` is exempt, and not for tidiness: `Review::VERDICTS` are
#    Strings, so a refusal returned from the one message that answers a
#    verdict could not be told from a verdict. That the port has nowhere for a
#    QUERY's refusal to go is the tension {Surface::Null#verdict}'s own
#    comment records -- still open, and this law states its edge rather than
#    papering over it.
#
#    SAY THE COST OF THIS LAW OUT LOUD, because a T19 review panel found it is
#    the one place nvim shaped the port: "a String means refused" is
#    {RenderInlet}'s convention promoted to a port law, and Null and Text
#    satisfy it ACCIDENTALLY -- `nil` and a byte count -- never exercising the
#    refusing half at all. The exemption above is that mildness made visible.
#    What removes both is the object the port is missing: a returned answer
#    carrying verdict-or-refusal, which would make this law uniform across all
#    six messages and delete the exemption. Filed as a follow-up; recorded here
#    so the law is read as provisional rather than settled.
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

  # Through `Surface.shape_of`, the SAME normalization `check!` applies, so the
  # group and the constructor-time check cannot disagree about what "the port's
  # shape" means: every argument's kind, and a keyword's name. A positional's
  # name is the method's own business -- pinning it made `def thread(_anchor)`
  # a shape defect, which is a rename.
  Lain::Review::Surface::MESSAGES.each do |port_message, shape|
    it "answers ##{port_message} with exactly the port's shape" do
      expect(Lain::Review::Surface.shape_of(subject.method(port_message)))
        .to eq(Lain::Review::Surface.shape_of(shape))
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

  # #annotate's OTHER argument. A T19 review panel's probe annotated the text
  # honestly and dropped `kind:` on the floor -- and `kind` is what tells a
  # blocker from a passing remark, which is the one thing a verdict policy reads.
  it "leaves evidence, in its transcript, that #annotate's kind actually reached it" do
    skip "transcript: :no_observation_channel -- this surface declares no observation channel" if transcript_declined

    annotation_kind = resolve_review_fixture(kind)
    subject.annotate(resolve_review_anchor(anchor), resolve_review_fixture(text), kind: annotation_kind)

    expect(resolve_review_fixture(transcript)).to match(/\b#{Regexp.escape(annotation_kind.to_s)}\b/)
  end

  it "leaves evidence, in its transcript, that #refuse's message actually reached it" do
    skip "transcript: :no_observation_channel -- this surface declares no observation channel" if transcript_declined

    reason = resolve_review_fixture(message)
    subject.refuse(reason)

    expect(resolve_review_fixture(transcript)).to include(reason)
  end

  # #thread had NO evidence law at all until a T19 review panel wrote a probe
  # whose `#thread` wrote nothing and stayed green. It is a query with no
  # argument to echo except the position itself, so the position is what is
  # checked -- both halves, since a surface naming the file and losing the line
  # points at the top of a diff rather than at the note.
  it "leaves evidence, in its transcript, that #thread named the anchor's position" do
    skip "transcript: :no_observation_channel -- this surface declares no observation channel" if transcript_declined

    at = resolve_review_anchor(anchor)
    subject.thread(at)

    rendered = resolve_review_fixture(transcript)
    expect(rendered).to include(at.path.to_s)
    expect(rendered).to match(/\b#{Regexp.escape(at.line.to_s)}\b/)
  end

  # The changeset duck `#present` is documented to need, resolved by NAME so a
  # surface that supplies a real transcript and the generic `Object.new`
  # stand-in is told which config key to fix rather than handed a
  # `NoMethodError` from inside an example about rendering (class doc's #4).
  # Everything a real `transcript:` obliges the OTHER fixtures to be, refused by
  # name at resolve time rather than as a `NoMethodError` three indirections
  # away, or -- worse -- as silence. `:empty` is not pedantry: every rendering
  # law is an `all` over one of these collections and `[].all?` is `true`, so an
  # empty fixture passes four laws without executing one comparison. Both
  # current fixtures are non-empty and neither the group nor a reader could say
  # so, which is the exact shape of vacuity this file has now been broken over
  # twice. A local Hash rather than a constant, for `no_observation_channel`'s
  # reason: this block re-runs once per inclusion.
  fixture_claims = {
    changeset_duck: "changeset: must answer #files and #by_commit for the rendering laws -- see " \
                    "Lain::Review::Surface's class doc, \"What present's changeset argument answers\". A " \
                    "surface that supplies a real transcript: must supply a real changeset: too",
    changeset_empty: "changeset: must carry at least one file AND at least one commit -- every rendering law " \
                     "is an `all` over one of those two and `[].all?` is true, so an empty one passes " \
                     "without comparing anything",
    changeset_states: "changeset: must carry files in at least TWO of Review::FILE_STATES -- a single-state " \
                      "fixture cannot tell a tri-state rendering from a constant one",
    anchor_duck: "anchor: must answer #path and #line for the position laws -- a surface that supplies a " \
                 "real transcript: must supply a real anchor: too"
  }.freeze

  define_method(:review_fixture_refusal) { |claim| raise ArgumentError, fixture_claims.fetch(claim) }

  define_method(:resolve_review_changeset) do |callable|
    resolved = resolve_review_fixture(callable)
    review_fixture_refusal(:changeset_duck) unless resolved.respond_to?(:files) && resolved.respond_to?(:by_commit)
    review_fixture_refusal(:changeset_empty) if resolved.files.to_a.empty? || resolved.by_commit.to_a.empty?

    resolved
  end

  # `#annotate` and `#thread` both say WHERE, so a surface with a real
  # transcript has to hand over something that can answer where.
  define_method(:resolve_review_anchor) do |callable|
    resolved = resolve_review_fixture(callable)
    review_fixture_refusal(:anchor_duck) unless resolved.respond_to?(:path) && resolved.respond_to?(:line)

    resolved
  end

  # The transcript line a path was rendered on, with the path itself removed:
  # whatever is left is the DECORATION the tri-state marker lives in, which is
  # what law #4d compares across states.
  define_method(:review_decoration_for) do |rendered, path|
    line = rendered.to_s.lines.find { |candidate| candidate.include?(path) }
    line&.sub(path, "")&.strip
  end

  # Law #4, in three halves. Each drives ONE `#present` against a fresh
  # subject, so the `:cumulative` half cannot be satisfied by rows a
  # `:commits` render left in an accumulating transcript.
  it "renders every file it was given at :cumulative scope" do
    skip "transcript: :no_observation_channel -- this surface declares no observation channel" if transcript_declined

    presented = resolve_review_changeset(changeset)
    subject.present(presented, scope: :cumulative)

    rendered = resolve_review_fixture(transcript)
    expect(presented.files.map(&:path)).to all(satisfy { |path| rendered.include?(path) })
  end

  it "renders every commit subject it was given at :commits scope" do
    skip "transcript: :no_observation_channel -- this surface declares no observation channel" if transcript_declined

    presented = resolve_review_changeset(changeset)
    subject.present(presented, scope: :commits)

    rendered = resolve_review_fixture(transcript)
    expect(presented.by_commit.map(&:subject)).to all(satisfy { |line| rendered.include?(line) })
  end

  it "renders no commit subject at :cumulative scope, so the two scopes differ" do
    skip "transcript: :no_observation_channel -- this surface declares no observation channel" if transcript_declined

    presented = resolve_review_changeset(changeset)
    subject.present(presented, scope: :cumulative)

    rendered = resolve_review_fixture(transcript)
    expect(presented.by_commit.map(&:subject)).to all(satisfy { |line| !rendered.include?(line) })
  end

  # #4d, and the half a T19 review panel proved missing: the three halves above
  # check only that an identifier APPEARS, never the STATE beside it -- which is
  # the entire purpose of the surface. A probe that flattened every tri-state to
  # one marker was green on all three. Checked as a DISTINCTION rather than
  # against any particular glyph, because the glyph is each adapter's own:
  # strip the path out of the line it was rendered on, and two files in
  # different states must not be left saying the same thing.
  it "renders each file's state beside its path, distinguishably" do
    skip "transcript: :no_observation_channel -- this surface declares no observation channel" if transcript_declined

    presented = resolve_review_changeset(changeset)
    by_state = presented.files.group_by { |file| file.state.to_s }
    review_fixture_refusal(:changeset_states) if by_state.size < 2

    subject.present(presented, scope: :cumulative)
    rendered = resolve_review_fixture(transcript)
    decorations = by_state.transform_values { |files| review_decoration_for(rendered, files.first.path) }

    expect(decorations.values.uniq.size).to eq(by_state.size)
  end

  # #4e: a commit section is its SUBJECT and the files under it. Checking only
  # the subject passed a probe whose `:commits` rendering dropped every file row.
  it "renders the files under each commit at :commits scope, not the subjects alone" do
    skip "transcript: :no_observation_channel -- this surface declares no observation channel" if transcript_declined

    presented = resolve_review_changeset(changeset)
    subject.present(presented, scope: :commits)

    rendered = resolve_review_fixture(transcript)
    nested = presented.by_commit.flat_map { |commit| commit.files.map(&:path) }
    expect(nested).to all(satisfy { |path| rendered.include?(path) })
  end

  # Law #5. The five COMMANDS only; `#verdict` is exempt for the reason the
  # class doc gives, and there is no generic way to drive the refusing half
  # (also the class doc) -- so this pins the landed half, which is what makes
  # "a String means it did not land" a fact a caller can act on rather than a
  # convention one adapter happens to follow.
  it "answers no refusal sentence for a message it took" do
    taken = [
      subject.present(resolve_review_fixture(changeset), scope: :cumulative),
      subject.annotate(resolve_review_fixture(anchor), resolve_review_fixture(text),
                       kind: resolve_review_fixture(kind)),
      subject.mark(resolve_review_fixture(hunk_key), resolve_review_fixture(state)),
      subject.thread(resolve_review_fixture(anchor)),
      subject.refuse(resolve_review_fixture(message))
    ]

    expect(taken).to all(satisfy { |answer| !answer.is_a?(String) })
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
