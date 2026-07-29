# frozen_string_literal: true

module Lain
  module CLI
    # The ONE file a user's selector names, and the ONE refusal when nothing
    # answers to it. `lain friction`, `lain consolidate` and `lain improve` all
    # take a session the way a user has it to hand -- copied out of
    # `lain sessions`, tab-completed off disk, or typed without its suffix -- and
    # all three had their own byte-identical copy of this lookup plus their own
    # `SessionNotFound`. Three copies of a user-facing contract (which shorthands
    # work, what the refusal says, which error a rescuer names) drift silently,
    # because nothing compares them.
    #
    # One public class method and no instances: this is a pure function of a
    # selector and a session dir, and an instance whose `#path` nobody but its own
    # constructor sends is API promised by accident.
    #
    # == It is NOT `lain chat --resume`'s resolver
    #
    # {Resume::Selector#chosen} is a different contract, deliberately: it PREFIX
    # matches within the session dir, refuses an ambiguous prefix, filters
    # headerless files, and has no explicit-path arm at all. So `--resume
    # 20260721` resumes a session that `lain friction 20260721` refuses, and
    # `lain friction ../elsewhere/s.ndjson` reads a file `--resume` cannot name.
    # The asymmetry is intended -- resuming continues the session you were in,
    # reporting reads the file you named, and a report that guessed between two
    # candidates would attribute one session's friction to another -- so the two
    # resolvers stay two, and neither claims the other's behaviour.
    #
    # == The other half of discovery lives in {SessionJournals}
    #
    # That object folds EVERY journal in the directory and may never miss one;
    # this one picks the SINGLE file a selector names, which means deliberately
    # skipping candidates. Opposite invariants, so: two objects. Merging them
    # would also put a `dir:`-scoped, `types:`-bounded fold and a one-file lookup
    # behind one name, and `lain epic`'s adoption of the fold would then depend on
    # a resolution it does not want.
    #
    # == `paths:` is required
    #
    # {Command::Surface}'s doctrine: a collaborator nobody passed is a loud
    # ArgumentError here, not a quiet resolution against whatever project this
    # process happens to sit in. The three commands above own the default
    # ({Paths.new}) because they own the `paths:` seam their specs inject.
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

      # The resolutions tried, in widening order: the selector as given (an
      # explicit path, so a session outside this project stays reachable), then
      # under this project's session dir, then with the suffix a user drops when
      # they read the name off `lain sessions`.
      def self.candidates(selector, paths)
        dir = paths.sessions_dir
        [selector, File.join(dir, selector), File.join(dir, "#{selector}.ndjson")]
      end
      private_class_method :candidates
    end
  end
end
