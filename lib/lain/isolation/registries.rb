# frozen_string_literal: true

module Lain
  module Isolation
    # Several checkout registries read as one, so the reaper judges linked
    # worktrees and shared clones under one root alike. Each question about a
    # path goes to the registry that listed it; one never listed goes to the
    # first.
    class Registries
      # @param registries [Array<Worktree::Registry>] the first answers for any path none listed
      def initialize(*registries)
        @registries = registries
        @owners = {}
      end

      # @return [Array<Worktree::Registry::Entry>]
      def entries
        @registries.flat_map { |registry| registry.entries.each { |entry| @owners[entry.path] = registry } }
      end

      def claim(entry) = owner(entry.path).claim(entry)

      def interrupted(path) = owner(path).interrupted(path)

      def uncommitted?(path) = owner(path).uncommitted?(path)

      def remove(path) = owner(path).remove(path)

      def rebasing(path) = owner(path).rebasing(path)

      def cut_at(path, clock) = owner(path).cut_at(path, clock)

      private

      def owner(path) = @owners.fetch(path) { @registries.first }
    end
  end
end
