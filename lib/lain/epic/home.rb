# frozen_string_literal: true

require "fileutils"
require "tempfile"

module Lain
  module Epic
    # Where one epic's human-facing markdown lives, and the only door to it.
    #
    # Two homes, chosen by `[epics] home` in `.lain/config.toml` and nothing
    # else: `:xdg` puts the tree under `<state_home>/epics/<project_hash>/`, so
    # an epic never shows up in `git status`; `:repo` puts it under
    # `<root>/.lain/epics/`, so a team can review an epic in a pull request.
    # {Paths} is injected rather than constructed, so a spec resolves against a
    # throwaway `$XDG_STATE_HOME` instead of the real one.
    #
    # The layout is fixed: `research.md`, `epic.md`, `issues/<id>.md`,
    # `plans/<id>.md`. Runtime state is deliberately absent -- an issue's current
    # status is the Journal fold, not a file here, so nothing in this directory
    # can disagree with the run that produced it. What lives here is what a human
    # reads and edits.
    Home = Data.define(:slug, :path)

    # Reopened rather than written as a `Data.define do ... end` block: a
    # constant or nested class defined THERE is lexically scoped to `Lain::Epic`,
    # so `MalformedName` and `Artifact` would be invisible to the very methods
    # that raise and build them (the documented trap; see `Request::SYSTEM_PREFIX`).
    class Home
      # A slug or an issue id being used as a filename. NOT {Epic::ID_RESERVED}:
      # that grammar reserves what the markdown needs (backticks delimit an id in
      # a heading, line breaks end one), and it is entirely satisfied by
      # `../escape` and by `a/b`. Those are directory problems, not text
      # problems, so a name that becomes a path gets a path's grammar -- one that
      # can express no separator, no parent reference, and no dotfile. Lowercase
      # because two names differing only in case are the same file on a
      # case-insensitive filesystem, which would silently merge two epics.
      NAME = /\A[a-z0-9][a-z0-9-]*\z/
      NAME_RULE = "lowercase letters, digits and dashes, opening with a letter or a digit"
      # Says what was rejected and what would be accepted, and stops there. Why
      # this grammar is not {Epic::ID_RESERVED} is a maintainer's question,
      # answered in the comment above rather than appended to the sentence a
      # developer reads at 2am.
      BAD_NAME = "%<kind>s %<value>s is not a filesystem name: it must match %<grammar>s (%<rule>s)"

      # Named per the error-taxonomy convention: a refusal subclasses
      # {Lain::Error} next to the owner that raises it (see {Paths::Unwritable}).
      class MalformedName < Error; end
      class MissingArtifact < Error; end
      class UnknownHome < Error; end
      class EscapesHome < Error; end

      # The read-side counterpart of {Paths::Unwritable}, and a separate class
      # from it rather than a reuse: "cannot create" is a lie about a read that
      # found a directory or was denied permission, and this unit has a standing
      # rule against error messages that misdescribe what happened (see
      # {Config::Malformed#describe}).
      class UnreadableArtifact < Error
        def initialize(path, cause)
          super("cannot read #{path}: #{cause.message}")
        end
      end

      # The directory holding every epic for this project, with no epic chosen.
      # Public and slug-free because "are there any epics yet" and "which slugs
      # exist" are questions a caller has to answer BEFORE it can name one.
      #
      # `else` rather than a Hash default: {Config::Epics} already closes the set
      # at construction, so reaching here means a config-shaped double or a value
      # added later, and quietly defaulting would write a user's epics somewhere
      # they never asked for.
      def self.container(config:, paths:, root: Dir.pwd)
        home = config.epics_home
        directory =
          case home
          when :xdg then File.join(paths.state_home, "epics", paths.project_hash(root))
          when :repo then File.join(root, ".lain", "epics")
          else raise UnknownHome, "epics_home #{home.inspect} names no artifact home (expected :xdg or :repo)"
          end
        directory.freeze
      end

      # The home for one epic. Resolution is PURE: it computes a path and creates
      # nothing, so a refused slug cannot have left a directory behind, and a
      # caller may resolve a home just to name it in a message. The directories
      # arrive on the first write.
      def self.resolve(config:, paths:, slug:, root: Dir.pwd)
        checked = checked_name(slug, "epic slug")
        new(slug: checked, path: File.join(container(config:, paths:, root:), checked).freeze)
      end

      # The boolean form of {#checked_name}'s grammar, so a caller can ask
      # whether a value would survive the gate without provoking the raise --
      # {Epic::Issue#emittable?} is the reason this exists: it names the
      # filesystem grammar as one of the two an issue must satisfy, and a
      # predicate that only raises cannot answer that question.
      def self.filesystem_name?(value) = value.is_a?(String) && NAME.match?(value)

      # The refusal {#checked_name} would raise, as a message rather than an
      # exception -- what {Epic::Issue#emittable_failures} names for an id
      # this grammar refuses, so that message and this one cannot drift apart
      # into two spellings of the same rule.
      def self.filesystem_name_failure(value, kind)
        return if filesystem_name?(value)

        format(BAD_NAME, kind:, value: value.inspect, grammar: NAME.inspect, rule: NAME_RULE)
      end

      # The one gate every path segment passes through, public because it is
      # checked in two places that cannot share a receiver: a slug before there
      # is a Home, and an issue id on every read and write after there is one.
      # Interned rather than merely frozen, matching {Epic::Issue}'s ids, so the
      # whole value stays Ractor-shareable.
      def self.checked_name(value, kind)
        failure = filesystem_name_failure(value, kind)
        raise MalformedName, failure if failure

        -value
      end

      def research = artifact("research.md")
      def epic = artifact("epic.md")
      def issue(id) = artifact(File.join("issues", filename(id)))
      def plan(id) = artifact(File.join("plans", filename(id)))

      # The graph as the document an author edits. {Document.to_markdown} refuses
      # issues it cannot write back verbatim, and that render happens while this
      # argument is evaluated -- before {Artifact#write} has made a directory or
      # touched `epic.md`. So a refusal leaves the previous epic exactly as it
      # was, which matters most in the case that provokes it: an author part-way
      # through a review.
      def write_epic(graph)
        epic.write(Document.to_markdown(graph))
        self
      end

      # Parse is the validation of the GRAMMAR: a heading, link line, status
      # mark, or fence the grammar cannot represent is refused loudly, and an
      # edge naming an issue with no heading is refused by Graph.
      #
      # It is NOT an integrity check on the bytes, and nothing here should be
      # read as one. A prefix of a valid epic is usually itself a valid epic, so
      # a file truncated mid-write parses cleanly to the issues that survived;
      # an empty file parses to an empty graph. Detecting that a document is
      # incomplete rather than merely small is a parser-side concern, recorded
      # against {Document} as a follow-up. What this method guarantees is that
      # whatever comes back is a well-formed {Graph} -- not that it is the graph
      # someone wrote.
      def read_epic = Document.parse_markdown(epic.read)

      private

      def artifact(relative) = Artifact.new(self, relative)

      def filename(id) = "#{Home.checked_name(id, "issue id")}.md"

      # One file inside a home: where it is, and the three things anyone does to
      # it. Separate from {Home} because "which directory is this epic's" and
      # "read or replace one file without ever leaving a partial one" are
      # different jobs, and the four artifacts differ only in a relative path.
      class Artifact
        # Interned, not merely assigned: a returned `path` that a caller can
        # append to is a handle that redirects the next write, and a String left
        # mutable inside a frozen object also costs `Ractor.shareable?`, which
        # this unit spells out as the mechanical statement that a value holds no
        # reachable mutable state.
        def initialize(home, relative)
          @home = home
          @relative = -relative
          @path = -File.join(home.path, relative)
          freeze
        end

        attr_reader :path

        # Refuses on exactly the paths {#read} and {#write} refuse, so the three
        # methods cannot disagree about whether a path is legitimate: without
        # this, `if a.exist? then a.read` goes true-then-`EscapesHome`, and a
        # dangling symlinked home answers "nothing here" to the question while
        # raising on the write. A predicate that raises is unusual; a duck whose
        # three methods answer differently about the same path is worse.
        def exist?
          contained!
          File.exist?(path)
        end

        # ENOENT is absence and has its own answer; every other errno -- EISDIR
        # when a directory sits where the file should, EACCES, ELOOP -- is one
        # failure to a caller, and naming it here is what keeps a raw
        # `Errno::EISDIR: Is a directory @ io_fread` from reaching a user. The
        # ENOENT clause must come first: it is a subclass of SystemCallError.
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
        # never a truncated one, and a crash mid-write costs the new content
        # rather than the content already there. `mkdir_p` is idempotent, so an
        # existing home is reused and never cleared -- only the named file is
        # replaced.
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
        # that is beyond reproach still lands wherever a link between the
        # container and the file points. Every segment from the container down to
        # the artifact itself must therefore be an ordinary entry.
        #
        # The container is exempt, deliberately: it is the location the user
        # configured, and symlinking `~/.local/state` elsewhere is their
        # arrangement rather than an escape from it. It is also the one segment
        # that never comes from model-authored text -- it is config plus {Paths}.
        #
        # A walk rather than a `File.realpath` prefix-compare, for two reasons
        # that are NOT "realpath gets the answer wrong" -- compared against the
        # CONFIGURED container it gets it right. First, `realpath` raises ENOENT
        # on a path that does not exist yet, which is the ordinary case here:
        # almost every write creates the artifact. Second, `File.symlink?` lstats,
        # so a segment that does not exist answers false and needs no `rescue`,
        # and the whole check can therefore run BEFORE `mkdir_p` -- a refusal has
        # not already made directories inside whatever the link pointed at.
        #
        # Refusing a symlink to a directory INSIDE the home is intended, not
        # collateral: "every segment is an ordinary entry" is total and
        # explainable, where "resolves to somewhere inside" reintroduces exactly
        # the resolution complexity this avoids.
        #
        # Non-goal, stated rather than left to be discovered: this is not
        # TOCTOU-safe. The lstat here and the `mkdir_p`/`File.read` that follow
        # are separate syscalls, so a link swapped in between them wins. Closing
        # that needs `O_NOFOLLOW`/`openat` throughout, and an attacker who can
        # swap entries in the user's own state directory has already won a bigger
        # fight. This raises the floor under model-authored names; it is not a
        # sandbox.
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
        # to what an ordinary `File.write` under this umask would have produced.
        # The block form tolerates the file being renamed out from under it.
        def replace(content)
          Tempfile.create(File.basename(path), File.dirname(path)) do |tmp|
            tmp.write(content)
            tmp.close
            File.chmod(0o666 & ~File.umask, tmp.path)
            File.rename(tmp.path, path)
          end
        end
      end

      # {resolve} claims to be the only door, so the other two are shut. Both
      # were reachable: `Home.new(slug: "../../etc", path: anywhere)` skips the
      # grammar entirely, and `Artifact.new` skips the home. `private` scopes
      # methods and not constants, which is why `Artifact` needs its own line
      # -- being nested under a private section reads like it is closed, and is
      # not. `[]` goes with `new` because {Data} defines both.
      private_class_method :new, :[]
      private_constant :Artifact
    end
  end
end
