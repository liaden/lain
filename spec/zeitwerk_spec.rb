# frozen_string_literal: true

# What boot cannot tell you about the loader in lib/lain.rb. A misconfigured
# loader -- a missing acronym, an ignored file nobody requires, a cycle -- does
# not need a spec: `require "lain"` raises and every example in the suite fails
# with it. So none of that is asserted here.
#
# What survives a green boot is the subject: a constant no path names, findable
# only because the file defining it is a file the loader loads; an ignore entry
# the loader never needed; an entry naming a file that is gone. Each of those
# boots clean and is wrong, and eager loading an already-required tree is silent
# about all three by construction -- every autoload Zeitwerk set was discarded
# when the manifest's `require_relative` defined the constant first.
#
# It is asked of the loader, never of a second implementation of it: the
# path-to-constant map below is Zeitwerk's own answer, so a change in its
# scanning rules shows up as a failure rather than as two wrong answers
# agreeing.
module ZeitwerkMapping
  # The loader's own root, never `__dir__`: a lib/ reached through a symlink
  # gives those two different answers, and a mapping keyed to the wrong one
  # matches nothing while still looking right.
  LIB = Lain::LOADER.dirs.first

  # { absolute path => constant path }, covering managed files AND the
  # directories that stand for namespaces. Ignored paths are already absent.
  EXPECTED = Lain::LOADER.all_expected_cpaths.freeze
  MANAGED = EXPECTED.keys.select { _1.end_with?(".rb") }.freeze

  IGNORED = Lain::LOADER_IGNORES.map { File.join(LIB, "lain", _1) }.freeze

  module_function

  def ignored_files = IGNORED.flat_map { File.directory?(_1) ? Dir.glob("#{_1}/**/*.rb") : [_1] }

  # The loader is not asked about an ignored path -- that is what ignoring one
  # means -- so its inflector is asked instead, which is still the loader's
  # answer and not a second one.
  def expected_for(path)
    segments = path.delete_prefix("#{LIB}/").delete_suffix(".rb").split("/")
    (["Lain"] + segments.drop(1).map { Lain::LOADER.inflector.camelize(_1, path) }).join("::")
  end

  # Stepwise and without inherited lookup, because that is how Zeitwerk resolves
  # one: a `Foo::Bar` inherited from a superclass would answer a question about
  # `Foo` the loader never asked.
  def resolvable?(cpath)
    cpath.split("::").inject(Object) do |mod, cname|
      return false unless mod.is_a?(Module) && mod.const_defined?(cname, false)

      mod.const_get(cname, false)
    end
    true
  end

  def rel(path) = path.delete_prefix("#{LIB}/")

  # Every constant the manifest's load left under {Lain}, against the file that
  # defined it. That is the set the equivalence is really about, and it is not
  # the set of paths: a file may define constants no path names.
  def defined_constants = walk(Lain, "Lain", Set.new([Lain]), {})

  def walk(mod, cpath, seen, out)
    mod.constants(false).each_with_object(out) do |cname, acc|
      here = "#{cpath}::#{cname}"
      file = mod.const_source_location(cname, false)&.first
      acc[here] = rel(file) if file&.start_with?("#{LIB}/")
      value = mod.const_get(cname, false)
      walk(value, here, seen, acc) if value.is_a?(Module) && seen.add?(value)
    end
  end

  CONSTANTS = defined_constants.freeze

  # The compiled extension defines 26 constants from Rust and is not a Ruby
  # file, so the loader never sees it; lib/lain.rb requires it by name, above
  # the loader, which is what makes those findable.
  def compiled = $LOADED_FEATURES.select { _1.start_with?("#{LIB}/") && !_1.end_with?(".rb") }

  # The files the loader will load: the ones it manages, plus the ignored ones
  # something has required by hand, plus the extension. A constant is findable
  # if and only if the file that defines it is in here.
  def loadable
    (MANAGED + ignored_files.select { $LOADED_FEATURES.include?(_1) } + compiled).to_set
  end

  # A constant the loader has no path for: no prefix of its own name is the
  # constant a managed file is expected to define. Eager loading finds these
  # anyway -- through the file, not through the name -- which is why the ones
  # that matter are references made at class-body time.
  def orphans
    CONSTANTS.reject { |_, file| ignored?(File.join(LIB, file)) }
             .reject do |cpath, file|
      expected = EXPECTED[File.join(LIB, file)] || expected_for(File.join(LIB, file))
      cpath == expected || cpath.start_with?("#{expected}::")
    end
  end

  def ignored?(path) = IGNORED.any? { path == _1 || path.start_with?("#{_1}/") }
end

RSpec.describe "the Zeitwerk loader" do
  it "sweeps enough of lib/ for the comparison to mean something" do
    expect(ZeitwerkMapping::MANAGED.size).to be > 700
    expect(ZeitwerkMapping::CONSTANTS.size).to be > 700
  end

  # The question stated as it is meant. Not "does the constant this PATH
  # implies exist" -- which a tree the manifest has already loaded answers yes
  # to for reasons of its own -- but "can the loader find every constant the
  # manifest defines".
  # Hundreds of them it cannot find by NAME at all, having no path of their
  # own. What makes those findable is the file defining them being a file the
  # loader loads -- which eager loading guarantees and lazy loading would not.
  it "finds every constant the manifest defines" do
    loadable = ZeitwerkMapping.loadable
    unfindable = ZeitwerkMapping::CONSTANTS
                 .reject { |_, file| loadable.include?(File.join(ZeitwerkMapping::LIB, file)) }

    expect(unfindable).to be_empty
  end

  # The case the path sweep structurally cannot see, named rather than counted:
  # `agent/loop_machine.rb` is the loader's path for {Lain::Agent::LoopMachine},
  # and its `included` hook `const_set`s {Lain::Agent::STATES} from the machine
  # it has just built. No autoload will ever carry that name, and no rename
  # could give it one -- the constant is written at include time rather than
  # spelled in any file.
  it "finds a constant no path names, through the file that does define it" do
    expect(Lain::LOADER.all_expected_cpaths.values).not_to include("Lain::Agent::STATES")
    expect(ZeitwerkMapping.orphans).to include("Lain::Agent::STATES" => "lain/agent/loop_machine.rb")
  end

  describe "the ignore list" do
    let(:files) { ZeitwerkMapping.ignored_files }

    it "names files that are really there" do
      expect(ZeitwerkMapping::IGNORED.reject { File.exist?(_1) }).to be_empty
    end

    # The converse of the sweep above, and what keeps the list from growing by
    # habit: an entry whose constant the loader could have found on its own is
    # one the loader should be finding.
    it "carries no entry the loader did not need" do
      needless = files.select { ZeitwerkMapping.resolvable?(ZeitwerkMapping.expected_for(_1)) }

      expect(needless).to be_empty
    end
  end
end
