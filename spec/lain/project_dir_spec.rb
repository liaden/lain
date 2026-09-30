# frozen_string_literal: true

require "digest"
require "fileutils"
require "ripper"
require "tmpdir"
require "pathname"

# Mechanical enforcement of ONE locator for every path `.lain/` governs and for
# the state containers beside it. A second spelling is trivial to write by hand
# and invisible in review -- the config file had three of them, one a bare string
# constant -- so it is forbidden here rather than in a paragraph nobody re-reads.
#
# The scan began life guarding one file, the published state feed, and grew to
# the rest when {Lain::ProjectDir} did. Both shapes are watched: an expression
# naming `.lain` outside the locator, and one naming an artifact or the state
# home together with any other ingredient of its location.
#
# The state containers are watched through their ingredients rather than through
# one owner's file, because the recipe lives on {Lain::Paths} -- beside
# {Lain::Paths#state_home} and {Lain::Paths#project_hash}, which compose it --
# while {Lain::ProjectDir#container} is the door for a caller holding a root.
# Neither file needs an exemption for it: the recipe named in one place names
# only `state_home`, and a rebuild elsewhere names a second ingredient.
#
# Ripper, not a text match, for the reason `spec/output_discipline_spec.rb`
# parses too. A grep catches ONE spelling: it misses the same join with the tail
# pre-joined, `"#{Dir.pwd}/.lain/state.json"`, `Dir.pwd + "/.lain"`, a
# recomposition through `ProjectDir::STATE_FILE`, and even a line-wrapped copy of
# the identical expression -- while flagging the words in a COMMENT, which the
# text version of this scan did until it was replaced. `lib/` is full of prose
# about `.lain/state.json`, and every word of it is invisible to an AST walk.
module ProjectDirDiscipline
  # The names this scan is about, plus every other name an expression can use to
  # reach one. Spelled here rather than read off the class so that a rename of a
  # constant cannot silently disarm the scan.
  #
  # The directory is watched on its own: nothing outside the locator has any
  # business spelling `.lain`, whatever it goes on to join to it.
  PROJECT_NAME = ".lain"
  CWD_READERS = %w[pwd getwd].freeze

  # Every artifact a project keeps, and the state file that moved out of the
  # tree. Each is an ANCHOR: an expression that names none of them is not
  # rebuilding one's path, which is what keeps a sentence with `state.json` in
  # it and nothing else from reading as a composition.
  STATE_NAME = "state.json"
  ARTIFACT_NAMES = (%w[config.rb prompt.toml epics slots skills meta
                       summarizers summarizers.rb services.rb] + [STATE_NAME]).freeze

  # The kind segments under `$XDG_STATE_HOME/lain`. They are ingredients in
  # their own right, and they have to be: a rebuild over an opaque root was
  # caught by its literals alone, while the XDG shape carries one literal plus
  # two method calls -- and hoisting those two calls into their own statements
  # left a final expression naming nothing but the file.
  KIND_NAMES = %w[status sessions epics worktrees workspace gc trust].freeze

  # Every literal a path expression can spell one of these with.
  LITERALS = ([PROJECT_NAME] + ARTIFACT_NAMES + KIND_NAMES).uniq.freeze

  # The two {Lain::Paths} readers a container is composed out of. Watched by
  # method NAME: whoever rebuilds the recipe has to call both, whatever they
  # call the receiver. `state_home` anchors too -- a container has no filename
  # to name, so the base it hangs off is what identifies it.
  XDG_READERS = %w[state_home project_hash].freeze

  # {Lain::ProjectDir#dir} hands out the project directory WITHOUT spelling it,
  # so an artifact joined to its answer rebuilds a governed path with no literal
  # for the other rules to see -- `File.join(project.dir, "config.rb")`. It is
  # public and {Lain::Project::Resolver} calls it, which makes this the most
  # available recomposition in the tree. Watched as a CALL, so an ordinary local
  # named `dir` stays ordinary: a local that was composed in the same file is
  # already carried by the binding table, and one that arrives from elsewhere is
  # the cross-file hole this gate has never claimed to close.
  DIR_READERS = %w[dir].freeze

  ANCHORS = (ARTIFACT_NAMES + ["state_home"]).freeze

  # {Lain::ProjectDir}'s own constants, mapped to the name each one spells, so a
  # recomposition through the locator's vocabulary counts as one.
  CONSTANTS = { "DIR" => PROJECT_NAME, "STATE_FILE" => STATE_NAME, "STATE_KIND" => "status",
                "CONFIG_FILE" => "config.rb", "PROMPT_FILE" => "prompt.toml", "EPICS_DIR" => "epics",
                "SLOTS_DIR" => "slots", "SKILLS_DIR" => "skills", "META_DIR" => "meta",
                "SUMMARIZERS_FILE" => "summarizers.rb", "SUMMARIZER_DRAFTS_DIR" => "summarizers",
                "SERVICES_FILE" => "services.rb" }.freeze

  # The node types a name can be bound to and read back through. Ripper spells
  # each with its sigil (`"@name"`), on both the binding and the reading side,
  # so one set serves both.
  BINDABLE = %i[@ident @const @ivar].freeze

  # The locator itself, which does not recompose these paths -- it IS the
  # composition. Relative to `lib/`, like {OutputDiscipline}'s allowlist.
  EXEMPT = ["lain/project_dir.rb"].freeze

  # The expression forms that BUILD a path. A subtree rooted at one of these
  # that names an artifact together with any other ingredient of its location
  # has rebuilt what one of {Lain::ProjectDir}'s readers resolves. Anchoring on these
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
    # * anything crossing a file boundary, since each file is scanned alone;
    # * an artifact name handed to the locator's own `.join`, which is a call ON
    #   the authority rather than a rebuild of what it answers;
    # * a path spelled inside one string chunk that also carries WORDS --
    #   `run("git -C \#{root}/.lain/state.json log")` was caught before the
    #   literal rule required a whitespace-free string and is not now. That is
    #   the price of the eleven refusal sentences in `lib/` that quote these
    #   paths; interpolation splits chunks, so the shape that escapes is
    #   narrow -- one chunk carrying both the path and the prose around it.
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
      return [] unless recomposition?(names)

      [Violation.new(@path, line_of(node), names.sort)]
    end

    # Two rules, because the governed paths have two shapes. The project
    # directory is owned outright, so naming it at all is enough. An artifact or
    # a state container is owned as a LOCATION, so the name alone is a mention
    # and the name beside a second ingredient is a rebuild.
    def recomposition?(names)
      return true if names.include?(PROJECT_NAME)

      names.length > 1 && names.intersect?(ANCHORS)
    end

    # Which of the ingredients this expression names, deduplicated.
    def names_in(node, found = [])
      return found unless node.is_a?(Array)

      found.concat(named_here(node))
      node.each { |child| names_in(child, found) }
      found.uniq
    end

    def named_here(node)
      [("Dir.pwd" if cwd_read?(node)), ("#dir" if project_dir_read?(node)), constant_name(node),
       xdg_reader(node), *literal_names(node), *bound_names(node), *concatenated_names(node)].compact
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

      names_in_text(tstring_contents(node).join)
    end

    def tstring_contents(node, found = [])
      return found unless node.is_a?(Array)

      found << node[1] if node[0] == :@tstring_content
      node.each { |child| tstring_contents(child, found) }
      found
    end

    def literal_names(node) = node[0] == :@tstring_content ? names_in_text(node[1]) : []

    # A literal names an ingredient when the literal IS a path: a whole
    # `/`-separated segment of a string with no whitespace in it.
    #
    # What that buys: `lib/` refuses and warns in eleven sentences that name
    # these files -- "the [isolation] settings in .lain/config.rb were not
    # read" -- and a substring match reads every one of those as a composition,
    # which would price the guard out of the names it now owns. Segments rather
    # than substrings for the same reason: a message carrying both
    # "status-right" and "state.json" is a sentence, and `locked.lain-claim-`
    # is a lock file rather than the project directory.
    #
    # What it COSTS, stated because a narrowing that only advertises its benefit
    # is how a gate rots: a path inside a chunk that also carries words is now
    # invisible, so `"git -C \#{root}/.lain/state.json log"` passes where it
    # once failed. `lib/` has eleven of the shape this buys and none of the
    # shape it loses, which is why the trade is taken.
    def names_in_text(text)
      return [] if text.match?(/\s/)

      segments = text.split("/")
      LITERALS.select { |name| segments.include?(name) }
    end

    # A call on the `Dir` constant, so a local variable named `pwd` is never
    # mistaken for a read of the working directory.
    def cwd_read?(node)
      node[0] == :call && const_named?(node[1], "Dir") && ident_in?(node[3], CWD_READERS)
    end

    # `project.dir`, `ProjectDir.new(root:).dir`, `@project.dir`: the receiver
    # can be anything, since the name is the tell and a second ingredient is
    # still required before any of this counts.
    def project_dir_read?(node) = node[0] == :call && ident_in?(node[3], DIR_READERS)

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

