" Enhanced PR Comments Plugin for Vim
" Fetches GitHub PR inline comments with better formatting and caching

" Configuration variables (can be set in .vimrc)
" let g:pr_comments_max_length = 300  " Maximum comment length in quickfix (default: 300)
" let g:pr_comments_show_full = 1      " Show full comments without truncation (default: 0)
" let g:pr_comments_wrap_quickfix = 1  " Enable line wrapping in quickfix (default: 0)
" let g:pr_comments_show_resolved = 0  " Show resolved comments (default: 0)

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

function! s:FetchPRComments(pr_number, force_refresh)
  " Check cache unless force refresh is requested
  if !a:force_refresh && s:cached_pr_number == a:pr_number && len(s:cached_comments) > 0
    echo "Using cached comments for PR #" . a:pr_number . " (use :PRCommentsReload to refresh)"
    return s:cached_comments
  endif
  
  let repo_info = trim(system('gh repo view --json nameWithOwner -q .nameWithOwner'))
  if v:shell_error != 0
    echoerr "Failed to get repository info"
    return []
  endif
  
  " Fetch comments via REST API
  let cmd = 'gh api repos/' . repo_info . '/pulls/' . a:pr_number . '/comments'
  let json_output = system(cmd)
  if v:shell_error != 0
    echoerr "Failed to fetch PR comments"
    return []
  endif
  
  try
    let all_comments = json_decode(json_output)
    let comments = []
    
    " Fetch full thread data including replies via GraphQL
    let [owner, repo] = split(repo_info, '/')
    let query = printf('query { repository(owner:"%s", name:"%s") { pullRequest(number:%d) { reviewThreads(first:100) { nodes { id isResolved comments(first:50) { nodes { id databaseId body author { login } createdAt } } } } } } }',
          \ owner, repo, a:pr_number)
    
    let result = system('gh api graphql --field query=' . shellescape(query))
    
    if v:shell_error == 0
      try
        let data = json_decode(result)
        let threads = data.data.repository.pullRequest.reviewThreads.nodes
        
        " Build a map of thread starters and collect reply IDs to filter out
        let reply_ids = {}
        let thread_map = {}
        
        for thread in threads
          if len(thread.comments.nodes) > 0
            " First comment is the thread starter
            let thread_map[thread.comments.nodes[0].databaseId] = {
                  \ 'isResolved': thread.isResolved,
                  \ 'replies': []
                  \ }
            
            " Collect replies (all comments after the first)
            if len(thread.comments.nodes) > 1
              for i in range(1, len(thread.comments.nodes) - 1)
                let reply = thread.comments.nodes[i]
                " Mark this as a reply so we can filter it out
                let reply_ids[reply.databaseId] = 1
                
                " Add to thread starter's replies
                call add(thread_map[thread.comments.nodes[0].databaseId].replies, {
                      \ 'author': has_key(reply.author, 'login') ? reply.author.login : 'Unknown',
                      \ 'body': reply.body,
                      \ 'created_at': has_key(reply, 'createdAt') ? reply.createdAt : ''
                      \ })
              endfor
            endif
          endif
        endfor
        
        " Filter comments to only include thread starters, not replies
        for comment in all_comments
          " Skip if this is a reply to another comment
          if has_key(reply_ids, comment.id)
            continue
          endif
          
          " Add thread data if available
          if has_key(thread_map, comment.id)
            let comment.is_resolved = thread_map[comment.id].isResolved
            let comment.replies = thread_map[comment.id].replies
          else
            let comment.is_resolved = 0
            let comment.replies = []
          endif
          
          " Add to final comments list
          call add(comments, comment)
        endfor
      catch
        " If GraphQL fails, use all comments without filtering
        echo "Warning: Could not fetch thread data, showing all comments"
        let comments = all_comments
        for comment in comments
          let comment.is_resolved = 0
          let comment.replies = []
        endfor
      endtry
    else
      " If GraphQL fails, use all comments
      let comments = all_comments
      for comment in comments
        let comment.is_resolved = 0
        let comment.replies = []
      endfor
    endif
    
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

