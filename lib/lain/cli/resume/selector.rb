# frozen_string_literal: true

require "active_support/core_ext/array/conversions"

module Lain
  module CLI
    class Resume
      # Resolves `--resume [SELECTOR]` to one path under the project's session
      # dir: nil/"" picks the newest, an exact filename or unique prefix picks
      # that session. Split out of {Resume} when the salvage wiring pushed that
      # class past `Metrics/ClassLength` -- extract, never loosen.
      class Selector
        # Why a durable file cannot be picked, in the words the refusal uses.
        # The first two are the SAME category -- a file the Loader could only
        # call Corrupt -- reached by two routes, which is why they are counted
        # apart but rejected together.
        EMPTY = "empty (a chat that recorded nothing)"
        HEADERLESS = "with no session header"
        EPHEMERAL = "ephemeral (--btw)"

        # "nothing wrong with it" -- {#unloadable}'s good-case key, named so the
        # arm answering {#resumable_names} reads as intent, not a `group_by`
        # artifact.
        PICKABLE = nil

        # How many headerless files the refusal names before it summarizes: they
        # are NAMED so a reader can recognize their own file, but a week of
        # `lain epic approve` drains would put twenty filenames in one sentence.
        NAMED_LIMIT = 3

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
        # newest -- also what makes resume idempotent: a resumed session that
        # exited immediately is itself the newest file, so a second `--resume`
        # continues the head of the CHAIN rather than forking the original.
        def session_names
          Dir.children(@dir).select { |name| name.end_with?(".ndjson") }.sort
        end

        # The bare pick and prefix matching see only the durable record -- the
        # same view `lain sessions` lists -- so resume/fork never silently land
        # on a scratch file the listing hides, nor record a `resumed_from`
        # naming a `.btw` file promotion later renames. The EXACT filename stays
        # selectable above: salvaging a crashed --btw session is deliberate.
        def durable_names
          session_names.reject { |name| Paths.ephemeral?(name) }
        end

        # The files a pick may answer with: durable, and loadable. Both skipped
        # kinds sort NEWEST and so were what the bare pick answered with, and
        # both the Loader could only call Corrupt.
        #
        # A zero-byte file is what {Journal.open} leaves behind when a chat dies
        # before its header lands. A HEADERLESS one arrives because
        # `sessions_dir` is not a chat's private directory: `lain epic queue`'s
        # sign-off drain appends its decision through {Journal.open} too, so the
        # epic fold reads every decision from one place. That file is durable,
        # non-ephemeral and non-empty, so only its missing header tells it apart.
        #
        # The idempotence claim above survives BOTH checks: a resumed session
        # writes its header at {SessionRecord::Scribe} construction, before it
        # can exit, so the head of the chain is never a file skipped here.
        def resumable_names = unloadable.fetch(PICKABLE, [])

        # Grouped once, because the refusal has to NAME what it skipped. Keys
        # are the reason constants, {PICKABLE} the good-case arm; insertion
        # order within a group is {#durable_names}' sort, so names come out
        # oldest first.
        def unloadable
          @unloadable ||= durable_names.group_by { |name| unloadable_reason(path_of(name)) }
        end

        # Empty is asked FIRST so a zero-byte file keeps the more specific
        # answer: it is headerless too, but "nothing was ever recorded" tells a
        # reader something "no header record" does not.
        def unloadable_reason(path)
          return EMPTY if Journal.empty?(path)

          headerless?(path) ? HEADERLESS : PICKABLE
        end

        # Lazy, and it stops at the first line of a real session: the header is
        # a session's FIRST record, so this is one line read per candidate, not
        # a file.
        #
        # "Has one" and not "has exactly one", deliberately, where
        # {Bench::Session::Loader#header} demands `sole`. The question here is
        # whether the file is a chat session AT ALL. A two-header file IS a
        # session, and a damaged one; hiding it from the pick would hide a
        # session the user wants to hear about, and the Loader already refuses
        # it by name. Skip what is not ours; let the Loader judge what is.
        def headerless?(path)
          Journal.records(File.foreach(path), type: SessionRecord::HEADER_TYPE).first.nil?
        rescue SystemCallError
          true
        end

        def chosen(selector)
          return newest if selector.empty?
          # An EXACT filename stays honored, headerless included: naming a file
          # is a choice, never an accident of sorting. Only the two CONVENIENCE
          # picks -- bare and prefix -- filter.
          return with_records(selector) if session_names.include?(selector)

          loadable(with_records(matched(durable_names, selector)))
        end

        # Applied after {#matched} rather than before it, so the refusal can say
        # what the file IS instead of "no session matching" about a file sitting
        # right there.
        def loadable(name)
          if headerless?(path_of(name))
            raise Refusal, "#{name} has no #{SessionRecord::HEADER_TYPE.inspect} header record, so it is not a " \
                           "chat session -- a `lain epic approve` sign-off journal, say"
          end

          name
        end

        def newest
          resumable_names.last or raise Refusal, "no sessions to resume under #{@dir}#{skipped}"
        end

        # "No sessions" said about a directory the user can SEE files in is a
        # refusal they stop believing, and it hides the only thing that would
        # let them act: an empty file is deleteable, an ephemeral one is
        # selectable by its exact name. Assembled from an explicit ordered list
        # rather than {#unloadable}'s key order, so the sentence is a function
        # of the reasons and not of which file landed in the directory first.
        # `to_sentence` because three reasons chained on "and" reads as one
        # run-on clause, each already carrying its own parenthetical.
        def skipped
          phrases = [counted(EMPTY), headerless_phrase, ephemeral_phrase].compact
          phrases.empty? ? "" : ": skipped #{phrases.to_sentence}"
        end

        def counted(reason)
          count = unloadable.fetch(reason, []).size
          "#{count} #{reason}" if count.positive?
        end

        # NAMED, where the other two reasons are only counted, and it IDENTIFIES
        # rather than advises. An earlier version said "name one exactly to load
        # it anyway", which was false: the exact-name path is honored here, but
        # a headerless file then refuses at the Loader, so nothing loads either
        # way. Saying what the file probably is lets a reader recognize their
        # own sign-off journal and stop looking.
        def headerless_phrase
          names = unloadable.fetch(HEADERLESS, [])
          return nil if names.empty?

          "#{names.size} #{HEADERLESS} (#{listed(names)}) -- not chat sessions; " \
            "a `lain epic approve` sign-off journal, say"
        end

        # NEWEST first, and the older end gets summarized: the file a reader is
        # about to act on is the one written most recently.
        def listed(names)
          older = names.size - NAMED_LIMIT
          newest = names.reverse.first(NAMED_LIMIT).join(", ")
          older.positive? ? "#{newest}, +#{older} older" : newest
        end

        def ephemeral_phrase
          count = session_names.size - durable_names.size
          "#{count} #{EPHEMERAL}" if count.positive?
        end

        # A NAMED empty session refuses saying exactly that. "Corrupt" -- what
        # the Loader would say next, having found no header -- sends a reader
        # hunting damage in a file that simply never got a record.
        def with_records(name)
          raise Refusal, "#{name} is empty: nothing was ever recorded into it" if Journal.empty?(path_of(name))

          name
        end

        def matched(names, selector)
          matches = names.select { |name| name.start_with?(selector) }
          candidates = narrowed(matches)
          return candidates.first if candidates.size == 1

          raise Refusal, "no session matching #{selector.inspect} under #{@dir}" if matches.empty?

          raise Refusal, "#{selector.inspect} is ambiguous under #{@dir}: #{candidates.join(", ")}"
        end

        # An unloadable file never makes a prefix AMBIGUOUS: picking it could
        # only end in Corrupt. It stays in play when it is the ONLY match, so
        # {#with_records} and {#loadable} can say what is actually wrong with it
        # rather than the prefix reading as unmatched.
        def narrowed(matches)
          loadable_matches = matches.reject { |name| unloadable_reason(path_of(name)) }
          loadable_matches.empty? ? matches : loadable_matches
        end
      end
    end
  end
end
