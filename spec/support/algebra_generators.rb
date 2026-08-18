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
    }.merge(strategy_claims).merge(middleware_claims).merge(toolset_claims).merge(partition_claims).freeze
  end

  # {Lain::IntervalPartition}'s refinement meet, kept apart from `registered`
  # for the same reason the three below it are: that list is at
  # Metrics/MethodLength's limit.
  def self.partition_claims
    { [Lain::IntervalPartition, :meet] => Partitions.refinement }
  end

  # The compaction strategies' claims, kept in their own hash rather than in the
  # list above because that list is at Metrics/MethodLength's limit and a
  # strategy seam grows an entry per strategy -- two here now, one each for the
  # summarizing and eliding strategies next.
  def self.strategy_claims
    { [Lain::Compaction::Strategy::Replacement, :+] => Replacements.concatenation,
      [Lain::Compaction::Strategy::Base, :|] => Strategies.composition,
      [Lain::Compaction::Strategy::Identity, :propose_ranges] => Strategies.identity_ranges,
      [Lain::Compaction::Strategy::Elide, :blocks] => Strategies.elide_blocks,
      [Lain::Compaction::Strategy::ElideToolObservations, :blocks] => Strategies.elide_on_tools_blocks,
      [Lain::Compaction::Strategy::Summarizing, :blocks] => Strategies.summarizing_blocks,
      [Lain::Compaction::Strategy::SummarizeConversation, :blocks] => Strategies.summarize_conversation_blocks }
  end

  # Middleware's monoid claim, kept apart from `registered` for the same
  # reason `strategy_claims` is: that hash is at Metrics/MethodLength's limit.
  def self.middleware_claims
    { [Lain::Middleware::Base, :>>] => Middlewares.composition }
  end

  # Toolset's attenuation claim, kept apart from `registered` for the same
  # reason `strategy_claims` and `middleware_claims` are: that hash is at
  # Metrics/MethodLength's limit.
  def self.toolset_claims
    { [Lain::Toolset, :only] => Toolsets.attenuation }
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

  module Middlewares
    module_function

    # A middleware that records its own entry/exit into env[:trace], the same
    # shape spec/lain/middleware_spec.rb's own `tag` helper builds.
    # SUBCLASS-flavored for the same reason {Combinators.tag} is: bare
    # {Lain::Middleware::Base} instances all behave as the identity, so a
    # generator drawing from the declared class alone would fold nothing but
    # units and pass the monoid laws vacuously.
    def tag(symbol)
      Class.new(Lain::Middleware::Base) do
        define_method(:call) do |env, &downstream|
          entered = env.merge(trace: env.fetch(:trace, []) + [[symbol, :in]])
          exited = downstream.call(entered)
          exited.merge(trace: exited.fetch(:trace) + [[symbol, :out]])
        end
      end.new
    end

    def composition
      { operation: ->(a, b) { a >> b },
        generator: draw_from(%i[a b c d].map { |symbol| tag(symbol) }),
        equal: observationally_equal }
    end

    # Chains of up to three, seeded with the declared unit so a zero-length
    # draw answers it -- {Combinators.draw_from}'s same shape.
    def draw_from(pool)
      -> { Array.new(rand(0..3)) { pool.sample }.reduce(Lain::Middleware::Identity, :>>) }
    end

    # Two composed middlewares are never `==` as objects, so equality is
    # OBSERVATIONAL: the same trace out, for the same input env.
    def observationally_equal
      observe = lambda do |middleware|
        middleware.call(Lain::Middleware::Env.wrap(trace: [])) { |env| env }.fetch(:trace)
      end
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

  # == How this population is built, and why that is the whole point
  #
  # Every subject is handed to `Lain::Toolset.new` as a list of tool INSTANCES,
  # and every request is a plain slice of the name Array those instances produce.
  # Neither `#only` nor `#except` is called anywhere in the construction. That
  # is not incidental: the monoid generators in this same file build each draw
  # with `reduce(Identity, :>>)`, so making `#>>` left-absorbing collapses every
  # draw onto the unit and leaves the law sweep green -- the laws hold vacuously
  # about a population the broken operation itself produced (follow-up A-1).
  # Break `#only` here in any way at all and the draws are untouched, so the
  # laws are read over the same subjects and the same requests they were before,
  # and they fail.
  module Toolsets
    module_function

    def attenuation
      draws = population
      { population: -> { draws }, observed: method(:revealed), refusal: Lain::Toolset::UnknownTool }
    end

    # Four sets of decreasing size plus the empty one, each crossed with the
    # requests below. Built ONCE and captured: T1 made construction eager --
    # the canonical schema and its digest are computed before the freeze -- so a
    # population rebuilt per law would pay for it repeatedly.
    def population
      tools = %w[bash glob grep read_file].map { |name| tool(name) }
      [tools, tools.first(3), tools.values_at(0, 3), tools.first(1), []]
        .map { |held| Lain::Toolset.new(held) }
        .flat_map { |subject| requests(subject.names).map { |request| [subject, request] } }
    end

    # Name subsets as DATA -- prefixes, suffixes, every PAIR, the empty request
    # and the whole list. Array slicing and `combination`, not attenuation: see
    # the note above the module.
    #
    # The pairs are here because prefixes and suffixes alone leave a hole in the
    # composition law. Two names at opposite ends of the sorted list co-occur
    # ONLY in the whole-list request, where `only(subject, request) == subject`
    # and the composition conjunct degenerates to `only(s, b) == only(s, b)` --
    # no chain passes through a narrowed intermediate holding both. Every pair
    # now has a request that genuinely narrows and still contains it.
    def requests(names)
      prefixes = names.each_index.map { |i| names.first(i + 1) }
      suffixes = names.each_index.map { |i| names.last(i + 1) }
      ([[], names] + prefixes + suffixes + names.combination(2).to_a).uniq
    end

    # A throwaway tool whose only interesting property is its name -- the whole
    # of what a capability set is keyed by. Mirrors spec/lain/toolset_spec.rb's
    # own helper.
    def tool(tool_name)
      Class.new(Lain::Tool) do
        define_method(:name) { tool_name.to_s }
        define_method(:description) { "the #{tool_name} tool" }
        def perform(_input, _context) = Lain::Tool::Result.ok("ok")
      end.new
    end

    # Every capability name a Toolset hands out through a public message, asked
    # of the DROPPED names as well as the kept ones -- which is why `candidates`
    # is a parameter rather than something derivable from the result.
    #
    # Three of these are what a reader sees: `#names`, the Enumerable, and the
    # schema sent to the model. The other two are what actually AUTHORIZES a
    # tool call -- `#include?` at effect/handler/live.rb:44 and `#fetch` at :44
    # and :69 -- and they are the ones that matter. A set honest in the first
    # three and lying in the last two passes every other law in this group while
    # a dropped tool executes end to end; spec/lain/toolset_spec.rb holds that
    # exact set and runs it through the live handler.
    #
    # `#[]` is not probed separately: it is an alias installed in Toolset's own
    # body, so it is a distinct method a subclass can leave honest while
    # overriding `#fetch`. The handler calls `#fetch`, so `#fetch` is what a
    # capability escape has to go through.
    def revealed(toolset, candidates)
      (listed(toolset) + candidates.select { |name| toolset.include?(name) } +
        candidates.flat_map { |name| fetched(toolset, name) }).uniq
    end

    def listed(toolset)
      toolset.names + toolset.map(&:name) + toolset.to_schema.map { |entry| entry["name"] }
    end

    # What a fetch hands over, under both names it could be known by: the one
    # the caller asked with and the one the tool answers to.
    def fetched(toolset, name)
      tool = toolset.fetch(name)
      [name, tool.name]
    rescue Lain::Toolset::UnknownTool
      []
    end
  end

  # == The population is EXHAUSTIVE, not sampled
  #
  # There are 34 partial interval partitions of `0..3` and they are all here.
  # A semilattice population is normally grown at random ({MeetSemilatticePopulations}
  # builds a forest, because a hand-picked shape is where an associativity bug
  # hides) -- but this order is small enough to enumerate outright, so the same
  # concern is answered by leaving nothing out rather than by sampling well.
  #
  # `ancestor_of:` is REFINEMENT and not ancestry: the group's default asks
  # `#ancestor_of?`, which this value does not answer, and the order the meet is
  # a meet OF is "every interval of mine sits inside one of yours".
  module Partitions
    module_function

    SPAN = 0..3

    # {AlgebraLaws::WITNESSES} takes the exhaustive battery's four members from
    # the END of a population, so the four that bend these laws hardest go last:
    # the bottom (claiming nothing), the top (the whole span uncut), and two
    # GAPPED partitions. A gap is what separates the common refinement from a
    # naive union of cut points, and it is where a wrong meet stops being a
    # lower bound at all.
    HARDEST = [[], [0..3], [0..1, 3..3], [0..0, 1..2]].freeze

    def refinement
      drawn = population
      { population: -> { drawn }, ancestor_of: ->(finer, coarser) { finer.refines?(coarser) } }
    end

    def population
      hardest = HARDEST.map { |ranges| partition(ranges) }
      (every_partition(SPAN) - hardest) + hardest
    end

    # Every ascending, non-overlapping selection of intervals inside the span --
    # which is every value {Lain::IntervalPartition} will accept over it, the
    # empty one included.
    def every_partition(span)
      subsets(intervals(span)).select { |ranges| disjoint?(ranges) }.map { |ranges| partition(ranges) }
    end

    def intervals(span) = span.flat_map { |first| (first..span.max).map { |last| first..last } }

    def subsets(pool) = (0..pool.size).flat_map { |size| pool.combination(size).to_a }

    # Ascending AND non-overlapping in one reading: `combination` preserves the
    # pool's order, so a selection whose every neighbour pair is separated is
    # already sorted.
    def disjoint?(ranges) = ranges.each_cons(2).all? { |before, after| before.max < after.first }

    def partition(ranges) = Lain::IntervalPartition.of(SPAN, ranges, owner: "a partition")
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

    # The one span every composition claim is read over, and the four zones it
    # divides into. Four because the widest law in the group -- associativity --
    # draws THREE times, so any three consecutive draws have to be three
    # different zones; a cycle of three would hand associativity `a | a` on
    # every third iteration.
    COMPOSITION_SPAN = 0..15
    ZONE = 4
    ZONES = 4

    # == Why the population is a fixed cycle of zone-disjoint strategies
    #
    # `#|` is PARTIAL -- two strategies whose ranges overlap refuse, and `a | a`
    # always overlaps -- while the shared monoid group draws its population
    # through a NULLARY `generator` called independently per law, up to three
    # times in one check. "Draw a disjoint pair" is therefore not expressible as
    # a filter over an already-built pool: nothing downstream of the generator
    # can see the other draws.
    #
    # So the pool is built disjoint instead. Four strategies, each owning one
    # quarter of {COMPOSITION_SPAN} and proposing a real range inside it, handed
    # out in a fixed cycle: any three consecutive draws are three different
    # zones, so no law can be given an overlapping pair and none can be given
    # `a | a`. The zones carry NON-EMPTY range-sets, so the laws are read over a
    # composition that actually composes something -- an all-Identity pool would
    # satisfy every law about nothing.
    #
    # And no draw is built THROUGH `#|` (follow-up A-1): {Combinators.draw_from}
    # and {Middlewares.draw_from} fold their pool with `reduce(Identity, :>>)`,
    # so a left-absorbing `#>>` collapses every draw onto the unit and both
    # monoid laws hold vacuously. Break `#|` here in any way at all and these
    # four are untouched -- a left-absorbing `#|` answers only the left operand's
    # zone, which the commutativity law reads as different ranges out and fails.
    def composition
      drawn = Array.new(ZONES) { |zone| zoned(zone) }.cycle
      { operation: ->(a, b) { a | b }, generator: -> { drawn.next }, equal: observationally_equal }
    end

    # One zone's worth of one span, collapsed to a marker naming the zone. The
    # range stops one index short of its zone so consecutive zones are separated
    # by a retained index rather than merely adjacent -- adjacency is legal, and
    # an off-by-one that merged two zones would then be invisible.
    def zoned(zone)
      first = zone * ZONE
      Class.new(Lain::Compaction::Strategy::Base) do
        define_method(:name) { -"zone #{zone}" }
        define_method(:propose_ranges) { |_messages, **| [first..(first + ZONE - 2)] }
        define_method(:blocks) { |_messages| [{ "type" => "text", "text" => "<zone #{zone}>" }] }
      end.new.freeze
    end

    # Two composed strategies are never `==` as objects, so equality is
    # OBSERVATIONAL -- {Combinators.observationally_equal}'s shape. What is
    # observed is both halves of the seam and not only the proposal: the ranges
    # answered over one span AND what each of them collapses to. Ranges alone
    # would leave the dispatch unread, which is the half `a | Identity`
    # collapsing exactly as `a` alone turns on.
    def observationally_equal
      probe = Array.new(COMPOSITION_SPAN.size) { |index| message("m#{index}") }
      observe = lambda do |strategy|
        strategy.ranges(probe, span: COMPOSITION_SPAN).map do |range|
          [range.first, range.max, strategy.collapse(probe[range], range:).content]
        end
      end
      ->(a, b) { observe.call(a) == observe.call(b) }
    end

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

    # {Lain::Compaction::Strategy::ElideToolObservations} restates its parent's
    # PURITY claim and not its elementwise one: elementwise is structural and
    # survives inheritance (`is_a?` is the classification), while purity is
    # registry-keyed on the EXACT class, which {Lain::Compaction::DerivationAudit}
    # both documents and depends on. So this entry carries the purity knobs
    # ALONE -- no `each:` and no `spans:`, which are the elementwise battery's
    # and would sit here unread.
    #
    # The population is the parent's, and drawn fresh on every call for the
    # reason spec/support/shared_examples/pure.rb documents: three laws over one
    # materialized population is an ordering bug the seed decides.
    def elide_on_tools_blocks
      elide_on_tools = Lain::Compaction::Strategy::ElideToolObservations.new
      { instance: -> { elide_on_tools },
        population: -> { spans } }
    end

    # {Lain::Compaction::Strategy::SummarizeConversation} restates its parent's
    # purity REFUTATION and not its elementwise one, for the mirror of the reason
    # {ElideToolObservations} restates the parent's claim: the registry is keyed
    # on the EXACT subject and scans it sign-agnostically, so a refutation is
    # dropped by a subclass exactly as a claim is, while elementwise is
    # classified structurally by `is_a?` and needs no restatement. Losing it cost
    # {Lain::Compaction::DerivationAudit} the `:incomplete_replay` and
    # `:window_or_replay` diagnoses on the one strategy in the pair that can
    # drift for oracle reasons.
    #
    # `refutes:` is a LAW NAME, not prose -- algebra_laws_spec asserts
    # `outcomes[refutes] == :fails`, so it matches the Pure battery byte for byte.
    def summarize_conversation_blocks
      strategy = Lain::Compaction::Strategy::SummarizeConversation.new(oracle: summarizer)
      { instance: -> { strategy },
        population: -> { spans },
        refutes: "reaches no mutable state",
        exhibits: { "holds an oracle, so it is not Ractor.shareable?" => -> { !Ractor.shareable?(strategy) } } }
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
