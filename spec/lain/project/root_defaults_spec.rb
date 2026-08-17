# frozen_string_literal: true

require "ripper"
require "pathname"

# Mechanical enforcement of "the working directory is not a project root".
#
# {Lain::Project::Resolver} answers where an agent's writes belong, and the CLI
# threads that answer down. The ~38 `root: Dir.pwd` keyword defaults already in
# `lib/` STAY: they are what makes each of those objects constructible outside a
# CLI boot, and rewriting them to a required keyword would break every direct
# construction for no gain. What must not happen is a THIRTY-NINTH one, written
# by a later card that reached for the nearest idiom -- because a new object
# defaulted to `Dir.pwd` is an object the resolved Project never reaches, and
# nothing about it looks wrong in review.
#
# So the current set is an explicit allowlist and anything outside it reddens.
# A documentation line does not stop the forty-first one.
#
# Ripper, not a grep, for the reason `spec/output_discipline_spec.rb` and
# `spec/lain/project_dir_spec.rb` both parse: the text `root: Dir.pwd` appears
# in prose in this very file, in {Lain::CLI::Wiring}'s comments, and in a YARD
# `@param` line -- while a keyword default written `root: Dir.getwd` or
# `root: File.expand_path(Dir.pwd)` is the same defect and matches no grep for
# the literal.
#
# == What it scans, and what it provably does not
#
# IN: every parameter default that can be read as the working directory --
# optional POSITIONALS as well as keywords, on `def`, `def self.`, a lambda, and
# a block (so `define_method(:x) { |root: Dir.pwd| }` counts). The spellings are
# `Dir`/`Pathname`/`FileUtils` `.pwd`/`.getwd`, a one-argument
# `File.expand_path(".")`/`File.absolute_path(".")`, and `ENV["PWD"]`.
#
# The positional half is not hypothetical: `Paths#project_hash(dir = Dir.pwd)`
# is a live one, and it keys the sessions directory AND the epic container --
# precisely what this chunk is about. The first edition of this guard could not
# see it, so it is allowlisted below by name, visibly, rather than absent.
#
# OUT, and each of these is a real hole rather than a thing declared irrelevant:
#
# * a cwd read in a method BODY. Deliberate -- {Lain::WorkerEnv.default} is one,
#   and it must stay. This guard is about DEFAULTS.
# * indirection: `D = Dir; def f(root: D.pwd)`, or `def cwd = Dir.pwd` with
#   `def f(root: cwd)`. Both need to know what a name is bound to, which a
#   syntactic scan does not.
# * `Dir.new(".").path`, and any other expression whose cwd-ness is only
#   knowable at runtime.
#
# A determined author walks past this. It is here for the ordinary case -- a
# later card reaching for the nearest idiom -- and the holes are written down so
# nobody reads a green run as more than it is.
module RootDefaultDiscipline
  # `getwd` is `pwd`'s alias on all three of these, so a guard that knew one
  # spelling would be a third of a guard.
  CWD_READERS = %w[pwd getwd].freeze

  # Receivers whose `.pwd`/`.getwd` IS the process working directory. Named
  # explicitly so a `queue.pwd` or a local called `pwd` can never match.
  CWD_RECEIVERS = %w[Dir Pathname FileUtils].freeze

  # `File.expand_path(".")` -- the most common idiom of all, and invisible to
  # any scan looking for the word `pwd`. Only ever a violation with ONE
  # argument: `File.expand_path(".", base)` resolves against `base` and has
  # nothing to do with the working directory.
  CWD_EXPANSIONS = %w[expand_path absolute_path realpath].freeze
  CWD_DOT = "."

  # `ENV["PWD"]` and `ENV.fetch("PWD", ...)`. The shell's answer rather than the
  # kernel's -- it survives a `cd` through a symlink where `Dir.pwd` does not --
  # but it is still "wherever the process was started".
  CWD_ENV_VAR = "PWD"

  # The nodes that carry a parameter list. The last three are what let a lambda
  # and a `define_method` block count; without them the guard covers `def` only,
  # and the idiom one line down is uncovered.
  PARAM_HOLDERS = %i[def defs lambda brace_block do_block].freeze

  # Every parameter default in `lib/` that reads the working directory today,
  # as `<owner>:<parameter>`, relative to `lib/` like {OutputDiscipline}'s
  # allowlist. Duplicated labels are deliberate: `review/delta.rb` has two
  # classes whose `initialize` each default `repo_root:`, and collapsing them
  # would let a third slip in unseen.
  #
  # An entry here is a place the resolved Project does NOT reach. Removing one
  # (by threading a real root to every caller) is progress; adding one needs an
  # argument. T5 removed two -- `cli/epic.rb` and `cli/epic_land.rb` now default
  # to {Lain::CLI::Wiring.default_project}'s root, so `lain epic status` and a
  # `lain chat` in the same project look in the same epic home.
  #
  # `lain/paths.rb` is the one entry that is a KNOWN DEFECT rather than a
  # library-usability default, and it is listed so it is visible rather than
  # invisible: `project_hash(dir = Dir.pwd)` keys the sessions directory and the
  # epic container off the working directory. Moving it would orphan every
  # existing resumable session, so it wants a migration rather than a keying
  # change and is ticketed separately. It is also why this guard scans optional
  # POSITIONALS: the first edition could not see it at all.
  ALLOWED = {
    "lain/approval/remembered.rb" => %w[initialize:root],
    "lain/approval/risk.rb" => %w[initialize:root],
    "lain/cli/command/meta.rb" => %w[initialize:root],
    "lain/cli/command/review.rb" => %w[initialize:root],
    "lain/cli/command/review_submit.rb" => %w[initialize:root],
    # `cwd:` rides beside `root:` here for {Command::Survey}'s sake, and is the
    # OTHER half of {Lain::Project} rather than a second spelling of the first:
    # root is the authority boundary, cwd is where a relative path resolves.
    # Whoever builds this surface should hand in both halves of the resolved
    # project; the defaults are so that a spec constructing one by hand need not
    # restate either.
    "lain/cli/command/surface.rb" => %w[initialize:cwd initialize:root],
    "lain/cli/epic_mount.rb" => %w[self.mount:root],
    "lain/cli/isolation_backend.rb" => %w[initialize:root],
    "lain/cli/review.rb" => %w[initialize:repo_root],
    "lain/cli/review_seams.rb" => %w[for:root],
    # `lain survey` is `lain review`'s shape one source over, and this is the
    # SAME argument `cli/review.rb`'s entry above makes: a one-shot command has
    # no resolved Project to be threaded one. It is not a root either -- the
    # survey's own root is the PATH argument, and this cwd only says which
    # project's `[sensitivity]` table is in force and what a relative rule in it
    # resolves against, which is the working directory by definition.
    "lain/cli/survey.rb" => %w[initialize:cwd],
    # `/survey` in a chat. `root:` is the SAME entry `command/review.rb` above
    # has for the same reason: {Lain::CLI::Command::Surface} threads it in on
    # the live path, and the default is the library-usability one a spec
    # constructing the command by hand would otherwise have to restate. It is
    # not the surveyed tree, which is the path argument.
    #
    # `cwd:` is `cli/survey.rb`'s entry below, one surface over, and it is NOT a
    # root at all: it is where this chat is STANDING, which decides what a
    # surveyed file is named -- the attached editor resolves a row against the
    # directory it was started in, and `lain up` gives both panes one `-c`, so
    # the chat's own working directory is that directory by definition.
    # {Lain::CLI::Command::Surface} threads it in on the live path exactly as it
    # threads `root:`, and this default is the library-usability one; it is
    # {Lain::CLI::Wiring} that decides where the value comes FROM.
    #
    # Defaulting it to the ROOT instead is the defect this entry exists to keep
    # out -- it names every file of a monorepo chat's survey from the repository
    # top, which the editor then resolves under its own cwd, and it regresses
    # `/survey .` from working to broken.
    "lain/cli/command/survey.rb" => %w[initialize:cwd initialize:root],
    "lain/cli/up.rb" => %w[initialize:cwd],
    "lain/config.rb" => %w[self.load:root],
    "lain/dsl_catalog.rb" => %w[self.load:root],
    "lain/epic/home.rb" => %w[self.container:root self.resolve:root],
    "lain/forge/gh.rb" => %w[initialize:cwd],
    "lain/forge/promotion.rb" => %w[initialize:repo_root],
    "lain/frontend/completion/sources.rb" => %w[initialize:root],
    "lain/frontend/prompt_composer.rb" => %w[self.config_path:project],
    "lain/isolation/compose.rb" => %w[initialize:project_root],
    "lain/isolation/worktree.rb" => %w[initialize:repo_root],
    "lain/isolation/worktree/handback.rb" => %w[initialize:repo_root],
    # A KNOWN DEFECT, not a usability default -- see the note above.
    "lain/paths.rb" => %w[project_hash:dir],
    "lain/project/resolver.rb" => %w[call:cwd],
    "lain/project_dir.rb" => %w[initialize:root],
    "lain/prompt/slots.rb" => %w[load:root],
    "lain/review/delta.rb" => %w[initialize:repo_root initialize:repo_root],
    "lain/review/source.rb" => %w[initialize:repo_root],
    "lain/review/source/github_pr.rb" => %w[initialize:repo_root],
    "lain/review/source/local_branch.rb" => %w[initialize:repo_root],
    "lain/skill/catalog.rb" => %w[load:root],
    "lain/skill/library.rb" => %w[self.load:root],
    "lain/supervisor/restart.rb" => %w[initialize:root],
    "lain/workspace/restore.rb" => %w[initialize:root],
    "lain/workspace/snapshot.rb" => %w[initialize:root]
  }.freeze

  # One parameter default that reads the working directory, with enough to fix
  # it. `owner` is the method, lambda or block the parameter belongs to.
  Default = Struct.new(:path, :owner, :parameter) do
    def label = "#{owner}:#{parameter}"

    def to_s = "#{path} -> #{owner}(... #{parameter} defaulted to the working directory)"
  end

  # Walks a Ripper s-expression collecting cwd-reading parameter defaults.
  class Scanner
    # The owner a parameter is attributed to when it belongs to a block or a
    # lambda no enclosing `def` or assignment names.
    ANONYMOUS = "(anonymous)"

    # A `params` node is `[:params, required, OPTIONAL, rest, post, KEYWORDS,
    # kwrest, block]`, and Ripper writes `nil` (not an empty Array) for each
    # slot a signature does not use. Both halves matter, and the optional half
    # is why: `Paths#project_hash(dir = Dir.pwd)` is a positional, and it is the
    # live instance this guard was widened for.
    OPTIONAL = 2
    KEYWORDS = 5

    def initialize(path)
      @path = path
    end

    # @return [Array<Default>]
    def scan(source)
      sexp = Ripper.sexp(source)
      raise "could not parse #{@path}" if sexp.nil?

      walk(sexp, ANONYMOUS)
    end

    private

    # `owner` descends: a block inside `def foo` reports as `foo`, and a lambda
    # assigned to `RESOLVE` reports as `RESOLVE`, so every finding names
    # something a reader can search for.
    def walk(node, owner, found = [])
      return found unless node.is_a?(Array)

      owner = renamed(node, owner)
      found.concat(defaults_in(node, owner)) if PARAM_HOLDERS.include?(node[0])
      node.each { |child| walk(child, owner, found) }
      found
    end

    # What renames the owner: a method definition, an assignment whose value is
    # a lambda (`RESOLVE = ->(root: Dir.pwd) { ... }`), and a `define_method`
    # -- so a finding always names something the reader can search for.
    def renamed(node, owner)
      case node[0]
      when :def then name_of(node[1])
      when :defs then "self.#{name_of(node[3])}"
      when :assign then assigned_name(node) || owner
      when :method_add_block then defined_method_name(node[1]) || owner
      else owner
      end
    end

    def defined_method_name(call)
      define_method_call?(call) ? define_method_owner(argument_list(call[2]).first) : nil
    end

    def define_method_call?(call)
      call.is_a?(Array) && call[0] == :method_add_arg &&
        call[1].is_a?(Array) && call[1][0] == :fcall && ident_in?(call[1][1], %w[define_method])
    end

    def define_method_owner(symbol)
      return nil unless symbol.is_a?(Array) && symbol[0] == :symbol_literal

      "define_method(:#{name_of(symbol[1][1])})"
    end

    def assigned_name(node)
      target = node[1]
      return nil unless target.is_a?(Array) && %i[var_field const_path_field].include?(target[0])

      name_of(target[1])
    end

    def name_of(node) = node.is_a?(Array) ? node[1].to_s : node.to_s

    # Ripper hangs a singleton method's params two slots later than a plain
    # one's, and a block's behind a `block_var`.
    def defaults_in(node, owner)
      params(node).select { |(_name, default)| default && cwd_read_in?(default) }
                  .map { |(name, _default)| Default.new(@path, owner, name_of(name).delete_suffix(":")) }
    end

    # The unwraps are what make `def f(x)`, `def f x` and `{ |x| }` one scan.
    def params(node)
      params = unwrapped(param_node(node))
      return [] unless params.is_a?(Array) && params[0] == :params

      [params[OPTIONAL], params[KEYWORDS]].grep(Array).flatten(1)
    end

    def unwrapped(node)
      %i[paren block_var paren].inject(node) do |current, wrapper|
        current.is_a?(Array) && current[0] == wrapper ? current[1] : current
      end
    end

    def param_node(node)
      case node[0]
      when :def then node[2]
      when :defs then node[4]
      else node[1]
      end
    end

    def cwd_read_in?(node)
      return false unless node.is_a?(Array)

      cwd_call?(node) || cwd_expansion?(node) || cwd_env?(node) ||
        node.any? { |child| cwd_read_in?(child) }
    end

    # A `.pwd`/`.getwd` ON one of {CWD_RECEIVERS}, so a local named `pwd` --
    # or somebody else's `#pwd` -- is never mistaken for one.
    def cwd_call?(node)
      node[0] == :call && CWD_RECEIVERS.any? { |name| const_named?(node[1], name) } &&
        ident_in?(node[3], CWD_READERS)
    end

    # `File.expand_path(".")` and its siblings, with EXACTLY one argument: a
    # second argument is the base it resolves against, which makes the call
    # nothing to do with the working directory.
    def cwd_expansion?(node)
      return false unless node[0] == :method_add_arg

      call = node[1]
      call.is_a?(Array) && call[0] == :call && const_named?(call[1], "File") &&
        ident_in?(call[3], CWD_EXPANSIONS) && sole_dot_argument?(node[2])
    end

    def sole_dot_argument?(args)
      list = argument_list(args)
      list.length == 1 && string_of(list.first) == CWD_DOT
    end

    # `ENV["PWD"]` (an `aref`) and `ENV.fetch("PWD", ...)` (a call), both of
    # which name the shell's idea of where the process started.
    def cwd_env?(node)
      (node[0] == :aref && const_named?(node[1], "ENV") && names_pwd?(argument_list(node[2]))) ||
        (node[0] == :method_add_arg && env_fetch?(node[1]) && names_pwd?(argument_list(node[2])))
    end

    def env_fetch?(call)
      call.is_a?(Array) && call[0] == :call && const_named?(call[1], "ENV") && ident_in?(call[3], %w[fetch])
    end

    def names_pwd?(list) = list.any? { |argument| string_of(argument) == CWD_ENV_VAR }

    # Ripper wraps an argument list in `arg_paren` and then `args_add_block`,
    # and writes a bare `args_add_block` when the call had no parentheses.
    def argument_list(node)
      node = node[1] if node.is_a?(Array) && node[0] == :arg_paren
      return [] unless node.is_a?(Array) && node[0] == :args_add_block

      node[1].is_a?(Array) ? node[1] : []
    end

    # The literal text of a plain string argument, or nil for anything with
    # interpolation or any other shape -- a guess there would be a false
    # positive, and this guard's fixtures are what a false positive costs.
    def string_of(node)
      return nil unless node.is_a?(Array) && node[0] == :string_literal

      parts = node[1].is_a?(Array) ? node[1][1..] : []
      parts.length == 1 && parts.first.is_a?(Array) && parts.first[0] == :@tstring_content ? parts.first[1] : nil
    end

    # `Dir`, `::Dir`, and the `var_ref` wrapper Ripper puts on a bare constant.
    def const_named?(node, name)
      return false unless node.is_a?(Array)

      (node[0] == :@const && node[1] == name) ||
        (%i[var_ref top_const_ref].include?(node[0]) && const_named?(node[1], name))
    end

    def ident_in?(node, names) = node.is_a?(Array) && node[0] == :@ident && names.include?(node[1])
  end

  module_function

  def lib_root = Pathname(__dir__).join("../../../lib").expand_path

  # @return [Hash{String => Array<String>}] every cwd-reading keyword default in
  #   `lib/`, as sorted labels per lib-relative path
  def declared
    lib_root.glob("**/*.rb").each_with_object({}) do |file, out|
      relative = file.relative_path_from(lib_root).to_s
      found = Scanner.new(relative).scan(file.read)
      out[relative] = found.map(&:label).sort unless found.empty?
    end
  end

  # Multiset, not Set: `Array#-` collapses the duplicate `initialize:repo_root`
  # pair in `review/delta.rb`, which would let a third one through allowlisted
  # by its twin.
  def difference(from, minus)
    from.filter_map do |path, labels|
      extra = surplus(labels, minus.fetch(path, []))
      [path, extra] unless extra.empty?
    end.to_h
  end

  def surplus(labels, budgeted)
    budget = budgeted.tally
    labels.each_with_object([]) do |label, extra|
      spent = budget[label].to_i
      spent.positive? ? budget[label] = spent - 1 : extra << label
    end
  end
