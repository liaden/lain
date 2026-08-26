# frozen_string_literal: true

module Lain
  module CLI
    # The ONE file a user's selector names, and the ONE refusal when nothing
    # answers to it. `lain friction`, `lain consolidate` and `lain improve` all
    # take a session the way a user has it to hand -- copied out of
    # `lain sessions`, tab-completed off disk, or typed without its suffix --
    # and a user-facing contract kept in three copies (which shorthands work,
    # what the refusal says, which error a rescuer names) drifts silently,
    # because nothing compares them.
    #
    # == It is NOT `lain chat --resume`'s resolver
    #
    # {Resume::Selector#chosen} PREFIX matches within the session dir, refuses
    # an ambiguous prefix, filters headerless files, and has no explicit-path
    # arm -- so `--resume 20260721` resumes a session `lain friction 20260721`
    # refuses. The asymmetry is intended: resuming continues the session you
    # were in, reporting reads the file you named, and a report that guessed
    # between two candidates would attribute one session's friction to another.
    #
    # {SessionJournals} stays separate for the same kind of reason: it folds
    # EVERY journal in a directory and may never miss one, where this picks the
    # SINGLE file a selector names, which means deliberately skipping
    # candidates. Opposite invariants.
    #
    # `paths:` is required -- {Command::Surface}'s doctrine: a collaborator
    # nobody passed is a loud ArgumentError, not a quiet resolution against
    # whatever project this process happens to sit in.
    class SessionFile
      # No file on disk answers to the given selector, under any resolution.
      class SessionNotFound < Error; end

      # @param selector [String] an explicit path, a bare filename, or a
      #   filename missing its ".ndjson" suffix
      # @param paths [Paths] resolves this project's session dir
      # @return [String] the resolved path
      # @raise [SessionNotFound] naming every candidate, so a typo against a
      #   session dir the user did not expect is diagnosable from the message
      def self.resolve(selector, paths:)
        tried = candidates(selector, paths)
        tried.find { |candidate| File.file?(candidate) } ||
          raise(SessionNotFound, "no session found for #{selector.inspect} -- looked at #{tried.join(", ")}")
      end

      # Widening order: the selector as given (an explicit path, so a session
      # outside this project stays reachable), then under this project's session
      # dir, then with the suffix a user drops reading a name off
      # `lain sessions`.
      def self.candidates(selector, paths)
        dir = paths.sessions_dir
        [selector, File.join(dir, selector), File.join(dir, "#{selector}.ndjson")]
      end
      private_class_method :candidates
    end
  end
end
