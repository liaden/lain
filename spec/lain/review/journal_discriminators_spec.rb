# frozen_string_literal: true

# Asked here as well as globally because the global sweep cannot ask it of
# these records. spec/journalable_surface_spec.rb groups by journal_type over the
# records GenericBuild could BUILD, and `hunk_marked`, `review_verdict` and
# `annotation_placed` refuse every uniform dummy -- so a collision on any of the
# three would pass that sweep in silence. Those three land on that sweep's named
# blind-spot list beside eight of the nine epic records, and this file is what
# covers them: the same claim, asked about the records the global one cannot
# build.
#
# It belongs to no one record, which is why it is here rather than in any of the
# six per-record files -- the property is about the SET.
RSpec.describe "the review records' journal discriminators" do
  # `allocate.journal_type`, not the class basename. Two records can share a
  # basename and still not collide, and -- the case that matters -- a record can
  # OVERRIDE `journal_type` and collide while its basename does not.
  # Forge::Intent and Forge::Outcome already override it in this repo, so this is
  # a shape the registry really has. Asking the method is also what makes the
  # sweep total: `allocate` needs no constructor, so a record whose guard refuses
  # every generic dummy is still answerable here.
  # ANONYMOUS classes are excluded, and the exclusion is what makes this sweep
  # deterministic. `journal_type` is `self.class.name.split("::")`, which raises
  # `NoMethodError` on a `Class.new` -- and a spec that builds an anonymous
  # Journalable includer leaves one reachable from ObjectSpace, so whether this
  # example saw it depended on load order and GC. It failed on 3 of 4 seeds under
  # `rspec spec/lain/review/` and passed under `rake pspec` only because the
  # workers happened to split those files apart. Nothing is lost by skipping
  # them: an anonymous class has no stable discriminator to collide WITH.
  def discriminators_in_the_registry
    ObjectSpace.each_object(Class).select do |klass|
      klass.include?(Lain::Telemetry::Journalable) && !klass.name.nil?
    rescue StandardError
      false
    end
  end

  it "collides with none of the includers already in the registry" do
    reviews = [Lain::Review::ChangesetOpened, Lain::Review::CorpusExtended, Lain::Review::HunkMarked,
               Lain::Review::ReviewVerdict, Lain::Review::AnnotationPlaced, Lain::Review::ChangesetClosed]
    taken = (discriminators_in_the_registry - reviews).map { |klass| klass.allocate.journal_type }

    expect(reviews.map { |klass| klass::JOURNAL_TYPE })
      .to contain_exactly("changeset_opened", "corpus_extended", "hunk_marked", "review_verdict",
                          "annotation_placed", "changeset_closed")
    expect(reviews.map { |klass| klass.allocate.journal_type } & taken).to be_empty
  end

  # The sweep answers for the WHOLE registry, which is the property that lets it
  # stand in for spec/journalable_surface_spec.rb's collision example over the
  # records GenericBuild cannot build.
  it "answers for every includer, including the ones no generic dummy constructs" do
    klasses = discriminators_in_the_registry

    expect(klasses.size).to be > 60
    expect(klasses.map { |klass| klass.allocate.journal_type }.uniq.size).to eq(klasses.size)
  end
end
