# frozen_string_literal: true

# The subject project an altitude arm works in, declaring the rspec layout over
# lib/ so the level roots are spec/unit, spec/seam and spec/integration. The
# lease harness grades one level root, which is why the tests this project
# commits are spread across two of them.
tests preset: :rspec, source_roots: %w[lib]
