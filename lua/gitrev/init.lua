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

local function trim_output(output)
  return output:gsub("%s+$", "")
end

local function run_system(cmd)
  local output = trim_output(vim.fn.system(cmd))
  return output, vim.v.shell_error
end

local function normalize_repo_url(url)
  if not url or url == "" then
    return nil
  end

  local normalized = vim.trim(url):gsub("%.git$", ""):gsub("/$", "")
  local host, path = normalized:match("^git@([^:]+):(.+)$")

  if not host then
    host, path = normalized:match("^[%w%+%-%.]+://([^/]+)/(.+)$")
  end
  if not host or not path then
    return normalized:lower()
  end

  host = host:gsub("^[^@]+@", ""):gsub(":%d+$", ""):lower()
  path = path:gsub("^/*", ""):lower()

  return host .. "/" .. path
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

local function git_commit_exists(ref)
  if not ref or ref == "" then
    return false
  end

  local _, exit_code = run_system({ "git", "cat-file", "-e", ref .. "^{commit}" })
  return exit_code == 0
end

local function get_pr_base(pr_arg)
  local cmd = { "gh", "pr", "view" }

  if pr_arg ~= "" then
    table.insert(cmd, pr_arg)
  end

  table.insert(cmd, "--json")
  table.insert(cmd, "baseRefName,baseRefOid")

  local output, exit_code = run_system(cmd)
  if exit_code ~= 0 then
    return nil, "RevPR: gh pr view failed: " .. output
  end

  local ok, data = pcall(vim.json.decode, output)
  if not ok or type(data) ~= "table" then
    return nil, "RevPR: failed to parse gh pr view output"
  end
  if not data.baseRefName or data.baseRefName == "" or not data.baseRefOid or data.baseRefOid == "" then
    return nil, "RevPR: gh pr view missing baseRefName or baseRefOid"
  end

  return data
end

local function get_repo_urls()
  local output, exit_code = run_system({ "gh", "repo", "view", "--json", "sshUrl,url" })
  if exit_code ~= 0 then
    return nil, "RevPR: gh repo view failed: " .. output
  end

  local ok, data = pcall(vim.json.decode, output)
  if not ok or type(data) ~= "table" then
    return nil, "RevPR: failed to parse gh repo view output"
  end

  local urls = {}
  if data.sshUrl and data.sshUrl ~= "" then
    table.insert(urls, normalize_repo_url(data.sshUrl))
  end
  if data.url and data.url ~= "" then
    table.insert(urls, normalize_repo_url(data.url))
  end
  if #urls == 0 then
    return nil, "RevPR: gh repo view missing repo URLs"
  end

  return urls
end

local function find_matching_remote(repo_urls)
  local output, exit_code = run_system({ "git", "remote", "-v" })
  if exit_code ~= 0 then
    return nil, "RevPR: failed to list git remotes: " .. output
  end

  local candidates = {}
  for _, url in ipairs(repo_urls) do
    candidates[url] = true
  end

  for _, line in ipairs(vim.split(output, "\n", { trimempty = true })) do
    local remote, url = line:match("^(%S+)%s+(%S+)")
    if remote and url and candidates[normalize_repo_url(url)] then
      return remote
    end
  end

  return nil, "RevPR: repo-to-remote resolution failed: could not match GitHub repo to a local remote"
end

local function fetch_base_ref(remote, base_ref_name)
  local output, exit_code = run_system({ "git", "fetch", remote, "refs/heads/" .. base_ref_name })
  if exit_code ~= 0 then
    return nil, "RevPR: git fetch failed: " .. output
  end

  return "FETCH_HEAD"
end

local function resolve_pr_base_ref(data)
  if git_commit_exists(data.baseRefOid) then
    return data.baseRefOid
  end

  local repo_urls, repo_err = get_repo_urls()
  if not repo_urls then
    return nil, repo_err
  end

  local remote, remote_err = find_matching_remote(repo_urls)
  if not remote then
    return nil, remote_err
  end

  return fetch_base_ref(remote, data.baseRefName)
end

function M.rev_pr(args)
  local pr_arg = args ~= "" and vim.trim(args) or ""
  local data, pr_err = get_pr_base(pr_arg)
  if not data then
    vim.notify(pr_err, vim.log.levels.ERROR)
    return
  end

  local base_ref, base_err = resolve_pr_base_ref(data)
  if not base_ref then
    vim.notify(base_err, vim.log.levels.ERROR)
    return
  end

  local sha, exit_code = run_system({ "git", "merge-base", "HEAD", base_ref })
  if exit_code ~= 0 then
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
  local cmd = { "git", "diff", "--name-only" }
  if review_base ~= "" then
    table.insert(cmd, review_base)
  end

  local output, exit_code = run_system(cmd)
  if exit_code ~= 0 then
    vim.notify("RevFiles: git diff failed: " .. output, vim.log.levels.ERROR)
    return
  end

  local files = vim.split(output, "\n", { trimempty = true })
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
