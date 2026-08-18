# frozen_string_literal: true

module Lain
  module Tools
    # Tier 1 (structured): reads one file's contents by path, whole or through
    # a line window. Direct Ruby, no subprocess -- there is no command string
    # here for the model to control, which is what makes tier 1 the lowest-risk
    # shape (see the plan's "Tool tiers, and where the security boundary is").
    #
    # A missing path, a directory, or an unreadable file is reported as an
    # error {Tool::Result}, never a raise: the model asked a reasonable
    # question and deserves an answer it can act on, not a crashed tool call.
    #
    # == The window, and why completeness is the interesting half
    #
    # `offset`/`limit` exist so a file too large to hand back whole is still
    # reachable. The bytes are the easy part; what matters is what the
    # read-set is told. A window that leaves lines unseen records
    # `complete: false`, so {Tools::EditFile} refuses the edit and says WHY --
    # editing from a window would clobber lines the model never saw -- and the
    # result itself carries one line saying the same thing, so the model learns
    # it before spending a turn on the refusal.
    #
    # A window that covers the whole file records a COMPLETE read, and that is
    # load-bearing rather than a nicety: it is the only path by which a file
    # that cannot be read unwindowed becomes editable at all. {Tools::WriteFile}
    # is not an alternative -- its overwrite contract asks {Lain::Session#read?}
    # too, and it replaces the whole file rather than one span.
    class ReadFile < Tool
      # The largest line number an input may name. Not a bound on how much may
      # be READ -- {Tool::Bounds}, T4/T5, owns that -- but on what a line number
      # can MEAN: past 2^53 a JSON number no longer carries an integer exactly,
      # so the value the model sent and the value we received stop being the
      # same number. It is also what keeps `offset`/`limit` away from Ruby's own
      # allocator, where the failure is a bare `RangeError: bignum too big to
      # convert into 'long'` naming neither the parameter nor a remedy.
      MAX_LINE_NUMBER = (2**53) - 1

      # The wire shape: one required path, and an optional line window.
      class Input < Tool::Input
        field :path, :string, description: "Path to the file to read.", required: true
        field :offset, :integer,
              description: "1-based line number to start reading at. Defaults to the first line."
        field :limit, :integer,
              description: "Maximum number of lines to return, counting from offset. " \
                           "Defaults to the rest of the file."

        # Shape, not safety (see the header of tool/input.rb): a line number
        # below 1 does not name a line, and one above MAX_LINE_NUMBER does not
        # survive the wire. Nothing here is a bound on how much may be read.
        validates :offset, numericality: {
          greater_than_or_equal_to: 1, less_than_or_equal_to: MAX_LINE_NUMBER
        }, allow_nil: true
        validates :limit, numericality: {
          greater_than_or_equal_to: 1, less_than_or_equal_to: MAX_LINE_NUMBER
        }, allow_nil: true
      end

      input_model Input

      # What a read handed back, and whether the model saw the whole file.
      # The two travel together because {Lain::Session#record_read} needs both
      # and neither {Whole} nor {Window} may answer one without deciding the
      # other.
      Read = Data.define(:contents, :complete)

      # The unwindowed read: `File.read`, byte for byte what this tool did
      # before a window existed, and complete by construction. Its own object
      # rather than a branch, so the default path cannot drift as the windowed
      # one grows (Null Object, as {Sink::Null} is to {Sink::IOAdapter}).
      class Whole
        def read(path) = Read.new(contents: File.read(path), complete: true)

        # One shared frozen instance, for {Channel::Null}'s reason: it has no
        # state, so every unwindowed read reuses this rather than allocating a
        # fresh reader per call.
        INSTANCE = new.freeze

        # @return [Whole] the shared instance
        def self.instance = INSTANCE
      end

      # `limit` lines from 1-based `offset`, either bound optional.
      class Window
        def initialize(offset:, limit:)
          @offset = offset || 1
          @limit = limit
          freeze
        end

        # ONE line past the window is the entire evidence for "there is more of
        # this file you have not seen", and pulling exactly one is what lets
        # completeness be decided without materialising the file a window
        # exists to avoid materialising -- the same collect-one-past-the-cap
        # discipline {Tools::Grep} uses for MAX_MATCHES. With no `limit` the
        # window runs to EOF, so there is no line past it and completeness
        # rests on `offset` alone.
        #
        # `take(n).force` and NOT `first(n)`, and the difference is not style:
        # `first` RESERVES an Array of n slots before a single line is read
        # (measured: 381 MB of address space at n = 5*10^7), and n here is a
        # number the model chose. `take` reserves nothing and returns the same
        # Array. Under an address-space cap the difference is a `NoMemoryError`,
        # which is not a StandardError -- so it would escape
        # {Effect::Handler::Live}'s rescue and propagate past the loop.
        def read(path)
          lines = File.foreach(path).lazy.drop(@offset - 1)
          @limit ? bounded(lines) : to_eof(lines)
        end

        private

        def bounded(lines)
          taken = lines.take(@limit + 1).force
          disclosed(taken.take(@limit), complete: from_the_top? && taken.size <= @limit)
        end

        def to_eof(lines) = disclosed(lines.force, complete: from_the_top?)

        # A complete window withheld nothing, so it says nothing -- and stays
        # byte-identical to the unwindowed read, which is what lets a window
        # covering the whole file stand in for one.
        def disclosed(seen, complete:)
          return Read.new(contents: seen.join, complete: true) if complete

          Read.new(contents: "#{terminated(seen.join)}#{notice(seen.size)}", complete: false)
        end

        # In {Tools::Grep}'s register: it names the window and the fact of
        # partialness, never a total -- knowing how many lines the file has
        # would mean reading the whole file, which is the cost a window exists
        # to avoid.
        def notice(count)
          "... window only: #{covered(count)}; the rest of the file was not read, " \
            "so edit_file will refuse it"
        end

        def covered(count)
          return "no lines at or after line #{@offset}" if count.zero?

          "lines #{@offset}-#{@offset + count - 1}"
        end

        # The notice needs a line of its own. A file whose last line has no
        # terminator is the one case where saying so costs a byte the file does
        # not contain, and running the two together would be worse.
        def terminated(text) = text.empty? || text.end_with?("\n") ? text : "#{text}\n"

        def from_the_top? = @offset == 1
      end

      def name = "read_file"

      def description
        "Reads a text file at the given path. Reads the whole file by " \
          "default; pass offset (1-based line number) and/or limit (number " \
          "of lines) to read one window of it instead. A window that does " \
          "not cover the whole file is labelled as partial and does not " \
          "satisfy edit_file's read-before-write requirement -- read the file " \
          "whole, or window it end to end, before editing it. Returns an " \
          "error result if the path does not exist, is a directory, or " \
          "cannot be read."
      end

      # Audited: this tool only reads the filesystem and appends to the
      # Session's read-set (Session::Journaled#record_read is documented
      # fiber-safe, no yield between its check and its mutate -- session.rb).
      # No process-global state: WorkerEnv#cwd is read, never chdir'd.
      def parallel_safe? = true

      protected

      def perform(input, invocation)
        session = session_of(invocation)
        # A relative path resolves against the session's WorkerEnv cwd (Dir.pwd
        # under the default, so byte-identical to a raw File.read); the RESOLVED
        # absolute path is what both the read and the read-set see, so the
        # edit-before-write contract matches on the same file regardless of how
        # the model spelled it.
        path = File.expand_path(input.path, session.worker_env.cwd)
        problem = problem_with(path)
        return Tool::Result.error(problem) if problem

        read = window_for(input).read(path)
        # The read-set is the point of tier 1 reads: a later edit-before-write
        # contract asks the session whether this file was read. Only a SUCCESSFUL
        # read counts -- a missing or unreadable path taught the model nothing.
        session.record_read(path, complete: read.complete)
        Tool::Result.ok(read.contents)
      rescue SystemCallError, IOError => e
        Tool::Result.error("could not read #{path}: #{e.message}")
      end

      private

      # A window from line one with no limit IS the whole file, so it takes the
      # whole-file path rather than materialising every line as its own String
      # to reach a byte-identical answer. Not merely wasteful: once the
      # unwindowed read is bounded by size, routing this spelling through
      # {Window} would make it a one-keyword bypass of that bound, at the
      # highest memory cost of the three spellings rather than the lowest.
      def window_for(input)
        return Whole.instance if input.limit.nil? && (input.offset.nil? || input.offset == 1)

        Window.new(offset: input.offset, limit: input.limit)
      end

      def problem_with(path)
        return "no such file: #{path}" unless File.exist?(path)
        return "is a directory, not a file: #{path}" if File.directory?(path)
        return "file is not readable: #{path}" unless File.readable?(path)

        nil
      end
    end
  end
end
