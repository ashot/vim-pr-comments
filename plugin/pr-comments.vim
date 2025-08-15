" Enhanced PR Comments Plugin for Vim
" Fetches GitHub PR inline comments with better formatting and caching

" Configuration variables (can be set in .vimrc)
" let g:pr_comments_max_length = 300  " Maximum comment length in quickfix (default: 300)
" let g:pr_comments_show_full = 1      " Show full comments without truncation (default: 0)
" let g:pr_comments_wrap_quickfix = 1  " Enable line wrapping in quickfix (default: 0)

" Script variables for caching
let s:cached_pr_number = ''
let s:cached_comments = []
let s:comment_details = {}

function! s:GetCurrentBranch()
  return trim(system('git branch --show-current'))
endfunction

function! s:GetPRNumber(branch)
  " Try multiple methods to find the PR
  " Method 1: Search by head branch name
  let cmd = 'gh pr list --search "head:' . a:branch . '" --json number --jq ".[0].number"'
  let pr_number = trim(system(cmd))
  
  " Method 2: If that fails, try using gh pr status for current branch
  if v:shell_error != 0 || pr_number == '' || pr_number == 'null'
    let cmd = 'gh pr status --json currentBranch --jq ".currentBranch.number"'
    let pr_number = trim(system(cmd))
  endif
  
  " Method 3: Try to get PR for current branch directly
  if v:shell_error != 0 || pr_number == '' || pr_number == 'null'
    let cmd = 'gh pr view --json number --jq ".number" 2>/dev/null'
    let pr_number = trim(system(cmd))
  endif
  
  if v:shell_error != 0 || pr_number == '' || pr_number == 'null'
    return ''
  endif
  return pr_number
endfunction

function! s:FetchPRComments(pr_number)
  " Check cache
  if s:cached_pr_number == a:pr_number && len(s:cached_comments) > 0
    echo "Using cached comments for PR #" . a:pr_number
    return s:cached_comments
  endif
  
  let repo_info = trim(system('gh repo view --json nameWithOwner -q .nameWithOwner'))
  if v:shell_error != 0
    echoerr "Failed to get repository info"
    return []
  endif
  
  let cmd = 'gh api repos/' . repo_info . '/pulls/' . a:pr_number . '/comments'
  let json_output = system(cmd)
  if v:shell_error != 0
    echoerr "Failed to fetch PR comments"
    return []
  endif
  
  try
    let comments = json_decode(json_output)
    " Update cache
    let s:cached_pr_number = a:pr_number
    let s:cached_comments = comments
    return comments
  catch
    echoerr "Failed to parse JSON response"
    return []
  endtry
endfunction

function! s:ParseDiffHunk(diff_hunk, comment)
  " Extract line number from diff hunk more accurately
  " GitHub comments are positioned relative to the diff hunk start
  " Format: @@ -old_start,old_count +new_start,new_count @@ context
  let matches = matchlist(a:diff_hunk, '@@ -\(\d\+\),\?\(\d*\) +\(\d\+\),\?\(\d*\) @@')
  if len(matches) > 3
    let hunk_start = str2nr(matches[3])
    
    " Count lines from hunk start to find actual position
    " This accounts for added/removed lines in the diff
    let lines = split(a:diff_hunk, '\n')
    let line_offset = 0
    let found_comment = 0
    
    for i in range(1, len(lines) - 1)
      let line = lines[i]
      " Skip the @@ line itself
      if line =~ '^@@'
        continue
      endif
      
      " Count non-removed lines (these exist in the new file)
      if line !~ '^-'
        let line_offset += 1
      endif
      
      " Check if we've reached the comment position
      " GitHub's position counting includes all diff lines
      if has_key(a:comment, 'original_position') && i == a:comment.original_position
        let found_comment = 1
        break
      endif
    endfor
    
    if found_comment && line_offset > 0
      return hunk_start + line_offset - 1
    else
      return hunk_start
    endif
  endif
  return 0
