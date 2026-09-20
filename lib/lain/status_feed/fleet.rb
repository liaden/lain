# frozen_string_literal: true

require "time"

module Lain
  class StatusFeed
    # Every spawn this feed has carried, folded into the tree the HUD's `fleet`
    # segment counts, `lain://status` draws and the input pane's header shows
    # the top of. Its own object for {Inbox}'s reason rather than an instance
    # variable in the feed: a standing set with an arrival side, a retirement
    # side and a parent edge is a collaborator, and the feed derives a dozen
    # unrelated fields beside it.
    #
    # A Hash keyed by digest, not an Array: that is what makes a redelivered
    # `:spawn` -- a journal replay, a warm start feeding recorded history back
    # through the sinks -- a no-op update instead of a second entry. Content
    # addressing does the rest, so two separately constructed Events naming the
    # same spawn are one member, because they name one spawn.
    #
    # THE STANDING SET AND THE LIVE SET ARE SEPARATE, which is
    # {CLI::FleetWindows}'s structure and the reason a member can leave at all:
    # keying arrival on live membership would make a `:spawn` redelivered AFTER
    # its own completion resurrect a child that is gone. `@seen` is therefore
    # never pruned -- two thousand finished spawns leave two thousand entries
    # against an empty roster, which is what that rule costs, not a leak.
    #
    # The retirement is journal-derived because it can be nothing else: the
    # {StatusFeed} class doc forbids this feed asking a live registry, so "has
    # this child finished" is only ever a fact read off a record.
    #
    # THE TREE IS BUILT FROM TWO RECORDS, and it has to be. A `:spawn` names the
    # HEAD it was spawned from and never the spawn that owns that head, so a
    # grandchild's branch is only placeable against the heads its parent has
    # reported in a {Telemetry::ChildProgress}. A spawn whose `spawned_from`
    # matches no reported head is a root: the run's own chain is nobody's child.
    #
    # TWO THINGS THE ADDRESS RULING COSTS THIS FOLD, both known. Identical
    # twins share one `:spawn` digest and so one row, but each dispatch counts
    # its own turns, so the shared row's count is whichever twin reported last
    # rather than either child's whole work -- and a twin's head can evict the
    # other's from the parent index, rooting anything spawned from it. And the
    # parent edge is resolved ONCE, at `launched`: a grandchild whose `:spawn`
    # somehow reached this fold before its parent's first progress record would
    # sit at the root for good. Production orders those the other way -- a turn
    # is promoted before the tool round that spawns from it runs -- but nothing
    # here can repair it if that ever changes.
    #
    # WHAT AN ENDED ROW COSTS is why {ENDED_SHOWN} exists. A child that hit its
    # ceiling must not vanish from the surface that was watching it, so an ended
    # row stays; but this struct is rewritten every turn, and a session's whole
    # spawn history in it would be a growing write per turn. So the tree keeps
    # every RUNNING row and the most recent ended ones, and `@seen` -- digests
    # alone -- keeps the no-resurrection rule whole whatever the tree drops.
    class Fleet
      # What a row says about its child. `running` until a record ends it;
      # `done` for the one-shot that answered, and the two ways it can end
      # without answering, spelled as {SpawnLifecycle} spells them.
      RUNNING = "running"
      DONE = "done"
      FAILED = "failed"
      STOPPED = "stopped"

      # How many ended rows the tree carries beyond the live ones, oldest
      # dropped first. Small on purpose: what a human acts on is the child that
      # just failed, not the forty before it.
      ENDED_SHOWN = 8

      # @param clock [#call] answers the current Time; the row's start instant
      #   is stamped from it, and injectable so a spec never races a real clock
      def initialize(clock: -> { Time.now })
        @clock = clock
        @seen = Set.new
        @members = {}
        @heads = {}
        @tree = nil
      end

      # Named for the lifecycle word the `:spawn` record already speaks, so the
      # call site reads as the event it is answering.
      #
      # @param event [#digest, #body] the arriving `:spawn` Event; its body's
      #   `spawned_from` is what places the row under its owner
      # @return [void]
      def launched(event)
        digest = event.digest
        return if @seen.include?(digest)

        @seen << digest
        @members[digest] = Member.new(spawn: digest, parent: @heads[spawned_from(event)], started: @clock.call)
        @tree = nil
      end

      # The other half of the same word: a `:message` that ends a spawn's
      # lifecycle takes it out of the live set. {SpawnLifecycle} answers whether
      # this record is that message -- an actor's farewell, a one-shot's answer
      # and a one-shot whose child failed or was stopped say so differently, and
      # asking is what keeps one reading of a journal record rather than a copy
      # of it per reader.
      #
      # WHICH member ended is the `causal_parents` join those records already
      # carry: an actor's farewell cites the address it took from its own
      # `:spawn` digest, a one-shot's completion cites that `:spawn` beside the
      # child's final head. EVERY cited digest is ended rather than the first
      # one found to be a member, because `Event#normalize_causal` uniqs and
      # SORTS: "the first cited parent" is not recoverable from the list, and
      # matching once would make the retirement turn on which digest sorted
      # lower. A record citing no member ends nothing. Identical twins share
      # one member, so whichever of them ends first -- answering or failing --
      # retires it.
      #
      # @param record [#causal_parents] an arriving `:message`, in either shape
      #   the feed's `:message` arm dispatches: a raw {Event} or the
      #   {Telemetry::Message} the actor path promotes it into
      # @return [void]
      def completed(record)
        lifecycle = SpawnLifecycle.new(record)
        return unless lifecycle.terminal?

        Array(record.causal_parents).each { |cited| @members[cited]&.ended(state_of(lifecycle)) }
        prune
        @tree = nil
      end

      # A {Telemetry::ChildProgress}: what the child has come to, folded onto
      # the row its spawn owns. Only the fields the record CARRIES are taken --
      # a turn record names no role, and a fold that took its nils would erase
      # the task line the dispatch record set.
      #
      # The head is kept as the LATEST one this spawn reported, and the one
      # before it is forgotten: a grandchild is spawned from the head its parent
      # is standing on, so an older head can place nothing and an index of every
      # head a session ever committed would grow with the transcript.
      #
      # @param record [Telemetry::ChildProgress]
      # @return [void]
      def progressed(record)
        member = @members[record.spawn]
        return if member.nil?

        @heads.delete(member.head)
        member.progressed(record)
        @heads[member.head] = member.spawn unless member.head.nil?
        @tree = nil
      end

      # @return [Array<String>] what the feed publishes as `fleet`, in the
      #   order the spawns arrived: the spawns nothing has ended
      def digests = live.map(&:spawn)

      # MEMOISED, and the three mutators above are its whole invalidation. This
      # is read from `StatusFeed#observed`, which runs on EVERY event the tee
      # carries -- a bash tool's stdout included -- while the fold moves only on
      # a spawn, a completion or a progress record. Measured before the memo, at
      # 25 members: 150us and 205 objects per call, against 5us for `digests`.
      #
      # @return [Array<Hash>] what the feed publishes as `fleet_tree`: one
      #   string-keyed row per member, parents before their children, each
      #   naming how deep it sits. A `started` instant rather than an elapsed
      #   count, for `cache_deadline`'s reason -- an absolute instant lets a
      #   renderer tick locally, while a duration would make this struct differ
      #   from itself once a second and earn a write every time.
      def tree = @tree ||= branches(nil, 0)

      private

      def live = @members.each_value.select(&:running?)

      # Depth-first, arrival order within a level, so a child is drawn under the
      # parent it was spawned from. A member whose parent has been pruned is
      # reached as a root rather than lost.
      def branches(parent, depth)
        placed = @members.each_value.select { |member| owner(member) == parent }
        placed.flat_map { |member| [member.published(depth), *branches(member.spawn, depth + 1)] }
      end

      def owner(member) = @members.key?(member.parent) ? member.parent : nil

      def state_of(lifecycle)
        return FAILED if lifecycle.failed?

        lifecycle.finished? ? DONE : STOPPED
      end

      # The ended rows beyond the budget, oldest first. Insertion order is
      # arrival order, so the Hash itself says which those are.
      def prune
        ended = @members.each_value.reject(&:running?)
        ended.take([ended.size - ENDED_SHOWN, 0].max).each do |member|
          @members.delete(member.spawn)
          @heads.delete(member.head)
        end
      end

      # Read the way {SpawnLifecycle} reads a body, and for its reason: this
      # runs on a per-turn status sink riding `CLI::JournalTee`, where a raised
      # sink is a lost turn, and a `:spawn` carrying no readable body is an
      # ordinary root rather than a failure.
      def spawned_from(event)
        body = event.body if event.respond_to?(:body)
        body["spawned_from"] if body.is_a?(Hash)
      rescue StandardError
        nil
      end
    end

    class Fleet
      # Reopened rather than nested mid-body, tty.rb's idiom.

      # One member's mutable half: what arrives about a spawn after it launched.
      # Mutable where every published value is frozen, because this IS the fold
      # -- the same reason {Fleet}'s own Hash is -- and nothing outside this file
      # holds one.
      class Member
        attr_reader :spawn, :parent, :head

        def initialize(spawn:, parent:, started:)
          @spawn = spawn
          @parent = parent
          @started = started
          @state = RUNNING
          @role = Telemetry::ChildProgress::DEFAULT_ROLE
          @task = ""
          @worker = nil
          @turns = 0
          @head = nil
        end

        def running? = @state == RUNNING

        def ended(state) = @state = state

        # Only what the record carries: a turn record names no role and no
        # task, and taking its nils would erase what the dispatch record said.
        def progressed(record)
          @role = record.role unless record.role.nil?
          @task = record.task_line unless record.task_line.nil?
          @worker = record.worker unless record.worker.nil?
          @head = record.head unless record.head.nil?
          @turns = record.turns
        end

        def published(depth)
          { "spawn" => @spawn, "role" => @role, "task" => @task, "worker" => @worker,
            "state" => @state, "turns" => @turns, "depth" => depth,
            "started" => @started.utc.iso8601 }.freeze
        end
      end

      Row = Data.define(:indent, :columns)

      # One published row, drawn. Both surfaces that show the tree -- the
      # editor's `lain://status` buffer and the input pane's header -- render
      # from this, so the columns cannot come to differ between them; what each
      # keeps is its own lead, since a markdown buffer wants a bullet and a
      # header does not.
      #
      # Reopened for its constants and its readers, since one declared inside a
      # `Data.define` block lands in the enclosing module. The docstring lives
      # on the reopen because YARD keeps only one and discards the other.
      class Row
        # Two spaces per level, so a grandchild reads as one under its parent
        # without a box-drawing character a status bar's font may not have.
        INDENT = "  "

        GAP = "  "

        # The whole drawn row's budget, in terminal COLUMNS and not characters:
        # a task clamped to 96 characters of CJK draws 214 columns, which wraps
        # the pane and costs it another of its six rows. Eighty is the classic
        # minimum width, so a row inside it fits every terminal lain draws in.
        COLUMNS = 80

        ELLIPSIS = "…"

        # A row with an AGE, for a surface where a redraw is free: nvim
        # rewrites the whole `lain://status` buffer either way.
        #
        # @param published [Hash] one row of {Fleet#tree}
        # @param now [Time] the instant every row in one drawing is aged against
        # @return [Row]
        def self.at(published, now:) = composed(published, aged(published["started"], now))

        # A row with NO age, for the input pane's header. The age is left out
        # rather than rendered coarsely because the header IS the frame the
        # chat publishes: an age that ticks makes that frame differ from itself
        # once a second, and each fresh frame tears the pane's read down and
        # redraws it. Measured in a real six-row pane: seven redraws in eight
        # seconds against one. The instant is still published, so a surface
        # that can afford the redraw shows it.
        #
        # @param published [Hash] one row of {Fleet#tree}
        # @return [Row]
        def self.undated(published) = composed(published, "")

        # Every cell is scrubbed here as well as at the record, and the second
        # pass is not redundant: this renders the PUBLISHED struct, which is
        # JSON read back off disk by a separate process
        # ({Reading.at}), so what reaches a terminal has not necessarily
        # come through {Telemetry::ChildProgress} in this run. Per cell rather
        # than over the joined line, because the scrub strips leading space and
        # the indent is leading space that means something.
        def self.composed(published, age)
          cells = [published["role"], published["state"], "#{published["turns"].to_i}t", age, published["task"]]
          new(indent: INDENT * published["depth"].to_i,
              columns: cells.map { |cell| Tools::AskHuman::InboxRow.one_line(cell) }.reject(&:empty?))
        end
        private_class_method :composed

        # A row's age is read off the instant it started, never off a stamped
        # duration, so it stays true between publications. An unreadable instant
        # ages to nothing rather than raising: this draws a status surface.
        def self.aged(started, now)
          Tools::AskHuman::InboxRow.aged(Time.iso8601(started.to_s), now)
        rescue ArgumentError, TypeError
          ""
        end

        # Clamped on the DRAWN line, because only here is the whole line known:
        # the indent, four columns and the task each contribute, and the task's
        # own character bound cannot see any of them.
        #
        # @param bullet [String] what the surface opens the row with -- a
        #   markdown list's dash, or nothing for a header that is not a list.
        #   It goes INSIDE the indent, or a nested row's dash would not line up
        #   under its parent's.
        def listed(bullet) = Row.clamped("#{indent}#{bullet}#{columns.join(GAP)}")

        def to_s = listed("")

        # Grapheme clusters, not characters: `Ext::Prompt.width` is the one
        # width lain measures with, and a ZWJ emoji is one cluster whose width
        # is not the sum of its parts'. The whole line is measured first, so an
        # ordinary row pays one call and only an over-wide one pays per cluster.
        def self.clamped(line, columns: COLUMNS)
          return line if Ext::Prompt.width(line) <= columns

          budget = columns - Ext::Prompt.width(ELLIPSIS)
          kept, = line.each_grapheme_cluster.inject(["", 0]) do |(text, spent), cluster|
            cost = Ext::Prompt.width(cluster)
            spent + cost > budget ? [text, spent] : ["#{text}#{cluster}", spent + cost]
          end
          "#{kept}#{ELLIPSIS}"
        end
      end
    end
  end
end
