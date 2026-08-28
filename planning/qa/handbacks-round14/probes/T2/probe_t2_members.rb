require "lain"
if ARGV[0] == "head"
  old = $VERBOSE; $VERBOSE = nil
  load File.expand_path("probe_t2_approval_view_AT_HEAD.rb", __dir__)
  $VERBOSE = old
end
puts "#{ARGV[0]}: #{Lain::Frontend::Neovim::ApprovalView::Rendering.members.inspect}"
