# frozen_string_literal: true

require "pathname"

module Lain
  class Workspace
    # Puts back ONE undone turn's own changes, path by path, and nothing else.
    # Each {Move} says what the turn left at a path and what stood there
    # before it. The revert checks that disk still holds the former, then
    # writes the latter back (bytes and executable bit), or deletes a path the
    # turn created. Paths outside the moves are never read or written, which
    # keeps a file made after the turn out of reach.
    #
    # Every obstruction is found BEFORE any IO and reported together, each
    # path with its reason ({Blocker}), so a refusal can say what to fix rather
    # than naming only the first problem it met.
    #
    # Deletions run first. A turn that swapped a file for a directory of the
    # same name, or the reverse, left its own entries in the way, and those
    # have to go before the earlier shape can come back.
    class Revert
      include OnDisk

      # `after` is what the turn left at `key`, which disk must still hold;
      # `before` is what stood there first, nil where nothing did.
      Move = Data.define(:key, :before, :after)

      # A path's content, and its git mode where the record knows one.
      Side = Data.define(:bytes, :mode) do
        def initialize(bytes:, mode:) = super(bytes: bytes.b.freeze, mode:)
      end

      Blocker = Data.define(:key, :reason)

      # Refused before anything moved; carries every blocked path.
      class Blocked < Error
        attr_reader :blockers

        def initialize(blockers)
          @blockers = blockers.freeze
          super("refusing to undo: #{blockers.map { |blocker| "#{blocker.key} (#{blocker.reason})" }.join(", ")}")
        end
      end

      EXECUTABLE = "100755"

      # A restore writes bytes, so a path the record holds as a link or as a
      # nested repository is one it cannot put back.
      SPECIAL = { "120000" => :symlink, "160000" => :nested_repository }.freeze

      def initialize(root:)
        @root = Pathname.new(File.expand_path(root)).freeze
      end

      # @param moves [Array<Move>]
      # @return [Array<Blocker>] empty when every move can be made
      def blockers(moves)
        deleted = moves.reject(&:before).map(&:key)
        moves.to_h { |move| [move.key, obstruction(move, deleted)] }.compact
             .map { |key, reason| Blocker.new(key:, reason:) }
      end

      # @param moves [Array<Move>]
      # @return [Restore::Result]
      # @raise [Blocked] before any IO, naming every obstruction
      # @raise [Restore::PartialApply] when IO fails midway
      def apply(moves)
        found = blockers(moves)
        raise Blocked, found unless found.empty?

        moved(moves)
      end

      private

      def moved(moves)
        ledger = Restore::Ledger.new({})
        moves.reject(&:before).each { |move| deleted(move.key, ledger) }
        moves.select(&:before).each { |move| written(move, ledger) }
        ledger.result
      rescue SystemCallError => e
        raise Restore::PartialApply.new(e, written: ledger.written, deleted: ledger.deleted)
      end

      def deleted(key, ledger)
        remove(key)
        ledger.deleted!(key)
      end

      def written(move, ledger)
        clear(move.key)
        place(move.key, move.before.bytes)
        executable!(move.key, move.before.mode)
        ledger.written!(move.key, nil)
      end

      def obstruction(move, deleted)
        return :outside_root if escapes?(move.key)

        special(move) || (:symlink if linked_anywhere?(move.key)) ||
          (:directory if walled?(move, deleted)) || drifted(move, deleted)
      end

      def special(move) = [move.before, move.after].compact.filter_map { |side| SPECIAL[side.mode] }.first

      def linked_anywhere?(key) = [*ancestors(key), key].any? { |path| linked?(path) }

      # A file the turn did not make, standing where a directory has to come
      # back. The turn's own file there is removed first, so it is no wall.
      def walled?(move, deleted)
        move.before && ancestors(move.key).any? { |dir| wall?(dir, deleted) }
      end

      def wall?(dir, deleted)
        path = absolute(dir)
        File.exist?(path) && !File.directory?(path) && !deleted.include?(dir)
      end

      def drifted(move, deleted)
        path = absolute(move.key)
        return directory_in_the_way(move, deleted) if File.directory?(path)
        return (File.exist?(path) ? :dirty : nil) if move.after.nil?

        as_left?(path, move.after) ? nil : :dirty
      end

      # The turn's own emptied directory is no obstruction: every file in it is
      # one this revert removes.
      def directory_in_the_way(move, deleted)
        move.after.nil? && emptied?(move.key, deleted) ? nil : :directory
      end

      def emptied?(key, deleted)
        files_under(absolute(key)).all? { |entry| deleted.include?(File.join(key, entry)) }
      end

      def files_under(dir)
        Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).reject { |entry| File.directory?(File.join(dir, entry)) }
      end

      def as_left?(path, side)
        File.file?(path) && File.binread(path) == side.bytes &&
          (side.mode.nil? || executable?(path) == (side.mode == EXECUTABLE))
      end

      def executable?(path) = File.stat(path).mode.anybits?(0o111)

      # The turn's emptied directory, standing where the earlier file goes.
      def clear(key)
        path = absolute(key)
        return unless File.directory?(path)

        Dir.glob("**/*/", base: path).sort_by { |dir| -dir.count("/") }.each { |dir| Dir.rmdir(File.join(path, dir)) }
        Dir.rmdir(path)
      end

      # Only the executable bit: git records nothing finer, and widening a
      # file's other permissions to 0644 would be a change the turn never made.
      def executable!(key, mode)
        return if mode.nil?

        path = absolute(key)
        current = File.stat(path).mode & 0o7777
        File.chmod(mode == EXECUTABLE ? current | 0o111 : current & ~0o111, path)
      end

      def ancestors(key) = Pathname.new(key).descend.map(&:to_s)[0...-1]
    end
  end
end
