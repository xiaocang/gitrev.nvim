local M = {}
local review_base = ""

local signify_state = {
  captured = false,
  vcs_cmd = "git diff --no-color --no-ext-diff -U0 -- %f",
  vcs_cmd_diffmode = "git show HEAD:./%f",
}

local function command_exists(name)
  return vim.fn.exists(":" .. name) == 2
end

local function copy_global_dict(name)
  local value = vim.g[name]
  if type(value) == "table" then
    return vim.deepcopy(value)
  end

  return {}
end

local function capture_signify_git_cmds()
  if signify_state.captured then
    return
  end

  local vcs_cmds = vim.g.signify_vcs_cmds
  local diffmode = vim.g.signify_vcs_cmds_diffmode

  if type(vcs_cmds) == "table" and vcs_cmds.git then
    signify_state.vcs_cmd = vcs_cmds.git
  end
  if type(diffmode) == "table" and diffmode.git then
    signify_state.vcs_cmd_diffmode = diffmode.git
  end
  signify_state.captured = true
end

local function build_signify_git_cmd(base)
  if base == "" then
    return signify_state.vcs_cmd
  end

  return "git diff --no-color --no-ext-diff -U0 " .. vim.fn.shellescape(base) .. " -- %f"
end

local function build_signify_git_cmd_diffmode(base)
  if base == "" then
    return signify_state.vcs_cmd_diffmode
  end

  return "git show " .. vim.fn.shellescape(base) .. ":./%f"
end

local function sync_gitgutter_base()
  vim.g.gitgutter_diff_base = review_base
  if command_exists("GitGutterAll") then
    vim.cmd("GitGutterAll")
  end
end

local function sync_signify_base()
  if review_base == "" and not signify_state.captured then
    return
  end
  capture_signify_git_cmds()

  local vcs_cmds = copy_global_dict("signify_vcs_cmds")
  local diffmode = copy_global_dict("signify_vcs_cmds_diffmode")

  vcs_cmds.git = build_signify_git_cmd(review_base)
  diffmode.git = build_signify_git_cmd_diffmode(review_base)

  vim.g.signify_vcs_cmds = vcs_cmds
  vim.g.signify_vcs_cmds_diffmode = diffmode

  if command_exists("SignifyRefresh") then
    vim.cmd("SignifyRefresh")
  end
end

local function set_base(ref)
  review_base = ref or ""
  sync_gitgutter_base()
  sync_signify_base()
  vim.notify("review base: " .. (review_base == "" and "HEAD (default)" or review_base))
end

function M.rev_base(args)
  local ref = args ~= "" and vim.trim(args) or ""
  set_base(ref)
end

function M.rev_pr(args)
  local pr_arg = args ~= "" and vim.trim(args) or ""
  local cmd = "gh pr view"
  if pr_arg ~= "" then
    cmd = cmd .. " " .. vim.fn.shellescape(pr_arg)
  end
  cmd = cmd .. " --json baseRefName"

  local output = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    vim.notify("RevPR: gh failed: " .. output, vim.log.levels.ERROR)
    return
  end

  local ok, data = pcall(vim.json.decode, output)
  if not ok or not data or not data.baseRefName then
    vim.notify("RevPR: failed to parse gh output", vim.log.levels.ERROR)
    return
  end

  local sha = vim.fn.system("git merge-base HEAD origin/" .. data.baseRefName):gsub("%s+$", "")
  if vim.v.shell_error ~= 0 then
    vim.notify("RevPR: git merge-base failed: " .. sha, vim.log.levels.ERROR)
    return
  end

  set_base(sha)
end

function M.rev_diff()
  if review_base ~= "" then
    vim.cmd("Gdiffsplit " .. review_base)
  else
    vim.cmd("Gdiffsplit")
  end
end

function M.rev_files()
  local cmd = "git diff --name-only"
  if review_base ~= "" then
    cmd = cmd .. " " .. review_base
  end

  local output = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    vim.notify("RevFiles: git diff failed: " .. output, vim.log.levels.ERROR)
    return
  end

  local files = vim.split(vim.trim(output), "\n", { trimempty = true })
  if #files == 0 then
    vim.notify("RevFiles: no changed files")
    return
  end

  local items = {}
  for _, f in ipairs(files) do
    table.insert(items, { filename = f, lnum = 1 })
  end

  vim.fn.setqflist(items, "r")
  vim.cmd("copen")
end

function M.get_base()
  return review_base
end

function M.setup()
  vim.api.nvim_create_user_command("RevPR", function(opts) M.rev_pr(opts.args) end,
    { nargs = "?", desc = "Scope to PR merge-base" })
  vim.api.nvim_create_user_command("RevBase", function(opts) M.rev_base(opts.args) end,
    { nargs = "?", desc = "Set review base ref" })
  vim.api.nvim_create_user_command("RevDiff", function() M.rev_diff() end,
    { nargs = 0, desc = "Gdiffsplit against review base" })
  vim.api.nvim_create_user_command("RevFiles", function() M.rev_files() end,
    { nargs = 0, desc = "Quickfix of changed files" })
end

return M