endfunction

function! s:ExtractCodeContext(diff_hunk, line_offset)
  " Extract a few lines of code context from the diff hunk
  let lines = split(a:diff_hunk, '\n')
  let context = []
  let target_line = 0
  
  for line in lines
    if line =~ '^@@'
      continue
    endif
    
    " Remove diff markers
    let clean_line = substitute(line, '^[+-]', '', '')
    if len(clean_line) > 0
      call add(context, clean_line)
    endif
    
    if len(context) >= 3
      break
    endif
  endfor
  
  return join(context, ' | ')
endfunction

function! s:FormatCommentForQuickfix(comment, index)
  let entry = {}
  
  " Get file path
  let entry.filename = a:comment.path
  
  " Priority for line number detection:
  " 1. 'line' - the current line in HEAD (most accurate for current code)
  " 2. Parse from diff_hunk with position info
  " 3. 'original_line' - line in the base branch
  " 4. 'start_line' - for multi-line comments
  
  let entry.lnum = 0
  
  " First try 'line' which is the position in the current version
  if has_key(a:comment, 'line') && a:comment.line != v:null
    let entry.lnum = a:comment.line
  " Then try parsing from diff hunk
  elseif has_key(a:comment, 'diff_hunk') && a:comment.diff_hunk != ''
    let entry.lnum = s:ParseDiffHunk(a:comment.diff_hunk, a:comment)
  endif
  
  " Fallback to original_line or start_line
  if entry.lnum == 0
    if has_key(a:comment, 'original_line') && a:comment.original_line != v:null
      let entry.lnum = a:comment.original_line
    elseif has_key(a:comment, 'start_line') && a:comment.start_line != v:null
      let entry.lnum = a:comment.start_line
    else
      let entry.lnum = 1
    endif
  endif
  
  " Format the comment text
  let author = has_key(a:comment.user, 'login') ? a:comment.user.login : 'Unknown'
  
  " Clean up body text
  let body = a:comment.body
  " Remove code suggestions
  let body = substitute(body, '```suggestion.*```', '[suggestion]', 'gs')
  let body = substitute(body, '```.*```', '[code]', 'gs')
  " Replace newlines with spaces
  let body = substitute(body, '\n', ' ', 'g')
  " Clean up multiple spaces
  let body = substitute(body, '\s\+', ' ', 'g')
  
  " Truncate long comments for quickfix display (configurable)
  if !exists('g:pr_comments_show_full') || !g:pr_comments_show_full
    let max_length = exists('g:pr_comments_max_length') ? g:pr_comments_max_length : 300
    if len(body) > max_length
      let body = body[0:max_length-3] . '...'
    endif
  endif
  
  let entry.text = printf("[%d] %s: %s", a:index, author, body)
  
  " Store full comment details for later retrieval
  let s:comment_details[a:index] = {
    \ 'author': author,
    \ 'body': a:comment.body,
    \ 'url': has_key(a:comment, 'html_url') ? a:comment.html_url : '',
    \ 'created_at': has_key(a:comment, 'created_at') ? a:comment.created_at : '',
    \ 'diff_hunk': has_key(a:comment, 'diff_hunk') ? a:comment.diff_hunk : '',
    \ 'line_info': printf('line=%s, original_line=%s, position=%s', 
    \   has_key(a:comment, 'line') ? string(a:comment.line) : 'null',
    \   has_key(a:comment, 'original_line') ? string(a:comment.original_line) : 'null',
    \   has_key(a:comment, 'position') ? string(a:comment.position) : 'null'),
    \ 'resolved_line': entry.lnum
    \ }
  
  " Use different types for different authors
  if author == 'Copilot'
    let entry.type = 'W'  " Warning for bot comments
  else
    let entry.type = 'E'  " Error for human reviews
  endif
  
  return entry
endfunction

