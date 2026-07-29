# frozen_string_literal: true

require "active_support/core_ext/array/conversions"

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
        # Why a durable file cannot be picked, in the words the refusal uses.
        # Both are the SAME category -- a file the Loader could only call
        # Corrupt -- reached by two routes, which is why they are counted apart
        # but rejected together.
        EMPTY = "empty (a chat that recorded nothing)"
        HEADERLESS = "with no session header"
        EPHEMERAL = "ephemeral (--btw)"

        # "nothing wrong with it" -- {#unloadable}'s good-case key. Named, so the
        # arm that answers {#resumable_names} reads as the intent it is rather
        # than as a `group_by` artifact.
        PICKABLE = nil

        # How many headerless files the refusal names before it summarizes. They
        # are NAMED and not merely counted so a reader can recognize their own
        # file -- but a week of `lain epic approve` drains would otherwise put
        # twenty filenames in one sentence.
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

        # The files a pick may answer with: durable, and loadable.
        #
        # A file with no bytes in it is what {Journal.open} leaves behind when a
        # chat dies before its header lands, and UTC-timestamped names make it
        # sort NEWEST -- so the bare pick answered with it and the Loader could
        # only call it Corrupt.
        #
        # A HEADERLESS file is the same category by a different route, and it
        # arrives now because `sessions_dir` is not a chat's private directory:
        # `lain epic queue`'s sign-off drain ({CLI::EpicQueue}) appends its
        # decision through {Journal.open} too, deliberately, so the epic fold
        # reads every decision from one place. That file is durable,
        # non-ephemeral, and non-empty, so only its missing header tells it
        # apart -- and being written this morning, it sorts newest and the bare
        # pick landed on it. {Bench::Session::Loader#header} raises Corrupt
        # without a `"session"` record, so skipping it here is this method's
        # existing policy applied to the case that now exists, not a new one.
        #
        # The idempotence claim above survives BOTH checks: a resumed session
        # writes its header at {SessionRecord::Scribe} construction, before it
        # can exit, so the head of the chain is never a file skipped here.
        def resumable_names = unloadable.fetch(PICKABLE, [])

        # Grouped once, because the refusal has to NAME what it skipped and
        # "no sessions" said about a directory the user can see files in is a
        # refusal they stop believing. Keys are the reason constants, {PICKABLE}
        # the good-case arm; insertion order within each group is
        # {#durable_names}' sort, so the names come out oldest first.
        def unloadable
          @unloadable ||= durable_names.group_by { |name| unloadable_reason(path_of(name)) }
        end

        # Empty is asked FIRST so a zero-byte file keeps its own, more specific
        # answer: it is headerless too, but "nothing was ever recorded" tells a
        # reader something "no header record" does not.
        def unloadable_reason(path)
          return EMPTY if Journal.empty?(path)

          headerless?(path) ? HEADERLESS : PICKABLE
        end

        # Lazy, and it stops at the first line of a real session: the header is
        # a session's FIRST record ({SessionRecord::Scribe} writes it at
        # construction), so this is one line read per candidate, not a file.
        # A file that vanished between the listing and here is unpickable for
        # the same reason an absent one is empty to {Journal.empty?}.
        #
        # "Has one" and not "has exactly one", deliberately, where
        # {Bench::Session::Loader#header} demands `sole`. The question here is
        # whether the file is a chat session AT ALL -- a headerless one belongs
        # to another writer entirely and was never this command's to offer. A
        # two-header file IS a session, and a damaged one; hiding it from the
        # pick would hide a session the user wants to hear about, and the Loader
        # already refuses it by name and says how many headers it found. Skip
        # what is not ours; let the Loader judge what is.
        def headerless?(path)
          Journal.records(File.foreach(path), type: SessionRecord::HEADER_TYPE).first.nil?
        rescue SystemCallError
          true
        end

        def chosen(selector)
          return newest if selector.empty?
          # An EXACT filename is deliberate and stays honored, headerless
          # included: salvaging a named file is a choice, never an accident of
          # sorting, and someone naming a drain file has said which file they
          # mean. Only the two CONVENIENCE picks -- bare and prefix -- filter.
          return with_records(selector) if session_names.include?(selector)

          loadable(with_records(matched(durable_names, selector)))
        end

        # The prefix pick's counterpart to {#resumable_names}, applied after
        # {#matched} rather than before it so the refusal can say what the file
        # IS instead of "no session matching" about a file sitting right there.
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
        # selectable by its exact name.
        # Assembled from an explicit ordered list rather than from
        # {#unloadable}'s own key order, so the sentence a user reads is a
        # function of the reasons and not of which file happened to land in the
        # directory first.
        # `to_sentence` rather than `join(" and ")`: three reasons chained on
        # "and" reads as one run-on clause, and each of these already contains
        # its own parenthetical.
        def skipped
          phrases = [counted(EMPTY), headerless_phrase, ephemeral_phrase].compact
          phrases.empty? ? "" : ": skipped #{phrases.to_sentence}"
        end

        def counted(reason)
          count = unloadable.fetch(reason, []).size
          "#{count} #{reason}" if count.positive?
        end

        # NAMED, where the other two reasons are only counted, because "no
        # sessions" said about a directory the user can see files in is a refusal
        # they stop believing.
        #
        # It IDENTIFIES rather than advises. An earlier version said "name one
        # exactly to load it anyway", which was simply false: the exact-name path
        # is honored by this class, but a headerless file then refuses at the
        # Loader too, so nothing loads either way. Saying what the file probably
        # is lets a reader recognize their own sign-off journal and stop looking.
        def headerless_phrase
          names = unloadable.fetch(HEADERLESS, [])
          return nil if names.empty?

          "#{names.size} #{HEADERLESS} (#{listed(names)}) -- not chat sessions; " \
            "a `lain epic approve` sign-off journal, say"
        end

        # NEWEST first, and it is the older end that gets summarized: these names
        # sort chronologically, and the file a reader is about to act on is the
        # one written most recently.
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
        # the Loader says next, having found no header -- would send a reader
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

        # An unloadable file never makes a prefix AMBIGUOUS -- it is not a
        # candidate anyone has to disambiguate from, since picking it could only
        # end in Corrupt. It stays in play when it is the ONLY match, so
        # {#with_records} and {#loadable} can each say what is actually wrong
        # with it rather than the prefix reading as unmatched.
        def narrowed(matches)
          loadable_matches = matches.reject { |name| unloadable_reason(path_of(name)) }
          loadable_matches.empty? ? matches : loadable_matches
        end
      end
    end
  end
end