# The project-scoped `.lain/` tree, and the files this class deliberately keeps
# OUT of it. It owns both sides now: every `.lain/` name -- config, summarizers,
# services, slots, skills, prompt, `/meta` output and repo-mode epics -- and the
# `<state_home>/<kind>/<key>` recipe the published state feed shares with the
# epics, worktrees, workspace, gc and trust containers. Sixteen expressions
# composed those by hand before this class grew the readers, the config file
# alone in three independent spellings.
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

    # The naming half of the class/instance split: what a class BODY asks for,
    # where there is no root yet -- {Lain::Summarizer::Catalog::DSL_PATH} and
    # {Lain::Isolation::Services::DSL_PATH} are these, and
    # {Lain::Approval::Remembered}'s refusals quote one in a sentence.
    it "names the artifacts a class body reaches for, relative to a root" do
      expect([described_class.config, described_class.meta, described_class.summarizers,
              described_class.summarizer_drafts, described_class.services])
        .to eq([".lain/config.rb", ".lain/meta", ".lain/summarizers.rb",
                ".lain/summarizers", ".lain/services.rb"])
    end
  end

  # Every name the project tree holds, through one locator. Before these
  # readers, eleven expressions in `lib/` spelled one of these paths themselves
  # -- the config file three ways, one of them a bare string constant.
  describe "the project's own files, resolved against a root" do
    let(:project) { described_class.new(root: "/srv/app") }

    it "resolves every name under the project directory" do
      expect([project.config, project.prompt, project.epics, project.slots, project.skills,
              project.meta, project.summarizers, project.summarizer_drafts, project.services])
        .to all(start_with("/srv/app/.lain/"))
    end

    it "names the config file" do
      expect(project.config).to eq("/srv/app/.lain/config.rb")
    end

    it "names the prompt config, which is a project artifact and not machine state" do
      expect(project.prompt).to eq("/srv/app/.lain/prompt.toml")
    end

    it "names the override directories" do
      expect([project.slots, project.skills, project.epics])
        .to eq(["/srv/app/.lain/slots", "/srv/app/.lain/skills", "/srv/app/.lain/epics"])
    end

    # The trap this class exists to hold in one place: Ruby's own
    # `foo.rb`-plus-`foo/` convention reads these as one unit, and they are not.
    # {Lain::Summarizer::Catalog} loads the FILE; nothing loads the directory,
    # which is only where `/meta` leaves a declaration for a human to read.
    it "keeps the summarizers DSL file and the /meta drafts directory apart" do
      expect(project.summarizers).to eq("/srv/app/.lain/summarizers.rb")
      expect(project.summarizer_drafts).to eq("/srv/app/.lain/summarizers")
    end

    it "names the services DSL file" do
      expect(project.services).to eq("/srv/app/.lain/services.rb")
    end

    it "creates nothing, so a renderer may resolve a path just to name it" do
      Dir.mktmpdir("lain-project-dir") do |tmp|
        described_class.new(root: tmp).config

        expect(Dir.children(tmp)).to be_empty
      end
    end
  end

  # The recipe the state feed shares with five sibling containers, which was
  # composed eight ways before this method: one of them split across two
  # methods, one flattening the key into a filename, and one taking a digest of
  # a different width.
  describe "a durable state container" do
    it "composes the state home, the kind and the project key" do
      expect(described_class.new(root: "/srv/app", paths:).container("epics"))
        .to eq("/xdg-state/lain/epics/#{digest_of("/srv/app")}")
    end

    it "is what the state feed's own location is built from" do
      project = described_class.new(root: "/srv/app", paths:)

      expect(project.state_path).to start_with(project.container("status"))
    end

    # Passing the key rather than defaulting it is what makes a deliberate
    # exception visible at the call instead of discoverable by reading all eight.
    it "takes an explicit key, so a deliberate exception reads at the call" do
      full = Digest::SHA256.hexdigest("/srv/app")

      expect(described_class.new(root: "/srv/app", paths:).container("trust", key: full))
        .to eq("/xdg-state/lain/trust/#{full}")
    end

    # {Lain::CLI::GcSchedule} and {Lain::CLI::Worktrees} name files in one
    # shared container rather than a directory per project, which the same
    # parameter serves.
    it "takes a key that is a filename" do
      expect(described_class.new(root: "/srv/app", paths:).container("gc", key: "worktrees-abc.stamp"))
        .to eq("/xdg-state/lain/gc/worktrees-abc.stamp")
    end

    it "creates nothing" do
      Dir.mktmpdir("lain-project-dir") do |tmp|
        state = File.join(tmp, "state")
        described_class.new(root: "/srv/app", paths: paths(state:)).container("epics")

        expect(File.exist?(state)).to be(false)
      end
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
  describe "one locator for every governed path" do
    def scan(source) = ProjectDirDiscipline::Scanner.new("fixture.rb").scan(source)

    it "is the only place lib/ composes a governed path" do
      violations = ProjectDirDiscipline.violations

      expect(violations).to be_empty, lambda {
        listing = violations.map { |violation| "  #{violation}" }.join("\n")
        "Every path `.lain/` governs and every durable state container has one locator, " \
          "Lain::ProjectDir -- #config, #epics, #slots, #skills, #prompt, #meta, #summarizers, " \
          "#services, #state_path, #container. Ask it instead of rebuilding the path:\n#{listing}"
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
        %(x = File.join(Dir.pwd,\n              ".lain",\n              "state.json")\n),
      # The names the locator grew to cover. The project directory is owned
      # outright, so each of these is caught by naming `.lain` at all -- and the
      # last three, which never spell it, by naming an artifact beside a second
      # ingredient of its location.
      "the config file rebuilt beside a root" => 'x = File.join(root, ".lain", "config.rb")',
      "the config file as one pre-joined string" => 'WHERE = ".lain/config.rb"',
      "the prompt config rebuilt" => 'x = File.join(project, ".lain", "prompt.toml")',
      "the slots directory rebuilt" => 'x = File.join(root, ".lain", "slots")',
      "the skills directory rebuilt" => 'x = File.join(root, ".lain", "skills")',
      "the summarizers DSL path rebuilt" => 'x = File.join(root, ".lain", "summarizers.rb")',
      "the /meta drafts directory rebuilt" => 'x = File.join(root, ".lain", "summarizers")',
      "the in-repo epics home rebuilt" => 'x = File.join(root, ".lain", "epics")',
      "the project directory itself rebuilt" => 'x = File.join(root, ".lain")',
      "the directory hoisted into a local" => %(dir = ".lain"\nx = File.join(root, dir, "skills")\n),
      "a recomposition through the locator's own artifact constants" =>
        "x = File.join(root, Lain::ProjectDir::DIR, Lain::ProjectDir::CONFIG_FILE)",
      "the epics container rebuilt" =>
        'x = File.join(paths.state_home, "epics", paths.project_hash(root))',
      "the gc container rebuilt" => %(x = File.join(paths.state_home, "gc", "worktrees-\#{hash}.stamp")),
      "a container over an opaque kind" => "x = File.join(paths.state_home, kind, paths.project_hash(root))",
      "the sessions container rebuilt" =>
        'x = File.join(paths.state_home, "sessions", paths.project_hash(root))',
      # The shape the locator's own API invites, and the one a `.lain` literal
      # cannot catch: `#dir` answers the project directory without spelling it.
      "an artifact joined to the locator's own directory" =>
        'x = File.join(ProjectDir.new(root: root).dir, "config.rb")',
      "an artifact interpolated after the locator's directory" =>
        %(x = "\#{project.dir}/skills")
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

    # A refusal that quotes a path is prose, not a composition, and `lib/` is
    # full of them -- eleven raise sites and startup notices name `.lain/`
    # artifacts in sentences. Whitespace is what separates the two, which is why
    # a literal only counts when it IS a path.
    it "leaves a refusal that quotes a config file alone" do
      expect(scan('x = "the [isolation] settings in .lain/config.rb were not read"')).to be_empty
    end

    it "leaves a refusal that quotes the services DSL alone" do
      expect(scan('raise Unknown, "unknown service in .lain/services.rb; a container is the answer"')).to be_empty
    end

    # A lock file whose PREFIX happens to contain the directory's name. Segments
    # rather than substrings is what tells the two apart.
    it "leaves a name that merely contains the directory's own alone" do
      expect(scan('CLAIMED = "locked.lain-claim-"')).to be_empty
    end

    # The file that OWNS the recipe is not exempt and must not need to be: the
    # single expression composing it names `state_home` beside two parameters,
    # so the anchor stands alone and the scan is silent. Asserted against the
    # real source rather than a fixture, because a fixture would pass whether or
    # not anyone had looked at the file. An edit that inlines a `project_hash`
    # call into that method reddens this, which is right -- it would be a second
    # composition inside the file that holds the first.
    it "needs no exemption for the file that owns the recipe" do
      recipe = ProjectDirDiscipline.lib_root.join("lain/paths.rb")

      expect(ProjectDirDiscipline::Scanner.new("lain/paths.rb").scan(recipe.read)).to be_empty
    end

    # The binding table's own false-positive edge, and the reason it records
    # WHICH ingredients a name carries rather than just "this local is
    # interesting": the project key alone names no container, and a later
    # expression using it must not inherit an anchor it never saw.
    it "does not let a local bound to the project key become a container" do
      expect(scan(%(key = paths.project_hash(root)\nx = File.join(base, "sessions", key)\n))).to be_empty
    end

    # `#dir` is watched as a CALL, so the commonest local name in `lib/` stays
    # ordinary. A local that was composed in this file is caught anyway, by the
    # binding table -- the example below it shows that arm.
    it "leaves an ordinary local named dir alone" do
      expect(scan('x = File.join(dir, "config.rb")')).to be_empty
    end

    it "still catches a local that was composed from the directory here" do
      expect(scan(%(dir = File.join(root, ".lain")\nx = File.join(dir, "config.rb")\n))).not_to be_empty
    end

    # And a local bound to nothing interesting stays uninteresting, so the
    # table cannot make an ordinary variable name radioactive.
    it "leaves a local bound to an unrelated value alone" do
      expect(scan(%(name = "README.md"\nx = File.join(root, "docs", name)\n))).to be_empty
    end

    it "reports the line and what the expression composed" do
      violation = scan(%(x = 1\ny = File.join(Dir.pwd, ".lain", "state.json")\n)).first

      expect(violation.line).to eq(2)
      expect(violation.names).to eq([".lain", "Dir.pwd", "state.json"])
    end
  end
end
