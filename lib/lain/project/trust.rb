# frozen_string_literal: true

require "digest"
require "fileutils"
require "shellwords"

module Lain
  class Project
    # Consent to run a project's own Ruby: every `.lain/*.rb`, which lain
    # `instance_eval`s with no sandbox. A cloned repository carries those files,
    # so nothing in them runs until a human has said yes to these exact bytes.
    #
    # The consent is keyed on CONTENT, not on a root. The digest covers each
    # file's name and bytes, so a leased worktree or a bench subject holding the
    # same files needs no second decision, and one changed byte is a new one.
    #
    # It covers the top-level `.lain/*.rb` files only, never what they require
    # or load: digesting `.lain/**` would void trust on every `/meta` draft
    # written under `.lain/summarizers/`, so the boundary is stated instead.
    #
    # The bytes are read once, here, and {#sources} hands out those same bytes:
    # a loader that evaluates them runs what was digested rather than what the
    # file holds a moment later.
    class Trust
      # Where the marks live under {Paths#state_home}.
      DIR = "trust"

      # What the refusal says; {CLI::Trust} is the one place a mark is granted.
      UNTRUSTED = "%<files>s %<verb>s Ruby this project runs on launch, and these bytes have not been trusted. " \
                  "Read %<pronoun>s, then run: lain trust %<root>s"

      # A project's Ruby that nobody has trusted yet.
      class Untrusted < Error; end

      # A `.lain/*.rb` or a mark that could not be read, so no answer is possible.
      class Unreadable < Error; end

      # Every control and format character but a newline, so a name or a body
      # can neither redraw the terminal nor reorder a line with a bidi override.
      HIDDEN = /[\p{Cc}\p{Cf}&&[^\n]]/

      # @param text [String] anything headed for a human's terminal
      # @return [String] the text with every {HIDDEN} character escaped
      def self.legible(text) = text.scrub.gsub(HIDDEN) { |char| char.dump[1..-2] }

      # A mark is one file per trusted digest, whose body is that digest.
      #
      # Presence is not the test: a directory, a FIFO and a half-written file
      # all exist. A mark counts only as a regular file holding exactly its
      # digest, and the read is bounded, so a planted entry cannot grant or hang.
      class Record
        # A digest plus a newline, with room to see that a longer file is longer.
        LIMIT = 66

        # @param paths [Paths] supplies the state home the marks live under
        def initialize(paths: Paths.new)
          @paths = paths
          freeze
        end

        # @param digest [String] a full-width hex digest
        # @return [Boolean]
        # @raise [Unreadable] when a mark is there and cannot be read
        def granted?(digest)
          path = path_for(digest)
          File.file?(path) && File.read(path, LIMIT) == mark_for(digest)
        rescue SystemCallError => e
          raise Unreadable, Trust.legible("cannot read the trust mark: #{e.message}")
        end

        # Atomic replace: the bytes land in a sibling and one rename swaps them
        # in, so a reader only ever sees a whole mark.
        #
        # @param digest [String] a full-width hex digest
        # @return [String] the mark that now exists
        def grant(digest)
          target = path_for(digest)
          FileUtils.mkdir_p(File.dirname(target))
          tmp = "#{target}.tmp-#{Process.pid}-#{object_id}"
          begin
            File.write(tmp, mark_for(digest))
            File.rename(tmp, target)
          ensure
            FileUtils.rm_f(tmp)
          end
          target
        end

        # @param digest [String] a full-width hex digest
        # @return [String] the mark's path, whether or not it exists
        def path_for(digest) = @paths.container(DIR, key: digest)

        private

        def mark_for(digest) = "#{digest}\n"
      end

      # @param project_dir [ProjectDir] the project whose `.lain/*.rb` is judged
      # @param paths [Paths] supplies the state home the marks live under
      # @return [Trust]
      # @raise [Unreadable] when a `.lain/*.rb` cannot be read
      def self.for(project_dir:, paths: Paths.new)
        new(root: project_dir.root, sources: sources_in(project_dir.dir), record: Record.new(paths:))
      end

      def self.sources_in(dir)
        files = Dir.glob("*.rb", base: dir).sort.map { |name| File.join(dir, name) }.select { |path| File.file?(path) }
        files.to_h { |path| [path, File.read(path)] }
      rescue SystemCallError => e
        raise Unreadable, legible("cannot read this project's Ruby: #{e.message}")
      end
      private_class_method :sources_in

      # @param root [String] the project root, which the refusal names
      # @param sources [Hash{String => String}] each `.lain/*.rb` path and its bytes
      # @param record [Record] the mark store
      def initialize(root:, sources:, record:)
        @root = root
        @sources = sources.to_h { |path, bytes| [path.dup.freeze, bytes.dup.freeze] }.freeze
        @record = record
        freeze
      end

      # @return [Hash{String => String}] each `.lain/*.rb` path and the bytes digested
      attr_reader :sources

      # @return [Array<String>] every `.lain/*.rb`, sorted
      def files = @sources.keys

      # Length-prefixed so no pair of names and bodies can be spelled as another.
      #
      # @return [String] the full-width hex digest of every file's name and bytes
      def digest
        @sources.each_with_object(Digest::SHA256.new) do |(path, bytes), sha|
          name = File.basename(path)
          sha << "#{name.bytesize}:#{name}#{bytes.bytesize}:" << bytes
        end.hexdigest
      end

      # A project with no Ruby has nothing to consent to.
      #
      # @return [Boolean]
      def trusted? = @sources.empty? || @record.granted?(digest)

      # @return [void]
      # @raise [Untrusted] naming every file and `lain trust`
      def require!
        raise Untrusted, Trust.legible(refusal) unless trusted?
      end

      # @return [String, nil] the mark written, or nil when there was nothing to trust
      def grant! = @sources.empty? ? nil : @record.grant(digest)

      private

      def refusal
        many = files.length > 1
        format(UNTRUSTED, files: files.join(", "), verb: many ? "are" : "is",
                          pronoun: many ? "them" : "it", root: Shellwords.escape(@root))
      end
    end
  end
end
