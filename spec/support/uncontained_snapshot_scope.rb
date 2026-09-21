# frozen_string_literal: true

# A snapshot {Lain::Workspace::Snapshot::Scope} that puts the dropped half of
# another scope's answer back, so every path it was handed is keyed -- root or
# no root. No shipped scope does: each drops a recorded path outside the
# snapshot's root, because a ../ key is one an undo or a restore can only
# refuse. Those refusals are still live guards -- a record written before the
# containment landed carries such keys, and the payload format is frozen -- so
# the specs pinning them need a writer that still produces one.
#
# A decorator rather than a subclass because the refusals live at two depths:
# {Lain::Workspace::Restore} and the log's own planning answer about a plain
# write-set map, while `/undo`'s command-level refusal is reached only through a
# scope that also stages trees. Wrapping lets one fixture serve both.
class UncontainedSnapshotScope
  # @param scope [#paths] the scope whose answer is un-narrowed; the write-set
  #   scope by default, the shadow one where staged trees are what a spec needs
  def initialize(scope = Lain::Workspace::Snapshot::Scope::WriteSet.new)
    @scope = scope
  end

  def paths(write_set:, root:)
    selection = @scope.paths(write_set:, root:)
    Lain::Workspace::Snapshot::Scope::Selection.new(kept: (selection.to_a + selection.outside).freeze,
                                                    outside: [].freeze)
  end

  def note = @scope.note

  def label = @scope.label

  def baseline(root) = @scope.baseline(root)

  def pair(root) = @scope.pair(root)

  def unchanged?(...) = @scope.unchanged?(...)
end
