# frozen_string_literal: true

require "ripper"
require "tmpdir"
require "pathname"

# Mechanical enforcement of ONE resolver for `.lain/state.json`. Three renderers
# read or write that file, each used to compose the path itself, and a fourth
# spelling is trivial to write by hand and invisible in review -- so it is
# forbidden here rather than in a paragraph nobody re-reads.
#
# Ripper, not a text match, for the reason `spec/output_discipline_spec.rb`
# parses too. A grep catches ONE spelling: it misses the same join with the tail
# pre-joined, `"#{Dir.pwd}/.lain/state.json"`, `Dir.pwd + "/.lain"`, a
# recomposition through `ProjectDir::DIR`, and even a line-wrapped copy of the
# identical expression -- while flagging the words in a COMMENT, which the text
# version of this scan did until it was replaced.
module ProjectDirDiscipline
  # The two halves {Lain::ProjectDir} exists to join, plus the file this scan is
  # about. Spelled here rather than read off the class so that a rename of the
  # constant cannot silently disarm the scan.
  PROJECT_NAME = ".lain"
  STATE_NAME = "state.json"
  CWD_READERS = %w[pwd getwd].freeze

  # The locator itself, which does not recompose the path -- it IS the
  # composition. Relative to `lib/`, like {OutputDiscipline}'s allowlist.
  EXEMPT = ["lain/project_dir.rb"].freeze

  # The expression forms that BUILD a path. A subtree rooted at one of these
  # that names the project directory together with either the working directory
  # or the state file has rebuilt what {Lain::ProjectDir#state_path} resolves.
  # Anchoring on these (rather than on any node at all) is what keeps a whole
  # file, or a whole class body, from counting as one expression.
  COMPOSITIONS = %i[method_add_arg command command_call binary string_literal].freeze

  Violation = Struct.new(:path, :line, :names) do
    def to_s = "#{path}:#{line} -> composes #{names.join(" + ")}"
  end

  # Walks a Ripper s-expression collecting recompositions of the state path.
  class Scanner
    def initialize(path)
      @path = path
    end

    # @return [Array<Violation>] at most one per line, since the composition
    #   sites of one expression nest (a string inside a `File.join`)
    def scan(source)
      sexp = Ripper.sexp(source)
      raise "could not parse #{@path}" if sexp.nil?

      walk(sexp).uniq(&:line)
    end

    private

    def walk(node, found = [])
      return found unless node.is_a?(Array)

      found.concat(violation(node)) if COMPOSITIONS.include?(node[0])
      node.each { |child| walk(child, found) }
      found
    end

    def violation(node)
      names = names_in(node)
      return [] unless names.include?(PROJECT_NAME) && names.length > 1

      [Violation.new(@path, line_of(node), names.sort)]
    end

    # Which of the three things this expression names, deduplicated.
    def names_in(node, found = [])
      return found unless node.is_a?(Array)

      found << "Dir.pwd" if cwd_read?(node)
      found << PROJECT_NAME if project_name?(node)
      found << STATE_NAME if string_including?(node, STATE_NAME)
      node.each { |child| names_in(child, found) }
      found.uniq
    end

    # A call on the `Dir` constant, so a local variable named `pwd` is never
    # mistaken for a read of the working directory.
    def cwd_read?(node)
      node[0] == :call && const_named?(node[1], "Dir") && ident_in?(node[3], CWD_READERS)
    end

    # The project directory, named as a string or through the locator's constant.
    def project_name?(node)
      string_including?(node, PROJECT_NAME) || project_dir_const?(node)
    end

    def string_including?(node, needle) = node[0] == :@tstring_content && node[1].include?(needle)

    # `ProjectDir::DIR`, however it is scoped -- `Lain::ProjectDir::DIR` too.
    def project_dir_const?(node)
      node[0] == :const_path_ref && const_named?(node[2], "DIR") && names_const?(node[1], "ProjectDir")
    end

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

# The project-scoped `.lain/` tree. This class does not own every `.lain/` name
# in `lib/` -- seven others still compose their own, which is a named follow-up,
# not this card -- it owns the resolution of `.lain/state.json`, which had three
# independent spellings across the three renderers of one feed.
RSpec.describe Lain::ProjectDir do
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

    it "resolves the published state feed" do
      expect(described_class.new(root: "/srv/app").state_path).to eq("/srv/app/.lain/state.json")
    end

    it "keeps the root it was handed" do
      expect(described_class.new(root: "/srv/app").root).to eq("/srv/app")
    end

    # Read at CONSTRUCTION, not at require time, so the three renderers keep
    # the behaviour their literals had: whatever directory the process is in
    # when the object is built.
    it "defaults the root to the working directory" do
      Dir.mktmpdir("lain-project-dir") do |dir|
        Dir.chdir(dir) do
          expect(described_class.new.state_path).to eq(File.join(Dir.pwd, ".lain", "state.json"))
        end
      end
    end
  end

  # T29's acceptance criterion, asserted over the tree rather than trusted to
  # review. Every fixture below is a real way to rebuild the state path by hand,
  # and each must redden the scan -- otherwise the scan is theatre.
  describe "one resolver for .lain/state.json" do
    def scan(source) = ProjectDirDiscipline::Scanner.new("fixture.rb").scan(source)

    it "is the only place lib/ composes the state path" do
      violations = ProjectDirDiscipline.violations

      expect(violations).to be_empty, lambda {
        listing = violations.map { |violation| "  #{violation}" }.join("\n")
        "`.lain/state.json` has one resolver, Lain::ProjectDir#state_path. Ask it " \
          "instead of rebuilding the path:\n#{listing}"
      }
    end

    {
      "the canonical three-segment join" => 'x = File.join(Dir.pwd, ".lain", "state.json")',
      "a join with the tail pre-joined" => 'x = File.join(Dir.pwd, ".lain/state.json")',
      # Escaped, not single-quoted: this is fixture SOURCE that must contain a
      # literal interpolation, and Lint/InterpolationCheck reads a single-quoted
      # `#{}` as a mistake -- its autocorrect would make the interpolation real.
      "an interpolated string" => %(x = "\#{Dir.pwd}/.lain/state.json"),
      "concatenation onto the directory name" => 'x = Dir.pwd + "/.lain"',
      "a recomposition through the locator's own constant" =>
        'x = File.join(Dir.pwd, Lain::ProjectDir::DIR, "state.json")',
      "the identical expression wrapped over three lines" =>
        %(x = File.join(Dir.pwd,\n              ".lain",\n              "state.json")\n)
    }.each do |spelling, source|
      it "catches #{spelling}" do
        expect(scan(source)).not_to be_empty
      end
    end

    # The false-positive side, and why this is an AST walk and not a grep: a text
    # match flagged this class's OWN comment, and the workaround was to reword
    # prose -- the tell that text is the wrong tool.
    it "ignores the names in a comment" do
      expect(scan(%(# joins Dir.pwd with .lain and state.json\nx = 1\n))).to be_empty
    end

    # The other `.lain/` artifact names in lib/ are a named follow-up, not this
    # card: composing one of those is not recomposing the state feed.
    it "leaves the other `.lain/` artifact names alone" do
      expect(scan('x = File.join(root, ".lain", "config.toml")')).to be_empty
    end

    it "reports the line and what the expression composed" do
      violation = scan(%(x = 1\ny = File.join(Dir.pwd, ".lain", "state.json")\n)).first

      expect(violation.line).to eq(2)
      expect(violation.names).to eq([".lain", "Dir.pwd", "state.json"])
    end
  end
end
