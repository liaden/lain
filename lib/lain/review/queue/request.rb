# frozen_string_literal: true

require "shellwords"

module Lain
  module Review
    class Queue
      # A review the queue asks a chat to open, as a plain map of strings that
      # crosses a socket or a file. Any same-uid process can write one, so a
      # request is never a line: it is 1 of 4 shapes, each field checked on
      # load, and the `/review` line is rebuilt from those fields alone.
      class Request
        # A request that is not 1 of the 4 shapes; {#field} names what failed.
        class Refused < Error
          # @return [String]
          attr_reader :field

          # @param field [String]
          # @param why [String]
          def initialize(field, why)
            @field = field
            super("queued review request refused: #{field} #{why}")
          end
        end

        # The fields a kind must carry, and the ones it may.
        Shape = Data.define(:required, :optional)

        # Terminal escape sequences, CSI and OSC whole, so none of their bytes outlive the strip.
        ESCAPES = %r{\e\[[0-?]*[ -/]*[@-~]|\e\][^\a\e]*(?:\a|\e\\)?|\e.}m

        UNPRINTABLE = /[[:cntrl:]\p{Cf}\p{Zl}\p{Zp}\s]+/

        SHA = /\A[0-9a-f]{40}\z/
        PULL = %r{\Ahttps://github\.com/(?<name>[A-Za-z0-9-]+/[A-Za-z0-9._-]+)/pull/[1-9][0-9]*\z}
        # Printable ASCII only: a focus is spliced into a line the chat runs.
        PRINTABLE = "\\x20-\\x7E"
        FOCUS_LIMIT = 80
        FOCUS = /\A[#{PRINTABLE}]{1,#{FOCUS_LIMIT}}\z/
        UNFOCUSABLE = /[^#{PRINTABLE}]+/
        # Git takes these in a branch name, and each would show the human
        # something other than the bytes the chat runs.
        # A decomposed é (e + U+0301) is refused for its mark, since it looks
        # like the composed é, which loads, while naming another ref.
        # U+2800 is in none of the classes, so it is named.
        UNSEEN = /[\p{Cc}\p{Cf}\p{Z}\p{M}\p{Default_Ignorable_Code_Point}\u2800]/
        SHAPES = {
          "range" => Shape.new(required: %w[base head repo_root], optional: []),
          "branch" => Shape.new(required: %w[branch repo_root], optional: %w[base]),
          "dirty" => Shape.new(required: %w[repo_root], optional: []),
          "pr" => Shape.new(required: %w[url], optional: %w[since focus])
        }.freeze
        private_constant :UNPRINTABLE, :Shape, :SHA, :PULL, :PRINTABLE, :FOCUS_LIMIT, :FOCUS, :UNFOCUSABLE, :UNSEEN,
                         :SHAPES

        # @param text [Object] any text, including an escape sequence or a newline
        # @return [String] one line with no control character in it
        def self.plain(text)
          text.to_s.scrub.gsub(ESCAPES, "").gsub(UNPRINTABLE, " ").strip
        end

        # Free text, such as a row's reason, cut to what a focus may be rather
        # than refused for it: an accent folds to its letter first, so a
        # reason in another script keeps what it can.
        #
        # @param text [String]
        # @return [String, nil] a focus {.load} takes, or nil when nothing printable is left
        def self.focus(text)
          plain = String.new(text.to_s).force_encoding(Encoding::UTF_8).scrub.gsub(ESCAPES, "")
          cut = plain.unicode_normalize(:nfkd).gsub(UNFOCUSABLE, " ").squeeze(" ").strip[0, FOCUS_LIMIT].strip
          cut if FOCUS.match?(cut)
        end

        # @param hash [Hash{String => String}] the wire or file form
        # @param checkouts [Checkouts] finds a pull request's local clone
        # @param shell_out_factory [#call] builds the subprocess runner
        # @return [Request]
        # @raise [Refused] naming the first field that is not of its shape
        def self.load(hash, checkouts:, shell_out_factory: Shell::Out.public_method(:new))
          fields = Fields.new(hash, shell_out_factory).read
          root = fields["kind"] == "pr" ? checkouts.for(fields["url"][PULL, :name]) : fields["repo_root"]
          new(fields, root&.then { |path| String.new(path).freeze })
        end

        # Copies a map into frozen UTF-8 strings, then checks the copy against
        # {SHAPES} field by field, so nothing the caller holds can change it.
        class Fields
          CHECKS = { "kind" => :kind?, "base" => :base?, "head" => :sha?, "since" => :sha?, "focus" => :focus?,
                     "url" => :url?, "repo_root" => :repo_root?, "branch" => :branch? }.freeze

          # @param hash [Object] whatever arrived
          # @param shell_out_factory [#call]
          def initialize(hash, shell_out_factory)
            @hash = hash
            @shell_out_factory = shell_out_factory
          end

          # @return [Hash{String => String}] a frozen copy, every field checked
          def read
            @fields = copy
            shape = SHAPES.fetch(@fields["kind"]) { refuse!("kind", "is not one of #{SHAPES.keys.join(", ")}") }
            refuse_extra!(shape.required + shape.optional)
            refuse_missing!(shape.required)
            @fields.each { |field, value| refuse!(field, "is not of its shape") unless send(CHECKS[field], value) }
            @fields
          end

          private

          def copy
            refuse!("kind", "is not a map") unless @hash.is_a?(Hash)
            @hash.each_pair.to_h { |key, value| [text(key.to_s, key), text(key.to_s, value)] }.freeze
          end

          # The wire form is UTF-8 JSON, so a value is its bytes read as UTF-8.
          def text(field, value)
            refuse!(field, "is not a string") unless value.is_a?(String)
            refuse!(field, "is not readable text") unless value.valid_encoding? && value.encoding.ascii_compatible?
            utf8 = String.new(value).force_encoding(Encoding::UTF_8)
            refuse!(field, "is not UTF-8 text without a NUL") unless utf8.valid_encoding? && !utf8.include?("\0")
            utf8.freeze
          end

          def refuse_extra!(allowed)
            extra = (@fields.keys - allowed - ["kind"]).first
            refuse!(extra, "is not a field of a #{@fields["kind"]} request") if extra
          end

          def refuse_missing!(required)
            missing = (required - @fields.keys).first
            refuse!(missing, "is missing") if missing
          end

          def refuse!(field, why) = raise(Refused.new(field, why))

          def kind?(value) = SHAPES.key?(value)

          def sha?(value) = SHA.match?(value)

          def focus?(value) = FOCUS.match?(value)

          def url?(value) = PULL.match?(value)

          # A range's base is a sha; a branch's base is another branch.
          def base?(value) = @fields["kind"] == "branch" ? branch?(value) : sha?(value)

          # The root must be the work tree's top, spelled as git spells it, so
          # the chat it is sent to can be found by that path alone.
          def repo_root?(value)
            return false unless value.start_with?("/") && File.directory?(value)

            answers?(value, %w[rev-parse --show-toplevel], value)
          end

          # `--branch` expands `@{-1}`, so the answer must be the name itself;
          # `@` alone is HEAD.
          def branch?(value)
            root = @fields["repo_root"]
            return false if value == "@" || UNSEEN.match?(value) || !(root && repo_root?(root))

            answers?(root, ["check-ref-format", "--branch", value], value)
          end

          # Git answers in bytes, so its answer is compared as bytes.
          def answers?(dir, args, value)
            shell = Isolation::Checkout.of(dir, shell_out_factory: @shell_out_factory).run(*args)
            Shell::Out.ok?(shell) && shell.stdout.chomp.b == value.b
          end
        end
        private_constant :Fields

        private_class_method :new

        # @param fields [Hash{String => String}] already checked and frozen
        # @param repo_root [String, nil]
        def initialize(fields, repo_root)
          @fields = fields
          @repo_root = repo_root
          freeze
        end

        # @return [Hash{String => String}] the wire and file form, frozen
        def to_h = @fields

        # @return [String, nil] the repository the review runs in; nil for a
        #   pull request with no local clone
        attr_reader :repo_root

        # For a dirty tree, every call takes a new snapshot and so writes a new
        # commit object: call it once per offer.
        # @param shell_out_factory [#call] builds the subprocess runner for a snapshot
        # @return [String] the `/review` line, built only from checked fields
        # @raise [Refused] a dirty tree that is clean or has no commit yet
        def review_line(shell_out_factory: Shell::Out.public_method(:new))
          ["/review", *words(shell_out_factory)].join(" ")
        end

        private

        def words(shell_out_factory)
          case @fields["kind"]
          when "range" then [@fields["head"], "--base", @fields["base"]]
          when "branch" then branch_words
          when "dirty" then [snapshot(shell_out_factory), "--base", "HEAD"]
          when "pr" then pull_words
          end
        end

        # Spelled as full refs: a bare `close` or `12` reads as a verb or a
        # pull request number to /review, and a tag can share the name.
        def branch_words
          base = @fields["base"]
          [ref(@fields["branch"]), *(["--base", ref(base)] if base)]
        end

        def ref(branch) = Shellwords.escape("refs/heads/#{branch}")

        def pull_words
          since, focus = @fields.values_at("since", "focus")
          [@fields["url"], *(["--since", since] if since), *("--critique=#{Shellwords.escape(focus)}" if focus)]
        end

        def snapshot(shell_out_factory)
          Snapshot.new(repo_root: @fields["repo_root"], shell_out_factory:).take or
            raise Refused.new("repo_root", "has no uncommitted changes")
        rescue Isolation::Checkout::Failed => e
          raise Refused.new("repo_root", "cannot be snapshotted: #{e.message}")
        end
      end
    end
  end
end