function! ReplyToComment()
  " Get current quickfix item
  let qf_index = line('.') - 1
  let qf_list = getqflist()
  
  if qf_index < 0 || qf_index >= len(qf_list)
    echo "No comment selected"
    return
  endif
  
  let item = qf_list[qf_index]
  let text = item.text
  
  " Extract comment index from text
  let matches = matchlist(text, '^\[\(\d\+\)\]')
  if len(matches) > 1
    let comment_index = str2nr(matches[1])
    if comment_index > 0 && comment_index <= len(s:cached_comments)
      let comment = s:cached_comments[comment_index - 1]
      let detail = s:comment_details[comment_index]
      
      " Get the reply text from user
      let reply = input('Reply to comment (empty to cancel): ')
      if reply == ''
        echo "\nReply cancelled"
        return
      endif
      
      " Get PR number
      let pr_number = s:cached_pr_number
      if pr_number == ''
        let branch = s:GetCurrentBranch()
        let pr_number = s:GetPRNumber(branch)
      endif
      
      " Get repo info
      let repo_info = trim(system('gh repo view --json nameWithOwner -q .nameWithOwner'))
      
      " Build the reply body with context
      let reply_body = "> " . substitute(detail.body, '\n', '\n> ', 'g') . "\n\n" . reply
      
      " For inline comments, we need to use the review comments API
      " GitHub's review comment replies require creating a new review
      if has_key(comment, 'pull_request_review_id') && has_key(comment, 'id')
        " Create a proper JSON payload for the reply
        let json_body = json_encode({'body': reply})
        
        " Use gh api to post a reply to the specific comment thread
        let cmd = printf('gh api -X POST repos/%s/pulls/%s/comments/%d/replies --input -',
              \ repo_info,
              \ pr_number,
              \ comment.id)
        
        echo "\nPosting reply to inline comment..."
        
        " Write JSON to stdin of the command
        let result = system(cmd, json_body)
        
        if v:shell_error != 0
          " If replies endpoint fails, try creating a review with the comment
          echo "\nTrying review-based reply..."
          
          " Create a review that replies to this thread
          let review_json = json_encode({
                \ 'body': 'Replying to review comments',
                \ 'event': 'COMMENT',
                \ 'comments': [{
                \   'path': comment.path,
                \   'line': has_key(comment, 'line') && comment.line != v:null ? comment.line : comment.original_line,
                \   'side': has_key(comment, 'side') ? comment.side : 'RIGHT',
                \   'body': reply
                \ }]
                \ })
          
          let cmd = printf('gh api -X POST repos/%s/pulls/%s/reviews --input -',
                \ repo_info,
                \ pr_number)
          
          let result = system(cmd, review_json)
        endif
      else
        echoerr "\nCannot reply: Missing comment ID or review ID"
        return
      endif
      
      if v:shell_error == 0
        echo "\nReply posted successfully!"
        " Optionally refresh comments
        if confirm("Refresh comments to see your reply?", "&Yes\n&No", 1) == 1
          call PRComments('refresh')
        endif
      else
        echoerr "\nFailed to post reply: " . result
      endif
    endif
  endif
endfunction

