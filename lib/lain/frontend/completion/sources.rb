# frozen_string_literal: true

require "find"

module Lain
  module Frontend
    class Completion
      # Where a sigil's candidates come from, and the matcher built over them.
      #
      # Built ONCE per sigil and kept: {Lain::Ext::Fuzzy}'s constructor is the
      # expensive half (one crossing of the FFI boundary with the whole batch,
      # plus a directory walk for paths), while `#match` is the cheap half that
      # runs per keystroke. Building per keystroke would walk the project on
      # every character typed, which is the difference between a completion
      # that feels instant and one that does not.
      class Sources
        COMMAND = "/"
        PATH = "@"
        SIGILS = [COMMAND, PATH].freeze

        # Directories a build tool owns, pruned by name at every level. Not
        # taste: a populated Rust `target/` is six figures of paths, and the
        # walk is synchronous on the human's first keypress. A `.gitignore`
        # reader would be the honest general answer and is a ticket, not this.
        PRUNED = %w[target tmp vendor node_modules].freeze

        # @param commands [Enumerable] anything yielding objects that answer
        #   `#name` -- {Lain::CLI::Command::Registry} includes Enumerable and
        #   yields in registration order, so it is already one of these
        # @param skills [Enumerable] skill names, i.e. {Skill::Catalog#names}.
        #   Names rather than the catalog itself: a command and a skill are the
        #   same thing at the prompt (`/word`), so they reduce to one list
        # @param root [String] the tree an `@path` candidate is walked from
        def initialize(commands: [], skills: [], root: Dir.pwd)
          @commands = commands
          @skills = skills
          @root = root
          @matchers = {}
        end

        def sigil?(char) = SIGILS.include?(char)

        # @return [Lain::Ext::Fuzzy] the matcher for `sigil`, built on first ask
        def for(sigil) = @matchers[sigil] ||= Ext::Fuzzy.new(candidates_for(sigil))

        private

        def candidates_for(sigil)
          case sigil
          when COMMAND then command_names
          when PATH then paths
          else raise ArgumentError, "#{sigil.inspect} names no completion source; expected #{SIGILS.inspect}"
          end
        end

        # Bare names, without the sigil: the sigil is the {Completion::Token}'s
        # and is put back when a candidate is accepted, so it is neither
        # matched against nor stored a thousand times over.
        def command_names
          named = (@commands.map(&:name) + @skills.to_a).map { |name| Completion.printable(name.to_s) }
          named.reject(&:empty?)
        end

        # A plain directory walk, deliberately NOT {Tools::ListFiles} or
        # {Tools::Glob}: those are Tool subclasses with Tool::Input validation
        # that flow through the effect/approval machinery, so sourcing a
        # keystroke's candidates from them would invert the dependency
        # direction (frontend -> tools) and drag approval into a render loop.
        #
        # `Find` and not `Dir.glob` because glob has no exclusion: it would
        # walk every path in a pruned directory before anything could filter
        # them, which is the whole cost. Find also lstats each entry once --
        # the same stat glob's caller had to make separately -- and lstat is
        # why a symlinked directory reads as a symlink and is never descended
        # into a loop.
        #
        # WHAT SCRUBBING AT THE SOURCE COSTS, stated because choosing it
        # deliberately means writing down its price. A scrubbed candidate is no
        # longer the name on disk: accepting `@[2Jevil_tty.rb` yields a token
        # `File.exist?` answers false for, and two files whose names differ only
        # in control bytes collapse to one string drawn twice. NOT a security
        # regression -- a collision with a legitimate name resolves to the
        # innocent file and leaves the hostile one uncompletable, which is the
        # safe direction -- but it is a real limitation. Naming a hostile file
        # is something the human must do by hand.
        #
        # A name that is ENTIRELY control bytes scrubs to "", which is not a
        # candidate at all: it would sort first and draw a bare sigil the human
        # cannot act on. Dropped rather than drawn.
        #
        # THE CANDIDATE SET IS FIXED FOR THE LIFE OF THE PROCESS. A file
        # written after the first completion cannot be completed until lain
        # restarts. Deliberate -- see the class comment on why this is built
        # once -- but it is a real limitation with no invalidation hook yet.
        #
        # Sorted because the matcher breaks equal scores by insertion order,
        # and filesystem order would differ between machines.
        def paths
          found = []
          Find.find(@root) do |path|
            Find.prune if pruned?(path)
            found << Completion.printable(path.delete_prefix(File.join(@root, ""))) if File.file?(path)
          end
          found.reject(&:empty?).sort
        end

        # Dot entries go for the reason `.git` does -- thousands of paths no
        # human names at a prompt. The root itself is never pruned, or the walk
        # would end before it began.
        #
        # Matched on the BASENAME, so a plain file named `tmp` or `target` is
        # pruned too and cannot be completed. Accepted rather than fixed: the
        # alternative is a `File.directory?` stat per entry to save a filename
        # nobody has, and the walk's whole point is not paying for entries it
        # does not want.
        def pruned?(path)
          return false if path == @root

          name = File.basename(path)
          name.start_with?(".") || PRUNED.include?(name)
        end
      end
    end
  end
end
