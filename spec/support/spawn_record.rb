# frozen_string_literal: true

# What a spawn left behind, read off the events it WROTE rather than off the
# tool that wrote them.
#
# {Lain::Tools::Subagent} used to keep the same three facts in `@last_spawn`,
# `@last_child` and `@last_message`, and its own comment said what the shape
# cost: the ivars were safe only because a one-shot spawn runs synchronously
# inside a single dispatch, so actor mode could never inherit them and a
# concurrent fan-out could only race them. An actor's record rides its events
# instead, and so does this -- the seam is {Lain::Tools::Subagent::Seam}'s own
# `observer:`, the outward slot the live session scribe attaches to, so a spec
# watches exactly what production watches.
#
# It reads the LATEST of each kind, which is what the ivars meant. A fan-out
# writes one pair per sibling and this answers for whichever finished last;
# an example about several siblings at once reads {#spawns} and {#messages},
# or the shared Store, rather than asking a singular question of a plural run.
class SpawnRecord
  def initialize
    @events = []
  end

  # The `observer:` duck: one call per event, in emission order.
  def call(event) = @events << event

  # Every event the spawn emitted -- the :spawn, the child's own turns, the
  # :message -- so an example about the funnel itself can compare the whole
  # sequence.
  def events = @events.dup

  def spawns = of_kind(:spawn)
  def messages = of_kind(:message)

  # nil when nothing was spawned, which is the assertion a depth refusal wants:
  # not "the tool forgot to remember" but "nothing was written".
  def spawn = spawns.last
  def message = messages.last

  # The child's Timeline, rebuilt from the digest its :message names over the
  # Store the parent already shares with it. The same walk `last_child` gave --
  # a Timeline IS a head digest and a store, and both are recorded.
  #
  # @param store [Lain::Store] the shared store the spawn wrote into
  # @return [Lain::Timeline, nil] nil when no child ever finished
  def child(store)
    # Any kind-`:message` event is the latest one, including an actor's note,
    # whose body carries "text" and no "final" -- so this asks rather than
    # fetches, and answers nil for a record that named no child.
    final = message&.body&.[]("final")
    final && Lain::Timeline.new(head_digest: final, store:)
  end

  private

  def of_kind(kind) = @events.select { |event| event.is_a?(Lain::Event) && event.kind == kind }
end
