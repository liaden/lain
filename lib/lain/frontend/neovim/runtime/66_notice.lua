-- News, not a refusal: the same fitting as `review_refused`, so a sentence
-- longer than the message area elides instead of raising hit-enter over the
-- human's editor, but in the Normal highlight and without the warning colour.
-- A fitted line is not the original, so only a sentence that fit is recorded
-- in `:messages`.
-- `fitted` and `folded` are 65_review.lua's locals, in scope because the
-- runtime files load as one chunk.
function _G.__lain.notice(text)
  local full = "lain: " .. tostring(text)
  local shown = fitted(folded(full))
  vim.api.nvim_echo({ { shown, "Normal" } }, shown == full, {})
  return shown
end