function! s:IsCommentResolved(comment)
  " Check GitHub's resolved state for the comment
  " GitHub review comments have an 'in_reply_to_id' field when they're replies
  " and a conversation can be marked as resolved
  
  " Check if comment has resolved_at field (GitHub's resolution timestamp)
  if has_key(a:comment, 'resolved_at') && a:comment.resolved_at != v:null
    return 1
  endif
  
  " Check if comment has resolved field
  if has_key(a:comment, 'resolved') && a:comment.resolved
    return 1
  endif
  
  " Check if it's part of a resolved conversation
  if has_key(a:comment, 'is_resolved') && a:comment.is_resolved
    return 1
  endif
  
  return 0
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
  
  " Build the main comment text
  let comment_text = body
  
  " Add replies if they exist - show last 2 replies
  if has_key(a:comment, 'replies') && len(a:comment.replies) > 0
    let reply_count = len(a:comment.replies)
    
    if reply_count > 2
      " Show collapsed count and last 2 replies
      let comment_text .= printf(" [...%d more...] ", reply_count - 2)
    endif
    
    " Show last 2 replies (or all if less than 3)
    let start_idx = reply_count > 2 ? reply_count - 2 : 0
    for i in range(start_idx, reply_count - 1)
      let reply = a:comment.replies[i]
      let reply_body = reply.body
      " Clean up reply body
      let reply_body = substitute(reply_body, '```suggestion.*```', '[suggestion]', 'gs')
      let reply_body = substitute(reply_body, '```.*```', '[code]', 'gs')
      let reply_body = substitute(reply_body, '\n', ' ', 'g')
      let reply_body = substitute(reply_body, '\s\+', ' ', 'g')
      
      " Truncate reply if needed
      if len(reply_body) > 60
        let reply_body = reply_body[0:57] . '...'
      endif
      
      " Add reply
      let comment_text .= printf(" [↪ %s: %s]", reply.author, reply_body)
    endfor
  endif
  
  " Truncate long comments for quickfix display (configurable)
  if !exists('g:pr_comments_show_full') || !g:pr_comments_show_full
    let max_length = exists('g:pr_comments_max_length') ? g:pr_comments_max_length : 300
    if len(comment_text) > max_length
      let comment_text = comment_text[0:max_length-3] . '...'
    endif
  endif
  
  " Check if comment is resolved
  let is_resolved = s:IsCommentResolved(a:comment)
  
  " Add resolved marker to text if resolved
  if is_resolved
    let entry.text = printf("[%d] [RESOLVED] %s: %s", a:index, author, comment_text)
  else
    let entry.text = printf("[%d] %s: %s", a:index, author, comment_text)
  endif
  
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
    \ 'resolved_line': entry.lnum,
    \ 'is_resolved': is_resolved
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
      
      " Get PR number from cache or detect it
      let pr_number = s:cached_pr_number
      if pr_number == ''
        let branch = s:GetCurrentBranch()
        let pr_number = s:GetPRNumber(branch)
        if pr_number == ''
          echoerr "Could not determine PR number"
          return
        endif
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
          " Check if error is due to pending review
          if result =~ 'pending review' || result =~ 'Unprocessable Entity'
            echo "\nDetected pending review. Creating reply with in_reply_to..."
            
            " When there's a pending review, we need to use in_reply_to parameter
            " to ensure our comment is a reply to the existing thread
            let review_comment_json = json_encode({
                  \ 'body': reply,
                  \ 'path': comment.path,
                  \ 'line': has_key(comment, 'line') && comment.line != v:null ? comment.line : comment.original_line,
                  \ 'side': has_key(comment, 'side') ? comment.side : 'RIGHT',
                  \ 'in_reply_to': comment.id
                  \ })
            
            " Post as a new review comment with in_reply_to
            let add_cmd = printf('gh api -X POST repos/%s/pulls/%s/comments --input -',
                  \ repo_info,
                  \ pr_number)
            
            let result = system(add_cmd, review_comment_json)
            
            if v:shell_error == 0
              echo "\nReply posted successfully (added to pending review)."
            else
              " No pending review found, create new one
              echo "\nCreating new review with comment..."
              let review_json = json_encode({
                    \ 'body': '',
                    \ 'event': 'PENDING',
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
              
              if v:shell_error == 0
                " Now submit it immediately
                echo "\nSubmitting review..."
                let submit_json = json_encode({
                      \ 'body': '',
                      \ 'event': 'COMMENT'
                      \ })
                
                " Get the review ID from result
                try
                  let review_data = json_decode(result)
                  if has_key(review_data, 'id')
                    let submit_cmd = printf('gh api -X POST repos/%s/pulls/%s/reviews/%d/events --input -',
                          \ repo_info,
                          \ pr_number,
                          \ review_data.id)
                    
                    let submit_result = system(submit_cmd, submit_json)
                  endif
                catch
                  " Ignore if we can't parse
                endtry
              endif
            endif
          else
            " Other error - try creating a simple review comment
            echo "\nTrying simple review comment..."
            let review_json = json_encode({
                  \ 'body': '',
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
        endif
      else
        echoerr "\nCannot reply: Missing comment ID or review ID"
        return
      endif
      
      if v:shell_error == 0
        echo "\nReply posted successfully!"
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
      
      " No confirmation - just resolve
      
      " Get PR number from cache or detect it
      let pr_number = s:cached_pr_number
      if pr_number == ''
        let branch = s:GetCurrentBranch()
        let pr_number = s:GetPRNumber(branch)
        if pr_number == ''
          echoerr "Could not determine PR number"
          return
        endif
      endif
      
      " Get repo info
      let repo_info = trim(system('gh repo view --json nameWithOwner -q .nameWithOwner'))
      
      " GitHub's resolve functionality requires the thread ID, not the comment ID
      " We need to fetch the thread ID first
      if has_key(comment, 'id') && has_key(comment, 'pull_request_review_id')
        " Get repo info
        let [owner, repo] = split(repo_info, '/')
        
        " First, get the thread ID for this comment
        let query = printf('query { repository(owner:"%s", name:"%s") { pullRequest(number:%d) { reviewThreads(first:100) { nodes { id isResolved comments(first:100) { nodes { id databaseId } } } } } } }',
              \ owner, repo, pr_number)
        
        echo "\nFinding review thread..."
        let result = system('gh api graphql --field query=' . shellescape(query))
        
        if v:shell_error == 0
          try
            let data = json_decode(result)
            let threads = data.data.repository.pullRequest.reviewThreads.nodes
            let thread_id = ''
            
            " Find the thread containing our comment
            for thread in threads
              for thread_comment in thread.comments.nodes
                if thread_comment.databaseId == comment.id
                  let thread_id = thread.id
                  let is_already_resolved = thread.isResolved
                  break
                endif
              endfor
              if thread_id != ''
                break
              endif
            endfor
            
            if thread_id == ''
              echoerr "\nCould not find thread for this comment"
              return
            endif
            
            if is_already_resolved
              echo "\nComment thread is already resolved"
              return
            endif
            
            " Now resolve the thread
            let mutation = json_encode({
                  \ 'query': 'mutation($threadId: ID!) { resolveReviewThread(input: {threadId: $threadId}) { thread { isResolved } } }',
                  \ 'variables': {'threadId': thread_id}
                  \ })
            
            echo "\nResolving comment thread..."
            let result = system('gh api graphql --input -', mutation)
            
            if v:shell_error != 0
              echoerr "\nFailed to resolve thread. You may not have permission to resolve this comment."
              return
            endif
          catch
            echoerr "\nFailed to parse GraphQL response"
            return
          endtry
        else
          echoerr "\nFailed to fetch thread information"
          return
        endif
      else
        echoerr "\nCannot resolve: This doesn't appear to be a review comment"
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
      
      " Add replies if available
      let comment = s:cached_comments[comment_index - 1]
      if has_key(comment, 'replies') && len(comment.replies) > 0
        call append(line_num, '')
        call append(line_num + 1, 'Replies:')
        call append(line_num + 2, '--------')
        let line_num = line_num + 3
        
        for reply in comment.replies
          call append(line_num, '')
          call append(line_num + 1, '  ➤ ' . reply.author . ' (' . reply.created_at . '):')
          let reply_lines = split(reply.body, '\n')
          let line_num = line_num + 2
          for reply_line in reply_lines
            call append(line_num, '    ' . reply_line)
            let line_num += 1
          endfor
        endfor
      endif
      
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
  " Optional argument to force refresh, debug, or show all
  let force_refresh = a:0 > 0 && (a:1 == 'reload' || a:1 == 'refresh' || a:1 == '!')
  let debug_mode = a:0 > 0 && a:1 == 'debug'
  let show_all = a:0 > 0 && (a:1 == 'all' || a:1 == 'show-resolved')
  
  if force_refresh
    echo "Reloading PR comments from GitHub..."
  else
    echo "Opening PR comments..."
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
  
  " Fetch comments from PR (with force_refresh flag)
  let comments = s:FetchPRComments(pr_number, force_refresh)
  if len(comments) == 0
    echo "No inline comments found in PR #" . pr_number
    return
  endif
  
  " Clear previous comment details
  let s:comment_details = {}
  
  " Determine if we should show resolved comments
  let show_resolved = show_all || (exists('g:pr_comments_show_resolved') && g:pr_comments_show_resolved)
  
  " Format comments for quickfix
  let qf_list = []
  let index = 1
  let resolved_count = 0
  let total_count = 0
  
  for comment in comments
    let entry = s:FormatCommentForQuickfix(comment, index)
    if entry != {}
      let total_count += 1
      " Check if this comment is resolved
      if s:comment_details[index].is_resolved
        let resolved_count += 1
        " Only add resolved comments if we're showing them
        if show_resolved
          call add(qf_list, entry)
        endif
      else
        " Always add unresolved comments
        call add(qf_list, entry)
      endif
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
      autocmd FileType qf nnoremap <buffer> U :call UnresolveComment()<CR>
      " Enable line wrapping if configured
      if exists('g:pr_comments_wrap_quickfix') && g:pr_comments_wrap_quickfix
        autocmd FileType qf setlocal wrap linebreak
      endif
    augroup END
    
    " Build status message
    let status_msg = "Loaded " . len(qf_list) . " comments from PR #" . pr_number
    if resolved_count > 0
      if show_resolved
        let status_msg .= " (including " . resolved_count . " resolved)"
      else
        let status_msg .= " (" . resolved_count . " resolved hidden, use :PRCommentsAll to show)"
      endif
    endif
    let status_msg .= " | Keys: Space=details, r=reply, R=resolve, U=unresolve"
    echo status_msg
  else
    if total_count > 0 && len(qf_list) == 0
      echo "All " . total_count . " comments are resolved! Use :PRCommentsAll to show them."
    else
      echo "Failed to parse comments from PR #" . pr_number
    endif
  endif
endfunction

function! UnresolveComment()
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
      
      if !has_key(comment, 'id') || !has_key(comment, 'pull_request_review_id')
        echoerr "Cannot unresolve: This doesn't appear to be a review comment"
        return
      endif
      
      " No confirmation - just unresolve
      
      " Get PR number and repo info
      let pr_number = s:cached_pr_number
      if pr_number == ''
        let branch = s:GetCurrentBranch()
        let pr_number = s:GetPRNumber(branch)
      endif
      
      let repo_info = trim(system('gh repo view --json nameWithOwner -q .nameWithOwner'))
      let [owner, repo] = split(repo_info, '/')
      
      " First, get the thread ID for this comment
      let query = printf('query { repository(owner:"%s", name:"%s") { pullRequest(number:%d) { reviewThreads(first:100) { nodes { id isResolved comments(first:100) { nodes { id databaseId } } } } } } }',
            \ owner, repo, pr_number)
      
      echo "\nFinding review thread..."
      let result = system('gh api graphql --field query=' . shellescape(query))
      
      if v:shell_error == 0
        try
          let data = json_decode(result)
          let threads = data.data.repository.pullRequest.reviewThreads.nodes
          let thread_id = ''
          let is_already_unresolved = 0
          
          " Find the thread containing our comment
          for thread in threads
            for thread_comment in thread.comments.nodes
              if thread_comment.databaseId == comment.id
                let thread_id = thread.id
                let is_already_unresolved = !thread.isResolved
                break
              endif
            endfor
            if thread_id != ''
              break
            endif
          endfor
          
          if thread_id == ''
            echoerr "\nCould not find thread for this comment"
            return
          endif
          
          if is_already_unresolved
            echo "\nComment thread is already unresolved"
            return
          endif
          
          " Now unresolve the thread
          let mutation = json_encode({
                \ 'query': 'mutation($threadId: ID!) { unresolveReviewThread(input: {threadId: $threadId}) { thread { isResolved } } }',
                \ 'variables': {'threadId': thread_id}
                \ })
          
          echo "\nUnresolving comment thread..."
          let result = system('gh api graphql --input -', mutation)
          
          if v:shell_error == 0
            echo "\nComment marked as unresolved"
            " Update the display to remove [RESOLVED] marker
            let item.text = substitute(item.text, '\[RESOLVED\] ', '', '')
            call setqflist(qf_list, 'r')
          else
            echoerr "\nFailed to unresolve thread. You may not have permission."
          endif
        catch
          echoerr "\nFailed to parse GraphQL response"
        endtry
      else
        echoerr "\nFailed to fetch thread information"
      endif
    endif
  endif
endfunction

" Create commands
command! -nargs=? PRComments call PRComments(<f-args>)
command! PRCommentsOpen call PRComments()
command! PRCommentsReload call PRComments('reload')
command! PRCommentsRefresh call PRComments('refresh')
command! PRCommentsAll call PRComments('all')
command! PRCommentsDebug call PRComments('debug')
command! PRCommentDetail call ShowCommentDetail()
command! PRCommentReply call ReplyToComment()
command! PRCommentResolve call ResolveComment()
command! PRCommentUnresolve call UnresolveComment()

" Create mappings (customize as needed)
nnoremap <leader>prc :PRCommentsOpen<CR>
nnoremap <leader>prr :PRCommentsReload<CR>
nnoremap <leader>pra :PRCommentsAll<CR>

" Add quickfix navigation helpers
nnoremap ]c :cnext<CR>
nnoremap [c :cprev<CR>
nnoremap ]C :clast<CR>
nnoremap [C :cfirst<CR>