function! ResolveComment()
  " Get current quickfix item
  let qf_index = line('.') - 1
  let qf_list = getqflist()
  
  if qf_index < 0 || qf_index >= len(qf_list)
    echo "No comment selected"
    return
  endif
  
  let item = qf_list[qf_index]
  let text = item.text
  
  " Extract comment index
  let matches = matchlist(text, '^\[\(\d\+\)\]')
  if len(matches) > 1
    let comment_index = str2nr(matches[1])
    if comment_index > 0 && comment_index <= len(s:cached_comments)
      let comment = s:cached_comments[comment_index - 1]
      let detail = s:comment_details[comment_index]
      
      if !has_key(comment, 'id')
        echoerr "Cannot resolve: Comment ID not found"
        return
      endif
      
      " Confirm resolution
      if confirm("Resolve this comment?", "&Yes\n&No", 2) != 1
        echo "Resolution cancelled"
        return
      endif
      
      " Get PR number
      let pr_number = s:cached_pr_number
      if pr_number == ''
        let branch = s:GetCurrentBranch()
        let pr_number = s:GetPRNumber(branch)
      endif
      
      " Get repo info
      let repo_info = trim(system('gh repo view --json nameWithOwner -q .nameWithOwner'))
      
      " GitHub doesn't have a true "resolve" API for PR review comments
      " We'll add a reply with a resolution marker
      let resolution_text = "✅ Resolved"
      
      " For inline review comments, post as a reply
      if has_key(comment, 'pull_request_review_id') && has_key(comment, 'id')
        " Create JSON payload for the resolution marker
        let json_body = json_encode({'body': resolution_text})
        
        " Try to post a reply to the specific comment thread
        let cmd = printf('gh api -X POST repos/%s/pulls/%s/comments/%d/replies --input -',
              \ repo_info,
              \ pr_number,
              \ comment.id)
        
        echo "\nMarking comment as resolved..."
        let result = system(cmd, json_body)
        
        if v:shell_error != 0
          " Fallback: Create a review with resolution comment
          echo "\nTrying review-based resolution..."
          
          let review_json = json_encode({
                \ 'body': 'Resolving review comments',
                \ 'event': 'COMMENT',
                \ 'comments': [{
                \   'path': comment.path,
                \   'line': has_key(comment, 'line') && comment.line != v:null ? comment.line : comment.original_line,
                \   'side': has_key(comment, 'side') ? comment.side : 'RIGHT',
                \   'body': resolution_text
                \ }]
                \ })
          
          let cmd = printf('gh api -X POST repos/%s/pulls/%s/reviews --input -',
                \ repo_info,
                \ pr_number)
          
          let result = system(cmd, review_json)
        endif
      else
        echoerr "\nCannot resolve: Missing comment ID or review ID"
        return
      endif
      
      if v:shell_error == 0
        echo "\nComment marked as resolved"
        " Update the display
        let item.text = "[RESOLVED] " . item.text
        call setqflist(qf_list, 'r')
      else
        echoerr "\nFailed to resolve comment: " . result
      endif
    endif
  endif
endfunction

function! ShowCommentDetail()
  " Get current quickfix item
  let qf_index = line('.') - 1
  let qf_list = getqflist()
  
  if qf_index < 0 || qf_index >= len(qf_list)
    echo "No comment selected"
    return
  endif
  
  let item = qf_list[qf_index]
  let text = item.text
  
  " Extract comment index from text
  let matches = matchlist(text, '^\[\(\d\+\)\]')
  if len(matches) > 1
    let comment_index = str2nr(matches[1])
    if has_key(s:comment_details, comment_index)
      let detail = s:comment_details[comment_index]
      
      " Create a preview window with full comment
      new
      setlocal buftype=nofile
      setlocal bufhidden=wipe
      setlocal noswapfile
      setlocal nowrap
      
      " Add content
      call append(0, ['PR Comment Details', '==================', ''])
      call append(3, 'Author: ' . detail.author)
      call append(4, 'Created: ' . detail.created_at)
      call append(5, 'URL: ' . detail.url)
      call append(6, 'Line Info: ' . detail.line_info)
      call append(7, 'Resolved to line: ' . detail.resolved_line)
      call append(8, '')
      call append(9, 'Comment:')
      call append(10, '--------')
      
      " Split body into lines
      let body_lines = split(detail.body, '\n')
      let line_num = 11
      for body_line in body_lines
        call append(line_num, body_line)
        let line_num += 1
      endfor
      
      " Add diff context if available
      if detail.diff_hunk != ''
        call append(line_num, '')
        call append(line_num + 1, 'Diff Context:')
        call append(line_num + 2, '-------------')
        let diff_lines = split(detail.diff_hunk, '\n')
        let line_num = line_num + 3
        for diff_line in diff_lines
          call append(line_num, diff_line)
          let line_num += 1
        endfor
      endif
      
      " Clean up empty first line and position cursor
      normal! ggdd
      normal! gg
      
      " Make window smaller
      resize 20
      
      " Set syntax highlighting
      setlocal filetype=markdown
      
      " Map q to close the window
      nnoremap <buffer> q :close<CR>
    endif
  endif
