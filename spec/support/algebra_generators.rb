# frozen_string_literal: true

# The means of proof for every claim in {Lain::Algebra.registry}, keyed by the
# declaring class and the operation. spec/algebra_laws_spec.rb walks the
# registry and looks each claim up here; a claim with no entry fails the sweep
# by name, which is what makes a declaration an obligation rather than a label.
#
# These live in spec/support and never in `lib/`. A generator is test
# scaffolding -- random forests, tag combinators, hand-built witness spans --
# and shipping it would put the means of checking a claim inside the thing
# being checked.
module AlgebraGenerators
  # Memoized, so the populations below are built ONCE for the whole sweep. That
  # is not tidiness: two Timelines from different `Timeline.empty` calls raise
  # CrossStore against each other, and {Lain::Timeline::Dominators} carries the
  # memo that keeps the dominator laws from rebuilding a union-graph dominator
  # tree per invocation.
  def self.registered
    @registered ||= {
      [Lain::Context::Combinator, :>>] => Combinators.composition,
      [Lain::Usage, :+] => Usages.addition,
      [Lain::Timeline, :meet] => Timelines.render_meet,
      [Lain::Timeline, :dominator_meet] => Timelines.dominator_meet,
      [Lain::Timeline, :causal_meets] => Timelines.causal_meets,
      [Lain::Context::DedupeToolCalls, :call] => Spans.dedupe,
      [Lain::Context::PurgeFailedInputs, :call] => Spans.purge
    }.merge(strategy_claims).freeze
  end

  # The compaction strategies' claims, kept in their own hash rather than in the
  # list above because that list is at Metrics/MethodLength's limit and a
  # strategy seam grows an entry per strategy -- two here now, one each for the
  # summarizing and eliding strategies next.
  def self.strategy_claims
    { [Lain::Compaction::Strategy::Replacement, :+] => Replacements.concatenation,
      [Lain::Compaction::Strategy::Identity, :propose_ranges] => Strategies.identity_ranges,
      [Lain::Compaction::Strategy::Elide, :blocks] => Strategies.elide_blocks,
      [Lain::Compaction::Strategy::Summarizing, :blocks] => Strategies.summarizing_blocks }
  end

  def self.claims = registered.keys

  def self.knobs_for(entry) = registered[[entry.subject, entry.operation]]

  module Combinators
    module_function

    # A combinator that appends one marker block, mirroring
    # spec/lain/context/base_spec.rb. SUBCLASS-flavored on purpose: the base
    # {Lain::Context::Combinator#call} returns its argument, so
    # `Combinator.new` IS the identity and a generator that drew from the
    # declared class alone would fold nothing but units -- the monoid laws
    # would pass vacuously and prove nothing.
    def tag(symbol)
      Class.new(Lain::Context::Combinator) do
        define_method(:call) do |messages|
          messages + [{ "role" => "tag", "content" => [{ "type" => "text", "text" => symbol.to_s }] }]
        end
      end.new
    end

    def composition
      { operation: ->(a, b) { a >> b },
        generator: draw_from(%i[a b c d].map { |symbol| tag(symbol) }),
        equal: observationally_equal }
    end

    # Chains of up to three, seeded with the declared unit so a zero-length
    # draw answers it -- the same shape base_spec.rb composes.
    def draw_from(pool)
      -> { Array.new(rand(0..3)) { pool.sample }.reduce(Lain::Context::Identity, :>>) }
    end

    # Two composed combinators are never `==` as objects, so equality is
    # OBSERVATIONAL: same tags out, for the same input.
    def observationally_equal
      observe = ->(combinator) { combinator.call([]).map { |message| message["content"].first["text"] } }
      ->(a, b) { observe.call(a) == observe.call(b) }
    end
  end

  module Usages
    module_function

    # The draw is captured as a local, not left as a bare method call: the law
    # groups `instance_exec` every callable, so `self` inside one is the
    # example instance and a receiverless `usage` there would not resolve.
    def addition
      draw = method(:usage)
      { operation: ->(a, b) { a + b }, generator: -> { draw.call } }
    end

    def usage
      Lain::Usage.new(input_tokens: rand(0..5000), output_tokens: rand(0..2000),
                      cache_creation_input_tokens: rand(0..3000), cache_read_input_tokens: rand(0..9000))
    end
  end

  module Timelines
    module_function

    def say(timeline, body, causal: [])
      timeline.commit(role: :user, content: [{ "type" => "text", "text" => body }], causal_parents: causal)
    end

    # A render forest with causal cross-links added, the shape
    # spec/lain/timeline_spec.rb grows for this same group: `#meet` walks the
    # render edge only, and the fan-ins sit as leaves ON that tree, so what
    # this pins is that causal edges leave the render meet unperturbed.
    def render_meet
      forest = MeetSemilatticePopulations.grow([say(Lain::Timeline.empty, "root")], 30, "n")
      10.times { |i| forest << MeetSemilatticePopulations.fan_in(forest.sample(3), "f#{i}") }
      { population: -> { forest } }
    end

    # ONE Dominators across the whole run, as spec/lain/timeline_spec.rb does:
    # `#dominator_meet`'s default argument mints a fresh one per call, which
    # rebuilds the entire union-graph dominator tree every invocation. The
    # order predicate is dominance, which the group's default render-ancestry
    # predicate is strictly weaker than.
    def dominator_meet
      empty = Lain::Timeline.empty
      forest = MeetSemilatticePopulations.union_graph(empty)
      dominators = Lain::Timeline::Dominators.new(empty.store)
      { population: -> { forest },
        meet: ->(a, b) { a.dominator_meet(b, dominators:) },
        ancestor_of: ->(m, a) { dominators.dominates?(m.head_digest, a.head_digest) } }
    end

    # The refutation's witness, and the single-valued READING that makes it a
    # law failure rather than a type error.
    #
    # `#causal_meets` answers a SET, so asking it the semilattice laws bare
    # kills associativity with a NoMethodError on Array -- an error, which says
    # nothing about associativity. It sorts its answer, so it designates
    # exactly two single-valued readings of itself, `.first` (== min) and
    # `.last` (== max), and the witness below fails associativity under BOTH.
    # The refutation is therefore not co-constructed against the reading the
    # battery happens to use: a THREE-way criss-cross leaves three incomparable
    # maximal lower bounds, and a third element that is neither the least nor
    # the greatest of them reassociates differently whichever end a reading
    # picks. (A two-way criss-cross does NOT have that property -- there `.last`
    # holds all four laws -- which is why the witness is three-way.)
    #
    # Why a failing associativity refutes the structure at all: had the causal
    # order a unique greatest lower bound, the derived single-valued function
    # WOULD be the meet, and a meet is associative. `exhibits` then states the
    # registry's recorded reason head-on -- the answer's cardinality exceeds
    # one, so there is no greatest among them to derive.
    def causal_meets
      empty = Lain::Timeline.empty
      x, y, mid = criss_cross(empty)
      { population: -> { [x, y, mid] },
        meet: ->(a, b) { a.checkout(a.causal_meets(b).first) },
        ancestor_of: causally_below(empty.store),
        refutes: "is associative",
        exhibits: { "answers more than one maximal lower bound, so there is no greatest one" =>
                      -> { x.causal_meets(y).size > 1 } } }
    end

    # Two tips that each render off one branch and causally fold the other two,
    # plus the branch point that is neither the least nor the greatest of the
    # three by digest -- the one NO reading of the set picks, which is what
    # makes reassociation disagree with itself under either.
    def criss_cross(empty)
      root = say(empty, "root")
      branches = %w[a b c].map { |body| say(root, body) }
      tips = branches.first(2).map { |from| say(from, "tip", causal: (branches - [from]).map(&:head_digest)) }
      tips + [branches.sort_by(&:head_digest)[1]]
    end

    # The order `#causal_meets` is a meet OF -- reachability over both parent
    # edges. The group's default `#ancestor_of?` walks render edges only and
    # would be answering about a different order entirely.
    def causally_below(store)
      ancestry = Lain::Timeline::CausalAncestry.new(store)
      ->(m, a) { m.head_digest.nil? || ancestry.closure([a.head_digest]).key?(m.head_digest) }
    end
  end

  module Spans
    module_function

    def tool_use(id:, input: { "q" => "cats" })
      { "type" => "tool_use", "id" => id, "name" => "search", "input" => input }
    end

    def tool_result(id:, content: "r", is_error: false)
      { "type" => "tool_result", "tool_use_id" => id, "content" => content, "is_error" => is_error }
    end

    def message(role, *blocks) = { "role" => role, "content" => blocks }

    # The shapes the per-element map has to survive. Built eagerly and handed
    # back by a lambda that closes over them, like every other generator here:
    # a lambda that called back into this module would resolve `message`
    # against whatever `self` a law group `instance_exec`s it with.
    def dedupe
      spans = [restated_call, repeated_rewrite, []]
      { instance: -> { Lain::Context::DedupeToolCalls.new }, each: :without_stale, spans: -> { spans } }
    end

    # A stale tool_use superseded by a later identical one: the first call's
    # message is rewritten and its answering tool_result dropped, which is the
    # pair of outcomes a per-element map has to be able to express.
    def restated_call
      [message("assistant", tool_use(id: "a")), message("user", tool_result(id: "a", content: "old")),
       message("assistant", tool_use(id: "b")), message("user", tool_result(id: "b", content: "new"))]
    end

    # The declaration's half of the one law that separates it from the
    # refutation below, and deliberately the same SHAPE as that refutation's
    # witness: `[m, answer, m]`, where the two `==` messages are ones the call
    # genuinely rewrites (each carries a text block, so dropping the duplicated
    # tool_use leaves content behind rather than emptying the message). Both
    # sides of the answering tool_result take the same image, because
    # `#without_stale` is a function of the message and the analysis. Two `==`
    # messages this call never touches would prove nothing.
    def repeated_rewrite
      repeated = message("assistant", { "type" => "text", "text" => "look" }, tool_use(id: "dup"))
      answer = message("user", tool_result(id: "dup"), { "type" => "text", "text" => "note" })
      [repeated, answer, repeated]
    end

    # The strong witness: a span `[m, error, m]` whose first and last messages
    # are `==` and take DIFFERENT images in one call -- the first is aged into
    # the purge window and emptied, the last is not. An elementwise map is a
    # function of (element, analysis), and a function cannot answer two things
    # for one argument, so this rules out EVERY candidate analysis at once
    # rather than merely the one the class happens to compute. That is why the
    # named law is functionality and not the concatenation law, which the same
    # witness also breaks but only against `#failed_tool_use_ids` specifically.
    def purge
      combinator = Lain::Context::PurgeFailedInputs.new(turns: 1)
      witness = positional_witness
      { instance: -> { combinator },
        each: :without_failed_input,
        analysis: :failed_tool_use_ids,
        spans: -> { [witness] },
        refutes: "gives two equal elements equal images within one call",
        exhibits: { "gives one message two images, by which side of the trailing window it falls" =>
                      two_images(combinator, witness) } }
    end

    # `[m, error, m]` with `turns: 1`: the first and last messages `==`, the
    # failure recorded on the tool_result between them, and the boundary
    # falling between the two.
    def positional_witness
      repeated = message("assistant", tool_use(id: "x", input: { "q" => "BIG" }))
      [repeated, message("user", tool_result(id: "x", is_error: true)), repeated]
    end

    # The recorded reason, said as a predicate over the witness rather than as
    # prose this file only measures the length of.
    def two_images(combinator, witness)
      lambda {
        images = combinator.call(witness)
        witness.first == witness.last && images.first != images.last
      }
    end
  end

  module Replacements
    module_function

    # The free monoid on content blocks, drawn from three one-block
    # replacements, one two-block replacement, and the unit itself -- DROP has
    # to be IN the draw as well as being the declared identity, since `a + DROP`
    # is a fold this monoid meets constantly (a range that collapses to nothing)
    # and associativity around it is exactly what the laws are for.
    def concatenation
      unit = Lain::Compaction::Strategy::DROP
      pool = %w[a b c].map { |body| Lain::Compaction::Strategy::Replacement.text(body) }
      pool << (pool.first + pool.last) << unit
      { operation: ->(a, b) { a + b }, generator: -> { pool.sample } }
    end
  end

  module Strategies
    module_function

    # {Lain::Compaction::Strategy::Identity} proposes no ranges whatever it is
    # offered, so what the purity laws read here is the shareability proxy and
    # the absence of any reachable state -- which is the whole claim for a Null
    # Object.
    #
    # The population is rebuilt on every draw and never captured: the laws call
    # it once each, precisely so that one law cannot read arguments another law
    # has already been through. A generator answering one memoized Array would
    # put that bug back where the shared example cannot see it.
    def identity_ranges
      identity = Lain::Compaction::Strategy::Identity.new
      { instance: -> { identity },
        population: -> { spans },
        keywords: ->(span) { { span: 0..[span.size - 1, 0].max } } }
    end

    # {Lain::Compaction::Strategy::Elide} attests one text block per message and
    # is unconditional -- the {Lain::Algebra::Elementwise::Alone} shape -- so ONE
    # entry, keyed [Elide, :blocks], carries both structures' knobs: `each:` and
    # `spans:` for the elementwise declaration, `population:` for the purity one.
    # `operation:` and `analysis:` come from the registry rather than from here.
    def elide_blocks
      elide = Lain::Compaction::Strategy::Elide.new
      { instance: -> { elide },
        each: :attested,
        spans: -> { [repeating, *spans] },
        population: -> { spans } }
    end

    # {Lain::Compaction::Strategy::Summarizing} refutes TWO structures on ONE
    # operation, which is what the per-structure `refutes:`/`exhibits:` shape
    # exists for -- the registry is keyed [subject, operation], so both
    # refutations are judged through this single entry.
    #
    # `each:` and `analysis:` are the elementwise battery's half and come from
    # here rather than from the registry (a Refutation carries neither);
    # `population:` is the purity battery's, drawn FRESH on every call for the
    # reason spec/support/shared_examples/pure.rb documents. The strategy itself
    # is built once and captured: the answers it holds by content address are
    # what let the purity battery invoke #blocks twice per input without the
    # oracle being asked a second time.
    def summarizing_blocks
      strategy = Lain::Compaction::Strategy::Summarizing.new(oracle: summarizer)
      halves = [[message("a")], [message("b")]]
      { instance: -> { strategy },
        each: :per_message, analysis: :whole_span,
        spans: -> { [halves.flatten] },
        population: -> { spans },
        refutes: { elementwise: "concatenates its per-element map against the whole-span analysis",
                   pure: "reaches no mutable state" },
        exhibits: summarizing_exhibits(strategy, halves) }
    end

    # The two recorded reasons, said as predicates over a witness rather than as
    # prose this file would otherwise only measure the length of: one block for
    # a span whose halves answer two is the homomorphism failing, and an oracle
    # held is the shareability proxy failing.
    def summarizing_exhibits(strategy, halves)
      { elementwise: { "answers one block for a span it answers two for in halves" =>
                         -> { strategy.blocks(halves.flatten).size == 1 && halved(strategy, halves) == 2 } },
        pure: { "holds an oracle, so it is not Ractor.shareable?" => -> { !Ractor.shareable?(strategy) } } }
    end

    def halved(strategy, halves) = halves.sum { |half| strategy.blocks(half).size }

    # A tier that answers every question the same way, through the definition's
    # own schema. Deterministic on purpose: the purity battery invokes the
    # operation twice per input, so a counting or queue-consuming tier would
    # report a second negative the refutation above does not name.
    def summarizer
      definition = Lain::Compaction::Strategy::Summarizing.definition
      Class.new do
        define_method(:ask) { |_inputs| definition.answer("summary" => "a summary") }
      end.new
    end

    # `[m, other, m]`: attested per message, so the image preserves length and
    # repeats an element, and no message survives untouched -- the three
    # conditions spec/support/shared_examples/elementwise.rb's `judged` guard
    # reads. Without them that law is read over nothing and certifies nothing.
    # The plain {#spans} ride along beside it, as {Spans#dedupe}'s three do: the
    # guards need this one span, but `concatenates?` reads every span it is
    # given, and the EMPTY one is the shape a generated `flat_map` is likeliest
    # to break on.
    def repeating
      repeated = message("a")
      [repeated, message("b"), repeated]
    end

    def spans = [[], [message("a")], [message("a"), message("b")]]

    def message(body) = { "role" => "user", "content" => [{ "type" => "text", "text" => body }] }
  end
end