end

# T5's second acceptance criterion, asserted over the tree rather than trusted
# to review.
RSpec.describe "root: Dir.pwd defaults" do
  def scan(source) = RootDefaultDiscipline::Scanner.new("fixture.rb").scan(source)

  describe "the tree as it stands" do
    it "declares no cwd-reading keyword default outside the allowlist" do
      added = RootDefaultDiscipline.difference(RootDefaultDiscipline.declared, RootDefaultDiscipline::ALLOWED)

      expect(added).to be_empty, lambda {
        listing = added.map { |path, labels| "  #{path} -> #{labels.join(", ")}" }.join("\n")
        "A project root now comes from Lain::Project::Resolver, threaded through " \
          "Lain::CLI::Wiring. Take a `root:` from your caller instead of defaulting it to " \
          "the working directory:\n#{listing}\n" \
          "If the default really is right, add it to RootDefaultDiscipline::ALLOWED with a reason."
      }
    end

    # The other half, its own example so a REMOVED default never masks an added
    # one: an allowlist entry for a default that no longer exists is a licence
    # nobody is using, and it would silently re-permit the same line later.
    it "keeps no allowlist entry for a default that is gone" do
      stale = RootDefaultDiscipline.difference(RootDefaultDiscipline::ALLOWED, RootDefaultDiscipline.declared)

      expect(stale).to be_empty, lambda {
        listing = stale.map { |path, labels| "  #{path} -> #{labels.join(", ")}" }.join("\n")
        "These allowlist entries name defaults that no longer exist. Delete them:\n#{listing}"
      }
    end
  end

  # Every fixture below is a real way to default a keyword to the working
  # directory, and each must redden the scan -- otherwise the scan is theatre.
  describe "what reddens it" do
    {
      "the plain keyword default" => "def initialize(root: Dir.pwd); end",
      "an endless singleton method" => "def self.load(root: Dir.pwd) = new(root:)",
      "a keyword under some other name" => "def initialize(repo_root: Dir.pwd); end",
      "the pwd alias" => "def initialize(root: Dir.getwd); end",
      "a cwd read wrapped in an expression" => "def initialize(root: File.expand_path(Dir.pwd)); end",
      "a top-level constant reference" => "def initialize(root: ::Dir.pwd); end",
      "a def written without parentheses" => "def initialize root: Dir.pwd\nend",
      "a def nested inside a Data.define block" =>
        "X = Data.define(:a) do\n  def initialize(root: Dir.pwd)\n    super\n  end\nend",
      # Everything below walked past the first edition of this guard; the T5
      # review found them, and the positional one is live in lib/.
      "an OPTIONAL POSITIONAL default" => "def project_hash(dir = Dir.pwd); end",
      "a positional default in a keyword-heavy signature" => "def initialize(root = Dir.pwd, journal: nil); end",
      "File.expand_path(\".\") -- the commonest idiom, with no `pwd` in it" =>
        'def initialize(root: File.expand_path(".")); end',
      "File.absolute_path(\".\")" => 'def initialize(root: File.absolute_path(".")); end',
      "Pathname.pwd" => "def initialize(root: Pathname.pwd.to_s); end",
      "FileUtils.pwd" => "def initialize(root: FileUtils.pwd); end",
      "ENV.fetch(\"PWD\")" => 'def initialize(root: ENV.fetch("PWD", nil)); end',
      "ENV[\"PWD\"]" => 'def initialize(root: ENV["PWD"]); end',
      "a lambda keyword default" => "RESOLVE = ->(root: Dir.pwd) { root }",
      "a define_method block" => "define_method(:go) { |root: Dir.pwd| root }",
      "a chained cwd read" => "def initialize(root: Dir.pwd.dup); end"
    }.each do |spelling, source|
      it "catches #{spelling}" do
        expect(scan(source)).not_to be_empty
      end
    end

    it "names the file, the owner and the parameter, so the failure is actionable" do
      found = scan("class C\n  def self.mount(root: Dir.pwd); end\nend").first

      expect([found.path, found.owner, found.parameter]).to eq(["fixture.rb", "self.mount", "root"])
      expect(found.to_s).to include("self.mount").and include("root")
    end

    # The two that are not `def`s still have to name something a reader can
    # search for, or the failure message sends them hunting.
    it "names a lambda by what it was assigned to, and a define_method by its method" do
      expect(scan("RESOLVE = ->(root: Dir.pwd) { root }").map(&:label)).to eq(["RESOLVE:root"])
      expect(scan("define_method(:go) { |root: Dir.pwd| root }").map(&:label)).to eq(["define_method(:go):root"])
    end
  end

  # The false-positive side, and why this is an AST walk and not a grep. The
  # first two are what a text scan would flag in this repository TODAY.
  describe "what it leaves alone" do
    {
      "the words in a comment" => "# every caller used to write root: Dir.pwd\ndef initialize(root:); end",
      "the words in a string" => 'def initialize(root:)
                                    @doc = "root: Dir.pwd is the old idiom"
                                  end',
      "a cwd read in a method BODY -- WorkerEnv.default must stay" => "def self.default = new(cwd: Dir.pwd)",
      "a keyword default that is not a cwd read" => "def initialize(root: Project.root); end",
      "a required keyword with no default at all" => "def initialize(root:); end",
      "a local variable that merely spells pwd" => "def initialize(root: pwd); end",
      # The base argument is the whole point of these two: they resolve against
      # what they are GIVEN, so flagging them would be a false positive on the
      # correct idiom this card is asking people to write.
      "File.expand_path with an explicit base" => 'def initialize(root: File.expand_path(".", base)); end',
      "File.expand_path of a real argument" => "def initialize(root: File.expand_path(dir)); end",
      "an ENV read of some other variable" => 'def initialize(root: ENV.fetch("LAIN_ROOT", nil)); end',
      "a #pwd on something that is not a cwd source" => "def initialize(root: queue.pwd); end"
    }.each do |spelling, source|
      it "ignores #{spelling}" do
        expect(scan(source)).to be_empty
      end
    end
  end

  # The COMPARISON half, which until the T5 review was asserted in prose and
  # nowhere else: every example above exercises {Scanner}, so `difference`
  # returning `{}` and `surplus` degrading to `Array#-` -- the exact degradation
  # the allowlist's own comment argues against -- both survived. Literal
  # fixtures, never slices of {ALLOWED}, so the pin cannot move with the data.
  describe "the allowlist comparison" do
    it "reports a label the allowlist does not budget for" do
      found = { "a.rb" => %w[initialize:root load:root] }
      allowed = { "a.rb" => %w[initialize:root] }

      expect(RootDefaultDiscipline.difference(found, allowed)).to eq({ "a.rb" => %w[load:root] })
    end

    # The multiset claim, stated as an example: three copies against a budget of
    # two must report ONE, and `Array#-` reports none.
    it "counts duplicates, so a third copy is not allowlisted by its twin" do
      found = { "a.rb" => %w[initialize:repo_root initialize:repo_root initialize:repo_root] }
      allowed = { "a.rb" => %w[initialize:repo_root initialize:repo_root] }

      expect(RootDefaultDiscipline.difference(found, allowed)).to eq({ "a.rb" => %w[initialize:repo_root] })
    end

    it "reports a whole file the allowlist has never heard of" do
      expect(RootDefaultDiscipline.difference({ "new.rb" => %w[initialize:root] }, {}))
        .to eq({ "new.rb" => %w[initialize:root] })
    end

    it "answers empty when every label is budgeted, duplicates included" do
      pair = { "a.rb" => %w[initialize:root initialize:root] }

      expect(RootDefaultDiscipline.difference(pair, pair)).to be_empty
    end

    # And that {.declared} reads the real tree rather than answering nothing --
    # an empty scan would make both tree examples pass vacuously.
    it "reads real defaults out of lib/" do
      expect(RootDefaultDiscipline.declared).to include("lain/config.rb" => %w[self.load:root])
      expect(RootDefaultDiscipline.declared.size).to be > 20
    end
  end
end
