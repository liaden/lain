# frozen_string_literal: true

module Lain
  module Review
    # `/critique` over the review a chat is holding: the critique skill's
    # instructions, run by one fresh role child per chunk of the changeset, and
    # the findings merged back in chunk order. A set of {Documents} is
    # critiqued the same way, one child per cluster; what follows is the diff.
    #
    # == Why not the skill inline
    #
    # The skill inline is a model turn over the WORKING TREE, and the working
    # tree is not what is under review: the human goes on editing while a round
    # is open, so an inline critique reads bytes nobody reviewed. So every byte
    # a child is SHOWN comes out of git objects -- its prompt is the chunk's
    # hunks as the changeset parsed them -- and its working directory is a
    # detached checkout of the reviewed head ({Checkouts}), so a relative read
    # lands on committed bytes. The read tools confine no path, by the design
    # that keeps the secret boundary in one place, so an absolute path still
    # reaches the project: what holds is that no request carries working-tree
    # bytes the model did not ask for, and the brief says as much.
    #
    # == Chunks are sized to the child's window, or nothing is spent
    #
    # {Bounds#each_critique_chunk} packs at a LINE ceiling, and a line is not a
    # token. The ceiling is derived here from the window the child's model is
    # served, less the role's prelude, the response it may write and
    # {SCHEMA_RESERVE_TOKENS}, at this changeset's own measured bytes per line
    # -- and a chunk's content may take only half of what that leaves, because
    # a child told it may read has every read's result ride its NEXT request.
    # A mean can still pack a chunk of wide lines past its share, so every
    # chunk is then MEASURED ({Packing}), and the ceiling narrowed until they
    # all fit. Where no narrowing can help, the whole critique refuses by name
    # before a checkout is cut or a child spawned: a critique of chunks one and
    # two that refuses at three is neither a critique nor a refusal.
    #
    # A window nobody vouches for refuses too. Sizing to a guess is how the
    # fixed 7,000-line default came to send ~99k tokens at a 32k window.
    class Critique
      # A critique that cannot run as asked, said before anything was spent.
      class Refused < Error; end

      # The catalog role each chunk of a diff is read by, unless whoever
      # constructs a critique names another through `role:`.
      ROLE = :diff_critic

      # A FRESH root: a child conditioned on the chat's own conversation about
      # the change is not an independent reading of it.
      MODE = :fresh

      # Canonical bytes to a token, for every estimate here. Three, not
      # {ProxyBytes::BYTES_PER_TOKEN}'s four: that figure is quoted for English
      # prose, and real tokenizers land nearer three bytes a token on code and
      # diff text, which is most of what a brief carries.
      BYTES_PER_TOKEN = 3

      # How a chunk's share is cut: its content takes at most 1/READ_SHARE of
      # what the instructions and the reserves leave. The rest is the child's,
      # for the results of the reads it is invited to make.
      READ_SHARE = 2

      # The tokens a child request carries beyond its prompt, its prelude and
      # its response: the read tools' schemas and the message framing. The four
      # read tools' schemas measured 3,710 canonical bytes, about 1,240 tokens
      # at {BYTES_PER_TOKEN}.
      SCHEMA_RESERVE_TOKENS = 1_536

      # "refused" stays for records written before a raised error was told apart.
      OUTCOMES = %w[answered refused failed empty].freeze

      NO_REVISION = "the open review has no reviewed revision to critique from -- it was opened over a " \
                    "tree rather than over commits, so /critique would read the working tree it is meant to " \
                    "avoid. Open a /review of a branch or pull request to critique one."

      NOTHING_CHANGED = "/critique refused before spawning anything: the open review changes no file, so there " \
                        "is nothing to critique"

      UNVOUCHED = "/critique refused before spawning anything: the window for %<model>s is %<provenance>s " \
                  "(%<window>d tokens): nothing the server has reported vouches for it, and `--num-ctx` is a " \
                  "request rather than a confirmation. On ollama, send one turn so the runner loads and reports " \
                  "its window, then run /critique again; a provider that reports no window needs a model lain's " \
                  "published table knows."

      RESERVE_OVER = "/critique refused before spawning anything: a %<response>d-token response reserve " \
                     "and %<overhead>d tokens of instructions, role prelude and tool schemas leave " \
                     "no room for a chunk in %<model>s's %<window>d-token window -- run " \
                     "against a model with a larger window"

      FILE_OVER = "/critique refused before spawning anything: %<path>s alone estimates %<estimate>d tokens, " \
                  "over the %<room>d a chunk may take in %<model>s's %<window>d-token window (half of what the " \
                  "instructions and a %<response>d-token response reserve leave, the other half kept for the " \
                  "critic's reads) -- a file is the smallest chunk a critique splits by, so review that file on " \
                  "its own or run against a model with a larger window"

      CHUNK_OVER = "/critique refused before spawning anything: %<chunk>s (%<paths>s) estimates %<estimate>d " \
                   "tokens, over the %<room>d a chunk may take in %<model>s's %<window>d-token window -- the " \
                   "chunker packs by line count and cannot split a file, so a file of many short lines sets a " \
                   "line ceiling its wider-lined neighbours pack past; critique a narrower range of this change"

      CLUSTER_OVER = "the document critique refused before spawning anything: cluster %<chunk>s (%<paths>s) " \
                     "estimates %<estimate>d tokens, over the %<room>d a cluster may take in %<model>s's " \
                     "%<window>d-token window -- one critic reads a cluster whole, so split it into smaller " \
                     "clusters or run against a model with a larger window"

      NOTHING_SAID = "the critic came back with nothing to say"

      # What a chunk nobody critiqued leaves in the RECORD. The record travels
      # on its own, and a reader of one has no heading above it, so the words
      # name the chunk themselves; the merged prose already carries
      # {Brief#heading} and keeps the bare reason, or it would say the same
      # thing twice running.
      CHUNK_REFUSED = "chunk %<ordinal>d of %<count>d (%<label>s) was not critiqued: %<reason>s"

      EMPTY = "no file of this commit survives in the changeset, so nothing was sent"

      # Each critic is a full child per chunk, so the count is a spend the caller names and
      # must not typo into a bill.
      MAX_CRITICS = 5

      # How many critics read each chunk unless the caller names a count; epic_review parses for the same.
      DEFAULT_CRITICS = 1

      BAD_CRITICS = "/critique refused before spawning anything: critics must be a whole number from 1 to " \
                    "%<max>d, got %<critics>s"

      NO_WINDOW = "/critique refused before spawning anything: no window is known for %<model>s, so a chunk " \
                  "cannot be sized to it -- name a model the run's provider reports a window for"

      # Said only when the chunk had several readers, so one critic renders
      # exactly as it always has.
      READERS = "%<critics>d critics read this chunk"

      HEADLINE = "critique of %<base>s..%<head>s in %<count>d chunk%<plural>s, each read by the %<role>s role " \
                 "from a checkout of %<head>s"

      # The one rule for a critics count, public so a caller can refuse before it opens anything.
      #
      # @param critics [Object] the count a caller named
      # @return [nil]
      # @raise [Refused] unless it is a whole number from 1 to {MAX_CRITICS}
      def self.refuse_bad_critics!(critics)
        return if critics.is_a?(Integer) && (1..MAX_CRITICS).cover?(critics)

        raise Refused, format(BAD_CRITICS, max: MAX_CRITICS, critics: critics.inspect)
      end

      # @param text [String]
      # @return [Integer] canonical bytes, the unit every request is measured in
      def self.bytes(text) = Canonical.dump(text.to_s).bytesize

      # ROUNDED UP, where {ProxyBytes#to_tokens} floors: that figure ends in a
      # dollar claim and understates honestly, while this one guards a window
      # and has to overstate.
      #
      # @param text [String]
      # @return [Integer]
      def self.tokens(text) = (bytes(text) + BYTES_PER_TOKEN - 1) / BYTES_PER_TOKEN

      # @param subject [Diff, Documents] what is critiqued: a held round's diff, or a set of documents
      # @param spawn [#within, #seam] {Skill::RoleSpawn}: `within(worker_env)`
      #   lends a checkout and answers `call(role, mode, prompt)`; `seam` names
      #   the child's context, for its model and its response ceiling. The
      #   subject decides which copy of it spawns ({Documents#spawned})
      # @param window [#resolve] the run's window book, asked about the reviewer's model when one is named
      # @param checkouts [#hold] cuts the checkout of the reviewed head ({Checkouts}), or lends
      #   the documents' read root ({Documents::ReadRoots})
      # @param journal [#<<] where each chunk's record lands
      # @param slots [Prompt::Slots] renders the role's prelude, which is measured
      # @param instructions [String] the rendered critique skill, with any focus
      # @param role [Symbol, nil] a {Role::Catalog} name; nil takes the changeset's own default
      # @param critics [Integer] how many independent children read each chunk,
      #   one after another
      # @param model [String, nil] a model to read the diff on in place of the
      #   run's own; chunks are then sized to ITS window
      def initialize(subject:, spawn:, window:, checkouts:, journal:, slots:, instructions:, role: nil,
                     critics: DEFAULT_CRITICS, model: nil)
        @subject = subject
        @spawn = subject.spawned(spawn)
        @window = window
        @checkouts = checkouts
        @journal = journal
        @slots = slots
        @instructions = instructions
        @role = role || @subject.role
        @critics = critics
        @model = Tools::Subagent::ModelChoice.of(model, declared_by: "/critique")
      end

      # @return [String] the merged findings
      # @raise [Refused] before any checkout or spawn
      def call
        @subject.refuse_unreadable!
        self.class.refuse_bad_critics!(@critics)

        refuse_unserved_model!
        chunks = @subject.chunks(budget:, brief: method(:brief))
        answers = @checkouts.hold(@subject.head_ref) { |worker_env| answered(chunks, @spawn.within(worker_env)) }
        rendered(answers)
      end

      private

      def budget
        context = @spawn.seam.context_factory.call
        Budget.for(window: @window, model: reviewer(context), max_tokens: context.max_tokens,
                   prelude: Role::Catalog.fetch(@role).prelude(slots: @slots))
      end

      # Asked of the run's own provider, once, so an unserved model is one refusal
      # rather than a refused record for every critic of every chunk.
      def refuse_unserved_model!
        @model.bind(@spawn.seam.context_factory.call, provider: @spawn.seam.provider)
      end

      def reviewer(context) = @model.model.empty? ? context.model : @model.model

      def brief(chunk, ordinal, count) = @subject.brief(instructions: @instructions, chunk:, ordinal:, count:)

      # One child at a time: the lent checkout serves one dispatch at once, and
      # the findings are merged in chunk order anyway.
      def answered(chunks, lent)
        count = chunks.size
        chunks.each_with_index.map do |chunk, index|
          brief = brief(chunk, index + 1, count)
          readings = Array.new(@critics) { |critic| read(lent, brief, critic + 1) }
          [brief, readings]
        end
      end

      def read(lent, brief, critic)
        outcome, text = answer(lent, brief)
        @journal << record(brief, outcome, text, critic)
        text
      end

      # A child that fails costs its own chunk and never the others, for
      # {Docent::Delivery}'s reason: the failure's words are the finding.
      # `Async::Stop` is not a StandardError, so a cancelled critique stays
      # cancelled and {Checkouts#hold} releases on the way out.
      #
      # The child's own request budget is what makes those words worth merging:
      # a prompt the provider refused whole arrives here already said in the
      # harness's vocabulary, with the server's body demoted to the cause. A
      # failure with no words at all is still a finding, and gets the same
      # sentence a critic with nothing to say gets.
      def answer(lent, brief)
        return ["empty", EMPTY] if brief.paths.empty?

        result = lent.call(@role, MODE, brief.to_s, model: @model)
        outcome(result.error? ? "refused" : "answered", result.text)
      rescue StandardError => e
        ["failed", said?(e.message) ? Tools::Subagent::Actor.cause(e) : NOTHING_SAID]
      end

      def outcome(outcome, words) = said?(words) ? [outcome, words] : ["refused", NOTHING_SAID]

      def said?(words) = !words.to_s.strip.empty?

      def record(brief, outcome, text, critic)
        CritiqueChunk.new(head_ref: brief.head_ref, ordinal: brief.ordinal, count: brief.count, critic:,
                          model: recorded_model, label: brief.label, paths: brief.paths, role: @role,
                          brief_key: brief.key, outcome:, text: outcome == "answered" ? text : chunked(brief, text))
      end

      def chunked(brief, reason)
        format(CHUNK_REFUSED, ordinal: brief.ordinal, count: brief.count, label: brief.label, reason:)
      end

      def rendered(answers)
        headline = @subject.headline(count: answers.size, role: @role) + on_model
        [headline, *answers.map { |brief, readings| "#{brief.heading}\n\n#{findings(readings)}" }].join("\n\n")
      end

      def recorded_model = @model.model.empty? ? nil : @model.model

      def on_model = @model.model.empty? ? "" : ", read on #{@model.model}"

      # Each critic's words verbatim under a heading of its own: agreement is
      # for the reader to see, and nothing here summarises one critic into another.
      def findings(readings)
        return readings.first if readings.one?

        sections = readings.each_with_index.map { |text, index| "### critic #{index + 1}\n\n#{text}" }
        [format(READERS, critics: readings.size), *sections].join("\n\n")
      end
    end

    class Critique
      # A held diff as a critique reads it: refused without a reviewed
      # revision, packed by line, and read from a checkout of its head.
      class Diff
        # @param changeset [Review::Changeset]
        def initialize(changeset)
          @changeset = changeset
          freeze
        end

        # @return [Symbol] the catalog role a diff critique defaults to
        def role = ROLE

        # A diff's children are confined by the checkout they are lent, and may
        # still ask a human, so the spawn is the caller's own.
        #
        # @param spawn [Skill::RoleSpawn]
        # @return [Skill::RoleSpawn] the same spawn
        def spawned(spawn) = spawn

        # @return [String] the reviewed head's sha
        def head_ref = @changeset.head_ref

        # @raise [Refused] for a round with no reviewed revision, or one that changes nothing
        def refuse_unreadable!
          raise Refused, NO_REVISION unless @changeset.sides == Source::BOTH_SIDES
          raise Refused, NOTHING_CHANGED if @changeset.files.empty?
        end

        # @param budget [Budget]
        # @param brief [#call] `(chunk, ordinal, count) -> Brief`
        # @return [Array<Partition>]
        def chunks(budget:, brief:) = Packing.new(changeset: @changeset, budget:, brief:).chunks

        # @return [Brief]
        def brief(instructions:, chunk:, ordinal:, count:)
          Brief.new(instructions:, chunk:, ordinal:, count:, base_ref: @changeset.base_ref, head_ref:)
        end

        # @return [String]
        def headline(count:, role:)
          format(HEADLINE, base: @changeset.base_ref[0, 12], head: head_ref[0, 12], count:,
                           plural: count == 1 ? "" : "s", role:)
        end
      end

      Budget = Data.define(:model, :window_tokens, :response_tokens, :reserved_tokens)

      # What a chunk may spend, in tokens of the child's served window.
      class Budget
        # @param window [#resolve] asked for the reviewer's model, which is not always the chat's
        # @param model [String] the model that reads the chunks, whose window sizes them
        # @param max_tokens [Integer] the child's output cap, of which only a {ReplyReserve} is held back
        # @param prelude [String] the role's rendered system prompt
        # @return [Budget]
        # @raise [Refused] for a window only a guess stands behind
        def self.for(window:, model:, max_tokens:, prelude:)
          resolution = resolved(window, model)
          unless resolution.authoritative?
            raise Refused, format(UNVOUCHED, model:, provenance: resolution.provenance,
                                             window: resolution.window_tokens)
          end

          response_tokens = ReplyReserve.tokens(window: resolution.window_tokens, ceiling: Integer(max_tokens))
          new(model: -model.to_s, window_tokens: resolution.window_tokens, response_tokens:,
              reserved_tokens: response_tokens + Critique.tokens(prelude) + SCHEMA_RESERVE_TOKENS)
        end

        def self.resolved(window, model)
          window.resolve(model)
        rescue ContextWindow::UnknownModel
          raise Refused, format(NO_WINDOW, model:)
        end
        private_class_method :resolved

        # What a chunk's CONTENT may estimate, once the brief's fixed text is
        # paid for: its {READ_SHARE} of what is left.
        #
        # @param skeleton [Integer] the estimate of a brief with no hunks in it
        # @return [Integer] zero or less when nothing is left at all
        def room(skeleton) = (window_tokens - reserved_tokens - skeleton) / READ_SHARE

        # @param skeleton [Integer] as for {#room}
        # @return [Hash] the figures every refusal names, so none can name a
        #   different window
        def figures(skeleton)
          { model:, window: window_tokens, response: response_tokens, room: room(skeleton),
            overhead: reserved_tokens - response_tokens + skeleton }
        end
      end

      Brief = Data.define(:instructions, :chunk, :ordinal, :count, :base_ref, :head_ref)

      # One child's prompt: the instructions, where the chunk sits, and its
      # hunks as the changeset parsed them from git objects.
      class Brief
        # The address a chunk record carries this brief under, versioned like
        # every scheme in {Review::Keying}.
        KEY_SCHEME = "critique-brief-v1"

        CHUNK = "# The chunk under critique"

        HUNKS = "# Its hunks, as the reviewed revisions show them"

        TREE = "Your working directory is a checkout of %<head>s, the reviewed head, so a relative path you " \
               "read resolves to that revision's committed bytes. Your read tools do not confine paths: an " \
               "absolute path can still reach the project's working tree, which holds edits nobody reviewed, " \
               "so read by relative path."

        OTHERS = "Other reviewers are critiquing the rest of the change in chunks of their own."

        def to_s = [instructions, "#{CHUNK}\n\n#{where}", "#{HUNKS}\n\n#{hunks}"].join("\n\n")

        def key = Keying.digest(KEY_SCHEME, [to_s])

        def label = chunk.detail.named(chunk.label)

        def paths = chunk.files.map(&:path)

        def heading = "## chunk #{ordinal} of #{count} -- #{label}\nfiles: #{paths.join(", ")}"

        private

        def where
          "chunk #{ordinal} of #{count}: #{label}\nbase #{base_ref}, head #{head_ref}\n" \
            "files: #{paths.join(", ")}\n\n#{tree}"
        end

        def tree = [format(TREE, head: head_ref), (OTHERS if count > 1)].compact.join(" ")

        def hunks = chunk.files.map { |file| Patch.of(file) }.join("\n")
      end

      # One file's hunks as unified diff text: what a child reads, and what
      # {Packing} measures bytes per line over.
      module Patch
        # A side the file does not have. Words rather than git's device path,
        # which reads to a model as a file it might open.
        ADDED = "(no old side: the file was added)"
        DELETED = "(no new side: the file was deleted)"

        # @param file [Source::ChangedFile]
        # @return [String]
        def self.of(file)
          old_side = file.old_path ? "a/#{file.old_path}" : ADDED
          new_side = file.new_path ? "b/#{file.new_path}" : DELETED
          ["--- #{old_side}", "+++ #{new_side}", *file.hunks.map { |hunk| hunk_text(hunk) }].join("\n")
        end

        def self.hunk_text(hunk) = [hunk.header, *hunk.lines].join("\n")
        private_class_method :hunk_text
      end

      # How much of a child's window a chunk's brief takes, against the
      # budget: what {Packing} and {Clusters} both measure by.
      class Measure
        # @param budget [Budget]
        # @param brief [#call] `(chunk, ordinal, count) -> Brief`
        def initialize(budget:, brief:)
          @budget = budget
          @brief = brief
        end

        private

        def refuse_reserve!
          raise Refused, format(RESERVE_OVER, **figures) unless room.positive?
        end

        # What a chunk's content adds to a brief, apart from the text every
        # brief carries.
        def content(chunk, ordinal = 1, count = 1)
          Critique.tokens(@brief.call(chunk, ordinal, count).to_s) - skeleton
        end

        def skeleton = @skeleton ||= Critique.tokens(@brief.call(Partition.new(label: "", files: []), 1, 1).to_s)

        def room = @budget.room(skeleton)

        def figures = @budget.figures(skeleton)

        def overflowing(chunks)
          count = chunks.size
          chunks.each_with_index.lazy
                .map { |chunk, index| [chunk, content(chunk, index + 1, count)] }
                .find { |_chunk, estimate| estimate > room }
        end

        def over_figures(chunk, estimate)
          { chunk: chunk.detail.named(chunk.label), paths: chunk.files.map(&:path).join(", "), estimate:, **figures }
        end
      end

      # The chunks a diff critique spends on, packed by line and every one
      # measured against the budget before any is returned.
      class Packing < Measure
        # @param changeset [Review::Changeset]
        # @param budget [Budget]
        # @param brief [#call] `(chunk, ordinal, count) -> Brief`
        def initialize(changeset:, budget:, brief:)
          @changeset = changeset
          super(budget:, brief:)
        end

        # @return [Array<Review::Partition>]
        # @raise [Refused] naming the reserve, the file or the chunk no packing fits
        def chunks
          refuse_reserve!
          files.each { |file| refuse_file!(file) }
          packed(initial_ceiling)
        end

        private

        def files = @changeset.files

        def refuse_file!(file)
          estimate = content(Partition.new(label: file.path, files: [file]))
          return if estimate <= room

          raise Refused, format(FILE_OVER, path: file.path, estimate:, **figures)
        end

        # {Bounds} refuses a file over the line ceiling on its own, and every
        # file has already been measured to fit, so the ceiling never starts
        # below the longest file.
        def floor = files.map(&:rendered_lines).max.to_i

        def initial_ceiling
          lines = Bounds::Size.lines_in(files)
          return [floor, 1].max if lines.zero?

          per_line = (files.sum { |file| Critique.bytes(Patch.of(file)) } + lines - 1) / lines
          [room * BYTES_PER_TOKEN / per_line, floor, 1].max
        end

        def packed(ceiling)
          chunks = Bounds.new(max_critique_lines: ceiling).each_critique_chunk(@changeset).to_a
          over = overflowing(chunks)
          return chunks if over.nil?

          chunk, estimate = over
          narrower = [ceiling * room / estimate, ceiling - 1].min
          raise Refused, chunk_over(chunk, estimate) if narrower < floor

          packed(narrower)
        end

        def chunk_over(chunk, estimate) = format(CHUNK_OVER, **over_figures(chunk, estimate))
      end

      # Chunks that are already cut, as a document set's clusters are: each is
      # measured, and none can be narrowed.
      class Clusters < Measure
        # @param chunks [Array<Review::Partition>]
        # @return [Array<Review::Partition>] the same chunks
        # @raise [Refused] naming the reserve, or the first chunk over its room
        def fitted(chunks)
          refuse_reserve!
          over = overflowing(chunks)
          raise Refused, format(CLUSTER_OVER, **over_figures(*over)) if over

          chunks
        end
      end

      # Where a critique's children read: a detached checkout of the reviewed
      # head, cut per critique and released on every way out of it -- a return,
      # a raise, and a cancelled task alike.
      #
      # Detached, and at a commit, so a relative read lands on committed bytes
      # and the checkout holds no branch. It lives with every other lain checkout, where
      # `lain worktrees gc` reaps one a killed process left behind.
      class Checkouts
        # The base {Isolation::Worktree} cuts a lease from: a commit, with no
        # branch for work to land on, because a critic writes nothing.
        Revision = Data.define(:tip) do
          def name = ""
        end

        # @param repo_root [String] the repository the round was opened in
        # @param root [String] where lain's checkouts of that repository live
        def initialize(repo_root:, root:)
          @repo_root = repo_root
          @root = root
          freeze
        end

        # @param revision [String] the reviewed head's sha
        # @yieldparam worker_env [WorkerEnv] the checkout's environment
        # @return [Object] the block's value
        def hold(revision, &block)
          lease = Isolation::Worktree.new(root: @root, repo_root: @repo_root, base: Revision.new(tip: revision))
                                     .acquire("critique-#{revision}")
          released(lease, &block)
        end

        private

        def released(lease)
          yield lease.worker_env
        ensure
          lease.release
        end
      end
    end

    class Critique
      CritiqueChunk = Data.define(:head_ref, :ordinal, :count, :critic, :model, :label, :paths, :role, :brief_key,
                                  :outcome, :text) do
        include Telemetry::Journalable
        include Declarative

        declare do
          attribute :head_ref
          attribute :ordinal
          attribute :count
          attribute :critic
          attribute :model
          attribute :label
          attribute :role
          attribute :brief_key
          attribute :outcome
          attribute :text
          validates :head_ref, presence: { message: Wire.refusal("must name the revision that was critiqued") }
          validates :role, presence: { message: Wire.refusal("must name the role that read the chunk") }
          validates :brief_key, presence: { message: Wire.refusal("must address the prompt the child was handed") }
          validates :outcome, inclusion: { in: OUTCOMES, message: Wire.refusal("must be one of #{OUTCOMES.join("/")}") }
          validates :text, presence: { message: Wire.refusal("must carry what came back for the chunk") }
        end

        def initialize(head_ref:, ordinal:, count:, label:, paths:, role:, brief_key:, outcome:, text:, critic: 1,
                       model: nil)
          values = { head_ref: Wire.token(head_ref), ordinal: Epic::WireInteger.read(ordinal, field: "ordinal"),
                     count: Epic::WireInteger.read(count, field: "count"),
                     critic: Epic::WireInteger.read(critic, field: "critic"), model: (unless model.nil?
                                                                                        Wire.token(model)
                                                                                      end),
                     label: Wire.text(label),
                     role: Wire.token(role), brief_key: Wire.token(brief_key), outcome: Wire.token(outcome),
                     text: Wire.text(text) }
          self.class.check!(**values)

          super(**values, paths: Array(paths).map { |path| -path.to_s }.freeze)
        end
      end

      # One chunk of a critique, and what came back for it. `brief_key` is the
      # address of the exact prompt the child was handed ({Brief#key}), so two
      # arms critiquing one chunk are comparable byte for byte without the
      # record carrying the diff; `role` is the arm's name for the same reason.
      class CritiqueChunk
        # Pinned so a rename breaks at the constant rather than relabelling
        # records nobody can join anymore.
        JOURNAL_TYPE = "critique_chunk"
      end
    end
  end
end
