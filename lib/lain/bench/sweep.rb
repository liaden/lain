# frozen_string_literal: true

require "yaml"
require "json"

module Lain
  module Bench
    # The retrieval eval: a deterministic, offline comparison of the
    # five retrieval arms -- manifest, bm25, vector, hybrid, graph -- over the
    # committed gold corpus, ranked by recall@k with a tokens-on-recall column.
    #
    # A Compare-STYLE report, not a {Compare}: Compare folds many runs into one
    # distribution PER METRIC, whereas this folds each ARM's per-query recall
    # into its OWN distribution and ranks the arms. A different shape from
    # {Compare::Run}'s scalar score, so the transposed fold is delegated to
    # {Compare::ArmFold} rather than reshaping Compare's public surface.
    #
    # Unlike its siblings it renders ONE ranked table rather than a section per
    # metric, because the tokens-on-recall column is a SECOND metric's mean
    # riding beside the first metric's distribution: ranking by recall is the
    # headline, and tokens is what that recall cost. So it takes ArmFold's six
    # shared cells and appends its own seventh, rather than asking for a section
    # it would then have to take apart.
    #
    # Zero network by construction: the vector arm reads COMMITTED fixture
    # embeddings through {Embeddings}, never a live embedder. The gold corpus
    # and its embeddings ship WITH THE GEM rather than living under spec/ --
    # the eval is bound to exactly that gold set, and a `lain bench sweep` run
    # in an installed gem has no spec/ tree.
    class Sweep
      # A packaging mistake or a deleted fixture, never a normal ArgumentError.
      # Named and path-bearing so the exe presents it without a backtrace
      # instead of an unhelpful Errno::ENOENT.
      class MissingCorpus < Lain::Error; end

      DEFAULT_K = 5
      DEFAULT_MODEL = Embedder::Ollama::DEFAULT_MODEL

      # One wikilink hop past the lexical seed: the gold leaves sit exactly one
      # `[[link]]` out of their class-overview hub (retrieval_corpus.yml), which
      # is the whole ability the graph arm exists to probe.
      GRAPH_HOPS = 1

      # A rendered tail starting with this is a real recall injection to be
      # counted; one that does not means the arm recalled nothing for that query.
      RECALL_TAG = "<recall>"
      private_constant :RECALL_TAG

      CORPUS_PATH = Paths::Shipped::BENCH_CORPUS_PATH
      EMBEDDINGS_PATH = Paths::Shipped::BENCH_EMBEDDINGS_PATH

      # ArmFold's seven, plus this sweep's own. Extended, never restated,
      # so a column added to the shared fold cannot silently skip this report.
      COLUMNS = [*Compare::ArmFold::HEADERS, "recall tokens", "ndcg@10", "abstention", "support@200",
                 "graph from bm25 top 5"].freeze
      private_constant :COLUMNS

      NDCG_K = 10
      SUPPORT_BUDGET = 200
      # Split by query; gold items may appear in both, since a wikilink query needs its hub's leaves.
      SPLITS = %w[dev test].freeze

      # How many bm25 hits seed the graph control, in place of the manifest seed.
      CONTROL_SEEDS = 5
      private_constant :CONTROL_SEEDS

      WIKILINK = /\[\[([^\[\]]+)\]\]/
      private_constant :WIKILINK

      NO_CELL = "-"
      private_constant :NO_CELL

      RECALL_FMT = ->(value) { format("%.3f", value) }
      private_constant :RECALL_FMT

      # One gold query: the text, its gold ids, the ability class it probes, its split and its
      # graded relevance. An abstention query has no gold ids: the right answer is no hits.
      Query = Data.define(:text, :gold_ids, :klass, :split, :relevance) do
        def abstention? = gold_ids.empty?
      end

      # A committed text => vector map standing in for a live {Embedder}. Keyed
      # on the SAME text the arm embeds, resolved through each item's content
      # digest so the committed JSON stays addressable and a corpus edit that
      # changes a body misses loudly rather than scoring against a stale vector.
      class Embeddings
        # @raise [Error] when the fixture's model id differs from the
        #   requested one (named on BOTH sides so the fix is obvious), or when
        #   its recorded content digest no longer matches the vectors -- a
        #   hand-edited float would otherwise shift the headline in silence.
        def self.load(path:, items:, model:)
          data = JSON.parse(File.read(path))
          check_model!(data.fetch("model_id"), model, path)
          check_content!(data, path)
          new(item_vectors(data.fetch("items"), items).merge(data.fetch("queries")))
        end

        def self.check_model!(recorded, model, path)
          return if recorded == model

          # A silent stale fixture would measure the wrong model's geometry and lie.
          # Names both ids (see {Embeddings.load}).
          raise Error, "fixture embeddings at #{path} were recorded under model " \
                       "#{recorded.inspect} but the sweep requested #{model.inspect}; " \
                       "regenerate corpus_embeddings.json (the :ollama sweep-fixture spec)"
        end
        private_class_method :check_model!

        # Canonical over everything BUT itself, recorded at regeneration --
        # corruption detection for the committed vectors, not a security control.
        def self.check_content!(data, path)
          recorded = data.fetch("content_digest") do
            raise Error, "fixture embeddings at #{path} carry no content digest; " \
                         "regenerate corpus_embeddings.json (the :ollama sweep-fixture spec)"
          end
          computed = Canonical.digest(data.except("content_digest"))
          return if recorded == computed

          raise Error, "fixture embeddings at #{path} fail their content digest check " \
                       "(recorded #{recorded}, computed #{computed}); the vectors were " \
                       "edited after recording -- regenerate corpus_embeddings.json"
        end
        private_class_method :check_content!

        def self.item_vectors(by_digest, items)
          items.to_h do |item|
            ["#{item.description}\n#{item.body}", by_digest.fetch(item.digest) do
              raise Error, "no committed embedding for item #{item.id.inspect} " \
                           "(digest #{item.digest}); regenerate corpus_embeddings.json"
            end]
          end
        end
        private_class_method :item_vectors

        def initialize(map)
          @map = map.freeze
          freeze
        end

        # The {Embedder} duck: one vector per text, in order. A text absent from
        # the committed fixture is a stale fixture, never a silent zero vector.
        def embed(texts)
          texts.map do |text|
            @map.fetch(text) do
              raise Error, "no committed embedding for text #{text.inspect}; " \
                           "regenerate corpus_embeddings.json"
            end
          end
        end
      end

      # Fixes the graph arm's hop count so it presents the SAME `#search(query)`
      # duck the other arms do: the grader and Context::Recall then treat every
      # arm identically, and the hop policy lives in one place.
      HopSearch = Data.define(:graph, :hops) do
        def search(query) = graph.search(query, hops:)
      end
      private_constant :HopSearch

      # The graph arm's control: the same one-hop wikilink walk, but from bm25's top hits instead of
      # the manifest seed, so a graph win cannot be only a better seed.
      SeededHop = Data.define(:bm25, :items) do
        def search(query)
          seeds = bm25.search(query).first(CONTROL_SEEDS)
          reached = seeds.flat_map { |seed| linked(seed.id) }.uniq - seeds.map(&:id)
          [*seeds, *reached.filter_map { |id| items[id] }.map { |item| hop_hit(item) }]
        end

        private

        def linked(id) = items.key?(id) ? items.fetch(id).body.scan(WIKILINK).flatten.map(&:strip) : []

        def hop_hit(item)
          Memory::Manifest::Hit.new(id: item.id, description: item.description, score: 0.5, why: "linked from a seed")
        end
      end
      private_constant :SeededHop

      # True when every gold id's line sits wholly inside the first `budget` whitespace tokens of the
      # recall block's lines.
      #
      # @param lines [Array<String>] the block's "id | description -- why" lines, in order
      # @param gold_ids [Array<String>]
      # @param budget [Integer] whitespace tokens the block may spend
      # @return [Boolean]
      def self.fully_supported?(lines, gold_ids, budget: SUPPORT_BUDGET)
        spent = 0
        held = lines.take_while { |line| (spent += line.split.size) <= budget }
        (gold_ids - held.map { |line| line.split(" | ").first }).empty?
      end

      # @param k [Integer] the retrieval depth recall is scored at (recall@k).
      # @param corpus_path [String] path to the retrieval fixture (queries, gold
      #   ids, classes); defaults to the committed corpus.
      # @param embeddings_path [String] path to the committed embeddings JSON,
      #   content-digest checked against the corpus at load.
      # @param model [String] the embedding model the fixture must match.
      # @param split [String] "dev" or "test"; the splits are never mixed in one report.
      # rubocop:disable Naming/MethodParameterName -- `k` is the pinned recall@k
      # name, matching Grader::Recall and Context::Recall's own k:.
      def initialize(k: DEFAULT_K, corpus_path: CORPUS_PATH, embeddings_path: EMBEDDINGS_PATH, model: DEFAULT_MODEL,
                     split: "dev")
        @k = Integer(k)
        raise ArgumentError, "k must be positive, got #{@k}" unless @k.positive?
        unless SPLITS.include?(split)
          raise ArgumentError,
                "split must be one of #{SPLITS.join(", ")}, got #{split.inspect}"
        end

        @split = split

        @corpus_path = corpus_path
        @embeddings_path = embeddings_path
        @model = model
      end
      # rubocop:enable Naming/MethodParameterName

      # Memoized so that reporting twice is byte-identical for free.
      def report
        @report ||= render(ranked)
      end

      private

      # Sorted by recall mean descending then name, so ties never depend on Hash
      # order.
      def ranked
        measured.sort_by { |name, dists| [-dists.fetch(:recall).mean, name] }
      end

      def measured
        arms.to_h { |name, arm| [name, distributions_for(arm)] }
      end

      def distributions_for(arm)
        { recall: Compare::Distribution.new(positives.map { |query| recall_at_k(arm, query) }),
          tokens: Compare::Distribution.new(positives.map { |query| recall_tokens(arm, query) }),
          ndcg: Compare::Distribution.new(positives.map { |query| ndcg_at_k(arm, query) }),
          support: Compare::Distribution.new(positives.map { |query| support_of(arm, query) }),
          abstention: Compare::Distribution.new(abstaining.map { |query| abstains?(arm, query) ? 1.0 : 0.0 }) }
      end

      def ndcg_at_k(arm, query)
        Grader::Ndcg.new(relevance: query.relevance).grade(arm.search(query.text), k: NDCG_K).score
      end

      def abstains?(arm, query) = arm.search(query.text).first(@k).empty?

      def support_of(arm, query)
        lines = recall_block(arm, query).to_s.lines.map(&:chomp).grep_v(%r{\A</?recall>\z})
        self.class.fully_supported?(lines, query.gold_ids) ? 1.0 : 0.0
      end

      def recall_at_k(arm, query)
        Grader::Recall.new(gold_ids: query.gold_ids).grade(arm.search(query.text), k: @k).score
      end

      def control_recall
        arm = SeededHop.new(bm25: arms.fetch("bm25"), items: items.to_h { |item| [item.id, item] })
        Compare::Distribution.new(positives.map { |query| recall_at_k(arm, query) }).mean
      end

      # Tokens-on-recall from the dry-rendered Context::Recall block. No BPE
      # tokenizer lives in-process, so this is a whitespace-token proxy:
      # deterministic and offline, measuring relative cost across arms rather
      # than exact provider billing.
      def recall_tokens(arm, query) = recall_block(arm, query)&.split&.size || 0

      def recall_block(arm, query)
        tail = Context::Recall.new(index: arm, k: @k).call([user_message(query.text)]).last["content"].last
        tail["text"] if tail["text"].to_s.start_with?(RECALL_TAG)
      end

      def user_message(text)
        { "role" => "user", "content" => [{ "type" => "text", "text" => text }] }
      end

      def arms
        bm25 = Memory::Bm25Cache.new.for(index)
        vector = Memory::Vector.new(index:, embedder: embeddings)
        { "manifest" => Memory::Manifest.new(index),
          "bm25" => bm25,
          "vector" => vector,
          "hybrid" => Memory::Hybrid.new(bm25:, vector:),
          "graph" => HopSearch.new(graph: Memory::Graph.new(index:), hops: GRAPH_HOPS) }
      end

      def index
        @index ||= items.inject(Memory::Index.empty(store: Dag::Factory.store)) { |acc, item| acc.write(item) }
      end

      def items
        @items ||= corpus.fetch("items").map do |raw|
          Memory::Item.new(id: raw.fetch("id"), description: raw.fetch("description"), body: raw.fetch("body"))
        end
      end

      def queries
        @queries ||= corpus.fetch("queries").map { |raw| query_from(raw) }.select { |query| query.split == @split }
      end

      def positives = queries.reject(&:abstention?)

      def abstaining = queries.select(&:abstention?)

      def query_from(raw)
        gold_ids = raw.fetch("gold_ids")
        Query.new(text: raw.fetch("query"), gold_ids:, klass: raw.fetch("class"), split: raw.fetch("split"),
                  relevance: raw.fetch("relevance") { gold_ids.to_h { |id| [id, 1] } })
      end

      def corpus
        @corpus ||= YAML.safe_load_file(existing!(@corpus_path, "corpus"))
      end

      def embeddings
        @embeddings ||= Embeddings.load(path: existing!(@embeddings_path, "embeddings"), items:, model: @model)
      end

      # A missing corpus or embeddings file is a packaging/checkout mistake,
      # not user input to refuse (contrast Bench::CLI::Refusal) -- it names the
      # exact path so the fix is obvious, and it is Errno::ENOENT's replacement,
      # never its wrapper, so the exe's `rescue Lain::Error` catches it cleanly.
      # `kind` says WHICH file is missing -- the corpus and the embeddings are
      # two different paths, and a refusal that always says "corpus" sends
      # someone hunting the wrong file when it is the embeddings that never
      # got regenerated.
      def existing!(path, kind)
        raise MissingCorpus, "no sweep #{kind} file at #{path}" unless File.file?(path)

        path
      end

      def render(ranked_arms)
        rows = ranked_arms.map { |name, dists| row_for(name, dists) }
        [header, "", Compare::Table.new(headers: COLUMNS, rows:).to_s, *verdicts(ranked_arms)].join("\n")
      end

      def header
        "Sweep — #{split_note}: recall@#{@k} over #{positives.size} queries, #{abstaining.size} abstention, " \
          "#{items.size} items (model #{@model})"
      end

      def split_note
        @split == "dev" ? "dev split, the default; --split test scores the held-out queries" : "test split"
      end

      def row_for(name, dists)
        [*fold.row(name, dists.fetch(:recall), fmt: RECALL_FMT), format("%.1f", dists.fetch(:tokens).mean),
         RECALL_FMT.call(dists.fetch(:ndcg).mean), rate(dists.fetch(:abstention)), rate(dists.fetch(:support)),
         name == "graph" ? RECALL_FMT.call(control_recall) : NO_CELL]
      end

      def rate(dist) = dist.n.zero? ? NO_CELL : RECALL_FMT.call(dist.mean)

      def verdicts(ranked_arms)
        means = ranked_arms.to_h { |name, dists| [name, dists.fetch(:recall).mean] }
        return [] if means.fetch("hybrid") > means.fetch("bm25")

        ["", "hybrid does not beat bm25 on recall@#{@k} (#{RECALL_FMT.call(means.fetch("hybrid"))} vs " \
             "#{RECALL_FMT.call(means.fetch("bm25"))})"]
      end

      def fold = @fold ||= Compare::ArmFold.new
    end
  end
end
