# frozen_string_literal: true

module Lain
  module Shell
    class Executable
      # `realpath` for a filesystem that offers only `lstat` and `readlink`, one component at a time so
      # a caller may answer each hop from a different place.
      module RealpathWalk
        # @param path [String] absolute
        # @return [String] every link and `..` resolved
        # @raise [Errno::ENOENT] a component is missing
        # @raise [Errno::ELOOP] more than {Resolver::Bound::MAX_LINKS} links were followed
        def realpath(path)
          resolved = []
          pending = components(path)
          links = 0
          until pending.empty?
            name = pending.shift
            target = step(resolved, name)
            next_links = target ? links + 1 : links
            raise Errno::ELOOP, path if next_links > Resolver::Bound::MAX_LINKS

            links = next_links
            resolved.clear if target&.start_with?("/")
            pending = components(target) + pending if target
          end
          "/#{resolved.join("/")}"
        end

        private

        def components(path) = path.split("/")

        # Appends or pops a plain name onto +resolved+; returns a link's target without moving.
        def step(resolved, name)
          case name
          when "", "." then nil
          when ".." then resolved.pop && nil
          else
            target = link_at(resolved + [name])
            resolved << name unless target
            target
          end
        end

        def link_at(parts)
          full = "/#{parts.join("/")}"
          readlink(full) if lstat(full).symlink?
        end
      end
    end
  end
end
