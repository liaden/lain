# frozen_string_literal: true

# What a green boot cannot tell you about the loader in lib/lain.rb. A
# misconfigured loader -- a missing acronym, a cycle, a path whose constant
# disagrees with it -- needs no spec: it stops `require "lain"` and every
# example in the suite fails with it. So none of that is asserted here.
#
# What survives a green boot is the subject: HUNDREDS of constants that no path
# names, reachable only through the file that happens to define them. The tree
# boots because eager loading loads every file regardless, which is a property
# of loading everything and not of the names resolving -- so the question worth
# asking is whether each one's defining file is a file the loader loads.
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

  module_function

  # For a path the loader has no mapping for -- the compiled extension, or
  # anything else that reaches $LOADED_FEATURES without being managed -- its
  # inflector is asked instead, which is still the loader's answer rather than
  # a second one.
  def expected_for(path)
    segments = path.delete_prefix("#{LIB}/").delete_suffix(".rb").split("/")
    (["Lain"] + segments.drop(1).map { Lain::LOADER.inflector.camelize(_1, path) }).join("::")
  end

  def rel(path) = path.delete_prefix("#{LIB}/")

  # Every constant a full load leaves under {Lain}, against the file that
  # defined it. That is the set the question is really about, and it is not the
  # set of paths: a file may define constants no path names.
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

  # The files the loader will load: the ones it manages, plus the compiled
  # extension, which lib/lain.rb requires by name. A constant is findable if
  # and only if the file that defines it is in here.
  def loadable
    (MANAGED + compiled).to_set
  end

  # A constant the loader has no path for: no prefix of its own name is the
  # constant a managed file is expected to define. Eager loading finds these
  # anyway -- through the file, not through the name -- which is why the ones
  # that matter are references made at class-body time.
  def orphans
    CONSTANTS.reject do |cpath, file|
      expected = EXPECTED[File.join(LIB, file)] || expected_for(File.join(LIB, file))
      cpath == expected || cpath.start_with?("#{expected}::")
    end
  end
end

RSpec.describe "the Zeitwerk loader" do
  it "sweeps enough of lib/ for the comparison to mean something" do
    expect(ZeitwerkMapping::MANAGED.size).to be > 700
    expect(ZeitwerkMapping::CONSTANTS.size).to be > 700
  end

  # The question stated as it is meant. Not "does the constant this PATH
  # implies exist", which a fully loaded tree answers yes to for reasons of its
  # own, but "can the loader find every constant lib/ defines".
  # Hundreds of them it cannot find by NAME at all, having no path of their
  # own. What makes those findable is the file defining them being a file the
  # loader loads -- which eager loading guarantees and lazy loading would not.
  it "finds every constant lib/ defines" do
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
end
