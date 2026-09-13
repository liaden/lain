# frozen_string_literal: true

# The Null collaborators a spec hands a production constructor, and the reason
# they live here rather than in `lib/`: a production default naming one of them
# is a wiring omission that assembles cleanly, which is the failure a
# constructor exists to make loud. `ToolRegistry::UNGUARDED` is the precedent
# and states the rule -- no production constant may mean "nothing was wired".
#
# `spec/lib_null_defaults_spec.rb` reads this module's own constants back out
# and refuses any of them a name in `lib/`, so the rule is checked rather than
# remembered. A Null added here therefore needs a name distinctive enough to
# search for; a generic one reddens that spec on the day it lands.
#
# One file per Null under `nulls/`, which `spec/spec_helper.rb` globs -- this
# file carries only the namespace and the rule.
module SpecNulls
end
