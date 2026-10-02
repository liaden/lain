# frozen_string_literal: true

require "concurrent/map"
require "ripper"

# One Ripper parse per distinct source, shared by every example in a run. Many
# discipline specs scan every file under lib/, and the parse is the larger half of
# each scan. The key is the source text, so a changed file is a new key rather
# than a stale hit.
#
# Trees and kept scans are frozen deeply, so a scanner that edits one raises
# instead of corrupting the next caller. Parsing all of lib/ holds about 94MB, so
# the memo is dropped once every file that used it has run its last group; files
# that never touch it do not hold it open.
module ParsedSource
  PARSED = Concurrent::Map.new
  SCANS = Concurrent::Map.new
  GROUPS_LEFT = Concurrent::Map.new
  USERS = Concurrent::Map.new
  private_constant :PARSED, :SCANS, :GROUPS_LEFT, :USERS

  module_function

  # @param source [String]
  # @return [Array, nil] the frozen Ripper.sexp tree, nil for source that does not parse
  def sexp(source)
    note_user
    PARSED.compute_if_absent(source) { Ractor.make_shareable(Ripper.sexp(source)) }
  end

  # The result of one whole-tree scan, so examples asking the same question of
  # lib/ pay for it once.
  # @param key [Object] names the scan
  # @return [Object] the block's value, frozen
  def once(key)
    note_user
    SCANS.compute_if_absent(key) { Ractor.make_shareable(yield) }
  end

  # @return [void]
  def clear
    PARSED.clear
    SCANS.clear
    USERS.clear
  end

  # @param groups [Array<Class>] the top-level groups the run will execute
  # @return [void]
  def expect_groups(groups)
    groups.each { |group| GROUPS_LEFT.compute(file_of(group)) { |left| left.to_i + 1 } }
  end

  # @param group [Class] a top-level example group that just finished
  # @return [void]
  def group_finished(group)
    GROUPS_LEFT.compute(file_of(group)) { |count| count.to_i - 1 }
    clear unless USERS.keys.any? { |file| GROUPS_LEFT[file].to_i.positive? }
  end

  def file_of(group) = group.metadata.fetch(:absolute_file_path)
  private_class_method :file_of

  # A call outside an example (a before(:context) hook) is not attributed.
  def note_user
    example = RSpec.current_example
    USERS[file_of(example.example_group)] = true if example
  end
  private_class_method :note_user
end

RSpec.configure do |config|
  config.before(:suite) do
    ParsedSource.expect_groups(RSpec.world.example_groups.select { |group| group.descendant_filtered_examples.any? })
  end
  config.after(:context) { ParsedSource.group_finished(self.class) }
end
