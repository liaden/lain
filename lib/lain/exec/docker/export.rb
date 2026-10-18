# frozen_string_literal: true

require "rubygems/package"

module Lain
  module Exec
    class Docker
      # What `docker export` says about an image's files. Only the tar headers are read: the export runs nothing in
      # the image, and every symlink hop, mode and owner arrives as the image holds it.
      module Export
        TYPES = { "0" => "file", "1" => "hardlink", "2" => "symlink", "5" => "directory" }.freeze

        # @param io [IO] a tar stream
        # @return [Hash{String => Shell::Executable::ListedStat::Entry}] every entry, by absolute path, less any whose
        #   name is not valid UTF-8
        # @raise [Gem::Package::Error] for bytes that are not a whole tar
        def self.read(io) = Reader.new(io).entries

        # Filtered after the whole tar is read, because a link's target can come earlier in the tar than the link.
        #
        # @param entries [Hash{String => Shell::Executable::ListedStat::Entry}] as {.read} returns them
        # @param path [String] the image's `PATH`
        # @return [Hash{String => Shell::Executable::ListedStat::Entry}] each `PATH` directory's children, every hop
        #   of the link chains they start, and every directory those paths pass through
        def self.keep(entries, path:)
          walk = RecordingWalk.new(entries)
          children = entries.keys.group_by { File.dirname(_1) }
          path.split(":").select { _1.start_with?("/") }.filter_map { walk.resolve(_1) }
              .each { |dir| children.fetch(dir, []).each { walk.resolve(_1) } }
          walk.seen.merge("/" => entries.fetch("/", Shell::Executable::ListedStat::ROOT)).sort.to_h
        end

        # `Gem::Package::TarReader` applies none of the headers that rename an entry, and stops quietly at a short
        # read. podman writes a PAX `x` header for a name over the ustar limits, so that one is applied here; the
        # others are refused rather than misread, and so is a tar without its end-of-archive marker.
        class Reader
          BLOCK = 512

          def initialize(io)
            @io = io
            @extended = {}
          end

          def entries
            listed = Gem::Package::TarReader.new(@io).each.with_object({}) { |entry, out| take(entry, out) }
            raise Gem::Package::TarInvalidError, "the tar ends before its end-of-archive marker" unless ended?

            listed
          end

          private

          def ended? = @io.read(BLOCK) == ("\0" * BLOCK)

          def take(entry, out)
            case entry.header.typeflag
            when "x" then @extended = records(entry.read.to_s.b)
            when "g", "L", "K" then raise Gem::Package::TarInvalidError, "a #{entry.header.typeflag} header is not read"
            else named(entry, out)
            end
          end

          def named(entry, out)
            name = utf8(@extended.fetch("path", entry.full_name))
            link = utf8(@extended.fetch("linkpath", entry.header.linkname))
            @extended = {}
            out[rooted(name)] = described(entry.header, link) if legible?(name, link)
          end

          def rooted(name) = "/#{name.delete_prefix("./").delete_prefix("/").chomp("/")}"

          def described(header, linkname)
            type = TYPES.fetch(header.typeflag, "other")
            Shell::Executable::ListedStat::Entry.new(type:, mode: header.mode, uid: header.uid, gid: header.gid,
                                                     link: link(type, linkname))
          end

          # A hard link's name is relative to the tar's root; a symlink's target is kept as written.
          def link(type, name)
            case type
            when "symlink" then name
            when "hardlink" then rooted(name)
            end
          end

          def legible?(*names) = names.all?(&:valid_encoding?)

          # UTF-8 rather than the locale's encoding, so the shared cache does not depend on who exported first.
          def utf8(name) = name.dup.force_encoding(Encoding::UTF_8)

          # Each record is "<length> <key>=<value>\n", the length counting the whole record.
          def records(body, found = {})
            return found if body.empty?

            length = body[/\A\d+/].to_i
            raise Gem::Package::TarInvalidError, "a PAX record has no length" unless length.positive?

            key, value = body.byteslice(0, length).chomp.split(" ", 2).last.split("=", 2)
            records(body.byteslice(length..), found.merge(key => value))
          end
        end

        # The paths a walk looked at are exactly what a listing must hold for the same walk to succeed offline.
        class RecordingWalk
          include Shell::Executable::RealpathWalk

          attr_reader :seen

          def initialize(entries)
            @entries = entries
            @seen = {}
          end

          def lstat(path) = @seen[path] = @entries.fetch(path) { raise Errno::ENOENT, path }

          def readlink(path) = @entries.fetch(path).link

          def resolve(path)
            realpath(path)
          rescue SystemCallError
            nil
          end
        end

        private_constant :Reader, :RecordingWalk
      end
    end
  end
end
