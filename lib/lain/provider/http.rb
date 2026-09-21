# frozen_string_literal: true

module Lain
  class Provider
    # The vendored HTTP transport, forked from ruby_llm 1.16.0, commit 2cf34b9
    # -- see VENDOR.md. Upstream relies on zeitwerk autoloading and so its own
    # files carry no requires for sibling classes, which is why the fork sat
    # behind a hand-written load order for as long as lain had one.
    module HTTP; end
  end
end
