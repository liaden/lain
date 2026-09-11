# frozen_string_literal: true

module Lain
  module CLI
    # `lain epic add|split|merge`: the iterate-epic door. One {Epic::Graph}
    # structural edit (`add`, `split` or `merge`), applied, journaled as a
    # {Epic::GraphRevision} and written back to `epic.md` -- in that order,
    # because the edit is what can refuse. Every operation reads a fresh graph
    # off disk and writes at most once, so a refusal (an unknown issue, a
    # would-be cycle, a duplicate id) leaves `epic.md` and the Journal exactly
    # as they were: nothing here degrades to a partial edit.
    #
    # == The write is `Home#write_epic`, not the journaled decorator
    #
    # {Epic::Home::Journaled} adds two things this door does not need: a
    # `DocWritten` ack and a review-baton refusal. Both exist for the PROSE
    # artifacts a human reviews turn-by-turn ({Epic::Review}); a structural
    # graph edit is the epic's own machinery revising its own graph, journaled
    # in the vocabulary built for exactly that ({Epic::Scribe#graph_revised}).
    # Wiring the review baton into this door is a later card's to make, once
    # something actually opens a review on `epic.md` mid-edit.
    #
    # == Every constant from the epic tier is reached at CALL time
    #
    # {CLI::Epic}'s header explains why: this unit loads before `lain/epic`
    # (lib/lain.rb: cli, then plan, then epic), so a `Lain::Epic::...`
    # reference evaluated while this file LOADS would raise `NameError` at
    # boot. Every such reference below sits inside a method body.
    class EpicGraph
      # One structural edit's report: what it moved and the digest pair a
      # replay would check. Held apart from the three public methods below
      # because "resolve the epic, read the graph, run the edit, write it
      # back, journal the fiber" is one shape all three share -- the only thing
      # that differs is what the edit itself is, which arrives at {#apply} as a
      # block, and this is only the rendering of what came back.
      #
      # The block runs BEFORE anything is written: {Epic::Graph}'s own
      # operations (`fetch`, `split`, `merge`, `Graph.new` under the hood) are
      # what refuse an unknown id, a self-merge, or a graph that would carry a
      # cycle, and every one of those refusals raises out of the block, past
      # `write_epic` and `graph_revised`, before either runs -- so this class
      # only ever renders a fiber that already named a graph on disk.
      class Applied
        def initialize(slug, fiber)
          @slug = slug
          @fiber = fiber
        end

        def to_s
          ["#{@fiber.operation} applied to epic `#{@slug}`: #{ids(@fiber.preimage)} -> #{ids(@fiber.results)}",
           "  epic.md written; graph #{@fiber.before} -> #{@fiber.after}"].join("\n")
        end

        private

        def ids(list) = list.empty? ? "(none)" : list.map { |id| "`#{id}`" }.join(", ")
      end
      private_constant :Applied

      # @param root [String] the project root; the config file and a repo-mode
      #   home both resolve under it
      # @param paths [Paths] injected, so a spec resolves against a throwaway
      #   XDG state home
      # @param config [Config] `.lain/config.toml`, already read
      # @param epics [CLI::Epic] answers WHICH epic a bare invocation means, the
      #   same object every other epic verb asks -- a second spelling of "the
      #   sole epic in the home" could disagree with it and neither would raise
      def initialize(root: Project::Resolver.default_project.root, paths: Paths.new, config: Config.load(root:),
                     epics: Epic.new(root:, paths:, config:))
        @root = root
        @paths = paths
        @config = config
        @epics = epics
      end

      # @param id [String] the new issue's id
      # @param title [String] the new issue's title
      # @param slug [String, nil] the epic; omitted resolves to the sole one
      # @param discovered_from [String, nil] the live issue this one grew out
      #   of, if any
      # @return [String] the applied edit, rendered
      # @raise [Lain::Error] any refusal from {Epic::Issue} or {Epic::Graph},
      #   before anything is written
      def add(id, title, slug = nil, discovered_from: nil)
        apply(slug, command: "epic add ID TITLE") do |graph|
          fiber = nil
          revised = graph.add(Lain::Epic::Issue.new(id:, title:), discovered_from:) { |cut| fiber = cut }
          [revised, fiber]
        end
      end

      # @param id [String] the issue leaving
      # @param into [String] the parts arriving, comma-separated ids -- each
      #   inherits `id`'s title, description and criteria; an author edits
      #   `epic.md` afterward to tell the parts apart
      # @param slug [String, nil] the epic; omitted resolves to the sole one
      # @return [String] the applied edit, rendered
      # @raise [Epic::UnknownIssue] naming `id`, before anything is written
      # @raise [Lain::Error] any other refusal from {Epic::Graph}, likewise
      #   before anything is written
      def split(id, into, slug = nil)
        apply(slug, command: "epic split ID") do |graph|
          original = graph.fetch(id)
          parts = comma_ids(into).map { |part_id| original.with(id: part_id) }
          fiber = nil
          revised = graph.split(id, into: parts) { |cut| fiber = cut }
          [revised, fiber]
        end
      end

      # @param left [String] one issue leaving
      # @param right [String] the other issue leaving
      # @param slug [String, nil] the epic; omitted resolves to the sole one
      # @param as [String] the merged issue's id
      # @param title [String, nil] the merged issue's title; defaults to
      #   combining both sides' so the command is usable without it
      # @return [String] the applied edit, rendered
      # @raise [Lain::Error] any refusal from {Epic::Issue} or {Epic::Graph},
      #   before anything is written
      def merge(left, right, slug = nil, as:, title: nil)
        apply(slug, command: "epic merge LEFT RIGHT") do |graph|
          arrival = Lain::Epic::Issue.new(id: as, title: title || merged_title(graph, left, right))
          fiber = nil
          revised = graph.merge(left, right, as: arrival) { |cut| fiber = cut }
          [revised, fiber]
        end
      end

      private

      def merged_title(graph, left, right) = "#{graph.fetch(left).title} / #{graph.fetch(right).title}"

      def comma_ids(value) = value.to_s.split(",").map(&:strip)

      # The one shape every edit shares. `home.read_epic` and `write_epic` are
      # two different reads/writes of the SAME artifact deliberately -- nothing
      # here holds the graph across the block, so a refusal inside the block
      # leaves `write_epic` uncalled rather than calling it on a half-built
      # value.
      #
      # `write_epic` runs BEFORE `journal_revision`, not after: a crash in
      # that window (disk full, `SIGKILL`) leaves `epic.md` advanced to the
      # new graph with no `graph_revision` record of the edit -- reviewed and
      # kept deliberately, because the other order is worse. Journaling first
      # would record an edit that then fails to land, which is a record lying
      # about the artifact; this way the artifact never lies about itself,
      # only the audit trail is short one entry. The cost is real but narrow:
      # the lineage chain a replay walks is missing exactly that edit, and
      # nothing reads `graph_revision` records for anything but that replay
      # today -- `epic.md` itself, `Progress.fold`, and every other reader
      # answer straight from the graph that is actually on disk.
      def apply(slug, command:)
        resolved = @epics.resolve_slug(slug, command:)
        home = Lain::Epic::Home.resolve(config: @config, paths: @paths, slug: resolved, root: @root)
        revised, fiber = yield(home.read_epic)
        home.write_epic(revised)
        journal_revision(resolved, fiber)
        Applied.new(resolved, fiber).to_s
      end

      # Opened and closed around this one write, the way {EpicSubmit} opens one
      # around its one decision: the fiber is already known good (it named the
      # graph `write_epic` just wrote), so nothing here can refuse.
      def journal_revision(slug, fiber)
        journal = Journal.open(paths: @paths)
        begin
          Lain::Epic::Scribe.new(epic_slug: slug, journal:).graph_revised(fiber)
        ensure
          journal.close
        end
      end
    end
  end
end
