# PR Comments for Vim

A Vim plugin to fetch GitHub PR inline comments and display them in the quickfix list for easy navigation.

## Features

- Fetches inline comments from GitHub PRs using `gh` CLI
- Displays comments in Vim's quickfix list
- Jump directly to file and line where comment was made
- Shows comment author and text
- Caches comments to avoid repeated API calls
- Full comment detail view with diff context

## Requirements

- Vim 8.0+ or Neovim
- `gh` CLI tool installed and authenticated
- Git repository with a GitHub remote

## Installation

### With Vundle
Already installed in `~/.vim/bundle/pr-comments/`

### Manual Installation
```bash
mkdir -p ~/.vim/plugin
cp plugin/pr-comments.vim ~/.vim/plugin/
```

## Configuration

Add these to your `.vimrc` to customize the plugin:

```vim
" Maximum comment length in quickfix (default: 300 chars)
let g:pr_comments_max_length = 500

" Show full comments without truncation (default: 0)
let g:pr_comments_show_full = 1

" Enable line wrapping in quickfix window (default: 0)
let g:pr_comments_wrap_quickfix = 1
```

## Usage

### Commands

- `:PRComments` - Fetch PR comments for current branch (uses cache if available)
- `:PRCommentsRefresh` - Force refresh, clearing cache
- `:PRCommentsDebug` - Show debug information for troubleshooting
- `:PRCommentDetail` - Show full comment details in preview window
- `:PRCommentReply` - Reply to the selected comment
- `:PRCommentResolve` - Mark comment as resolved

### Default Mappings

- `<leader>prc` - Fetch PR comments
- `<leader>prr` - Refresh PR comments (force refresh)
- `]c` - Next comment in quickfix
- `[c` - Previous comment in quickfix
- `]C` - Last comment
- `[C` - First comment

### Quickfix Window Mappings

- `<CR>` - Jump to file/line and close quickfix
- `o` - Jump to file/line (keep quickfix open)
- `<Space>` - Show full comment details in preview window
- `r` - Reply to the selected comment
- `R` - Resolve the selected comment (adds a ✅ resolved marker)
- `q` - Close detail window (when in detail view)

## How It Works

1. Detects current Git branch
2. Finds associated PR using `gh pr list`
3. Fetches inline comments via GitHub API
4. Parses comments and extracts file paths and line numbers
5. Populates Vim's quickfix list
6. Allows navigation to exact comment locations

## Comment Types

- `E` (Error) - Human reviewer comments
- `W` (Warning) - Bot comments (e.g., Copilot suggestions)

## Tips

- Comments are cached per PR to improve performance
- Use `:PRCommentsRefresh` to get latest comments after new ones are added
- The quickfix title shows PR number and comment count
- Press `<Space>` on any comment in quickfix to see full details including:
  - Full comment text (not truncated)
  - Author and timestamp
  - Diff context
  - URL to GitHub comment

## Troubleshooting

- **"No PR found for branch"** - Ensure your branch has an open PR on GitHub
- **"Failed to fetch PR comments"** - Check that `gh` CLI is authenticated: `gh auth status`
- **Line numbers incorrect** - The plugin uses the line numbers from when the comment was made; if the file has changed significantly, positions may be off

## License

MIT