# frozen_string_literal: true

require "yaml"
require "json"

module Lain
  module Bench
    # The M6 retrieval eval (6-2.4): a deterministic, offline comparison of the
    # five retrieval arms -- manifest, bm25, vector, hybrid, graph -- over the
    # committed gold corpus, ranked by recall@k with a tokens-on-recall column.
    #
    # It is a Compare-STYLE report, not a Compare: Compare folds many runs into
    # one distribution PER METRIC (compare.rb), whereas the sweep folds each
    # ARM's per-query recall into its OWN distribution and ranks the arms. That
    # is a different shape than Compare::Run's scalar score, so -- per the plan
    # card's escalation trigger -- the sweep does NOT reshape Compare's public
    # surface. It reuses the one piece that fits verbatim: {Compare::Distribution}
    # (the mean/median/min/max value object), and renders its own ranked table.
    #
    # Zero network by construction: the vector arm reads COMMITTED fixture
    # embeddings (corpus/corpus_embeddings.json) through {Embeddings}, never a
    # live embedder, so the whole sweep runs under the suite's offline posture.
    # The gold corpus and its embeddings ship WITH THE GEM (lib/lain/bench/corpus/)
    # rather than living under spec/ -- the eval is bound to exactly that gold
    # set, and a `lain bench sweep` run in an installed gem (no spec/ tree) needs
    # them present.
    class Sweep
      # Raised when the committed embeddings were recorded under a different
      # model than the sweep asks for -- a silent stale fixture would measure the
      # wrong model's geometry and lie. Names both ids (see {Embeddings.load}).
      class StaleEmbeddings < Lain::Error; end

      # Raised when a corpus or embeddings path does not exist -- a packaging
      # mistake or a deleted fixture, never a normal ArgumentError. Named and
      # path-bearing like {StaleEmbeddings}, so the exe presents it without a
      # backtrace (`exe/lain`'s `rescue Lain::Error` on the sweep command)
      # instead of an unhelpful Errno::ENOENT.
      class MissingCorpus < Lain::Error; end

      DEFAULT_K = 5
      DEFAULT_MODEL = Embedder::Ollama::DEFAULT_MODEL

      # One wikilink hop past the lexical seed: the gold leaves sit exactly one
      # `[[link]]` out of their class-overview hub (retrieval_corpus.yml), which
      # is the whole ability the graph arm exists to probe.
      GRAPH_HOPS = 1

      # The recall block's opening tag (Context::Recall#recall_block). A rendered
      # tail that starts with it is a real recall injection to be counted; a tail
      # that does not means the arm recalled nothing for that query (zero tokens).
      RECALL_TAG = "<recall>"
      private_constant :RECALL_TAG

      CORPUS_PATH = File.expand_path("corpus/retrieval_corpus.yml", __dir__)
      EMBEDDINGS_PATH = File.expand_path("corpus/corpus_embeddings.json", __dir__)

      COLUMNS = ["arm", "n", "mean", "median", "min", "max", "recall tokens"].freeze
      private_constant :COLUMNS

      # One gold query: the text, its gold ids, and the ability class it probes.
      Query = Data.define(:text, :gold_ids, :klass)

      # A committed text => vector map standing in for a live {Embedder} -- the
      # vector arm's determinism oracle. Keyed on the SAME text the arm embeds
      # ("description\nbody"), resolved through each item's content digest so the
      # committed JSON stays addressable and a corpus edit that changes a body
      # misses loudly rather than scoring against a stale vector.
      class Embeddings
        # @raise [StaleEmbeddings] when the fixture's model id differs from the
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

          raise StaleEmbeddings, "fixture embeddings at #{path} were recorded under model " \
                                 "#{recorded.inspect} but the sweep requested #{model.inspect}; " \
                                 "regenerate corpus_embeddings.json (the :ollama sweep-fixture spec)"
        end
        private_class_method :check_model!

        # The digest is Canonical over everything BUT itself, recorded at
        # regeneration (the :ollama sweep-fixture spec) -- corruption detection
        # for the committed vectors, not a security control.
        def self.check_content!(data, path)
          recorded = data.fetch("content_digest") do
            raise StaleEmbeddings, "fixture embeddings at #{path} carry no content digest; " \
                                   "regenerate corpus_embeddings.json (the :ollama sweep-fixture spec)"
          end
          computed = Canonical.digest(data.except("content_digest"))
          return if recorded == computed

          raise StaleEmbeddings, "fixture embeddings at #{path} fail their content digest check " \
                                 "(recorded #{recorded}, computed #{computed}); the vectors were " \
                                 "edited after recording -- regenerate corpus_embeddings.json"
        end
        private_class_method :check_content!

        def self.item_vectors(by_digest, items)
          items.to_h do |item|
            ["#{item.description}\n#{item.body}", by_digest.fetch(item.digest) do
              raise StaleEmbeddings, "no committed embedding for item #{item.id.inspect} " \
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
              raise StaleEmbeddings, "no committed embedding for text #{text.inspect}; " \
                                     "regenerate corpus_embeddings.json"
            end
          end
        end
      end

      # Fixes the graph arm's hop count so it presents the SAME `#search(query)`
      # duck the other arms do -- both the grader and Context::Recall then treat
      # every arm identically, and the hop policy lives in exactly one place.
      HopSearch = Data.define(:graph, :hops) do
        def search(query) = graph.search(query, hops:)
      end
      private_constant :HopSearch

      # @param k [Integer] the retrieval depth recall is scored at (recall@k).
      # @param model [String] the embedding model the fixture must match.
      # rubocop:disable Naming/MethodParameterName -- `k` is the pinned recall@k
      # name, matching Grader::Recall and Context::Recall's own k:.
      def initialize(k: DEFAULT_K, corpus_path: CORPUS_PATH, embeddings_path: EMBEDDINGS_PATH, model: DEFAULT_MODEL)
        @k = Integer(k)
        raise ArgumentError, "k must be positive, got #{@k}" unless @k.positive?

        @corpus_path = corpus_path
        @embeddings_path = embeddings_path
        @model = model
      end
      # rubocop:enable Naming/MethodParameterName

      # A Compare-style ranked table as a String -- never printed (output
      # discipline). Memoized so "report twice" is byte-identical for free.
      def report
        @report ||= render(ranked)
      end

      private

      # [name, {recall:, tokens:}] per arm, sorted by recall mean desc then name
      # so ties never depend on Hash order -- the whole point of the determinism AC.
      def ranked
        measured.sort_by { |name, dists| [-dists.fetch(:recall).mean, name] }
      end

      def measured
        arms.to_h { |name, arm| [name, distributions_for(arm)] }
      end

      def distributions_for(arm)
        { recall: Compare::Distribution.new(queries.map { |query| recall_at_k(arm, query) }),
          tokens: Compare::Distribution.new(queries.map { |query| recall_tokens(arm, query) }) }
      end

      def recall_at_k(arm, query)
        Grader::Recall.new(gold_ids: query.gold_ids).grade(arm.search(query.text), k: @k).score
      end

      # Tokens-on-recall from the dry-rendered Context::Recall block: build the
      # recall stage over this arm, render it against the bare query, and count
      # the injected block. No BPE tokenizer lives in-process, so this is a
      # whitespace-token proxy -- deterministic and offline, which is what the
      # eval needs; the column measures relative cost across arms, not exact
      # provider billing.
      def recall_tokens(arm, query)
        tail = Context::Recall.new(index: arm, k: @k).call([user_message(query.text)]).last["content"].last
        tail["text"].to_s.start_with?(RECALL_TAG) ? tail["text"].split.size : 0
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
        @index ||= items.inject(Memory::Index.empty(store: Store.new)) { |acc, item| acc.write(item) }
      end

      def items
        @items ||= corpus.fetch("items").map do |raw|
          Memory::Item.new(id: raw.fetch("id"), description: raw.fetch("description"), body: raw.fetch("body"))
        end
      end

      def queries
        @queries ||= corpus.fetch("queries").map do |raw|
          Query.new(text: raw.fetch("query"), gold_ids: raw.fetch("gold_ids"), klass: raw.fetch("class"))
        end
      end

      def corpus
        @corpus ||= YAML.safe_load_file(existing!(@corpus_path))
      end

      def embeddings
        @embeddings ||= Embeddings.load(path: existing!(@embeddings_path), items:, model: @model)
      end

      # A missing corpus or embeddings file is a packaging/checkout mistake,
      # not user input to refuse (contrast Bench::CLI::Refusal) -- it names the
      # exact path so the fix is obvious, and it is Errno::ENOENT's replacement,
      # never its wrapper, so the exe's `rescue Lain::Error` catches it cleanly.
      def existing!(path)
        raise MissingCorpus, "no sweep corpus file at #{path}" unless File.file?(path)

        path
      end

      def render(ranked_arms)
        rows = ranked_arms.map { |name, dists| row_for(name, dists) }
        [header, "", Compare::Table.new(headers: COLUMNS, rows:).to_s].join("\n")
      end

      def header
        "Sweep — recall@#{@k} over #{queries.size} queries, #{items.size} items (model #{@model})"
      end

      def row_for(name, dists)
        recall = dists.fetch(:recall)
        [name, recall.n.to_s,
         *[recall.mean, recall.median, recall.min, recall.max].map { |value| format("%.3f", value) },
         format("%.1f", dists.fetch(:tokens).mean)]
      end
    end
  end
end
