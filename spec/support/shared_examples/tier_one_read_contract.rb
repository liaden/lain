# frozen_string_literal: true

# The tier-1 read contract, made executable instead of aspirational.
#
# Every tier-1 reader's own docstring promises the same thing -- a missing
# path, a directory, an unreadable file "is reported as an error Tool::Result,
# never a raise" -- and T5 broke exactly that promise for the most ordinary
# file there is. `File.read` with a LENGTH answers nil at EOF, so a zero-length
# file (`touch foo.rb`, an empty `__init__.py`, a `.keep`) hit a frozen literal
# and raised `FrozenError` straight past the tool's own rescue.
#
# ⚠️ It was the THIRD nil-or-frozen edge on a length-read in one card, and a
# 14,000-example suite was green through all three. That count is the argument
# for a table: the shapes below are where readers break, they are cheap to
# enumerate, and the next one then reddens at commit instead of reaching a
# model. The gap that hid the empty-file case is instructive on its own --
# there WAS an empty-file example, and it passed `offset`/`limit`, so it
# exercised the windowed reader and left the default path uncovered. Hence the
# rule that a subject with two readers runs this group once per reader.
#
# == The assertion is deliberately weak, and that is the design
#
# One thing per row: it comes back as a `Tool::Result` and nothing raises.
# Whether the bytes are right, what the message says, which narrower action it
# names -- all of that is asserted in the examples that already assert it, and
# duplicating it here would make the table expensive to extend. A table people
# stop adding rows to is worse than no table. The one refinement is free
# because it is DERIVED rather than declared per row: a shape at or under the
# subject's ceiling must succeed, one over it must refuse.
#
# == What the host supplies
#
#   #read_of(bytes)   a Tool::Result from reading a subject holding exactly
#                     those bytes. The host decides which READER that goes
#                     through, which is what lets one subject include this
#                     group once per arm.
#   #read_ceiling     the subject's own limit, so the two boundary rows sit on
#                     the number the subject enforces rather than on a copy of
#                     it kept next door.
RSpec.shared_examples "a tier-1 read that never raises" do
  # Sized from the host's ceiling so every row is past whatever internal
  # boundary that reader has -- for a chunking reader the chunk edge, for a
  # whole reader the ceiling itself.
  def past_every_boundary = read_ceiling + 1024

  # Two parities on purpose: a multi-byte character can only straddle a
  # boundary at one of them, and which one is an accident of the ceiling being
  # even. Pinning both means a reader cannot be correct by luck.
  def multibyte(offset) = ("a" * offset) + ("é" * (past_every_boundary / 2))

  def byte_shapes = separator_shapes.merge(boundary_shapes)

  # Where a reader's idea of "a line" goes wrong.
  def separator_shapes
    {
      "an empty file" => "",
      "one byte" => "x",
      "no trailing newline" => "alpha\nbeta",
      "a trailing newline" => "alpha\nbeta\n",
      "blank lines" => "alpha\n\n\nbeta\n",
      "CRLF endings" => "alpha\r\nbeta\r\n",
      "a lone CR and no LF at all" => "alpha\rbeta\r",
      "NUL bytes" => "alpha\u0000beta\n"
    }
  end

  # Where a reader's idea of "how much" goes wrong.
  def boundary_shapes
    {
      "one line and no separator anywhere" => "x" * past_every_boundary,
      "multi-byte characters straddling odd offsets" => multibyte(0),
      "multi-byte characters straddling even offsets" => multibyte(1),
      "exactly the ceiling" => "x" * read_ceiling,
      "one byte over the ceiling" => "x" * (read_ceiling + 1)
    }
  end
  it "answers every pathological shape with a Tool::Result and no raise" do
    byte_shapes.each do |shape, bytes|
      result = nil

      expect { result = read_of(bytes) }.not_to raise_error, shape
      expect(result).to be_a(Lain::Tool::Result), shape
      # Derived, never declared: over the ceiling refuses, at or under it does
      # not. A row cannot disagree with the subject about its own limit.
      expect(result.is_error).to be(bytes.bytesize > read_ceiling), "#{shape} (#{bytes.bytesize} bytes)"
    end
  end
end

# The half of the contract only a FILESYSTEM can pose, kept separate rather
# than filtered out of the group above. `Memory::Item` cannot hold non-UTF-8
# bytes at all -- `Canonical` refuses them at construction -- so "invalid
# UTF-8" is a file shape and not a shared one, and a per-host row filter would
# be exactly the maintenance tax the weak assertion above exists to avoid.
#
# What the host supplies:
#
#   #read_at(path)    a Tool::Result from reading that path
#   #scratch          a writable directory the rows may build in
RSpec.shared_examples "a tier-1 read of any path that never raises" do
  # `[path, should_refuse]`. A device and a fifo have no size to bound and must
  # be refused; a symlink to an ordinary file is an ordinary file and must not
  # be -- that row is what reddens if `File.file?` is ever "tidied" to
  # `File.ftype`, which is lstat-based and answers "link".
  def path_shapes
    {
      "a file of invalid UTF-8" => [binary_file("\xFF\xFE alpha\n".b), false],
      "a symlink to an ordinary file" => [symlink_to_file, false],
      "a missing path" => [File.join(scratch, "absent.txt"), true],
      "a directory" => [scratch, true],
      "a character device" => ["/dev/null", true],
      "a fifo" => [fifo, true]
    }
  end

  it "answers every path shape with a Tool::Result and no raise" do
    path_shapes.each do |shape, (path, refuses)|
      result = nil

      expect { result = read_at(path) }.not_to raise_error, shape
      expect(result).to be_a(Lain::Tool::Result), shape
      expect(result.is_error).to be(refuses), shape
    end
  end

  def binary_file(bytes)
    File.join(scratch, "binary.bin").tap { |path| File.binwrite(path, bytes) }
  end

  def symlink_to_file
    target = File.join(scratch, "target.txt")
    File.write(target, "through a link\n")
    File.join(scratch, "link.txt").tap { |link| File.symlink(target, link) }
  end

  def fifo
    File.join(scratch, "pipe").tap { |path| File.mkfifo(path) }
  end
end
