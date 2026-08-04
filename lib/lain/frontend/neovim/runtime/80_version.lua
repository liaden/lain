-- The observable half of the version handshake: :LainVersion surfaces the gem
-- version the attach recorded, straight into :messages -- no rpc round trip.
define("LainVersion", function()
  vim.api.nvim_echo({ { "lain gem " .. tostring(gem_version), "None" } }, true, {})
end)
