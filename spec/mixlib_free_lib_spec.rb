# frozen_string_literal: true

require "pathname"
require "tmpdir"

# lib/ shells out through {Lain::Shell::Out} alone. Text, not an AST, because a
# stale comment or a `require` is as much a claim that the gem is still a
# dependency as a constant reference is.
module MixlibFreeLib
  PATTERN = /mixlib/i

  module_function

  def lib_root
    Pathname(__dir__).join("..", "lib").expand_path
  end

  # @return [Array<String>] "path:line" for every line in `source` naming mixlib
  def mentions(path, source)
    source.each_line.with_index(1).filter_map { |line, number| "#{path}:#{number}" if line.match?(PATTERN) }
  end

  def violations
    # The compiled extension is a build artifact, not source, and is not text.
    lib_root.glob("**/*", File::FNM_DOTMATCH).select { |file| file.file? && file.extname != ".so" }.flat_map do |file|
      mentions(file.relative_path_from(lib_root).to_s, file.read)
    end
  end
end

RSpec.describe "mixlib-free lib" do
  it "names Mixlib nowhere in lib/, in code or in comments" do
    expect(MixlibFreeLib.violations).to be_empty
  end

  it "flags a planted mention, in a comment or a require (self-test)" do
    source = "# the old Mixlib::ShellOut path\nrequire \"mixlib/shellout\"\nx = 1\n"

    expect(MixlibFreeLib.mentions("planted.rb", source)).to eq(%w[planted.rb:1 planted.rb:2])
  end

  it "flags a planted mention in a non-Ruby file under lib/ (self-test)" do
    Dir.mktmpdir("lain-mixlib-free") do |dir|
      root = Pathname(dir)
      root.join("runtime").mkpath
      root.join("runtime", "plugin.lua").write("-- shells out like Mixlib did\n")
      allow(MixlibFreeLib).to receive(:lib_root).and_return(root)

      expect(MixlibFreeLib.violations).to eq(["runtime/plugin.lua:1"])
    end
  end
end
