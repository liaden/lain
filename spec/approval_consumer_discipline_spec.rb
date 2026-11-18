# frozen_string_literal: true

require "rubocop"

# The Lain/ApprovalConsumer cop refuses a `#dequeue` nobody ruled on; this is the
# ruling itself, written where a reader looking for "who may drain approvals" will
# find it. The arrival queue hands each parked call to exactly one consumer, and it
# has to be the surface that can ask a person.
RSpec.describe "approval consumer discipline" do
  let(:root) { File.expand_path("..", __dir__) }
  let(:allowed) do
    RuboCop::ConfigLoader.configuration_from_file(File.join(root, ".rubocop.yml"))
                         .for_cop("Lain/ApprovalConsumer").fetch("AllowedReceivers")
  end

  it "rules on the queue that ApprovalPolicy#watch drains, under the file that defines it" do
    consumer = Lain::Frontend::ApprovalPolicy.instance_method(:watch).source_location.first

    expect(allowed.fetch(consumer.delete_prefix("#{root}/"))).to include("queue")
  end
end
