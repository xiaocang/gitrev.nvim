# gitrev.nvim

A lightweight Neovim plugin for reviewing Git changes. Sets a "review base" ref and integrates with [vim-gitgutter](https://github.com/airblade/vim-gitgutter) and [vim-fugitive](https://github.com/tpope/vim-fugitive) to show diffs against it.

## Requirements

- [vim-gitgutter](https://github.com/airblade/vim-gitgutter) — gutter signs against review base
- [vim-fugitive](https://github.com/tpope/vim-fugitive) — `:RevDiff` uses `Gdiffsplit`
- [gh CLI](https://cli.github.com/) — `:RevPR` uses `gh pr view`

## Installation

lazy.nvim:

```lua
{
  "xiaocang/gitrev.nvim",
  config = function()
    require("gitrev").setup()
  end,
}
```

## Commands

| Command | Description |
|---------|-------------|
| `:RevBase [ref]` | Set the review base to `ref`. No argument resets to HEAD. |
| `:RevPR [pr]` | Set the review base to the merge-base of the current (or specified) PR. |
| `:RevDiff` | Open a diff split against the review base (uses fugitive). |
| `:RevFiles` | Populate the quickfix list with files changed since the review base. |

## Usage

```vim
" Review current PR's changes
:RevPR

" Review a specific PR
:RevPR 42

" Set an arbitrary base ref
:RevBase origin/main

" Reset to default (HEAD)
:RevBase

" Open diff for current file against review base
:RevDiff

" List all changed files in quickfix
:RevFiles
```

## Uninstall

This plugin is safe to remove at any time. It has no side effects beyond the four commands it registers. Simply remove it from your plugin manager config.
