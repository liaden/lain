# frozen_string_literal: true

# The default project is the checkout, and a wiring rooted there lists every tracked file to mask it.
module ThrowawayProject
  def throwaway_project(dir)
    root = File.realpath(dir)
    Lain::Project.new(root:, cwd: root, kind: :project, detected_by: :flag)
  end
end

RSpec.configure { |config| config.include ThrowawayProject }
