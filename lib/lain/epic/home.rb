# frozen_string_literal: true

require "fileutils"
require "tempfile"

module Lain
  module Epic
    Home = Data.define(:slug, :path)

    # Where one epic's human-facing markdown lives, and the only door to it.
    #
    # Two homes, chosen by `[epics] home` in `.lain/config.toml` and nothing
    # else: `:xdg` puts the tree under `<state_home>/epics/<project_hash>/`, so
    # an epic never shows up in `git status`; `:repo` puts it under
    # `<root>/.lain/epics/`, so a team can review an epic in a pull request.
    # {Paths} is injected, so a spec resolves against a throwaway
    # `$XDG_STATE_HOME`.
    #
    # Runtime state is deliberately absent from the layout (`research.md`,
    # `epic.md`, `issues/<id>.md`, `plans/<id>.md`) -- an issue's current status
    # is the Journal fold, not a file here, so nothing in this directory can
    # disagree with the run that produced it.
    class Home
      # Reopened rather than written as a `Data.define do ... end` block: a
      # constant or nested class defined THERE is lexically scoped to
      # `Lain::Epic`, so `MalformedName` and `Artifact` would be invisible to
      # the very methods that raise and build them.

      # A slug or an issue id being used as a filename. NOT {Epic::ID_RESERVED}:
      # that grammar reserves what the markdown needs, and is entirely satisfied
      # by `../escape` and by `a/b` -- directory problems, not text problems, so
      # a name that becomes a path gets a path's grammar. Lowercase because two
      # names differing only in case are the same file on a case-insensitive
      # filesystem, which would silently merge two epics.
      NAME = /\A[a-z0-9][a-z0-9-]*\z/
      NAME_RULE = "lowercase letters, digits and dashes, opening with a letter or a digit"
      # Says what was rejected and what would be accepted, and stops there: why
      # the grammar is what it is belongs above, not in a 2am error message.
      BAD_NAME = "%<kind>s %<value>s is not a filesystem name: it must match %<grammar>s (%<rule>s)"

      # Error taxonomy: a refusal subclasses {Lain::Error} beside its raiser.
      class MalformedName < Error; end
      class MissingArtifact < Error; end
      class EscapesHome < Error; end

      # The read-side counterpart of {Paths::Unwritable} and a separate class
      # rather than a reuse: "cannot create" is a lie about a read that found a
      # directory or was denied permission.
      class UnreadableArtifact < Error
        def initialize(path, cause)
          super("cannot read #{path}: #{cause.message}")
        end
      end

      # The directory holding every epic for this project, with no epic chosen:
      # public and slug-free because "are there any epics yet" is a question a
      # caller answers before it can name one. `else` rather than a Hash default
      # -- {Config::Epics} closes the set at construction, so reaching here means
      # a config-shaped double, and quietly defaulting would write a user's epics
      # somewhere they never asked for.
      def self.container(config:, paths:, root: Dir.pwd)
        home = config.epics_home
        directory =
          case home
          when :xdg then File.join(paths.state_home, "epics", paths.project_hash(root))
          when :repo then File.join(root, ".lain", "epics")
          else raise Error, "epics_home #{home.inspect} names no artifact home (expected :xdg or :repo)"
          end
        directory.freeze
      end

      # Resolution is PURE -- it computes a path and creates nothing -- so a
      # refused slug leaves no directory behind and a caller may resolve a home
      # just to name it in a message. Directories arrive on the first write.
      def self.resolve(config:, paths:, slug:, root: Dir.pwd)
        checked = checked_name(slug, "epic slug")
        new(slug: checked, path: File.join(container(config:, paths:, root:), checked).freeze)
      end

      # The boolean form of the grammar: a predicate that only raises cannot
      # answer {Epic::Issue#emittable?}'s question.
      def self.filesystem_name?(value) = value.is_a?(String) && NAME.match?(value)

      # The refusal {#checked_name} would raise, as a message rather than an
      # exception, so it and {Epic::Issue#emittable_failures} cannot drift into
      # two spellings of the same rule.
      def self.filesystem_name_failure(value, kind)
        return if filesystem_name?(value)

        format(BAD_NAME, kind:, value: value.inspect, grammar: NAME.inspect, rule: NAME_RULE)
      end

      # The one gate every path segment passes, public because it is checked in
      # two places that cannot share a receiver: a slug before there is a Home,
      # and an issue id on every read and write after there is one. Interned
      # rather than merely frozen, so the whole value stays Ractor-shareable.
      def self.checked_name(value, kind)
        failure = filesystem_name_failure(value, kind)
        raise MalformedName, failure if failure

        -value
      end

      def research = artifact("research.md")
      def epic = artifact("epic.md")
      def issue(id) = artifact(File.join("issues", filename(id)))
      def plan(id) = artifact(File.join("plans", filename(id)))

      # {Document.to_markdown} refuses issues it cannot write back verbatim, and
      # that render happens while this argument is evaluated -- before
      # {Artifact#write} has made a directory or touched `epic.md`. So a refusal
      # leaves the previous epic exactly as it was.
      def write_epic(graph)
        epic.write(Document.to_markdown(graph))
        self
      end

      # Parse is validation of the GRAMMAR, never an integrity check on the
      # bytes. A prefix of a valid epic is usually itself a valid epic, so a file
      # truncated mid-write parses cleanly to the issues that survived and an
      # empty file parses to an empty graph. What this guarantees is a
      # well-formed {Graph} -- not that it is the graph someone wrote.
      def read_epic = Document.parse_markdown(epic.read)

      private

      def artifact(relative) = Artifact.new(self, relative)

      def filename(id) = "#{Home.checked_name(id, "issue id")}.md"

      # One file inside a home. Separate from {Home} because "which directory is
      # this epic's" and "read or replace one file without ever leaving a partial
      # one" are different jobs, and the four artifacts differ only in a path.
      class Artifact
        # Interned, not merely assigned: a returned `path` a caller can append
        # to is a handle that redirects the next write, and a String left mutable
        # inside a frozen object also costs `Ractor.shareable?`.
        def initialize(home, relative)
          @home = home
          @relative = -relative
          @path = -File.join(home.path, relative)
          freeze
        end

        attr_reader :path

        # Refuses on exactly the paths {#read} and {#write} refuse, so the three
        # cannot disagree: without this, `if a.exist? then a.read` goes
        # true-then-{EscapesHome}. A predicate that raises is unusual; a duck
        # whose three methods answer differently about one path is worse.
        def exist?
          contained!
          File.exist?(path)
        end

        # ENOENT is absence and has its own answer; every other errno -- EISDIR,
        # EACCES, ELOOP -- is one failure to a caller, and naming it here keeps a
        # raw `Errno::EISDIR: Is a directory @ io_fread` from reaching a user.
        # The ENOENT clause must come first: it is a subclass of SystemCallError.
        def read
          contained!
          File.read(path)
        rescue Errno::ENOENT
          raise MissingArtifact, "no epic artifact at #{path}"
        rescue SystemCallError => e
          raise UnreadableArtifact.new(path, e)
        end

        # Written beside the target and renamed over it, because `rename` within
        # one directory is atomic: a reader sees the old file or the new one,
        # never a truncated one. `mkdir_p` is idempotent, so an existing home is
        # reused and never cleared -- only the named file is replaced.
        def write(content)
          contained!
          FileUtils.mkdir_p(File.dirname(path))
          replace(content)
          self
        rescue SystemCallError => e
          raise Paths::Unwritable.new(path, e)
        end

        private

        # The grammar guards the NAME; this guards the composed PATH. Neither
        # `mkdir_p` nor `Tempfile.create` refuses to follow a symlink, so a name
        # beyond reproach still lands wherever a link between the container and
        # the file points -- every segment below the container must therefore be
        # an ordinary entry, a symlink to a directory INSIDE the home included
        # ("every segment is an ordinary entry" is total, where "resolves to
        # somewhere inside" reintroduces the resolution complexity this avoids).
        # The container itself is exempt: it is the location the user configured,
        # and the one segment that never comes from model-authored text.
        #
        # A walk rather than a `File.realpath` prefix-compare, for two reasons
        # that are NOT "realpath gets it wrong": `realpath` raises ENOENT on a
        # path that does not exist yet, which is the ordinary case here, and
        # `File.symlink?` lstats, so a missing segment answers false with no
        # `rescue` and the whole check can therefore run BEFORE `mkdir_p` -- a
        # refusal has not already made directories inside whatever the link
        # pointed at.
        #
        # Non-goal: this is not TOCTOU-safe. The lstat here and the `mkdir_p`
        # that follows are separate syscalls, so a link swapped in between them
        # wins. This raises the floor under model-authored names, not a sandbox.
        def contained!
          [@home.slug, *@relative.split(File::SEPARATOR)]
            .inject(File.dirname(@home.path)) do |walked, segment|
              File.join(walked, segment).tap { |step| refuse_link!(step) }
            end
        end

        def refuse_link!(step)
          return unless File.symlink?(step)

          raise EscapesHome, "#{step} is a symlink, so #{path} would resolve outside the epic home"
        end

        # `Tempfile.create` opens 0600 -- correctly, since it cannot know who
        # should read the file it is about to become -- but what lands here is a
        # document a human opens and a team may review, so the mode is restored
        # to what an ordinary `File.write` under this umask would produce.
        def replace(content)
          Tempfile.create(File.basename(path), File.dirname(path)) do |tmp|
            tmp.write(content)
            tmp.close
            File.chmod(0o666 & ~File.umask, tmp.path)
            File.rename(tmp.path, path)
          end
        end
      end

      # {resolve} claims to be the only door, so the other two are shut: both
      # were reachable, and `Home.new(slug: "../../etc", path: anywhere)` skips
      # the grammar entirely. `private` scopes methods and not constants, which
      # is why `Artifact` needs its own line. `[]` goes with `new` because {Data}
      # defines both.
      private_class_method :new, :[]
      private_constant :Artifact
    end
  end
end

# This file is the home/ subtree's index. Journaled reopens the class above, so it
# loads AFTER the class body.
require_relative "home/journaled"
