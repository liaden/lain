# frozen_string_literal: true

module Lain
  module Frontend
    class Neovim
      # The injected runtime, assembled from its modules.
      #
      # `nvim_exec_lua` takes ONE chunk and an injected chunk has no
      # `package.path`, so `require` cannot reach a sibling file -- concatenation
      # at read time is the only way the runtime can be more than one file. The
      # modules are DISCOVERED, never listed: a hardcoded manifest would make this
      # class a file every new capability has to edit, which is exactly the
      # collision the split exists to remove.
      #
      # Load order is the PARSED PREFIX, and the filename is validated to have
      # one. Both halves earn their place, measured rather than assumed:
      #
      #   - Sorting filenames as STRINGS is lexicographic, so `100_foo.lua` loads
      #     FIRST -- ahead of `20_buffers.lua` -- and an unprefixed `sidebar.lua`
      #     loads LAST, past the attach announcement that must be last. Both are
      #     the obvious thing a later card does ("take the next number", "name it
      #     after the feature"), and both were silent.
      #   - Two cards picking the same prefix resolved by filename, silently.
      #
      # So a name that is not `NN_lowercase.lua` is refused, a repeated prefix is
      # refused, and order is an Integer comparison no directory reader can
      # influence. Nothing may sort past `99_attach.lua` because two digits cannot
      # exceed 99 and 99 is already claimed -- the reserved slot needs no separate
      # rule, and this class needs no second copy of a module's name.
      #
      # See {HEAD}'s own header comment for the three rules that follow from being
      # one chunk.
      class RuntimeLoader
        # The chunk head: the injected args, the protocol handshake, and the
        # `_G.__lain` namespace the modules publish through.
        HEAD = File.expand_path("runtime.lua", __dir__)

        # Everything else, one file per capability.
        MODULES = File.expand_path("runtime", __dir__)

        # Two digits, an underscore, then a lowercase name. Anchored at both ends,
        # which is what keeps `20_buffers.lua.orig` and `20_buffers.lua~` out
        # without needing a rule about editors.
        MODULE_NAME = /\A(?<prefix>\d{2})_[a-z0-9_]+\.lua\z/

        # @param head [String] path to the chunk head
        # @param modules [String] directory of `NN_name.lua` modules
        def initialize(head: HEAD, modules: MODULES)
          @head = head
          @modules = modules
        end

        # The whole chunk, ready for `nvim_exec_lua`.
        #
        # Read on every call rather than memoized: this runs once per attach, and
        # a cache would make the modules a thing the process learned at boot
        # instead of a thing on disk.
        #
        # @return [String]
        # @raise [RuntimeError] if the directory holds no modules -- injecting a
        #   bare head would leave nvim with the handshake and no runtime at all,
        #   which presents as an editor that attaches, reports a healthy protocol,
        #   and then answers nothing.
        def source
          if module_paths.empty?
            raise "no lua modules in #{@modules}; the injected runtime would be the handshake alone"
          end

          parts.map(&:last).join("\n")
        end

        # @return [Array<String>] module paths in load order
        def module_paths
          ordered(module_names).map { |name| File.join(@modules, name) }
        end

        # The load order, as a pure function of the names -- which is what makes it
        # assertable without stubbing a directory reader. A spec that stubs the
        # reader instead goes vacuously green the moment someone swaps the reader
        # out, and this order is a contract six later cards inherit.
        #
        # @param names [Array<String>] module filenames, in any order
        # @return [Array<String>] the same names, in load order
        # @raise [RuntimeError] naming the offending file, if one is misnamed or
        #   two claim the same prefix
        def ordered(names)
          numbered = names.map { |name| [prefix_of(name), name] }
          refuse_collisions(numbered)
          numbered.sort_by(&:first).map(&:last)
        end

        # Which module a line of the injected chunk came from.
        #
        # Lua reports errors against the chunk it was handed, which is a synthetic
        # concatenation: `[string "<nvim>"]:566` names no file and, since the
        # split, no longer indexes runtime.lua either. This is how that number
        # becomes a place a reader can open.
        #
        # @param line [Integer] 1-based line in {source}
        # @return [Array(String, Integer)] module basename, and the 1-based line
        #   within it
        def locate(line)
          located = spans.find { |_, first, last| line.between?(first, last) }
          raise unplaceable(line) if located.nil?

          [located.first, line - located[1] + 1]
        end

        private

        # A line belonging to no module is one of two different things, and saying
        # "outside the injected chunk" about a line in the MIDDLE of it is worse
        # than saying nothing: the blank each `join("\n")` leaves between modules
        # is inside the chunk and belongs to neither neighbour. Unreachable from a
        # real Lua error, which never points at a blank line -- but this is a
        # debugging tool, and one that contradicts itself is one nobody trusts.
        def unplaceable(line)
          following = spans.find { |_, first, _| first > line }
          return "line #{line} is outside the injected chunk (#{spans.last.last} lines)" if line < 1 || following.nil?

          "line #{line} is the blank separator before #{following.first}, not a line of any module"
        end

        # @return [Array<Array(String, String)>] basename and body, head first
        def parts
          [[File.basename(@head), File.read(@head)]] +
            module_paths.map { |path| [File.basename(path), File.read(path)] }
        end

        # Where each part lands in the joined chunk. `join("\n")` terminates a part
        # that has no trailing newline and adds a blank line after one that does,
        # which is the whole of the arithmetic.
        #
        # @return [Array<Array(String, Integer, Integer)>] name, first line, last line
        def spans
          offset = 0
          parts.map do |name, body|
            first = offset + 1
            last = first + body.lines.size - 1
            offset = last + (body.end_with?("\n") ? 1 : 0)
            [name, first, last]
          end
        end

        def module_names
          raise "the runtime module directory is missing: #{@modules}" unless Dir.exist?(@modules)

          # Dot-names are skipped before anything else, and an editor is the
          # reason: emacs writes a lock file `.#20_buffers.lua` as a DANGLING
          # symlink, which is neither a file nor a directory. Without this, lain
          # refuses to attach for as long as a developer has a module open --
          # and blames a directory, which is not what they are looking at. It
          # also restores `Dir.glob` equivalence: glob's `*` never matches a
          # leading dot, so a dotted module was the one input on which the two
          # readers disagreed.
          names = Dir.children(@modules).grep(/\.lua\z/).reject { |name| name.start_with?(".") }
          directories = names.reject { |name| File.file?(File.join(@modules, name)) }
          unless directories.empty?
            raise "#{directories.sort.join(", ")} in #{@modules} is a directory, not a runtime module"
          end

          names
        end

        def prefix_of(name)
          match = MODULE_NAME.match(name)
          if match.nil?
            raise "runtime module #{name.inspect} is not named NN_name.lua (two digits, underscore, then " \
                  "lowercase) -- the prefix IS the load order, so a name without one has no place in it"
          end

          Integer(match[:prefix], 10)
        end

        def refuse_collisions(numbered)
          collisions = numbered.group_by(&:first).select { |_, sharing| sharing.size > 1 }
          return if collisions.empty?

          detail = collisions.map do |prefix, sharing|
            "#{format("%02d", prefix)} is claimed by #{sharing.map(&:last).sort.join(" and ")}"
          end
          raise "two runtime modules cannot share a load position -- #{detail.join("; ")}"
        end
      end
    end
  end
end
