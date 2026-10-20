# frozen_string_literal: true

module Lain
  # The DAG's Ruby side: {Dag::Factory} builds every Timeline, Store and stored
  # event. The orders over them belong to the Store the Timelines point into,
  # not to either Timeline, and live in the extension: {Ext::Dag::RenderAncestry}
  # is the render edge alone.
  module Dag
  end
end
