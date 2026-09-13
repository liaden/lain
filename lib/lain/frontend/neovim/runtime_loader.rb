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
      # one. Both halves are measured rather than assumed:
      #
      #   - Sorting filenames as STRINGS is lexicographic, so `100_foo.lua` loads
      #     FIRST -- ahead of `20_buffers.lua` -- and an unprefixed `sidebar.lua`
      #     loads LAST, past the attach announcement that must be last. Both are
      #     the obvious thing to do next, and both were silent.
      #   - Two files picking the same prefix resolved by filename, silently.
      #
      # So a name that is not `NN_lowercase.lua` is refused, a repeated prefix is
      # refused, and order is an Integer comparison no directory reader can
      # influence. Nothing may sort past `99_attach.lua` because two digits cannot
      # exceed 99 and 99 is already claimed.
      #
      # See {HEAD}'s own header comment for the rules that follow from being one
      # chunk.
      class RuntimeLoader
        # The chunk head: the injected args, the protocol handshake, and the
        # `_G.__lain` namespace the modules publish through.
        HEAD = Paths::Shipped::NEOVIM_RUNTIME_HEAD

        # Everything else, one file per capability.
        MODULES = Paths::Shipped::NEOVIM_RUNTIME_MODULES_DIR

        # Two digits, an underscore, then a lowercase name. Anchored at both ends,
        # which is what keeps `20_buffers.lua.orig` and `20_buffers.lua~` out
        # without needing a rule about editors.
        MODULE_NAME = /\A(?<prefix>\d{2})_[a-z0-9_]+\.lua\z/

        # A module CANNOT be given its own `load(body, "@path")` -- that would
        # compile it as its own chunk, and a chunk's `local`s are invisible to
        # any other chunk. The runtime's modules are not independent: {HEAD}'s
        # own rule 2 is that a module sees every local declared above it, and
        # that is exactly the sharing a separate `load` per module would break.
        # Measured, not assumed: wrapping each real module that way loads as far
        # as `05_records.lua`, whose `RECORD_START` table is keyed by
        # `00_constants.lua`'s locals, and dies with "table index is nil" before
        # a single command is defined.
        #
        # So every module still runs in ONE shared scope -- but that scope is a
        # function, wrapped in `xpcall`. Two facts about `xpcall`'s second
        # argument (the message handler) are load-bearing:
        #
        #   1. It runs WHILE THE FAILING STACK IS STILL LIVE -- the one moment
        #      `debug.traceback` can see the real call chain. An identity
        #      handler that just returns the message, followed by a bare
        #      `error(msg, 0)` outside the `xpcall`, throws that chain away and
        #      reports the RE-RAISE site instead -- a confidently wrong line,
        #      which is worse than the opaque one it replaced.
        #   2. It only runs for a LOAD-TIME error. A command callback, an
        #      autocmd, `v:lua.__lain.foldexpr` -- every rail this runtime
        #      defines is a function that OUTLIVES the `xpcall` that defined
        #      it, so nearly every real error in a live cockpit fires after
        #      `xpcall` has already returned `true`. Translating only the
        #      load-time shape covers the rare case and silently drops the
        #      common one.
        #
        # `_G.__lain.locate` answers (2): the SAME translator the `xpcall`
        # handler uses, published on the namespace every module already
        # publishes through, so a deferred error caught anywhere -- Ruby,
        # `:messages`, a human's own `exec_lua` -- can still be decoded. That
        # is the same job `#locate` used to do on request; it moved into Lua
        # because Ruby-side offset arithmetic has nothing left to attribute
        # once the chunk it describes has already been discarded by nvim.
        #
        # The arithmetic did not go away -- it moved, and it had to: the
        # measured `05_records.lua:82` failure above is *why* no module can be
        # its own chunk, and a translator has to live somewhere once that is
        # true. `#spans_for` below is `#spans` with the head's contribution
        # taken as a parameter instead of assumed as the first entry.
        LOCATE = <<~LUA
          local function __lain_locate(message, spans)
            if type(message) ~= "string" then return message end
            return (message:gsub('%[string "<nvim>"%]:(%d+):', function(line)
              line = tonumber(line)
              for _, span in ipairs(spans) do
                if line >= span[2] and line <= span[3] then
                  return string.format("%s:%d:", span[1], line - span[2] + 1)
                end
              end
            end))
          end
        LUA
        private_constant :LOCATE

        # Forward-declared empty and filled in AFTER the module bodies (see
        # {#assemble}): a table whose LITERAL FORM is written once its rows are
        # known would have to be counted before it exists, which is exactly the
        # forward dependency the previous version of this file carried as
        # `#span_table_lines`. Filling it by index instead makes the fixed
        # prefix -- {HEAD}, {LOCATE}, this declaration, {PUBLISH_LOCATE},
        # {WRAP_OPEN} -- independent of how many modules there are.
        #
        # `__lain_spans` and `__lain_locate` are themselves top-level locals
        # every module below sees, under the same rule that lets modules share
        # `runtime.lua`'s constants -- and so, in principle, a module COULD
        # shadow either name and nothing would say so (rule 3 in {HEAD}'s own
        # header). The double-underscore is the same convention the runtime's
        # own modules use for names that must never collide with a
        # capability's.
        SPAN_DECLARATION = "local __lain_spans = {}\n"
        private_constant :SPAN_DECLARATION

        # Published on the namespace every module already publishes through,
        # so a DEFERRED error -- one raised by a function a module defined,
        # after the `xpcall` below already returned -- can still be decoded:
        # `_G.__lain.locate(tostring(err))` from Ruby, or typed by hand against
        # `:messages` from inside the editor this runtime is running in.
        PUBLISH_LOCATE = "_G.__lain.locate = function(message) return __lain_locate(message, __lain_spans) end\n"
        private_constant :PUBLISH_LOCATE

        # Opens the shared scope every module body is pasted into.
        WRAP_OPEN = "local ok, __lain_err = xpcall(function()\n"
        private_constant :WRAP_OPEN

        # Closes it. The handler is `debug.traceback` at level 1 -- the error
        # site itself, not this handler's own frame -- captured while the real
        # stack is still live, so the chain a human needs (which module called
        # which) survives into the message {#assemble} goes on to translate.
        WRAP_CLOSE = "end, function(message) return debug.traceback(message, 1) end)\n"
        private_constant :WRAP_CLOSE

        # Runs after {#span_assignments}, so the translator it calls always has
        # a complete table to search -- whether `ok` or not.
        FINAL = "if not ok then error(__lain_locate(__lain_err, __lain_spans), 0) end\n"
        private_constant :FINAL

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

          modules = module_paths.map { |path| [File.basename(path), with_trailing_newline(File.read(path))] }
          assemble(with_trailing_newline(File.read(@head)), modules)
        end

        # @return [Array<String>] module paths in load order
        def module_paths
          ordered(module_names).map { |name| File.join(@modules, name) }
        end

        # A pure function of the names, which is what makes the order assertable
        # without stubbing a directory reader -- a spec that stubs the reader
        # goes vacuously green the moment someone swaps the reader out.
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

        private

        # Every module body is normalized to end with exactly one newline before
        # concatenation, so a module's line count is the whole of its
        # contribution to {#spans_for}'s running offset -- no conditional blank
        # line to reason about, and so no line that belongs to neither neighbour.
        def with_trailing_newline(text)
          text.end_with?("\n") ? text : "#{text}\n"
        end

        # {HEAD} stays OUTSIDE the shared scope: it carries the injected varargs,
        # legal only in a main chunk, and it is the one part of the chunk a
        # translated error would gain nothing from -- the handshake is the
        # runtime's own text, not a capability a reader would need pointed at.
        #
        # @param head_body [String] {HEAD}'s contents, newline-terminated
        # @param modules [Array<Array(String, String)>] basename and
        #   newline-terminated body, in load order
        # @return [String] the assembled chunk
        def assemble(head_body, modules)
          prefix = head_body + LOCATE + SPAN_DECLARATION + PUBLISH_LOCATE + WRAP_OPEN
          spans = spans_for(modules, prefix.lines.size)

          prefix + modules.map(&:last).join + WRAP_CLOSE + span_assignments(spans) + FINAL
        end

        # @param modules [Array<Array(String, String)>] basename and
        #   newline-terminated body, in load order
        # @param start_line [Integer] the 1-based line the first module's body
        #   opens on, once everything ahead of it -- {HEAD}, {LOCATE},
        #   {SPAN_DECLARATION}, {PUBLISH_LOCATE}, {WRAP_OPEN} -- has been
        #   counted. Fixed regardless of module count, unlike the table those
        #   spans used to be written as, which is what let the old
        #   `#span_table_lines` retire along with the table.
        # @return [Array<Array(String, Integer, Integer)>] name, first and last
        #   line of each module WITHIN the assembled chunk
        def spans_for(modules, start_line)
          offset = start_line
          modules.map do |name, body|
            first = offset + 1
            offset += body.lines.size
            [name, first, offset]
          end
        end

        # Written AFTER the module bodies (see {#assemble}) precisely so the
        # spans' own text never has to be sized before the offsets it reports
        # are known -- index assignment rather than a table literal, so this
        # text's line count is never load-bearing to anything.
        #
        # @param spans [Array<Array(String, Integer, Integer)>] name, first and
        #   last line of each module WITHIN the assembled chunk
        # @return [String] Lua statements filling {SPAN_DECLARATION}'s table
        def span_assignments(spans)
          spans.each_with_index.map do |(name, first, last), i|
            "__lain_spans[#{i + 1}] = {#{name.inspect}, #{first}, #{last}}\n"
          end.join
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
