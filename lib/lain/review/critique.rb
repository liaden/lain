# frozen_string_literal: true

module Lain
  module Review
    # `/critique` over the review a chat is holding: the critique skill's
    # instructions, run by one fresh role child per chunk of the changeset, and
    # the findings merged back in chunk order.
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

      # The catalog role each chunk is read by, unless whoever constructs a
      # critique names another through `role:`.
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

      OUTCOMES = %w[answered refused empty].freeze

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
                     "(max_tokens) and %<overhead>d tokens of instructions, role prelude and tool schemas leave " \
                     "no room for a chunk in %<model>s's %<window>d-token window -- lower --max-tokens, or run " \
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

      NOTHING_SAID = "the critic came back with nothing to say"

      EMPTY = "no file of this commit survives in the changeset, so nothing was sent"

      HEADLINE = "critique of %<base>s..%<head>s in %<count>d chunk%<plural>s, each read by the %<role>s role " \
                 "from a checkout of %<head>s"

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

      # @param changeset [Review::Changeset] the held round's diff
      # @param spawn [#within, #seam] {Skill::RoleSpawn}: `within(worker_env)`
      #   lends a checkout and answers `call(role, mode, prompt)`; `seam` names
      #   the child's context, for its model and its response ceiling
      # @param window [#resolve] the run's window book
      # @param checkouts [#hold] cuts the checkout of the reviewed head; {Checkouts}
      # @param journal [#<<] where each chunk's record lands
      # @param slots [Prompt::Slots] renders the role's prelude, which is measured
      # @param instructions [String] the rendered critique skill, with any focus
      # @param role [Symbol] a {Role::Catalog} name
      def initialize(changeset:, spawn:, window:, checkouts:, journal:, slots:, instructions:, role: ROLE)
        @changeset = changeset
        @spawn = spawn
        @window = window
        @checkouts = checkouts
        @journal = journal
        @slots = slots
        @instructions = instructions
        @role = role
      end

      # @return [String] the merged findings
      # @raise [Refused] before any checkout or spawn
      def call
        raise Refused, NO_REVISION unless @changeset.sides == Source::BOTH_SIDES
        raise Refused, NOTHING_CHANGED if @changeset.files.empty?

        chunks = Packing.new(changeset: @changeset, budget:, brief: method(:brief)).chunks
        answers = @checkouts.hold(@changeset.head_ref) { |worker_env| answered(chunks, @spawn.within(worker_env)) }
        rendered(answers)
      end

      private

      def budget
        context = @spawn.seam.context_factory.call
        Budget.for(window: @window, model: context.model, max_tokens: context.max_tokens,
                   prelude: Role::Catalog.fetch(@role).prelude(slots: @slots))
      end

      def brief(chunk, ordinal, count)
        Brief.new(instructions: @instructions, chunk:, ordinal:, count:, base_ref: @changeset.base_ref,
                  head_ref: @changeset.head_ref)
      end

      # One child at a time: the lent checkout serves one dispatch at once, and
      # the findings are merged in chunk order anyway.
      def answered(chunks, lent)
        count = chunks.size
        chunks.each_with_index.map do |chunk, index|
          brief = brief(chunk, index + 1, count)
          outcome, text = answer(lent, brief)
          @journal << record(brief, outcome, text)
          [brief, outcome, text]
        end
      end

      # A child that fails costs its own chunk and never the others, for
      # {Docent::Delivery}'s reason: the failure's words are the finding.
      # `Async::Stop` is not a StandardError, so a cancelled critique stays
      # cancelled and {Checkouts#hold} releases on the way out.
      def answer(lent, brief)
        return ["empty", EMPTY] if brief.paths.empty?

        result = lent.call(@role, MODE, brief.to_s)
        outcome(result.error? ? "refused" : "answered", said(result))
      rescue StandardError => e
        outcome("refused", e.message)
      end

      def outcome(outcome, words) = words.to_s.strip.empty? ? ["refused", NOTHING_SAID] : [outcome, words]

      def said(result)
        content = result.content
        return content if content.is_a?(String)

        content.filter_map { |block| block["text"] || block[:text] }.join("\n")
      end

      def record(brief, outcome, text)
        CritiqueChunk.new(head_ref: brief.head_ref, ordinal: brief.ordinal, count: brief.count,
                          label: brief.label, paths: brief.paths, role: @role, brief_key: brief.key,
                          outcome:, text:)
      end

      def rendered(answers)
        head = @changeset.head_ref[0, 12]
        count = answers.size
        headline = format(HEADLINE, base: @changeset.base_ref[0, 12], head:, count:, plural: count == 1 ? "" : "s",
                                    role: @role)
        [headline, *answers.map { |brief, _outcome, text| "#{brief.heading}\n\n#{text}" }].join("\n\n")
      end
    end

    class Critique
      Budget = Data.define(:model, :window_tokens, :response_tokens, :reserved_tokens)

      # What a chunk may spend, in tokens of the child's served window.
      class Budget
        # @param window [#resolve] the run's window book
        # @param model [String] the child's model
        # @param max_tokens [Integer] the response the child may write
        # @param prelude [String] the role's rendered system prompt
        # @return [Budget]
        # @raise [Refused] for a window only a guess stands behind
        def self.for(window:, model:, max_tokens:, prelude:)
          resolution = window.resolve(model)
          unless resolution.authoritative?
            raise Refused, format(UNVOUCHED, model:, provenance: resolution.provenance,
                                             window: resolution.window_tokens)
          end

          response_tokens = Integer(max_tokens)
          new(model: -model.to_s, window_tokens: resolution.window_tokens, response_tokens:,
              reserved_tokens: response_tokens + Critique.tokens(prelude) + SCHEMA_RESERVE_TOKENS)
        end

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

        def self.hunk_text(hunk)
          header = "@@ -#{hunk.old_start},#{hunk.old_count} +#{hunk.new_start},#{hunk.new_count} @@ #{hunk.heading}"
          [header.rstrip, *hunk.lines].join("\n")
        end
        private_class_method :hunk_text
      end

      # The chunks a critique spends on, every one measured against the budget
      # before any is returned.
      class Packing
        # @param changeset [Review::Changeset]
        # @param budget [Budget]
        # @param brief [#call] `(chunk, ordinal, count) -> Brief`
        def initialize(changeset:, budget:, brief:)
          @changeset = changeset
          @budget = budget
          @brief = brief
        end

        # @return [Array<Review::Partition>]
        # @raise [Refused] naming the reserve, the file or the chunk no packing fits
        def chunks
          raise Refused, format(RESERVE_OVER, **figures) unless room.positive?

          files.each { |file| refuse_file!(file) }
          packed(initial_ceiling)
        end

        private

        def files = @changeset.files

        # What a chunk's hunks add to a brief, apart from the text every brief
        # carries.
        def content(chunk, ordinal = 1, count = 1)
          Critique.tokens(@brief.call(chunk, ordinal, count).to_s) - skeleton
        end

        def skeleton = @skeleton ||= Critique.tokens(@brief.call(Partition.new(label: "", files: []), 1, 1).to_s)

        def room = @budget.room(skeleton)

        def figures = @budget.figures(skeleton)

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

        def overflowing(chunks)
          count = chunks.size
          chunks.each_with_index.lazy
                .map { |chunk, index| [chunk, content(chunk, index + 1, count)] }
                .find { |_chunk, estimate| estimate > room }
        end

        def chunk_over(chunk, estimate)
          format(CHUNK_OVER, chunk: chunk.detail.named(chunk.label), paths: chunk.files.map(&:path).join(", "),
                             estimate:, **figures)
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
      CritiqueChunk = Data.define(:head_ref, :ordinal, :count, :label, :paths, :role, :brief_key, :outcome, :text) do
        include Telemetry::Journalable
        include Declarative

        declare do
          attribute :head_ref
          attribute :ordinal
          attribute :count
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

        def initialize(head_ref:, ordinal:, count:, label:, paths:, role:, brief_key:, outcome:, text:)
          values = { head_ref: Wire.token(head_ref), ordinal: Epic::WireInteger.read(ordinal, field: "ordinal"),
                     count: Epic::WireInteger.read(count, field: "count"), label: Wire.text(label),
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
