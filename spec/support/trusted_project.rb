# frozen_string_literal: true

# A project's `.lain/*.rb` runs only once its bytes are trusted, so a spec that
# plants one and expects it evaluated grants trust the way `lain trust` does.
# Call it AFTER writing the files: the mark is keyed on their bytes.
#
# The ambient state home is per PROCESS, not per example, and trust is keyed on
# content, so a grant here trusts those bytes for every later example in the
# worker. An example that pins a refusal injects its own `paths:` rather than
# relying on common bytes staying untrusted.
module TrustedProject
  def trust_project(root, paths: Lain::Paths.new)
    Lain::Project::Trust.for(project_dir: Lain::ProjectDir.new(root:, paths:), paths:).grant!
  end
end

RSpec.configure { |config| config.include TrustedProject }
