# frozen_string_literal: true

# Index for the forge/ unit. The forge tier is where lain reaches OUTSIDE the
# machine it is running on -- pushing a ref, opening a pull request, merging one
# -- and its discipline is that each such reach is journaled as an INTENT before
# it is attempted and an OUTCOME after, so a crash leaves a readable bet rather
# than a silence. {Forge::Reconcile} reads those back and asks the world which
# of them actually landed.
#
# `intent` carries the ACTIONS and the construction contracts for both journal
# records, so it loads first; `reconcile` folds the records they define.
require_relative "forge/intent"
require_relative "forge/reconcile"
require_relative "forge/gh"
require_relative "forge/journaled"
require_relative "forge/promotion"
require_relative "forge/landing"
require_relative "forge/local_landing"
