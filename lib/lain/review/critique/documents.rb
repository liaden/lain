# frozen_string_literal: true

module Lain
  module Review
    class Critique
      # A set of documents a {Critique} reads in place of a diff: clusters of
      # paths under one read root, each read whole by its own fresh child,
      # beside shared files every child reads too.
      #
      # Documents have no revision, so the record's `head_ref` is the
      # {Source::Corpus}'s content address, and the children run in the root
      # ({ReadRoots}) rather than in a checkout. Every byte a child is shown
      # comes through the corpus's projection, so a secret arrives masked.
      #
      # A cluster is never split: it is the unit a reviewer judges as a whole,
      # so one over the child's window refuses the critique rather than being
      # cut where the window happens to fall.
      class Documents
        # Read-only: a document review must not edit what it reviews.
        ROLE = :reviewer_code

        REFUSED = "the document critique refused before spawning anything: "

        NOTHING = "#{REFUSED}no cluster was named, so there is nothing to critique".freeze

        MISSING = "#{REFUSED}%<path>s is not a file under %<root>s".freeze

        WITHHELD = "#{REFUSED}%<path>s was withheld from the documents under %<root>s: %<why>s".freeze

        # A chat read of such a file asks a human first, and a reviewer child
        # has nobody to ask, so the document is refused rather than read.
        GATED = "#{REFUSED}%<path>s is a credential-class file (%<why>s), and a reviewer child has no human to " \
                "ask before reading one -- leave it out of the documents".freeze

        EMPTY_CLUSTER = "#{REFUSED}cluster %<label>s names no document".freeze

        TWICE = "#{REFUSED}%<path>s is named twice -- a document belongs to one cluster, or to the shared " \
                "context, and not to both".freeze

        # The children run in the root, so a name read from anywhere else
        # resolves somewhere the brief did not say.
        RENAMED = "#{REFUSED}the corpus has its documents named from %<base>s, not from %<root>s, the root " \
                  "they are read under -- build it with no `named_from:`".freeze

        HEADLINE = "critique of %<count>d document cluster%<plural>s under %<root>s, each read by the %<role>s role"

        Cluster = Data.define(:label, :paths) do
          def initialize(label:, paths:)
            super(label: -label.to_s, paths: Array(paths).map { -_1.to_s }.freeze)
          end
        end

        Document = Data.define(:path, :text)

        # @return [String] the directory every path is read under and named from, absolute
        attr_reader :root

        # @return [String] the corpus's content address, standing in for a revision
        attr_reader :head_ref

        # @param corpus [Source::Corpus] the tree the documents are read out of
        # @param clusters [Array<Cluster>] in the order their findings merge
        # @param brief [String] what the set is, told to every child
        # @param shared [Array<String>] paths every child reads beside its cluster
        # @raise [Refused] for a corpus named from elsewhere, an empty cluster, a
        #   path named twice, or a path the corpus cannot show a child
        def initialize(corpus:, clusters:, brief:, shared: [])
          @root = -corpus.root
          raise Refused, format(RENAMED, base: corpus.named_from, root:) unless corpus.named_from == root

          @head_ref = corpus.head_ref
          @brief = -brief.to_s
          refuse_repeats!([*shared, *clusters.flat_map(&:paths)])
          @shared = read(corpus, shared)
          @clusters = clusters.map { |cluster| partition(corpus, cluster) }.freeze
          freeze
        end

        # @return [Symbol] the catalog role a document critique defaults to
        def role = ROLE

        # A reviewer child has nobody to ask, so what a chat would park for a
        # human is refused instead, whatever guard the caller's spawn holds.
        #
        # @param spawn [Skill::RoleSpawn]
        # @return [Skill::RoleSpawn] its never-parking copy
        def spawned(spawn) = spawn.never_parking

        # @raise [Refused] when there is nothing to critique
        def refuse_unreadable!
          raise Refused, NOTHING if @clusters.empty?
        end

        # @param budget [Budget]
        # @param brief [#call] `(chunk, ordinal, count) -> Brief`
        # @return [Array<Partition>] one per cluster, every one measured to fit
        def chunks(budget:, brief:) = Clusters.new(budget:, brief:).fitted(@clusters)

        # @return [Brief]
        def brief(instructions:, chunk:, ordinal:, count:)
          Brief.new(instructions:, about: @brief, shared: @shared, chunk:, ordinal:, count:, root:, head_ref:)
        end

        # @return [String]
        def headline(count:, role:) = format(HEADLINE, count:, plural: count == 1 ? "" : "s", root:, role:)

        private

        def refuse_repeats!(paths)
          twice = paths.tally.find { |_path, count| count > 1 }
          raise Refused, format(TWICE, path: twice.first) if twice
        end

        def partition(corpus, cluster)
          raise Refused, format(EMPTY_CLUSTER, label: cluster.label) if cluster.paths.empty?

          Partition.new(label: cluster.label, files: read(corpus, cluster.paths))
        end

        def read(corpus, paths) = paths.map { |path| document(corpus, path) }.freeze

        def document(corpus, path)
          refuse_unshowable!(corpus, path)
          Document.new(path: -path.to_s, text: -Utf8.legible(corpus.file_at(head_ref, path)))
        end

        def refuse_unshowable!(corpus, path)
          verdict = corpus.verdict_at(path)
          raise Refused, format(GATED, path:, why: verdict.explanation) if verdict&.gated?
          return if verdict

          withheld = corpus.withheld.find { |held| held.path == path }
          raise Refused, format(WITHHELD, path:, root:, why: withheld.explanation) if withheld

          raise Refused, format(MISSING, path:, root:)
        end
      end

      class Documents
        Brief = Data.define(:instructions, :about, :shared, :chunk, :ordinal, :count, :root, :head_ref)

        # One child's prompt. The documents are shown whole rather than left
        # for the child to read, so what it judged is exactly what {#key} names.
        class Brief
          KEY_SCHEME = "critique-documents-brief-v1"

          CHUNK = "# The documents under critique"

          SHARED = "# Shared context, read by every reviewer"

          DOCUMENTS = "# The cluster's documents"

          ROOT = "Every path here is named from %<root>s, your working directory, so a relative path you read " \
                 "resolves there. The documents below are shown as they stand, secrets masked."

          OTHERS = "Other reviewers are critiquing the other clusters in this set."

          def to_s
            [instructions, "#{CHUNK}\n\n#{where}", *shared_section, "#{DOCUMENTS}\n\n#{shown(files)}"].join("\n\n")
          end

          def key = Keying.digest(KEY_SCHEME, [to_s])

          def label = chunk.detail.named(chunk.label)

          def paths = files.map(&:path)

          def heading = "## cluster #{ordinal} of #{count} -- #{label}\nfiles: #{paths.join(", ")}"

          private

          def files = chunk.files

          def where
            "cluster #{ordinal} of #{count}: #{label}\n#{about}\nfiles: #{paths.join(", ")}\n\n" \
              "#{[format(ROOT, root:), (OTHERS if count > 1)].compact.join(" ")}"
          end

          def shared_section = shared.empty? ? [] : ["#{SHARED}\n\n#{shown(shared)}"]

          def shown(documents) = documents.map { |document| "## #{document.path}\n\n#{document.text}" }.join("\n\n")
        end

        # Lends the documents' root in place of a checkout: each child runs
        # with the root as its working directory. The never-parking guard
        # ({Documents#spawned}) refuses a read outside that directory and the
        # project root the guard was built over.
        class ReadRoots
          # @param root [String] the documents' read root
          # @param worker_env [WorkerEnv] the environment the children would
          #   otherwise run in, which keeps everything but its directory
          def initialize(root:, worker_env:)
            @lent = worker_env.with(cwd: -root.to_s)
            freeze
          end

          # The revision is the documents' content address, which names no
          # checkout, so it goes unread.
          #
          # @param _revision [String]
          # @yieldparam worker_env [WorkerEnv] rooted at the documents
          # @return [Object] the block's value
          def hold(_revision) = yield(@lent)
        end
      end
    end
  end
end
