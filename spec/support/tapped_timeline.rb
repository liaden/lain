# frozen_string_literal: true

# A Timeline that runs a hook before each message it is sent, and stays tapped
# across every move: whatever a commit, checkout or rewind answers is tapped
# too. The Rust timeline commits, walks and puts inside the extension, where no
# double on its Store can see, so the Timeline's own surface is where a spec
# injects a fault or watches a call.
class TappedTimeline
  REFUSAL = "this timeline refuses that result"

  # A Timeline refusing every commit whose content carries one of `markers`:
  # a result that cannot be stored, whatever made it so, without depending on
  # which bytes a text boundary upstream lets through. The first refusal says
  # REFUSAL alone and a later one numbers itself; `refusals` names the marker
  # each one met, in order.
  def self.refusing(timeline, *markers, refusals: [])
    new(timeline) do |name, content: nil, **|
      json = name == :commit ? JSON.generate(content) : ""
      marker = markers.find { |candidate| json.include?(candidate) }
      if marker
        refusals << marker
        raise Lain::Error, refusals.one? ? REFUSAL : "#{REFUSAL} (refusal #{refusals.size})"
      end
    end
  end

  # @yieldparam name [Symbol] the message about to be sent, then its arguments
  def initialize(timeline, &hook)
    @timeline = timeline
    @hook = hook
  end

  attr_reader :timeline

  def ==(other) = timeline == untapped(other)
  alias eql? ==

  def hash = timeline.hash

  def to_s = "#<TappedTimeline #{timeline}>"
  alias inspect to_s

  def method_missing(name, *args, **, &block)
    return super unless timeline.respond_to?(name)

    @hook.call(name, *args, **)
    tapped(timeline.public_send(name, *args.map { |arg| untapped(arg) }, **, &block))
  end

  def respond_to_missing?(name, include_private = false) = timeline.respond_to?(name, include_private) || super

  private

  def untapped(value) = value.is_a?(TappedTimeline) ? value.timeline : value

  def tapped(value) = value.instance_of?(timeline.class) ? TappedTimeline.new(value, &@hook) : value
end
