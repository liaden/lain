# frozen_string_literal: true

# rspec-expectations' stock differ pretty-prints two multi-line Hash#inspect
# STRINGS and diffs those strings char-by-char -- one changed leaf anywhere
# in the tree smears the whole output. super_diff instead walks the actual
# Ruby objects and diffs key-by-key/element-by-element, so a Response content
# block (a string-keyed Hash, `{ "type" => "tool_use", "input" => { ... } }`,
# never HashWithIndifferentAccess -- see lib/lain/response.rb) or a JSON
# Schema Hash (lib/lain/tool/input.rb) shows only the ONE divergent leaf.
# `require`ing this alone is what installs the patched differ; no config
# option is needed to make a String-keyed Hash diff structurally -- that is
# the library's unconditional default, verified against a nested content
# block before this file was written.
require "super_diff/rspec"

SuperDiff::RSpec.configure do |config|
  # Off by default anyway, but stated: an elided diff on a wrong-shaped
  # content block (nested `"input" => {...}`) is worse than a long one --
  # the whole point of wiring this in is to see every divergent leaf.
  config.diff_elision_enabled = false
end
