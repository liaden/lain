# frozen_string_literal: true

module Lain
  module CLI
    class Resume
      # Resolves `--resume [SELECTOR]` to one path under the project's session
      # dir: nil/"" picks the newest, an exact filename or unique prefix picks
      # that session. Split out of {Resume} (a pre-existing, self-contained
      # responsibility -- "which file does --resume mean") the same way
      # {Salvager} is: {Resume} grew past `Metrics/ClassLength` once T18's
      # salvage wiring landed, and CLAUDE.md's rule is to extract a real
      # collaborator, never loosen the limit.
      class Selector
        # @param dir [String] the project's session directory
        def initialize(dir:)
          @dir = dir
        end

        # @param selector [String, nil]
        # @return [String] the chosen file's full path
        # @raise [Refusal]
        def call(selector)
          path_of(chosen(selector.to_s))
        end

        private

        def path_of(name) = File.join(@dir, name)

        # UTC-timestamped filenames sort chronologically, so `.last` is the
        # newest -- also what makes resume idempotent: an exited-immediately
        # resumed session is itself the newest file, so a second `--resume`
        # continues the head of the CHAIN, never forking the original.
        def session_names
          Dir.children(@dir).select { |name| name.end_with?(".ndjson") }.sort
        end

        # The bare pick and prefix matching see only the durable record --
        # the same default view `lain sessions` lists (T3 fix round), so
        # resume/fork never silently land on a scratch file the listing
        # hides, nor record a `resumed_from` naming a `.btw` file promotion
        # later renames. The EXACT filename stays selectable above: salvaging
        # a crashed --btw session is deliberate, not an accident of sorting.
        def durable_names
          session_names.reject { |name| Paths.ephemeral?(name) }
        end

        # A file with no bytes in it is what {Journal.open} leaves behind when a
        # chat dies before its header lands, and UTC-timestamped names make it
        # sort NEWEST -- so the bare pick answered with it and the Loader could
        # only call it Corrupt. The idempotence claim above survives: a resumed
        # session writes its header before it can exit, so the head of the chain
        # is never a file skipped here.
        def resumable_names
          durable_names.reject { |name| Journal.empty?(path_of(name)) }
        end

        def chosen(selector)
          return newest if selector.empty?
          return with_records(selector) if session_names.include?(selector)

          with_records(matched(durable_names, selector))
        end

        def newest
          resumable_names.last or raise Refusal, "no sessions to resume under #{@dir}#{skipped}"
        end

        # "No sessions" said about a directory the user can SEE files in is a
        # refusal they stop believing, and it hides the only thing that would
        # let them act: an empty file is deleteable, an ephemeral one is
        # selectable by its exact name.
        def skipped
          counts = { "empty (a chat that recorded nothing)" => durable_names.size - resumable_names.size,
                     "ephemeral (--btw)" => session_names.size - durable_names.size }
          named = counts.filter_map { |label, count| "#{count} #{label}" if count.positive? }
          named.empty? ? "" : ": skipped #{named.join(" and ")}"
        end

        # A NAMED empty session refuses saying exactly that. "Corrupt" -- what
        # the Loader says next, having found no header -- would send a reader
        # hunting damage in a file that simply never got a record.
        def with_records(name)
          raise Refusal, "#{name} is empty: nothing was ever recorded into it" if Journal.empty?(path_of(name))

          name
        end

        def matched(names, selector)
          matches = names.select { |name| name.start_with?(selector) }
          return matches.first if matches.size == 1

          raise Refusal, "no session matching #{selector.inspect} under #{@dir}" if matches.empty?

          raise Refusal, "#{selector.inspect} is ambiguous under #{@dir}: #{matches.join(", ")}"
        end
      end
    end
  end
end
