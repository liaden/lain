# frozen_string_literal: true

require "fileutils"
require "securerandom"

module Lain
  module Tools
    class Subagent < Tool
      # Keeps a child's answer whole in a file when neither it nor its own
      # summary fits under the ceiling, so the parent is handed a pointer
      # rather than a clipped head that reads complete, or nothing at all.
      #
      # A file is named by the time and a random suffix, never by lease or
      # worker id, and opened exclusively: two children answering in the same
      # second must not meet, and a spill never writes over another.
      class Spill
        # The answers dir could not be made or written.
        class Unwritable < Error; end

        # What a keep can come to, one callback each: `kept` takes the paths
        # written, `unwritable` why they could not be, and `unkept` nothing,
        # for a spill that keeps nothing. A value rather than loose keywords,
        # so a misspelled callback raises where the outcomes are built.
        Outcomes = Data.define(:kept, :unwritable, :unkept)

        # A spawner with no answers dir: it keeps nothing, so its answer floors.
        module Null
          # @param _answer [String] unused: nothing is kept
          # @param _summary [String, nil] unused
          # @param outcomes [Outcomes]
          # @return [Object] what `unkept` answers
          def self.keep(_answer, _summary, outcomes) = outcomes.unkept.call
        end

        # @param paths [Paths]
        # @param root [String] the project root
        # @return [String] where the project's spilled answers are kept, keyed
        #   by project so a confined reader of one project's never reaches another's
        def self.home(paths, root) = paths.container("answers", key: paths.project_hash(root))

        # @param dir [String] the answers dir, created at the first spill
        def initialize(dir:)
          @dir = -dir.to_s
          freeze
        end

        # A summary that cannot be written still leaves the answer kept, since
        # the answer is the half the parent spawned the child for.
        #
        # @param answer [String] the child's whole answer
        # @param summary [String, nil] its own summary, when it gave a whole one
        # @return [Array<String>] the paths written, full answer first
        # @raise [Unwritable] when the answer itself could not be written
        def call(answer:, summary: nil)
          FileUtils.mkdir_p(@dir, mode: 0o700)
          stem = File.join(@dir, "#{Time.now.utc.strftime("%Y%m%dT%H%M%S")}-#{SecureRandom.hex(4)}")
          [written("#{stem}.md", answer), *summarized("#{stem}.summary.md", summary)]
        rescue SystemCallError, IOError => e
          raise Unwritable, e.message
        end

        # @param answer [String] the child's whole answer
        # @param summary [String, nil] its own summary, when it gave a whole one
        # @param outcomes [Outcomes]
        # @return [Object] what `kept` or `unwritable` answers
        def keep(answer, summary, outcomes)
          outcomes.kept.call(call(answer:, summary:))
        rescue Unwritable => e
          outcomes.unwritable.call(e.message)
        end

        private

        def summarized(path, summary)
          summary ? [written(path, summary)] : []
        rescue SystemCallError, IOError
          FileUtils.rm_f(path)
          []
        end

        def written(path, text)
          File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(text) }
          path
        end
      end
    end
  end
end
