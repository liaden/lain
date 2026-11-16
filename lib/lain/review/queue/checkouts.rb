# frozen_string_literal: true

module Lain
  module Review
    class Queue
      # Which local clone stands for a GitHub `owner/repo`, found by reading
      # each clone's `origin` under the configured roots.
      class Checkouts
        ORIGIN = %r{github\.com[:/](?<name>[^/\s]+/[^/\s]+?)(?:\.git)?/?\z}

        # @param roots [Array<String>] directories searched 2 levels deep
        # @param shell_out_factory [#call] builds the subprocess runner
        # @param notes [#puts] where a repo with several clones is named
        def initialize(roots:, shell_out_factory: Shell::Out.public_method(:new), notes: Sink::Null.new)
          @roots = roots
          @shell_out_factory = shell_out_factory
          @notes = notes
          @noted = Set.new
        end

        # @param name_with_owner [String] `owner/repo`, matched without regard to case
        # @return [String, nil] the clone's absolute path; with several, the one whose HEAD commit is newest
        def for(name_with_owner)
          clones = index.fetch(name_with_owner.downcase, [])
          newest = clones.max_by(&:last)&.first
          note_extras(name_with_owner, newest, clones)
          newest
        end

        private

        # Built on first use and kept: a clone cloned later is found on the next process.
        def index
          @index ||= candidates.each_with_object({}) do |dir, found|
            name = origin_of(dir)
            (found[name] ||= []) << [dir, committed_at(dir)] if name
          end
        end

        def candidates
          @roots.flat_map { |root| Dir.glob(["*", "*/*"], base: root).map { |sub| File.join(root, sub) } }
                .select { |dir| File.directory?(File.join(dir, ".git")) }
        end

        def origin_of(dir)
          shell = checkout(dir).run("remote", "get-url", "origin")
          Shell::Out.ok?(shell) ? shell.stdout.strip[ORIGIN, :name]&.downcase : nil
        end

        def committed_at(dir)
          shell = checkout(dir).run("log", "-1", "--format=%ct", "HEAD")
          Shell::Out.ok?(shell) ? shell.stdout.to_i : 0
        end

        def checkout(dir) = Isolation::Checkout.of(dir, shell_out_factory: @shell_out_factory)

        def note_extras(name, newest, clones)
          others = clones.map(&:first) - [newest]
          return unless others.any? && @noted.add?(name)

          @notes.puts("#{name} has other clones: #{others.join(", ")}; using #{newest}")
        end
      end
    end
  end
end
