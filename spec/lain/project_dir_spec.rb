# frozen_string_literal: true

require "digest"
require "fileutils"
require "ripper"
require "tmpdir"
require "pathname"

# Mechanical enforcement of ONE resolver for the published state feed. Three
# renderers read or write that file, each used to compose the path itself, and a
# fourth spelling is trivial to write by hand and invisible in review -- so it is
# forbidden here rather than in a paragraph nobody re-reads.
#
# The path the scan guards MOVED: the feed is rewritten every turn, so it
# is machine state and now lives under `$XDG_STATE_HOME/lain`, not in the
# project's `.lain/` tree. The scan moved with it. The old spelling is still
# forbidden -- an expression naming `state.json` beside `Dir.pwd` or `.lain` is
# somebody rebuilding the location this card retired -- and the new ingredients
# ({Lain::Paths#state_home}, {Lain::Paths#project_hash}) are watched alongside.
#
# Ripper, not a text match, for the reason `spec/output_discipline_spec.rb`
# parses too. A grep catches ONE spelling: it misses the same join with the tail
# pre-joined, `"#{Dir.pwd}/.lain/state.json"`, `Dir.pwd + "/.lain"`, a
# recomposition through `ProjectDir::STATE_FILE`, and even a line-wrapped copy of
# the identical expression -- while flagging the words in a COMMENT, which the
# text version of this scan did until it was replaced. `lib/` is full of prose
# about `.lain/state.json`, and every word of it is invisible to an AST walk.
module ProjectDirDiscipline
  # The file this scan is about, plus every other name an expression can use to
  # reach it. Spelled here rather than read off the class so that a rename of a
  # constant cannot silently disarm the scan.
  #
  # `STATE_NAME` is the ANCHOR: an expression that does not name the file is not
  # rebuilding its path, which is what keeps a sentence with `state.json` in it
  # and nothing else from reading as a composition.
  STATE_NAME = "state.json"
  PROJECT_NAME = ".lain"
  CWD_READERS = %w[pwd getwd].freeze

  # The kind segment under `$XDG_STATE_HOME/lain`. It is an ingredient in its
  # own right, and it has to be: the retired location carried TWO literals
  # (`.lain` and `state.json`), so a rebuild over an opaque root was caught by
  # the literals alone. The new one carries one literal plus two method calls,
  # and hoisting those two calls into their own statements left a final
  # expression naming nothing but `state.json` -- a from-scratch rebuild that
  # the gate reported clean.
  KIND_NAME = "status"

  # The two {Lain::Paths} readers {Lain::ProjectDir} composes the new location
  # out of. Watched by method NAME: whoever rebuilds the recipe has to call
  # both, whatever they call the receiver.
  XDG_READERS = %w[state_home project_hash].freeze

  # {Lain::ProjectDir}'s own constants, mapped to the name each one spells, so a
  # recomposition through the locator's vocabulary counts as one.
  CONSTANTS = { "DIR" => PROJECT_NAME, "STATE_FILE" => STATE_NAME, "STATE_KIND" => KIND_NAME }.freeze

  # The node types a name can be bound to and read back through. Ripper spells
  # each with its sigil (`"@name"`), on both the binding and the reading side,
  # so one set serves both.
  BINDABLE = %i[@ident @const @ivar].freeze

  # The locator itself, which does not recompose the path -- it IS the
  # composition. Relative to `lib/`, like {OutputDiscipline}'s allowlist.
  EXEMPT = ["lain/project_dir.rb"].freeze

  # The expression forms that BUILD a path. A subtree rooted at one of these
  # that names the state file together with any other ingredient of its location
  # has rebuilt what {Lain::ProjectDir#state_path} resolves. Anchoring on these
  # (rather than on any node at all) is what keeps a whole file, or a whole class
  # body, from counting as one expression.
  COMPOSITIONS = %i[method_add_arg command command_call binary string_literal].freeze

  Violation = Struct.new(:path, :line, :names) do
    def to_s = "#{path}:#{line} -> composes #{names.join(" + ")}"
  end

  # Walks a Ripper s-expression collecting recompositions of the state path.
  class Scanner
    # `x = ...`, `x ||= ...` and `a, b = ...` all hide a name equally well, so
    # all three bind. The right-hand side sits at a different index in each,
    # which is the whole of the difference.
    ASSIGNMENTS = { assign: 2, opassign: 3, massign: 2 }.freeze

    def initialize(path)
      @path = path
      # Empty rather than nil so the first binding pass -- which walks with the
      # table it is still building -- asks the same question every later reader
      # asks, and gets "nothing bound yet" instead of a NoMethodError.
      @bindings = {}
    end

    # @return [Array<Violation>] at most one per line, since the composition
    #   sites of one expression nest (a string inside a `File.join`)
    def scan(source)
      sexp = Ripper.sexp(source)
      raise "could not parse #{@path}" if sexp.nil?

      @bindings = bindings_in(sexp)
      walk(sexp).uniq(&:line)
    end

    private

    # Names bound to an ingredient somewhere in the file, so that HOISTING a
    # name out of the composition does not hide it. Round 9's panel closed this
    # hole at the kind segment; round 10's found the symmetric one at the
    # ANCHOR, and that one was fatal rather than partial -- every other rule is
    # gated on the anchor being named, so `name = "state.json"` one line above
    # the join disarmed the scan completely.
    #
    # Records WHICH ingredients each name carries, not merely that it is
    # interesting: a local bound to `state_home` for a SIBLING container must
    # not inherit an anchor it never saw.
    #
    # Two passes, not one and not a fixed point: a name can be hoisted through
    # a second local (`a = STATE_FILE; b = a`), and nothing in `lib/` has ever
    # gone deeper. This is a gate, not a prover.
    #
    # == What it CANNOT see, so round 11 does not over-trust it
    #
    # The table is built from ASSIGNMENTS. A name that arrives any other way is
    # invisible, and three of those shapes are idiomatic here rather than
    # exotic:
    #
    # * a method that RETURNS the name -- `def state_file = "state.json"` --
    #   which is the endless-method shape this codebase writes everywhere;
    # * a keyword or optional-argument DEFAULT carrying it;
    # * anything crossing a file boundary, since each file is scanned alone.
    #
    # Chasing those means resolving method bodies to their call sites, which is
    # a prover. The gate's honest claim is narrower: nobody rebuilds this path
    # in ONE expression, or by hoisting a piece of it into a local one line
    # above. That is the shape a reviewer misses and the shape the finding came
    # back as; the rest is what the class docstring in `project_dir.rb` is for.
    def bindings_in(sexp)
      @bindings = collect_bindings(sexp, {})
      collect_bindings(sexp, @bindings)
    end

    def collect_bindings(node, found)
      return found unless node.is_a?(Array)

      bind(node, found)
      node.each { |child| collect_bindings(child, found) }
      found
    end

    def bind(node, found)
      rhs = ASSIGNMENTS[node[0]]
      names = rhs ? names_in(node[rhs]) : []
      bound_targets(node[1]).each { |target| found[target] = (found[target] || []) | names } unless names.empty?
    end

    # A multiple assignment binds EVERY target to the whole right-hand side.
    # Deliberately over-broad: `mrhs_new_from_args` does not pair with the
    # targets positionally without rebuilding the arity rules, and the cost of
    # over-binding is a scan that asks one extra question, while the cost of
    # under-binding is the hole this closes. The false-positive fixtures below
    # pin that it stays quiet on the sibling containers.
    def bound_targets(field)
      return field.filter_map { |one| bound_target(one) } if field.is_a?(Array) && field[0].is_a?(Array)

      [bound_target(field)].compact
    end

    # A local, a constant or an ivar on the left of an assignment.
    def bound_target(field)
      return nil unless field.is_a?(Array) && field[0] == :var_field

      inner = field[1]
      inner.is_a?(Array) && BINDABLE.include?(inner[0]) ? inner[1] : nil
    end

    def walk(node, found = [])
      return found unless node.is_a?(Array)

      found.concat(violation(node)) if COMPOSITIONS.include?(node[0])
      node.each { |child| walk(child, found) }
      found
    end

    def violation(node)
      names = names_in(node)
      return [] unless names.include?(STATE_NAME) && names.length > 1

      [Violation.new(@path, line_of(node), names.sort)]
    end

    # Which of the ingredients this expression names, deduplicated.
    def names_in(node, found = [])
      return found unless node.is_a?(Array)

      found.concat(named_here(node))
      node.each { |child| names_in(child, found) }
      found.uniq
    end

    def named_here(node)
      [("Dir.pwd" if cwd_read?(node)), constant_name(node), xdg_reader(node),
       kind_name(node), *literal_names(node), *bound_names(node),
       *concatenated_names(node)].compact
    end

    # A reference to a name the file bound to an ingredient earlier.
    def bound_names(node)
      return [] unless BINDABLE.include?(node[0])

      @bindings.fetch(node[1], [])
    end

    # `"state" + ".json"`. Neither half names the file, so the literal rule
    # cannot see it; joining a concatenation's pieces can. Restricted to
    # `binary` on purpose -- joining the strings under an arbitrary node would
    # let three unrelated arguments of one call spell the anchor between them.
    def concatenated_names(node)
      return [] unless node[0] == :binary

      joined = tstring_contents(node).join
      [PROJECT_NAME, STATE_NAME].select { |name| joined.include?(name) }
    end

    def tstring_contents(node, found = [])
      return found unless node.is_a?(Array)

      found << node[1] if node[0] == :@tstring_content
      node.each { |child| tstring_contents(child, found) }
      found
    end

    def literal_names(node)
      [PROJECT_NAME, STATE_NAME].select { |name| string_including?(node, name) }
    end

    # The kind, matched as a whole path SEGMENT rather than as a substring: a
    # warning carrying both "status-right" and "state.json" is a real sentence,
    # and a substring match would read that message as a composition.
    def kind_name(node)
      return nil unless node[0] == :@tstring_content

      segments = node[1].split("/")
      segments.include?(KIND_NAME) ? KIND_NAME : nil
    end

    # A call on the `Dir` constant, so a local variable named `pwd` is never
    # mistaken for a read of the working directory.
    def cwd_read?(node)
      node[0] == :call && const_named?(node[1], "Dir") && ident_in?(node[3], CWD_READERS)
    end

    def string_including?(node, needle) = node[0] == :@tstring_content && node[1].include?(needle)

    # `ProjectDir::STATE_FILE`, however it is scoped -- `Lain::ProjectDir::DIR` too.
    def constant_name(node)
      return nil unless node[0] == :const_path_ref && names_const?(node[1], "ProjectDir")

      CONSTANTS.keys.find { |name| const_named?(node[2], name) }&.then { |name| CONSTANTS[name] }
    end

    # `paths.state_home`, `project_hash(root)`, `@paths.project_hash(...)`: the
    # method name is the tell, whatever the receiver is called.
    def xdg_reader(node) = node[0] == :@ident && XDG_READERS.include?(node[1]) ? node[1] : nil

    def names_const?(node, name)
      return false unless node.is_a?(Array)

      const_named?(node, name) || node.any? { |child| names_const?(child, name) }
    end

    def const_named?(node, name)
      return false unless node.is_a?(Array)

      (node[0] == :@const && node[1] == name) || (node[0] == :var_ref && const_named?(node[1], name))
    end

    def ident_in?(node, names) = node.is_a?(Array) && node[0] == :@ident && names.include?(node[1])

    # Ripper hangs `[line, column]` off every scanner token; the earliest one in
    # the subtree is where the expression starts.
    def line_of(node)
      return nil unless node.is_a?(Array)
      return node[2].first if node[0].is_a?(Symbol) && node[0].start_with?("@") && node[2].is_a?(Array)

      node.filter_map { |child| line_of(child) }.min
    end
  end

  module_function

  def lib_root = Pathname(__dir__).join("../../lib").expand_path

  # @return [Array<Violation>] every recomposition across the non-exempt `lib/` tree
  def violations
    lib_root.glob("**/*.rb").flat_map do |file|
      relative = file.relative_path_from(lib_root).to_s
      EXEMPT.include?(relative) ? [] : Scanner.new(relative).scan(file.read)
    end
  end
