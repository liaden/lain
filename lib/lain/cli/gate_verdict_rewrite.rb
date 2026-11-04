# frozen_string_literal: true

require "fileutils"
require "json"

module Lain
  module CLI
    # `lain epic rewrite-verdicts`: the readers refuse a `gate_decision` written
    # before decisions carried a verdict, and old sessions are still live, so
    # this rewrites them in place rather than dropping them.
    #
    # A chained file is re-linked from its first rewritten line, because a link
    # is derived from the bytes before it and `lain verify` must still pass; the
    # old and new tips are printed for anyone holding a saved one.
    #
    # Nothing is written until every file is locked and checked, so one refusal
    # leaves every file as it was. A broken chain is refused, never re-linked,
    # since re-linking would launder an edit. Each file is read only once
    # locked, or a line a session wrote in between would be lost.
    class GateVerdictRewrite
      BACKUP = ".pre-verdict.bak"

      # Raised before any file is written.
      class Refused < Error; end

      READABLE_CHAINS = %i[intact unchained].freeze
      private_constant :READABLE_CHAINS

      # @param paths [Paths] resolves the project's session directory
      # @param root [String] the project root
      def initialize(paths: Paths.new, root: Project::Resolver.default_project.root)
        @paths = paths
        @root = root
      end

      # @return [String] each file rewritten with its count, and for a chained one its old and new tip;
      #   or that nothing changed
      # @raise [Refused] naming the file that stopped the run
      def call
        files = sessions.map { |path| SessionFile.new(path) }.select(&:outdated?)
        return nothing_changed if files.empty?

        locked(files) { files.map(&:rewrite!).join("\n") }
      end

      private

      def sessions
        dir = @paths.filing_dir(root: @root)
        File.directory?(dir) ? Paths.ndjson_in(dir).sort : []
      end

      def nothing_changed
        "no gate_decision record written before verdicts in #{@paths.filing_dir(root: @root)}; nothing changed"
      end

      def locked(files)
        files.each(&:lock!)
        files.each(&:check!)
        yield
      ensure
        files.each(&:unlock)
      end

      # Per file, so its lock is held from the check through the rename.
      class SessionFile
        # @param path [String]
        def initialize(path)
          @path = path
        end

        # Read unlocked, so it only chooses which files to lock.
        def outdated? = File.foreach(@path, mode: "rb").any? { |line| Outdated.line?(line) }

        def lock!
          @io = File.open(@path, "rb")
          unless @io.flock(File::LOCK_EX | File::LOCK_NB)
            raise Refused, "#{@path} is held by a live lain session -- end that session, then run this again; " \
                           "no file was rewritten"
          end
          @lines = @io.read.lines
        end

        def check!
          # A rename over a symlink would replace the link and leave the session it names untouched.
          unless File.lstat(@path).file?
            raise Refused, "#{@path} is not a regular file -- replace the link with the file it names, " \
                           "then run this again; no file was rewritten"
          end
          @before = Journal::Verify.new(@path).call
          unless READABLE_CHAINS.include?(@before.reason)
            raise Refused, "#{@path} has a record chain that does not verify (#{@before.reason}) -- it is not " \
                           "re-linked over; inspect it with lain verify; no file was rewritten"
          end
          return unless File.exist?(backup)

          raise Refused, "#{backup} already exists -- move it aside first; no file was rewritten"
        end

        def unlock = @io&.close

        # @return [String] what changed in this file
        def rewrite!
          rewritten = Relinked.new(@lines).lines
          written(backup, @lines.join)
          temporary = "#{@path}.#{Process.pid}.rewrite"
          written(temporary, rewritten.join)
          File.rename(temporary, @path)
          said(rewritten)
        end

        private

        def backup = "#{@path}#{BACKUP}"

        # Created 0600 so the bytes are never readable wider than the session while
        # written, then given the session's own mode, which a umask cannot narrow.
        def written(path, bytes)
          File.open(path, "wbx", 0o600) do |file|
            file.write(bytes)
            file.fsync
            file.chmod(File.stat(@path).mode & 0o7777)
          end
        end

        def said(rewritten)
          count = @lines.count { |line| Outdated.line?(line) }
          lines = ["#{@path}: #{count} gate_decision records rewritten, original kept at #{backup}"]
          lines << "  tip #{@before.tip} -> #{Journal::Line.link(rewritten.last)}" if @before.chained_from
          lines.join("\n")
        end
      end
      private_constant :SessionFile

      # The old shape is named once, so choosing a file and rewriting its lines cannot disagree.
      module Outdated
        HELD_SURFACE = "held"

        # @param line [String]
        def self.line?(line)
          record = Journal.parse(line)
          !record.nil? && record?(record)
        end

        # @param record [Hash{String=>Object}]
        def self.record?(record)
          record["type"] == Lain::Epic::SignoffQueue::JOURNAL_TYPE && record.key?("approved") && !record.key?("verdict")
        end

        # The verdict takes the place `approved` held, so the record reads as it did.
        #
        # @param record [Hash{String=>Object}]
        # @return [Hash{String=>Object}]
        def self.upgraded(record)
          record.to_h { |key, value| key == "approved" ? ["verdict", word(record)] : [key, value] }
        end

        def self.word(record)
          return "approve" if record["approved"] == true
          return "hold" if record["answered_by"] == HELD_SURFACE

          "deny"
        end
        private_class_method :word
      end
      private_constant :Outdated

      # Every line of one file, old records upgraded and every link after them
      # recomputed from the line before it as it now reads.
      class Relinked
        # @param lines [Array<String>] the file's lines, each with its newline
        def initialize(lines)
          @lines = lines
        end

        # @return [Array<String>]
        def lines
          previous = nil
          @lines.map { |line| previous = relinked(upgraded(line), previous) }
        end

        private

        def upgraded(line)
          return line unless Outdated.line?(line)

          record = JSON.parse(line)
          body = JSON.generate(Outdated.upgraded(record.except(Journal::LINK)))
          record.key?(Journal::LINK) ? Journal::Line.splice!(+body, record[Journal::LINK]) << "\n" : "#{body}\n"
        end

        def relinked(line, previous)
          return line unless Journal::Verify::LINK_AT_END.match?(line)

          link = previous ? Journal::Line.link(previous) : Journal::Line::ORIGIN
          unlinked = line.sub(Journal::Verify::LINK_AT_END, "}")
          Journal::Line.splice!(unlinked, link) << (line.end_with?("\n") ? "\n" : "")
        end
      end
      private_constant :Relinked
    end
  end
end
