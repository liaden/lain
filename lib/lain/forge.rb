# frozen_string_literal: true

# Index for the forge/ unit (see CLAUDE.md, Requires). The forge tier is where
# lain reaches OUTSIDE the machine it is running on -- pushing a ref, opening a
# pull request, merging one -- and its whole discipline is that each such reach
# is journaled as an INTENT before it is attempted and an OUTCOME after, so a
# crash leaves a readable bet rather than a silence. {Forge::Reconcile} is what
# reads those back and asks the world which of them actually landed.
#
# `intent` carries the unit's ACTIONS and its Guards and so loads first;
# `reconcile` folds the records those guards define.
#
# The unit sits after `epic` in lain.rb. Nothing here resolves an Epic constant
# -- the coupling is by slug and issue id, which are strings -- but a forge
# action is always work done FOR an epic issue, and the manifest reads in that
# order.
require_relative "forge/intent"
require_relative "forge/reconcile"
require_relative "forge/gh"
require_relative "forge/journaled"
require_relative "forge/promotion"
require_relative "forge/landing"