end

# The project-scoped `.lain/` tree, and the ONE file this class deliberately
# keeps OUT of it. `.lain/` still holds config, summarizers, slots, skills and
# repo-mode epics -- this class does not own every one of those names, which is a
# named follow-up, not this card. What it owns is the published state feed, which
# had three independent spellings across the three renderers of one feed and now
# has one, under XDG state.
RSpec.describe Lain::ProjectDir do
  # A {Lain::Paths} over an injected env: the real `$XDG_STATE_HOME` is neither
  # read nor written by anything below, and no example touches the real `$HOME`.
  def paths(state: "/xdg-state", home: "/home/nobody")
    Lain::Paths.new(env: { "HOME" => home, "XDG_STATE_HOME" => state })
  end

  # The recipe, spelled out rather than asked of the subject: an assertion that
  # calls `project_hash` would pass against any hash the class happened to use.
  def digest_of(dir) = Digest::SHA256.hexdigest(dir)[0, 12]

  describe "naming, without a root and without the filesystem" do
    it "names the project directory itself" do
      expect(described_class::DIR).to eq(".lain")
    end

    it "joins a root-relative name, so a load-time constant needs no Dir.pwd" do
      expect(described_class.join("summarizers.rb")).to eq(File.join(".lain", "summarizers.rb"))
    end
  end

  describe "resolution against a root" do
    it "resolves the directory" do
      expect(described_class.new(root: "/srv/app").dir).to eq("/srv/app/.lain")
    end

    it "keeps the root it was handed" do
      expect(described_class.new(root: "/srv/app").root).to eq("/srv/app")
    end
  end

  # The feed is rewritten every turn -- `elapsed`, `idle` and `occupancy`
  # all move -- and nothing in `lib/` writes a `.gitignore`, so every session
  # left permanent `git status` noise in the user's repository and a `git add -A`
  # committed it. Machine state that changes every turn is durable per-project
  # state, which is what `$XDG_STATE_HOME` is for.
  describe "the published state feed, under XDG state" do
    it "resolves under XDG state, keyed by the project, and never inside it" do
      resolved = described_class.new(root: "/srv/app", paths:).state_path

      expect(resolved).to eq("/xdg-state/lain/status/#{digest_of("/srv/app")}/state.json")
      expect(resolved).not_to start_with("/srv/app")
    end

    it "honours the XDG fallback when XDG_STATE_HOME is unset" do
      fallback = Lain::Paths.new(env: { "HOME" => "/home/nobody" })
      resolved = described_class.new(root: "/srv/app", paths: fallback).state_path

      expect(resolved).to eq("/home/nobody/.local/state/lain/status/#{digest_of("/srv/app")}/state.json")
    end

    it "gives two different projects two different state files" do
      one = described_class.new(root: "/srv/app", paths:).state_path
      other = described_class.new(root: "/srv/other", paths:).state_path

      expect(one).not_to eq(other)
    end

    # Pure: the directory arrives on the first publish
    # ({Lain::StatusFeed::Publication} mkdir_p's it), so resolving a path -- which
    # a renderer does just to name the file in a message -- creates nothing.
    it "creates nothing" do
      Dir.mktmpdir("lain-project-dir") do |tmp|
        state = File.join(tmp, "state")
        described_class.new(root: "/srv/app", paths: paths(state:)).state_path

        expect(File.exist?(state)).to be(false)
      end
    end

    # The card's whole point, stated as the invariant rather than as a path: a
    # RELATIVE state path resolves against the process cwd, which is the
    # project, which is that same finding again wearing an XDG-shaped hat.
    # Round 9's worked example missed this because it injected a hostile `HOME`
    # into a fixture while the process `HOME` stayed healthy, so `Paths#home`'s
    # `Dir.home` fallback quietly supplied a good answer that production never
    # gets.
    it "never yields a non-absolute state path, whatever HOME says" do
      ["rel", ".", "", "../up"].each do |hostile|
        with_env("HOME" => hostile) do
          resolved = begin
            described_class.new(root: "/srv/app").state_path
          rescue Lain::Paths::NonAbsoluteHome
            nil # refusing is the other acceptable answer, and the one we chose
          end

          expect(resolved).to be_nil.or(start_with("/")),
                              "HOME=#{hostile.inspect} produced #{resolved.inspect}"
        end
      end
    end

    it "defaults the root to the working directory" do
      Dir.mktmpdir("lain-project-dir") do |tmp|
        real = File.realpath(tmp)
        Dir.chdir(real) do
          expect(described_class.new(paths:).state_path)
            .to eq("/xdg-state/lain/status/#{digest_of(real)}/state.json")
        end
      end
    end
  end

  # The escalation this card was warned about, pinned: {Lain::CLI::Up} builds the
  # HUD's path from the PATH argument it was given (`root: cwd`, a string a user
  # typed and `File.expand_path`'d), while {Lain::StatusFeed} and
  # {Lain::Frontend::TTY} take the bare default (`Dir.pwd`, which the KERNEL has
  # already resolved). Under `.lain/state.json` a disagreement between the two
  # merely looked stale; under a hashed path it is a HUD pointing at a file
  # nothing writes. What makes them agree is that the hash is taken of the
  # REALPATH, so every spelling of one directory is one project.
  describe "the writer and a HUD launched into the same directory" do
    def in_a_project
      Dir.mktmpdir("lain-project-dir") do |tmp|
        base = File.realpath(tmp)
        FileUtils.mkdir_p(File.join(base, "project", "services", "ingest"))
        File.symlink(File.join(base, "project"), File.join(base, "link"))
        yield(base)
      end
    end

    it "agrees when the HUD was handed a symlinked spelling of the writer's cwd" do
      in_a_project do |base|
        subdirectory = File.join(base, "project", "services", "ingest")
        writer = Dir.chdir(subdirectory) { described_class.new(paths:).state_path }
        hud = described_class.new(root: File.join(base, "link", "services", "ingest"), paths:).state_path

        expect(hud).to eq(writer)
      end
    end

    it "agrees when the HUD was handed an unexpanded spelling of the writer's cwd" do
      in_a_project do |base|
        subdirectory = File.join(base, "project", "services", "ingest")
        writer = Dir.chdir(subdirectory) { described_class.new(paths:).state_path }
        hud = described_class.new(root: File.join(base, "project", "services", "..", "services", "ingest"),
                                  paths:).state_path

        expect(hud).to eq(writer)
      end
    end

    # A directory that does not exist cannot be realpath'd; the lexical expansion
    # is hashed instead of raising, because {Lain::Paths#project_hash} keys
    # isolation WORKER IDS through the same method and those name no real path.
    it "falls back to the lexical expansion for a directory that does not exist" do
      expect(described_class.new(root: "/srv/nope/../nope/app", paths:).state_path)
        .to eq("/xdg-state/lain/status/#{digest_of("/srv/nope/app")}/state.json")
    end
  end

  # The acceptance criterion, re-aimed at the relocated file. Every fixture
  # below is a real way to rebuild the state path by hand -- the retired
  # `.lain/` location included, because rebuilding THAT is how the finding comes
  # back -- and each must redden the scan, otherwise the scan is theatre.
  describe "one resolver for the published state feed" do
    def scan(source) = ProjectDirDiscipline::Scanner.new("fixture.rb").scan(source)

    it "is the only place lib/ composes the state path" do
      violations = ProjectDirDiscipline.violations

      expect(violations).to be_empty, lambda {
        listing = violations.map { |violation| "  #{violation}" }.join("\n")
        "The published state feed has one resolver, Lain::ProjectDir#state_path. Ask it " \
          "instead of rebuilding the path:\n#{listing}"
      }
    end

    {
      "the XDG recipe, joined" =>
        'x = File.join(paths.state_home, "status", paths.project_hash(root), "state.json")',
      "the XDG recipe with the tail pre-joined" =>
        %(x = File.join(paths.state_home, "status/\#{paths.project_hash(root)}/state.json")),
      "the XDG recipe interpolated" =>
        %(x = "\#{paths.state_home}/status/\#{paths.project_hash(root)}/state.json"),
      # The panel's probe: a from-scratch rebuild that hoists both {Lain::Paths}
      # calls into their own statements, leaving a final expression that names
      # only the kind and the file. Invisible to the scan until the kind became
      # an ingredient.
      "the recipe rebuilt from hoisted locals" =>
        %(base = paths.state_home\nhash = paths.project_hash(root)\n) +
          %(x = File.join(base, "status", hash, "state.json")\n),
      "a recomposition through the locator's own kind constant" =>
        %(x = File.join(base, Lain::ProjectDir::STATE_KIND, hash, "state.json")),
      "a recomposition through the locator's own file constant" =>
        "x = File.join(paths.state_home, hash, Lain::ProjectDir::STATE_FILE)",
      # Round 9's panel closed the hoisting hole at the KIND. Round 10's found
      # the symmetric one at the ANCHOR, which is worse: the anchor is what
      # every other rule is gated on, so hoisting the FILENAME out of the
      # expression disarmed the scan completely. All seven below reported clean
      # before the binding table.
      "the filename hoisted into a local" =>
        %(name = Lain::ProjectDir::STATE_FILE\nx = File.join(paths.state_home, "status", hash, name)\n),
      "the filename hoisted as a plain string literal" =>
        %(name = "state.json"\nx = File.join(paths.state_home, "status", hash, name)\n),
      "the filename hoisted into a constant of one's own" =>
        %(FILE = "state.json"\nx = File.join(base, "status", hash, FILE)\n),
      "the kind AND the filename both hoisted" =>
        %(kind = "status"\nname = "state.json"\nx = File.join(paths.state_home, kind, hash, name)\n),
      "the retired location with the filename hoisted" =>
        %(name = "state.json"\nx = File.join(Dir.pwd, ".lain", name)\n),
      "the filename rebuilt from halves" =>
        %(x = File.join(paths.state_home, "status", hash, "state" + ".json")),
      "the retired location concatenated a piece at a time" =>
        %(x = File.join(Dir.pwd, ".lain") + "/" + "state" + ".json"),
      # A second level of hoisting, which is as far as the table chases. Deeper
      # is a prover's job, not a gate's, and nothing in `lib/` has ever gone
      # there.
      "the filename hoisted twice" =>
        %(a = "state.json"\nb = a\nx = File.join(paths.state_home, "status", hash, b)\n),
      # Three more the re-review found, all token-level: the binding table
      # looked at `@ident` and `@const` only, and at plain `=` only.
      "the filename hoisted into an instance variable" =>
        %(@name = "state.json"\nx = File.join(paths.state_home, "status", hash, @name)\n),
      "the kind and the filename hoisted by multiple assignment" =>
        %(kind, name = "status", "state.json"\nx = File.join(paths.state_home, kind, hash, name)\n),
      "the filename hoisted with a conditional assignment" =>
        %(name ||= "state.json"\nx = File.join(paths.state_home, "status", hash, name)\n),
      "the retired in-project location" => 'x = File.join(Dir.pwd, ".lain", "state.json")',
      "the retired location with the tail pre-joined" => 'x = File.join(Dir.pwd, ".lain/state.json")',
      # Escaped, not single-quoted: this is fixture SOURCE that must contain a
      # literal interpolation, and Lint/InterpolationCheck reads a single-quoted
      # `#{}` as a mistake -- its autocorrect would make the interpolation real.
      "the retired location interpolated" => %(x = "\#{Dir.pwd}/.lain/state.json"),
      "the retired location through the locator's directory constant" =>
        'x = File.join(Dir.pwd, Lain::ProjectDir::DIR, "state.json")',
      "the identical expression wrapped over three lines" =>
        %(x = File.join(Dir.pwd,\n              ".lain",\n              "state.json")\n)
    }.each do |spelling, source|
      it "catches #{spelling}" do
        expect(scan(source)).not_to be_empty
      end
    end

    # The false-positive side, and why this is an AST walk and not a grep: `lib/`
    # is full of prose about `.lain/state.json` -- a dozen comments name it -- and
    # a text match flagged this class's OWN comment, the tell that text is the
    # wrong tool.
    it "ignores the names in a comment" do
      expect(scan(%(# joins Dir.pwd with .lain and state.json\nx = 1\n))).to be_empty
    end

    # A warning sentence with `state.json` in it. Naming the file is not
    # rebuilding its path, which is why the scan wants a second ingredient before
    # it calls anything a composition -- and why the kind is matched as a path
    # SEGMENT: this sentence also says "status-right".
    it "leaves a message that merely names the file alone" do
      expect(scan('x = "jq not found on PATH -- status-right falls back to raw state.json"')).to be_empty
    end

    # The other `.lain/` artifact names in lib/ are a named follow-up, not this
    # card: composing one of those is not recomposing the state feed.
    it "leaves the other `.lain/` artifact names alone" do
      expect(scan('x = File.join(root, ".lain", "config.toml")')).to be_empty
    end

    # And nor is the XDG recipe for a DIFFERENT artifact -- {Lain::Epic::Home}
    # and {Lain::Paths#sessions_dir} both compose `<state_home>/<kind>/<hash>`,
    # and neither is this file.
    it "leaves the sibling XDG containers alone" do
      expect(scan('x = File.join(paths.state_home, "epics", paths.project_hash(root))')).to be_empty
    end

    # The binding table's own false-positive edge, and the reason it records
    # WHICH ingredients a name carries rather than just "this local is
    # interesting": a local bound to a sibling container names `state_home`,
    # and a later expression using it must not inherit an anchor it never saw.
    it "does not let a local bound to a sibling container become the state file" do
      expect(scan(%(base = paths.state_home\nx = File.join(base, "epics", hash)\n))).to be_empty
    end

    # And a local bound to nothing interesting stays uninteresting, so the
    # table cannot make an ordinary variable name radioactive.
    it "leaves a local bound to an unrelated value alone" do
      expect(scan(%(name = "config.toml"\nx = File.join(root, ".lain", name)\n))).to be_empty
    end

    it "reports the line and what the expression composed" do
      violation = scan(%(x = 1\ny = File.join(Dir.pwd, ".lain", "state.json")\n)).first

      expect(violation.line).to eq(2)
      expect(violation.names).to eq([".lain", "Dir.pwd", "state.json"])
    end
  end
end
