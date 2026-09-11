# frozen_string_literal: true

require "fileutils"

module Lain
  class Workspace
    # The disk half both write-backs share: root-relative keys resolved under
    # one root, the two refusals every write-back makes before touching
    # anything, and the two moves it then makes. {Restore} puts back a whole
    # recorded state and {Revert} one turn's own paths; sharing this is what
    # keeps them from drifting on what "outside the root" or "through a
    # symlink" means. An includer holds `@root` as a frozen, expanded Pathname.
    module OnDisk
      private

      # Lexical, matching Snapshot's lexical relativization.
      def escapes?(key)
        path = absolute(key)
        !(path == @root.to_s || path.start_with?("#{@root}#{File::SEPARATOR}"))
      end

      # The lexical key check cannot see a symlink AT the path, and a write
      # follows links -- one planted at a managed path would carry recorded
      # bytes wherever it points, including outside the root. lstat only
      # (File.symlink?), so nothing is dereferenced to decide.
      def linked?(key) = File.symlink?(absolute(key))

      # An escaping key is refused wholly and before any write, rather than
      # confined: a partial "confined" restore would leave disk in a state no
      # snapshot ever recorded, which is a quieter lie than a named refusal.
      def confine!(keys)
        escaped = keys.select { |key| escapes?(key) }
        return if escaped.empty?

        raise Restore::EscapesRoot, "refusing to restore outside #{@root}: #{escaped.join(", ")}"
      end

      # Refused exactly like an escaping key, even when the link points inside
      # the root: the record holds a regular file, and writing through a link
      # restores something else.
      def refuse_symlinks!(keys)
        linked = keys.select { |key| linked?(key) }
        return if linked.empty?

        raise Restore::EscapesRoot,
              "refusing to restore through symlinks (the record holds regular files): #{linked.join(", ")}"
      end

      # nil for no regular file, including one deleted between check and read:
      # the race resolves to the absence it raced.
      def read(key)
        path = absolute(key)
        File.file?(path) ? File.binread(path) : nil
      rescue Errno::ENOENT
        nil
      end

      def place(key, bytes)
        path = absolute(key)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, bytes)
      end

      # Already-absent is the goal, not an error.
      def remove(key)
        File.delete(absolute(key))
      rescue Errno::ENOENT
        nil
      end

      def absolute(key) = File.expand_path(key, @root.to_s)
    end
  end
end