endfunction

function! PRComments(...)
  " Optional argument to force refresh or debug
  let force_refresh = a:0 > 0 && (a:1 == '!' || a:1 == 'refresh')
  let debug_mode = a:0 > 0 && a:1 == 'debug'
  
  if force_refresh
    let s:cached_pr_number = ''
    let s:cached_comments = []
    echo "Cache cleared, fetching fresh PR comments..."
  else
    echo "Fetching PR comments..."
  endif
  
  " Get current branch
  let branch = s:GetCurrentBranch()
  if branch == ''
    echoerr "Failed to get current git branch"
    return
  endif
  
  if debug_mode
    echo "Current branch: " . branch
  endif
  
  " Get PR number for current branch
  let pr_number = s:GetPRNumber(branch)
  if pr_number == ''
    echoerr "No PR found for branch: " . branch
    echo "Try running: gh pr list --search \"head:" . branch . "\""
    echo "Or: gh pr view"
    return
  endif
  
  echo "Found PR #" . pr_number . " for branch " . branch
  
  " Fetch comments from PR
  let comments = s:FetchPRComments(pr_number)
  if len(comments) == 0
    echo "No inline comments found in PR #" . pr_number
    return
  endif
  
  " Clear previous comment details
  let s:comment_details = {}
  
  " Format comments for quickfix
  let qf_list = []
  let index = 1
  for comment in comments
    let entry = s:FormatCommentForQuickfix(comment, index)
    if entry != {}
      call add(qf_list, entry)
      let index += 1
    endif
  endfor
  
  " Populate quickfix list
  if len(qf_list) > 0
    call setqflist(qf_list, 'r')
    call setqflist([], 'a', {'title': 'PR #' . pr_number . ' Comments (' . len(qf_list) . ' items)'})
    copen
    
    " Add local mappings in quickfix window
    augroup PRCommentsQuickfix
      autocmd!
      autocmd FileType qf nnoremap <buffer> <CR> <CR>:cclose<CR>
      autocmd FileType qf nnoremap <buffer> o <CR>
      autocmd FileType qf nnoremap <buffer> <Space> :call ShowCommentDetail()<CR>
      autocmd FileType qf nnoremap <buffer> r :call ReplyToComment()<CR>
      autocmd FileType qf nnoremap <buffer> R :call ResolveComment()<CR>
      " Enable line wrapping if configured
      if exists('g:pr_comments_wrap_quickfix') && g:pr_comments_wrap_quickfix
        autocmd FileType qf setlocal wrap linebreak
      endif
    augroup END
    
    echo "Loaded " . len(qf_list) . " comments from PR #" . pr_number 
          \ . " | Keys: Space=details, r=reply, R=resolve"
  else
    echo "Failed to parse comments from PR #" . pr_number
  endif
endfunction

" Create commands
command! -nargs=? PRComments call PRComments(<f-args>)
command! PRCommentsRefresh call PRComments('refresh')
command! PRCommentsDebug call PRComments('debug')
command! PRCommentDetail call ShowCommentDetail()
command! PRCommentReply call ReplyToComment()
command! PRCommentResolve call ResolveComment()

" Create mappings (customize as needed)
nnoremap <leader>prc :PRComments<CR>
nnoremap <leader>prr :PRCommentsRefresh<CR>

" Add quickfix navigation helpers
nnoremap ]c :cnext<CR>
nnoremap [c :cprev<CR>
nnoremap ]C :clast<CR>
nnoremap [C :cfirst<CR>