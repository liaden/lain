# frozen_string_literal: true

# A tool whose path argument is a file or a directory answers a target that is absent,
# of the wrong kind, or unreadable as an error Result, never a raise. The sentences come from
# Tool::FileTarget, which has its own spec; what this group pins is that each tool actually
# routes its path through it.
#
# Include with the kind of target the tool takes: :file, :directory, or :either (grep and
# ast_search take both, so no wrong-kind row applies). The host defines `call_with(path)` in
# the block, the tool's answer for that path with every other argument fixed, and exposes
# `tmpdir`, an empty directory this group may write into.
RSpec.shared_examples "a tool answering a bad file target" do |kind|
  wording = {
    file: { missing: "no such file", wrong_kind: "is a directory, not a file", unreadable: "file is not readable" },
    directory: { missing: "no such directory", wrong_kind: "not a directory",
                 unreadable: "directory is not readable" },
    either: { missing: "no such file or directory", unreadable: "not readable" }
  }.fetch(kind)

  # Either's sentence names no path, so only the wording is pinned there.
  define_method(:expect_error) do |result, row, path|
    content = kind == :either ? include(wording.fetch(row)) : eq("#{wording.fetch(row)}: #{path}")
    expect(result).to have_attributes(is_error: true, content:)
  end

  it "reports a missing path as an error Result rather than raising" do
    missing = File.join(tmpdir, "nope")

    expect_error(call_with(missing), :missing, missing)
  end

  unless kind == :either
    it "reports a target of the wrong kind as an error Result rather than raising" do
      path = kind == :file ? tmpdir : File.join(tmpdir, "a_file.txt").tap { |file| File.write(file, "x") }

      expect_error(call_with(path), :wrong_kind, path)
    end
  end

  it "reports an unreadable target as an error Result rather than raising" do
    path = File.join(tmpdir, "locked")
    kind == :directory ? Dir.mkdir(path) : File.write(path, "shh")
    File.chmod(0o000, path)

    expect_error(call_with(path), :unreadable, path)
  ensure
    File.chmod(0o700, path) if path && File.exist?(path)
  end
end
