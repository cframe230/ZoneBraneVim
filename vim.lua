-- Vim mode for ZeroBrane Studio.
-- Copyright (c) 2026 Fermín Chen Zheng. MIT license.

local VERSION = "0.3.0"

local states = setmetatable({}, {__mode = "k"})
local charhandlers = setmetatable({}, {__mode = "k"})

local runtime = {
  config = {},
  enabled = true,
  registered = false,
  register = {text = "", linewise = false},
  registers = {},
  lastsearch = nil,
  searchforward = true,
  ctrlvhotkey = nil,
  lastchange = nil,
  replaying = false,
  commandline = nil,
  commandhistory = {},
  searchhistory = {},
  alternatedocument = nil,
  laststatus = nil,
}

local function clamp(value, low, high)
  if value < low then return low end
  if value > high then return high end
  return value
end

local function countvalue(value)
  local count = tonumber(value)
  return count and math.max(1, count) or 1
end

local function repeattext(value, count)
  local values = {}
  for _ = 1, count do values[#values + 1] = value end
  return table.concat(values)
end

local function positionafter(editor, pos)
  local length = editor:GetLength()
  if pos >= length then return length end
  return editor:PositionAfter(pos)
end

local function positionbefore(editor, pos)
  if pos <= 0 then return 0 end
  return editor:PositionBefore(pos)
end

local function linecount(editor)
  return math.max(1, editor:GetLineCount())
end

local function linestart(editor, line)
  line = clamp(line, 0, linecount(editor) - 1)
  return editor:PositionFromLine(line)
end

local function lineend(editor, line)
  line = clamp(line, 0, linecount(editor) - 1)
  return editor:GetLineEndPosition(line)
end

local function lastcharonline(editor, line)
  local first, last = linestart(editor, line), lineend(editor, line)
  return last > first and positionbefore(editor, last) or first
end

local function inclusiveend(editor, pos)
  local line = editor:LineFromPosition(pos)
  if pos >= lineend(editor, line) then return pos end
  return positionafter(editor, pos)
end

local function clampnormal(editor, pos)
  pos = clamp(pos, 0, editor:GetLength())
  local line = editor:LineFromPosition(pos)
  return math.min(pos, lastcharonline(editor, line))
end

local function gotonormal(editor, pos)
  pos = clampnormal(editor, pos)
  editor:GotoPos(pos)
  editor:EnsureCaretVisible()
  return pos
end

local function chart(editor, pos)
  if pos < 0 or pos >= editor:GetLength() then return "" end
  return editor:GetTextRange(pos, positionafter(editor, pos))
end

local function charclass(value)
  if value == "" then return "eof" end
  if value:match("^%s$") then return "space" end
  local byte = value:byte(1)
  if value:match("^[%w_]$") or (byte and byte >= 128) then return "word" end
  return "punct"
end

local function firstnonblank(editor, line)
  local pos, finish = linestart(editor, line), lineend(editor, line)
  while pos < finish do
    local value = chart(editor, pos)
    if value ~= " " and value ~= "\t" then break end
    pos = positionafter(editor, pos)
  end
  return pos < finish and pos or linestart(editor, line)
end

local function leadingindent(editor, line)
  local first, finish = linestart(editor, line), lineend(editor, line)
  local pos = first
  while pos < finish do
    local value = chart(editor, pos)
    if value ~= " " and value ~= "\t" then break end
    pos = positionafter(editor, pos)
  end
  return editor:GetTextRange(first, pos)
end

local function geteol(editor)
  local mode = editor.GetEOLMode and editor:GetEOLMode() or nil
  local stc = rawget(_G, "wxstc")
  if stc and mode == stc.wxSTC_EOL_CRLF then return "\r\n" end
  if stc and mode == stc.wxSTC_EOL_CR then return "\r" end
  return "\n"
end

local function withundo(editor, callback)
  editor:BeginUndoAction()
  local ok, first, second = pcall(callback)
  editor:EndUndoAction()
  if not ok then error(first, 0) end
  return first, second
end

local function readonly(editor)
  return editor.GetReadOnly and editor:GetReadOnly() or false
end

local function resetpending(state)
  state.count = ""
  state.pending = nil
end

local function newstate(editor)
  local mode = runtime.config.startinsert and "insert" or "normal"
  local state = {
    mode = mode,
    count = "",
    pending = nil,
    goalcol = nil,
    visualanchor = nil,
    visualcursor = nil,
    lastfind = nil,
    undoopen = false,
    message = nil,
    caretperiod = editor.GetCaretPeriod and editor:GetCaretPeriod() or nil,
    repeatcandidate = nil,
    selectedregister = nil,
    blockinsert = nil,
  }
  states[editor] = state
  return state
end

local function getstate(editor)
  return states[editor] or newstate(editor)
end

local positionatcolumn

local function pendinglabel(state)
  local pending = state.pending
  if not pending then
    return (state.selectedregister and ('"' .. state.selectedregister) or "") .. state.count
  end
  if pending.kind == "operator" then
    local suffix = pending.post or ""
    if pending.stage == "g" then suffix = suffix .. "g" end
    if pending.stage == "char" then suffix = suffix .. (pending.motion or "") end
    return (pending.pre == 1 and "" or tostring(pending.pre)) .. pending.op .. suffix
  end
  if pending.kind == "prefix" then return (pending.counttext or "") .. pending.key end
  if pending.kind == "char" then return (pending.counttext or "") .. pending.action end
  if pending.kind == "register" then return '"' end
  return ""
end

local function modelabel(state)
  if state.mode == "insert" then return "-- INSERT --" end
  if state.mode == "replace" then return "-- REPLACE --" end
  if state.mode == "visual" then return "-- VISUAL --" end
  if state.mode == "visual_line" then return "-- VISUAL LINE --" end
  if state.mode == "visual_block" then return "-- VISUAL BLOCK --" end
  if state.mode == "command" then return ":" end
  if state.mode == "search" then return "/" end
  local pending = pendinglabel(state)
  return pending ~= "" and ("-- NORMAL --  " .. pending) or "-- NORMAL --"
end

local function setstatus(editor, state, message)
  state.message = message
  if runtime.config.status == false or not rawget(_G, "ide") then return end
  local text = message or modelabel(state)
  runtime.laststatus = text
  ide:SetStatus(text, 0)
end

local function setcaret(editor, state)
  if editor.SetCaretStyle then
    local style = (state.mode == "insert" or state.mode == "replace") and 1 or 2
    pcall(function() editor:SetCaretStyle(style) end)
  end
  if runtime.config.cursorblink ~= true and editor.SetCaretPeriod then
    pcall(function() editor:SetCaretPeriod(0) end)
  end
end

local function endinsertundo(editor, state)
  if state.undoopen then
    editor:EndUndoAction()
    state.undoopen = false
  end
end

local function begininsertundo(editor, state)
  if not state.undoopen then
    editor:BeginUndoAction()
    state.undoopen = true
  end
end

local function setmode(editor, state, mode)
  if (state.mode == "insert" or state.mode == "replace")
  and mode ~= "insert" and mode ~= "replace" then
    endinsertundo(editor, state)
  end
  if state.mode == "replace" and mode ~= "replace" and editor.SetOvertype then
    editor:SetOvertype(false)
  end

  state.mode = mode
  state.message = nil
  state.goalcol = nil
  resetpending(state)

  if mode == "insert" or mode == "replace" then
    if editor.SetSelectionMode and rawget(_G, "wxstc") then
      editor:SetSelectionMode(wxstc.wxSTC_SEL_STREAM)
    end
    if mode == "replace" and editor.SetOvertype then editor:SetOvertype(true) end
    begininsertundo(editor, state)
  elseif mode == "normal" then
    state.visualanchor, state.visualcursor = nil, nil
    state.selectedregister = nil
    if editor.SetSelectionMode and rawget(_G, "wxstc") then
      editor:SetSelectionMode(wxstc.wxSTC_SEL_STREAM)
    end
    editor:SetEmptySelection(clampnormal(editor, editor:GetCurrentPos()))
  end

  setcaret(editor, state)
  setstatus(editor, state)
end

local function leaveinsert(editor, state)
  local pos = editor:GetCurrentPos()
  local candidate = state.repeatcandidate
  if candidate and candidate.insertbefore and not runtime.replaying then
    local before, after = candidate.insertbefore, editor:GetText()
    local prefix, limit = 0, math.min(#before, #after)
    while prefix < limit and before:byte(prefix + 1) == after:byte(prefix + 1) do
      prefix = prefix + 1
    end
    while prefix > 0 do
      local b1, b2 = before:byte(prefix + 1), after:byte(prefix + 1)
      if (not b1 or b1 < 128 or b1 >= 192) and (not b2 or b2 < 128 or b2 >= 192) then break end
      prefix = prefix - 1
    end
    local suffix = 0
    while suffix < #before - prefix and suffix < #after - prefix
    and before:byte(#before - suffix) == after:byte(#after - suffix) do
      suffix = suffix + 1
    end
    while suffix > 0 do
      local b1 = before:byte(#before - suffix + 1)
      local b2 = after:byte(#after - suffix + 1)
      if (not b1 or b1 < 128 or b1 >= 192) and (not b2 or b2 < 128 or b2 >= 192) then break end
      suffix = suffix - 1
    end
    candidate.insertdelta = {
      offset = prefix - candidate.insertorigin,
      delete = #before - prefix - suffix,
      text = after:sub(prefix + 1, #after - suffix),
      caretoffset = pos - candidate.insertorigin,
    }
    runtime.registers["."] = {
      text = candidate.insertdelta.text,
      linewise = false,
      blockwise = false,
    }
    local blockinsert = state.blockinsert
    state.blockinsert = nil
    if blockinsert and candidate.insertdelta.text ~= ""
    and not candidate.insertdelta.text:find("[\r\n]") then
      for _, line in ipairs(blockinsert.lines) do
        if line ~= blockinsert.primary then
          local insert = positionatcolumn(editor, line, blockinsert.column, true)
          editor:InsertText(insert, candidate.insertdelta.text)
        end
      end
    end
  end
  local start = linestart(editor, editor:LineFromPosition(pos))
  if pos > start then pos = positionbefore(editor, pos) end
  setmode(editor, state, "normal")
  gotonormal(editor, pos)
end

local function enterinsert(editor, state, pos, replace)
  editor:GotoPos(clamp(pos, 0, editor:GetLength()))
  if state.repeatcandidate and not runtime.replaying then
    state.repeatcandidate.insertbefore = editor:GetText()
    state.repeatcandidate.insertorigin = editor:GetCurrentPos()
  end
  setmode(editor, state, replace and "replace" or "insert")
end

local function beginchange(editor, state, callback, pos)
  editor:BeginUndoAction()
  state.undoopen = true
  local ok, err = pcall(callback)
  if not ok then
    endinsertundo(editor, state)
    error(err, 0)
  end
  enterinsert(editor, state, pos or editor:GetCurrentPos(), false)
end

local function refreshvisual(editor, state)
  local anchor, cursor = state.visualanchor, state.visualcursor
  if not anchor or not cursor then return end
  anchor, cursor = clampnormal(editor, anchor), clampnormal(editor, cursor)
  state.visualanchor, state.visualcursor = anchor, cursor

  if state.mode == "visual_block" then
    if editor.SetSelectionMode and rawget(_G, "wxstc") then
      editor:SetSelectionMode(wxstc.wxSTC_SEL_RECTANGLE)
    end
    if editor.SetRectangularSelectionAnchor then editor:SetRectangularSelectionAnchor(anchor) end
    if editor.SetRectangularSelectionCaret then editor:SetRectangularSelectionCaret(cursor) end
  elseif state.mode == "visual_line" then
    if editor.SetSelectionMode and rawget(_G, "wxstc") then
      editor:SetSelectionMode(wxstc.wxSTC_SEL_LINES)
    end
    local first = math.min(editor:LineFromPosition(anchor), editor:LineFromPosition(cursor))
    local last = math.max(editor:LineFromPosition(anchor), editor:LineFromPosition(cursor))
    local finish = last + 1 < linecount(editor) and linestart(editor, last + 1) or editor:GetLength()
    editor:SetSelection(linestart(editor, first), finish)
  elseif cursor >= anchor then
    if editor.SetSelectionMode and rawget(_G, "wxstc") then
      editor:SetSelectionMode(wxstc.wxSTC_SEL_STREAM)
    end
    editor:SetSelection(anchor, inclusiveend(editor, cursor))
  else
    if editor.SetSelectionMode and rawget(_G, "wxstc") then
      editor:SetSelectionMode(wxstc.wxSTC_SEL_STREAM)
    end
    editor:SetSelection(inclusiveend(editor, anchor), cursor)
  end
  editor:EnsureCaretVisible()
end

local function entervisual(editor, state, linewise)
  local pos = clampnormal(editor, editor:GetCurrentPos())
  state.mode = linewise and "visual_line" or "visual"
  state.visualanchor, state.visualcursor = pos, pos
  resetpending(state)
  setcaret(editor, state)
  refreshvisual(editor, state)
  setstatus(editor, state)
end

local function entervisualblock(editor, state)
  local pos = clampnormal(editor, editor:GetCurrentPos())
  state.mode = "visual_block"
  state.visualanchor, state.visualcursor = pos, pos
  resetpending(state)
  setcaret(editor, state)
  refreshvisual(editor, state)
  setstatus(editor, state)
end

local function visualblockranges(editor, state)
  local anchor, cursor = state.visualanchor, state.visualcursor
  local firstline = math.min(editor:LineFromPosition(anchor), editor:LineFromPosition(cursor))
  local lastline = math.max(editor:LineFromPosition(anchor), editor:LineFromPosition(cursor))
  local firstcol = math.min(editor:GetColumn(anchor), editor:GetColumn(cursor))
  local lastcol = math.max(editor:GetColumn(anchor), editor:GetColumn(cursor))
  local ranges = {}
  for line = firstline, lastline do
    local from = editor:FindColumn(line, firstcol)
    local actualcol = editor:GetColumn(from)
    local finish = from
    if actualcol >= firstcol and from < lineend(editor, line) then
      local lastpos = editor:FindColumn(line, lastcol)
      finish = lastpos < lineend(editor, line) and positionafter(editor, lastpos)
        or lineend(editor, line)
    end
    ranges[#ranges + 1] = {line = line, from = from, finish = finish}
  end
  return ranges, firstline, lastline, firstcol, lastcol
end

local function visualrange(editor, state)
  local anchor, cursor = state.visualanchor, state.visualcursor
  if state.mode == "visual_line" then
    local first = math.min(editor:LineFromPosition(anchor), editor:LineFromPosition(cursor))
    local last = math.max(editor:LineFromPosition(anchor), editor:LineFromPosition(cursor))
    local finish = last + 1 < linecount(editor) and linestart(editor, last + 1) or editor:GetLength()
    return linestart(editor, first), finish, true, first, last
  end
  local first, last = math.min(anchor, cursor), math.max(anchor, cursor)
  return first, inclusiveend(editor, last), false,
    editor:LineFromPosition(first), editor:LineFromPosition(last)
end

local function horizontal(editor, pos, direction, count)
  local line = editor:LineFromPosition(pos)
  local first, last = linestart(editor, line), lastcharonline(editor, line)
  local moved = 0
  for _ = 1, count do
    if direction < 0 then
      if pos <= first then break end
      pos = positionbefore(editor, pos)
    else
      if pos >= last then break end
      pos = positionafter(editor, pos)
    end
    moved = moved + 1
  end
  return pos, moved
end

local function afteroncurrentline(editor, pos)
  return pos < lineend(editor, editor:LineFromPosition(pos)) and positionafter(editor, pos) or pos
end

local function vertical(editor, state, pos, direction, count)
  local source = editor:LineFromPosition(pos)
  if state.goalcol == nil then state.goalcol = editor:GetColumn(pos) end
  local target = clamp(source + direction * count, 0, linecount(editor) - 1)
  local found = editor:FindColumn(target, state.goalcol)
  return clampnormal(editor, found)
end

local function screenvertical(editor, state, pos, direction, amount)
  if not editor.VisibleFromDocLine or not editor.DocLineFromVisible then
    return vertical(editor, state, pos, direction, amount)
  end
  if state.goalcol == nil then state.goalcol = editor:GetColumn(pos) end
  local currentline = editor:LineFromPosition(pos)
  local visible = editor:VisibleFromDocLine(currentline)
  local target = math.max(0, visible + direction * amount)
  local line = clamp(editor:DocLineFromVisible(target), 0, linecount(editor) - 1)
  return clampnormal(editor, editor:FindColumn(line, state.goalcol))
end

local function wordforward(editor, pos, count, big)
  local length = editor:GetLength()
  for _ = 1, count do
    if pos >= length then break end
    local class = charclass(chart(editor, pos))
    if class == "space" then
      while pos < length and charclass(chart(editor, pos)) == "space" do
        pos = positionafter(editor, pos)
      end
    else
      while pos < length do
        local nextpos = positionafter(editor, pos)
        if nextpos >= length then pos = length break end
        local nextclass = charclass(chart(editor, nextpos))
        if nextclass == "space" or (not big and nextclass ~= class) then
          pos = nextpos
          break
        end
        pos = nextpos
      end
      while pos < length and charclass(chart(editor, pos)) == "space" do
        pos = positionafter(editor, pos)
      end
    end
  end
  return math.min(pos, length)
end

local function wordbackward(editor, pos, count, big)
  for _ = 1, count do
    if pos <= 0 then break end
    pos = positionbefore(editor, pos)
    while pos > 0 and charclass(chart(editor, pos)) == "space" do
      pos = positionbefore(editor, pos)
    end
    local class = charclass(chart(editor, pos))
    while pos > 0 do
      local previous = positionbefore(editor, pos)
      local previousclass = charclass(chart(editor, previous))
      if previousclass == "space" or (not big and previousclass ~= class) then break end
      pos = previous
    end
  end
  return pos
end

local function wordend(editor, pos, count, big)
  local length = editor:GetLength()
  for iteration = 1, count do
    if pos >= length then break end
    if iteration > 1 then pos = positionafter(editor, pos) end
    while pos < length and charclass(chart(editor, pos)) == "space" do
      pos = positionafter(editor, pos)
    end
    if pos >= length then break end
    local class = charclass(chart(editor, pos))
    while true do
      local nextpos = positionafter(editor, pos)
      if nextpos >= length then break end
      local nextclass = charclass(chart(editor, nextpos))
      if nextclass == "space" or (not big and nextclass ~= class) then break end
      pos = nextpos
    end
  end
  return math.min(pos, length)
end

local function paragraph(editor, pos, direction, count)
  local line = editor:LineFromPosition(pos)
  for _ = 1, count do
    line = clamp(line + direction, 0, linecount(editor) - 1)
    while line > 0 and line < linecount(editor) - 1 do
      if lineend(editor, line) == linestart(editor, line) then break end
      line = line + direction
    end
  end
  return linestart(editor, line)
end

local function findchar(editor, pos, kind, needle, count)
  local forward = kind == "f" or kind == "t"
  local line = editor:LineFromPosition(pos)
  local first, finish = linestart(editor, line), lineend(editor, line)
  local found = pos
  for _ = 1, count do
    local scan = forward and positionafter(editor, found) or positionbefore(editor, found)
    local match = nil
    while scan >= first and scan < finish do
      if chart(editor, scan) == needle then match = scan break end
      if forward then
        local nextpos = positionafter(editor, scan)
        if nextpos == scan then break end
        scan = nextpos
      else
        if scan == first then break end
        scan = positionbefore(editor, scan)
      end
    end
    if not match then return nil end
    found = match
  end
  if kind == "t" then found = positionbefore(editor, found) end
  if kind == "T" then found = positionafter(editor, found) end
  return found
end

local function bracketmatch(editor, pos)
  local pairs = {['('] = true, [')'] = true, ['['] = true, [']'] = true,
    ['{'] = true, ['}'] = true, ['<'] = true, ['>'] = true}
  local linefinish = lineend(editor, editor:LineFromPosition(pos))
  while pos < linefinish and not pairs[chart(editor, pos)] do
    pos = positionafter(editor, pos)
  end
  if not pairs[chart(editor, pos)] or not editor.BraceMatch then return nil end
  local match = editor:BraceMatch(pos)
  return match and match >= 0 and match or nil
end

local function resolvemotion(editor, state, key, count, argument, hadcount)
  local invisual = state.mode == "visual" or state.mode == "visual_line"
    or state.mode == "visual_block"
  local pos = invisual and state.visualcursor or editor:GetCurrentPos()
  local result = {pos = pos, inclusive = false, linewise = false, vertical = false,
    allowemptychange = false}

  if key == "h" or key == "<Left>" or key == "<BS>" then
    result.pos = horizontal(editor, pos, -1, count)
  elseif key == "l" or key == "<Right>" or key == " " then
    local moved
    result.pos, moved = horizontal(editor, pos, 1, count)
    if moved < count then result.inclusive = true end
  elseif key == "j" or key == "<Down>" or key == "<CR>" then
    result.pos = vertical(editor, state, pos, 1, count)
    result.linewise, result.vertical = true, true
  elseif key == "k" or key == "<Up>" then
    result.pos = vertical(editor, state, pos, -1, count)
    result.linewise, result.vertical = true, true
  elseif key == "w" or key == "W" then
    result.pos = wordforward(editor, pos, count, key == "W")
    result.allowemptychange = true
  elseif key == "b" or key == "B" then
    result.pos = wordbackward(editor, pos, count, key == "B")
  elseif key == "e" or key == "E" then
    result.pos = wordend(editor, pos, count, key == "E")
    result.inclusive, result.allowemptychange = true, true
  elseif key == "0" or key == "<Home>" then
    result.pos = linestart(editor, editor:LineFromPosition(pos))
  elseif key == "^" then
    result.pos = firstnonblank(editor, editor:LineFromPosition(pos))
  elseif key == "$" or key == "<End>" then
    local line = clamp(editor:LineFromPosition(pos) + count - 1, 0, linecount(editor) - 1)
    result.pos, result.inclusive, result.allowemptychange = lastcharonline(editor, line), true, true
  elseif key == "gg" then
    local line = hadcount and clamp(count - 1, 0, linecount(editor) - 1) or 0
    result.pos, result.linewise = firstnonblank(editor, line), true
  elseif key == "G" then
    local line = hadcount and clamp(count - 1, 0, linecount(editor) - 1) or linecount(editor) - 1
    result.pos, result.linewise = firstnonblank(editor, line), true
  elseif key == "|" then
    result.pos = clampnormal(editor, editor:FindColumn(editor:LineFromPosition(pos), count - 1))
  elseif key == "{" then
    result.pos = paragraph(editor, pos, -1, count)
  elseif key == "}" then
    result.pos = paragraph(editor, pos, 1, count)
  elseif key == "%" then
    result.pos, result.inclusive = bracketmatch(editor, pos), true
  elseif key == "f" or key == "F" or key == "t" or key == "T" then
    result.pos = findchar(editor, pos, key, argument, count)
    result.inclusive = true
  elseif key == ";" or key == "," then
    if not state.lastfind then return nil end
    local kind = state.lastfind.kind
    if key == "," then
      kind = ({f = "F", F = "f", t = "T", T = "t"})[kind]
    end
    local origin = pos
    if kind == "t" then origin = positionafter(editor, origin)
    elseif kind == "T" then origin = positionbefore(editor, origin) end
    result.pos = findchar(editor, origin, kind, state.lastfind.char, count)
    result.inclusive = true
  elseif key == "H" or key == "M" or key == "L" then
    local first = editor.GetFirstVisibleLine and editor:GetFirstVisibleLine() or 0
    local visible = editor.LinesOnScreen and editor:LinesOnScreen() or 1
    local displayline = key == "H" and first or key == "M" and first + math.floor(visible / 2)
      or first + visible - 1
    local line = editor.DocLineFromVisible and editor:DocLineFromVisible(displayline) or displayline
    result.pos = firstnonblank(editor, clamp(line, 0, linecount(editor) - 1))
    result.linewise = true
  else
    return nil
  end

  if result.pos == nil then return nil end
  result.pos = clamp(result.pos, 0, editor:GetLength())
  if not result.vertical then state.goalcol = nil end
  return result
end

local function moveresult(editor, state, result)
  if state.mode == "visual" or state.mode == "visual_line" or state.mode == "visual_block" then
    state.visualcursor = clampnormal(editor, result.pos)
    refreshvisual(editor, state)
  else
    gotonormal(editor, result.pos)
  end
end

local function copyregister(register)
  if not register then return {text = "", linewise = false, blockwise = false} end
  local lines
  if register.lines then
    lines = {}
    for index, value in ipairs(register.lines) do lines[index] = value end
  end
  return {
    text = register.text or "",
    linewise = register.linewise and true or false,
    blockwise = register.blockwise and true or false,
    lines = lines,
    width = register.width,
  }
end

local function clipboardtext()
  if not rawget(_G, "wx") or not wx.wxClipboard or not wx.wxTextDataObject then return nil end
  local clipboard = wx.wxClipboard:Get()
  if not clipboard:Open() then return nil end
  local data = wx.wxTextDataObject()
  local ok = clipboard:GetData(data)
  clipboard:Close()
  return ok and data:GetText() or nil
end

local function storeregister(name, register, append)
  name = name or '"'
  local target = name:match("^[A-Z]$") and name:lower() or name
  if append then
    local previous = runtime.registers[target]
    if previous and previous.text ~= "" then
      register.text = previous.text .. register.text
      if previous.blockwise and register.blockwise and previous.lines and register.lines then
        local lines = {}
        local total = math.max(#previous.lines, #register.lines)
        for index = 1, total do
          lines[index] = (previous.lines[index] or "") .. (register.lines[index] or "")
        end
        register.lines = lines
        register.width = (previous.width or 0) + (register.width or 0)
      end
    end
  end
  runtime.registers[target] = copyregister(register)
end

local function getregister(state, editor)
  local name = state and state.selectedregister or '"'
  if name:match("^[A-Z]$") then name = name:lower() end
  local register
  if name == "+" or name == "*" then
    local text = clipboardtext()
    register = text and {text = text, linewise = false, blockwise = false}
      or runtime.registers[name]
  elseif name == "%" and rawget(_G, "ide") then
    local document = ide:GetDocument(editor)
    register = {text = document and (document:GetFilePath() or document:GetFileName()) or ""}
  elseif name == "#" then
    local document = runtime.alternatedocument
    register = {text = document and (document:GetFilePath() or document:GetFileName()) or ""}
  else
    register = runtime.registers[name]
  end
  if name == '"' and runtime.register and runtime.register ~= runtime.registers['"'] then
    register = runtime.register
  end
  return copyregister(register), name
end

local function consumeregister(state)
  if state then state.selectedregister = nil end
end

local function saveregister(text, linewise, blocklines, blockwidth, state, operation)
  if linewise and text ~= "" and not text:match("[\r\n]$") then text = text .. "\n" end
  local register = {
    text = text,
    linewise = linewise and true or false,
    blockwise = blocklines ~= nil,
    lines = blocklines,
    width = blockwidth,
  }
  local name = state and state.selectedregister or '"'
  local append = name:match("^[A-Z]$") ~= nil
  consumeregister(state)
  if name == "_" then return end

  storeregister(name, copyregister(register), append)
  runtime.registers['"'] = copyregister(register)
  runtime.register = runtime.registers['"']

  if operation == "yank" then
    runtime.registers["0"] = copyregister(register)
  elseif operation == "delete" or operation == "change" then
    if linewise or text:find("[\r\n]") then
      for index = 9, 2, -1 do
        runtime.registers[tostring(index)] = copyregister(runtime.registers[tostring(index - 1)])
      end
      runtime.registers["1"] = copyregister(register)
    else
      runtime.registers["-"] = copyregister(register)
    end
  end

  if runtime.config.clipboard ~= false and rawget(_G, "ide") and ide.CopyToClipboard then
    pcall(function() ide:CopyToClipboard(text) end)
  end
end

local function motionrange(editor, startpos, result)
  if result.linewise then
    local first = math.min(editor:LineFromPosition(startpos), editor:LineFromPosition(result.pos))
    local last = math.max(editor:LineFromPosition(startpos), editor:LineFromPosition(result.pos))
    local finish = last + 1 < linecount(editor) and linestart(editor, last + 1) or editor:GetLength()
    return linestart(editor, first), finish, true, first, last
  end

  if result.pos >= startpos then
    local finish = result.inclusive and inclusiveend(editor, result.pos) or result.pos
    return startpos, finish, false,
      editor:LineFromPosition(startpos), editor:LineFromPosition(result.pos)
  end
  local finish = result.inclusive and inclusiveend(editor, startpos) or startpos
  return result.pos, finish, false,
    editor:LineFromPosition(result.pos), editor:LineFromPosition(startpos)
end

local function linewisetext(editor, first, last)
  local from = linestart(editor, first)
  local finish = last + 1 < linecount(editor) and linestart(editor, last + 1) or editor:GetLength()
  local text = editor:GetTextRange(from, finish)
  if not text:match("[\r\n]$") then text = text .. geteol(editor) end
  return text
end

local function deletecharwise(editor, from, finish)
  if finish <= from then return from end
  editor:DeleteRange(from, finish - from)
  return clampnormal(editor, from)
end

local function deletelinewise(editor, first, last)
  local from = linestart(editor, first)
  local finish = last + 1 < linecount(editor) and linestart(editor, last + 1) or editor:GetLength()
  if last == linecount(editor) - 1 and first > 0 then
    from = lineend(editor, first - 1)
  end
  editor:DeleteRange(from, finish - from)
  return clampnormal(editor, from)
end

local function changelinewise(editor, first, last)
  local indent = leadingindent(editor, first)
  local from = linestart(editor, first)
  local finish = last + 1 < linecount(editor) and linestart(editor, last + 1) or editor:GetLength()
  local hasfollowing = last + 1 < linecount(editor)
  editor:DeleteRange(from, finish - from)
  local replacement = hasfollowing and (indent .. geteol(editor)) or indent
  editor:InsertText(from, replacement)
  editor:GotoPos(from + #indent)
end

local function indentlines(editor, first, last, direction)
  local width = editor.GetIndent and editor:GetIndent() or 0
  if not width or width <= 0 then width = editor.GetTabWidth and editor:GetTabWidth() or 2 end
  for line = first, last do
    local current = editor.GetLineIndentation and editor:GetLineIndentation(line) or 0
    if editor.SetLineIndentation then
      editor:SetLineIndentation(line, math.max(0, current + direction * width))
    end
  end
end

local function applyoperator(editor, state, operator, result, startpos)
  if readonly(editor) and operator ~= "y" then
    setstatus(editor, state, "Vim: document is read-only")
    return false
  end

  local from, finish, linewise, first, last = motionrange(editor, startpos, result)
  if operator == ">" or operator == "<" then linewise = true end
  if linewise then
    first = math.min(editor:LineFromPosition(startpos), editor:LineFromPosition(result.pos))
    last = math.max(editor:LineFromPosition(startpos), editor:LineFromPosition(result.pos))
    from = linestart(editor, first)
    finish = last + 1 < linecount(editor) and linestart(editor, last + 1) or editor:GetLength()
  end
  if finish <= from and operator ~= ">" and operator ~= "<"
  and not (linewise and (first > 0 or operator == "y" or operator == "c")) then
    if operator == "c" and result.allowemptychange then
      enterinsert(editor, state, from, false)
      return true
    end
    return false
  end

  local text = linewise and linewisetext(editor, first, last) or editor:GetTextRange(from, finish)
  if operator == "y" then
    saveregister(text, linewise, nil, nil, state, "yank")
    gotonormal(editor, startpos)
    setstatus(editor, state, linewise and ("Vim: yanked " .. (last - first + 1) .. " line(s)")
      or ("Vim: yanked " .. #text .. " byte(s)"))
    return true
  end

  if operator == ">" or operator == "<" then
    withundo(editor, function() indentlines(editor, first, last, operator == ">" and 1 or -1) end)
    gotonormal(editor, firstnonblank(editor, first))
    return true
  end

  saveregister(text, linewise, nil, nil, state, operator == "c" and "change" or "delete")
  if operator == "d" then
    local cursor
    withundo(editor, function()
      cursor = linewise and deletelinewise(editor, first, last) or deletecharwise(editor, from, finish)
    end)
    gotonormal(editor, cursor)
    return true
  elseif operator == "c" then
    local insertpos = not linewise and from or nil
    beginchange(editor, state, function()
      if linewise then changelinewise(editor, first, last)
      else editor:DeleteRange(from, finish - from) editor:GotoPos(from) end
    end, insertpos)
    return true
  end
  return false
end

local function ensureline(editor, line)
  while line >= linecount(editor) do
    editor:InsertText(editor:GetLength(), geteol(editor))
  end
end

positionatcolumn = function(editor, line, column, pad)
  ensureline(editor, line)
  local pos = editor:FindColumn(line, column)
  local actual = editor:GetColumn(pos)
  if pad and actual < column then
    local spaces = string.rep(" ", column - actual)
    editor:InsertText(pos, spaces)
    pos = pos + #spaces
  end
  return pos
end

local function pasteblock(editor, state, before, count, register)
  if readonly(editor) or not register.lines or #register.lines == 0 then return false end
  local current = editor:GetCurrentPos()
  local firstline = editor:LineFromPosition(current)
  local column = editor:GetColumn(current) + (before and 0 or 1)
  local cursor = current
  withundo(editor, function()
    for index, value in ipairs(register.lines) do
      local line = firstline + index - 1
      local pos = positionatcolumn(editor, line, column, true)
      local text = repeattext(value, count)
      editor:InsertText(pos, text)
      if index == 1 then cursor = pos end
    end
  end)
  gotonormal(editor, cursor)
  return true
end

local function paste(editor, state, before, count)
  local register = getregister(state, editor)
  if readonly(editor) or not register or register.text == "" then return false end
  consumeregister(state)
  if register.blockwise then return pasteblock(editor, state, before, count, register) end
  local text = repeattext(register.text, count)
  local pos = editor:GetCurrentPos()
  withundo(editor, function()
    if register.linewise then
      local line = editor:LineFromPosition(pos)
      local insert
      if before then
        insert = linestart(editor, line)
        editor:InsertText(insert, text)
      elseif line + 1 < linecount(editor) then
        insert = linestart(editor, line + 1)
        editor:InsertText(insert, text)
      else
        insert = editor:GetLength()
        local prefix = insert > 0 and lineend(editor, line) == insert and geteol(editor) or ""
        editor:InsertText(insert, prefix .. text)
        insert = insert + #prefix
      end
      pos = firstnonblank(editor, editor:LineFromPosition(insert))
    else
      local insert = before and pos or afteroncurrentline(editor, pos)
      editor:InsertText(insert, text)
      pos = positionbefore(editor, insert + #text)
    end
  end)
  gotonormal(editor, pos)
  return true
end

local function deletechars(editor, state, backward, count, enter)
  if readonly(editor) then return false end
  local pos = editor:GetCurrentPos()
  local first, finish = pos, pos
  if backward then
    for _ = 1, count do
      local line = editor:LineFromPosition(first)
      if first <= linestart(editor, line) then break end
      first = positionbefore(editor, first)
    end
    finish = pos
  else
    local linefinish = lineend(editor, editor:LineFromPosition(pos))
    for _ = 1, count do
      if finish >= linefinish then break end
      finish = positionafter(editor, finish)
    end
  end
  if finish <= first then
    if enter then enterinsert(editor, state, first, false) return true end
    return false
  end
  saveregister(editor:GetTextRange(first, finish), false, nil, nil, state,
    enter and "change" or "delete")
  if enter then
    beginchange(editor, state, function() editor:DeleteRange(first, finish - first) end, first)
  else
    withundo(editor, function() editor:DeleteRange(first, finish - first) end)
    gotonormal(editor, first)
  end
  return true
end

local function replacechars(editor, state, value, count)
  if readonly(editor) then return false end
  if value == "<CR>" then value = geteol(editor) end
  local first, finish = editor:GetCurrentPos(), editor:GetCurrentPos()
  local linefinish = lineend(editor, editor:LineFromPosition(first))
  local actual = 0
  for _ = 1, count do
    if finish >= linefinish then break end
    finish = positionafter(editor, finish)
    actual = actual + 1
  end
  if actual == 0 then return false end
  saveregister(editor:GetTextRange(first, finish), false, nil, nil, state, "change")
  withundo(editor, function()
    editor:DeleteRange(first, finish - first)
    editor:InsertText(first, repeattext(value, actual))
  end)
  gotonormal(editor, first + #repeattext(value, math.max(0, actual - 1)))
  return true
end

local function togglecase(editor, from, finish)
  local text = editor:GetTextRange(from, finish)
  text = text:gsub("%a", function(value)
    return value == value:lower() and value:upper() or value:lower()
  end)
  editor:DeleteRange(from, finish - from)
  editor:InsertText(from, text)
end

local function togglechars(editor, count)
  if readonly(editor) then return false end
  local first, finish = editor:GetCurrentPos(), editor:GetCurrentPos()
  local linefinish = lineend(editor, editor:LineFromPosition(first))
  for _ = 1, count do
    if finish >= linefinish then break end
    finish = positionafter(editor, finish)
  end
  if finish <= first then return false end
  withundo(editor, function() togglecase(editor, first, finish) end)
  gotonormal(editor, positionbefore(editor, finish))
  return true
end

local function openline(editor, state, below)
  if readonly(editor) then return false end
  local line = editor:LineFromPosition(editor:GetCurrentPos())
  local indent, eol = leadingindent(editor, line), geteol(editor)
  local insert, text, cursor
  if below then
    if line + 1 < linecount(editor) then
      insert, text = linestart(editor, line + 1), indent .. eol
      cursor = insert + #indent
    else
      insert, text = editor:GetLength(), eol .. indent
      cursor = insert + #eol + #indent
    end
  else
    insert, text = linestart(editor, line), indent .. eol
    cursor = insert + #indent
  end
  beginchange(editor, state, function() editor:InsertText(insert, text) end, cursor)
  return true
end

local function joinlines(editor, count)
  if readonly(editor) then return false end
  local changed = false
  withundo(editor, function()
    for _ = 1, count do
      local line = editor:LineFromPosition(editor:GetCurrentPos())
      if line + 1 >= linecount(editor) then break end
      local finish = lineend(editor, line)
      local nextnonblank = firstnonblank(editor, line + 1)
      local left = finish > linestart(editor, line) and chart(editor, positionbefore(editor, finish)) or ""
      local right = chart(editor, nextnonblank)
      local separator = (left == "" or right == "" or left:match("%s")) and "" or " "
      editor:DeleteRange(finish, nextnonblank - finish)
      if separator ~= "" then editor:InsertText(finish, separator) end
      editor:GotoPos(finish)
      changed = true
    end
  end)
  gotonormal(editor, editor:GetCurrentPos())
  return changed
end

local function wordunder(editor, pos)
  if pos >= editor:GetLength() then return nil end
  local class = charclass(chart(editor, pos))
  if class == "space" or class == "eof" then return nil end
  local first, finish = pos, positionafter(editor, pos)
  while first > 0 do
    local previous = positionbefore(editor, first)
    if charclass(chart(editor, previous)) ~= class then break end
    first = previous
  end
  while finish < editor:GetLength() and charclass(chart(editor, finish)) == class do
    finish = positionafter(editor, finish)
  end
  return editor:GetTextRange(first, finish)
end

local function searchflags(query)
  local stc = rawget(_G, "wxstc")
  local matchcase = stc and stc.wxSTC_FIND_MATCHCASE or 4
  local ignore = runtime.config.ignorecase == true
  if ignore and runtime.config.smartcase ~= false and query:find("%u") then ignore = false end
  return ignore and 0 or matchcase
end

local function searchonce(editor, query, forward, origin)
  local length = editor:GetLength()
  editor:SetSearchFlags(searchflags(query))
  if forward then
    editor:SetTargetStart(math.min(length, positionafter(editor, origin)))
    editor:SetTargetEnd(length)
  else
    editor:SetTargetStart(math.max(0, positionbefore(editor, origin)))
    editor:SetTargetEnd(0)
  end
  local found = editor:SearchInTarget(query)
  local notfound = rawget(_G, "wx") and wx.wxNOT_FOUND or -1
  if found == notfound and runtime.config.wrapscan ~= false then
    editor:SetTargetStart(forward and 0 or length)
    editor:SetTargetEnd(forward and math.min(length, origin) or math.min(length, origin))
    found = editor:SearchInTarget(query)
  end
  return found ~= notfound and found or nil
end

local function runsearch(editor, state, query, forward, count)
  if not query or query == "" then return false end
  local pos = editor:GetCurrentPos()
  for _ = 1, count do
    local found = searchonce(editor, query, forward, pos)
    if not found then
      setstatus(editor, state, "Vim: pattern not found: " .. query)
      return false
    end
    pos = found
  end
  runtime.lastsearch, runtime.searchforward = query, forward
  runtime.registers["/"] = {text = query, linewise = false, blockwise = false}
  gotonormal(editor, pos)
  return true
end

local opencommandline

local function promptsearch(editor, state, forward, count)
  local previous = state.mode
  if opencommandline and rawget(_G, "wx") then
    state.mode = "search"
    setstatus(editor, state, forward and "/" or "?")
    if opencommandline(editor, state, forward and "/" or "?", count) then return true end
  end
  if not rawget(_G, "ide") or not ide.GetTextFromUser then return false end
  state.mode = "search"
  setstatus(editor, state, forward and "/" or "?")
  local query = ide:GetTextFromUser(forward and "Search forward" or "Search backward",
    "Vim search", runtime.lastsearch or "")
  state.mode = previous
  setcaret(editor, state)
  if not query then setstatus(editor, state) return false end
  return runsearch(editor, state, query, forward, count)
end

local function closewhenidle(document, force)
  local close = function()
    if force and document.SetModified then document:SetModified(false) end
    document:Close()
  end
  if rawget(_G, "ide") and ide.DoWhenIdle then ide:DoWhenIdle(close) else close() end
end

local function switchtab(editor, direction, count, absolute)
  if not rawget(_G, "ide") or not ide.GetDocumentList then return false end
  local documents = ide:GetDocumentList()
  if #documents == 0 then return false end
  local current = 1
  for index, document in ipairs(documents) do
    if document:GetEditor() == editor then current = index break end
  end
  local target
  if absolute then
    target = clamp(count, 1, #documents)
  else
    target = ((current - 1 + direction * count) % #documents) + 1
  end
  if documents[target].SetActive then
    if target ~= current then runtime.alternatedocument = documents[current] end
    documents[target]:SetActive()
    return true
  end
  return false
end

local function switchalternatetab(editor)
  local alternate = runtime.alternatedocument
  if not alternate or not alternate.SetActive or not rawget(_G, "ide") then return false end
  local current = ide:GetDocument(editor)
  alternate:SetActive()
  runtime.alternatedocument = current
  return true
end

local function scrollposition(editor, where)
  local line = editor:LineFromPosition(editor:GetCurrentPos())
  local visible = editor.VisibleFromDocLine and editor:VisibleFromDocLine(line) or line
  local onscreen = editor.LinesOnScreen and editor:LinesOnScreen() or 1
  if where == "center" then
    if editor.VerticalCentreCaret then editor:VerticalCentreCaret()
    elseif editor.SetFirstVisibleLine then
      editor:SetFirstVisibleLine(math.max(0, visible - math.floor(onscreen / 2)))
    end
  elseif editor.SetFirstVisibleLine then
    local first = where == "top" and visible
      or math.max(0, visible - onscreen + 1)
    editor:SetFirstVisibleLine(first)
  end
  editor:EnsureCaretVisible()
  return true
end

local function executeex(editor, state, command)
  command = (command or ""):match("^%s*(.-)%s*$")
  if command == "" then return true end
  runtime.lastcommand = command
  runtime.registers[":"] = {text = command, linewise = false, blockwise = false}
  if command:match("^%d+$") then
    local line = clamp(tonumber(command) - 1, 0, linecount(editor) - 1)
    gotonormal(editor, firstnonblank(editor, line))
    return true
  end

  local doc = rawget(_G, "ide") and ide:GetDocument(editor) or nil
  if command == "w" or command == "write" then
    local ok = doc and doc:Save()
    setstatus(editor, state, ok and "Vim: written" or "Vim: write cancelled")
    return ok and true or false
  elseif command == "q" or command == "quit" then
    if doc then closewhenidle(doc, false) return true end
  elseif command == "q!" or command == "quit!" then
    if doc then closewhenidle(doc, true) return true end
  elseif command == "wq" or command == "x" or command == "xit" then
    if doc and (command ~= "x" or doc:IsModified() or doc:IsNew()) and not doc:Save() then
      setstatus(editor, state, "Vim: write cancelled")
      return false
    end
    if doc then closewhenidle(doc, false) return true end
  elseif command == "wa" or command == "wall" then
    local ok = true
    for _, document in ipairs(ide:GetDocumentList()) do
      if (document:IsModified() or document:IsNew()) and not document:Save() then ok = false end
    end
    setstatus(editor, state, ok and "Vim: all files written" or "Vim: some writes were cancelled")
    return ok
  elseif command == "qa" or command == "qall" or command == "qa!" or command == "qall!" then
    local force = command:find("!", 1, true) ~= nil
    local documents = ide:GetDocumentList()
    for i = #documents, 1, -1 do closewhenidle(documents[i], force) end
    return true
  elseif command:match("^e%s+") or command:match("^edit%s+") then
    local path = command:match("^e%s+(.+)$") or command:match("^edit%s+(.+)$")
    if path and ide:LoadFile(path) then return true end
    setstatus(editor, state, "Vim: can't open " .. tostring(path))
    return false
  elseif command == "tabnext" or command == "tabn" or command == "bnext" or command == "bn" then
    return switchtab(editor, 1, 1, false)
  elseif command == "tabprevious" or command == "tabp" or command == "bprevious" or command == "bp" then
    return switchtab(editor, -1, 1, false)
  elseif command == "tabfirst" then
    return switchtab(editor, 1, 1, true)
  elseif command == "tablast" then
    return switchtab(editor, 1, 1000000, true)
  elseif command:match("^tab%s+%d+$") then
    return switchtab(editor, 1, tonumber(command:match("%d+")), true)
  elseif command == "tabnew" then
    if rawget(_G, "wx") and rawget(_G, "ID") and ID.NEW then
      ide:GetMainFrame():AddPendingEvent(wx.wxCommandEvent(wx.wxEVT_COMMAND_MENU_SELECTED, ID.NEW))
      return true
    end
    return false
  elseif command:match("^tabnew%s+") then
    return ide:LoadFile(command:match("^tabnew%s+(.+)$")) and true or false
  elseif command == "tabclose" then
    if doc then closewhenidle(doc, false) return true end
  elseif command == "tabonly" then
    if doc then
      local closeothers = function() doc:CloseAll({keep = true, scope = "notebook"}) end
      if ide.DoWhenIdle then ide:DoWhenIdle(closeothers) else closeothers() end
      return true
    end
  elseif command == "tabs" then
    local output = {"--- Tabs ---"}
    for index, document in ipairs(ide:GetDocumentList()) do
      output[#output + 1] = (document:IsActive() and "> " or "  ")
        .. index .. "  " .. (document:GetFilePath() or document:GetFileName() or "[No Name]")
    end
    if ide.Print then ide:Print(table.concat(output, "\n")) end
    return true
  elseif command == "registers" or command == "reg" then
    local names = {}
    for name, register in pairs(runtime.registers) do
      if register and register.text and register.text ~= "" then names[#names + 1] = name end
    end
    table.sort(names)
    local output = {"--- Registers ---"}
    for _, name in ipairs(names) do
      local value = runtime.registers[name].text:gsub("\r", "\\r"):gsub("\n", "\\n")
      output[#output + 1] = ('"%s   %s'):format(name, value)
    end
    if ide and ide.Print then ide:Print(table.concat(output, "\n")) end
    setstatus(editor, state, "Vim: " .. #names .. " register(s)")
    return true
  elseif command == "set ignorecase" or command == "set ic" then
    runtime.config.ignorecase = true
  elseif command == "set noignorecase" or command == "set noic" then
    runtime.config.ignorecase = false
  elseif command == "set smartcase" or command == "set scs" then
    runtime.config.smartcase = true
  elseif command == "set nosmartcase" or command == "set noscs" then
    runtime.config.smartcase = false
  elseif command == "set wrapscan" or command == "set ws" then
    runtime.config.wrapscan = true
  elseif command == "set nowrapscan" or command == "set nows" then
    runtime.config.wrapscan = false
  elseif command == "nohl" or command == "nohlsearch" then
    setstatus(editor, state)
    return true
  else
    setstatus(editor, state, "Vim: not an editor command: " .. command)
    return false
  end
  setstatus(editor, state, "Vim: " .. command)
  return true
end

opencommandline = function(editor, state, prefix, count)
  if not rawget(_G, "wx") or not rawget(_G, "ide") or not ide.GetStatusBar then
    return false
  end
  if runtime.commandline and runtime.commandline.close then runtime.commandline.close(false) end

  local statusbar = ide:GetStatusBar()
  local rect = wx.wxRect()
  statusbar:GetFieldRect(0, rect)
  local control = wx.wxTextCtrl(statusbar, wx.wxID_ANY, prefix,
    wx.wxPoint(rect:GetX(), rect:GetY()),
    wx.wxSize(rect:GetWidth(), rect:GetHeight()),
    wx.wxTE_PROCESS_ENTER + wx.wxNO_BORDER)
  if editor.GetFont then control:SetFont(editor:GetFont()) end
  control:SetInsertionPointEnd()
  control:SetFocus()

  local history = prefix == ":" and runtime.commandhistory or runtime.searchhistory
  local historyindex = #history + 1
  local closing = false
  local function setvalue(value)
    control:ChangeValue(prefix .. (value or ""))
    control:SetInsertionPointEnd()
  end
  local function close(execute)
    if closing then return end
    closing = true
    local value = control:GetValue()
    if value:sub(1, 1) == prefix then value = value:sub(2) end
    runtime.commandline = nil
    control:Destroy()
    if ide.IsValidCtrl == nil or ide:IsValidCtrl(editor) then editor:SetFocus() end
    state.mode = "normal"
    setcaret(editor, state)
    if not execute or value == "" then setstatus(editor, state) return end
    if history[#history] ~= value then history[#history + 1] = value end
    if prefix == ":" then executeex(editor, state, value)
    else runsearch(editor, state, value, prefix == "/", count or 1) end
  end
  runtime.commandline = {control = control, close = close, prefix = prefix}

  control:Connect(wx.wxEVT_KEY_DOWN, function(event)
    local key = event:GetKeyCode()
    if key == wx.WXK_ESCAPE then close(false)
    elseif key == wx.WXK_UP then
      if #history > 0 then
        historyindex = math.max(1, historyindex - 1)
        setvalue(history[historyindex])
      end
    elseif key == wx.WXK_DOWN then
      if historyindex < #history then
        historyindex = historyindex + 1
        setvalue(history[historyindex])
      else
        historyindex = #history + 1
        setvalue("")
      end
    elseif key == wx.WXK_HOME then
      control:SetInsertionPoint(1)
    elseif key == wx.WXK_BACK and control:GetInsertionPoint() <= 1 then
      return
    else
      event:Skip()
    end
  end)
  control:Connect(wx.wxEVT_COMMAND_TEXT_ENTER, function() close(true) end)
  control:Connect(wx.wxEVT_KILL_FOCUS, function()
    if not closing and runtime.commandline and runtime.commandline.control == control then close(false) end
  end)
  return true
end

local function promptex(editor, state)
  if opencommandline and rawget(_G, "wx") then
    state.mode = "command"
    setstatus(editor, state, ":")
    if opencommandline(editor, state, ":", 1) then return true end
  end
  if not rawget(_G, "ide") or not ide.GetTextFromUser then return false end
  state.mode = "command"
  setstatus(editor, state, ":")
  local command = ide:GetTextFromUser("Command", "Vim command", "")
  state.mode = "normal"
  setcaret(editor, state)
  if not command then setstatus(editor, state) return false end
  return executeex(editor, state, command)
end

local function collectblock(editor, state)
  local ranges, firstline, lastline, firstcol, lastcol = visualblockranges(editor, state)
  local lines = {}
  for index, range in ipairs(ranges) do
    lines[index] = editor:GetTextRange(range.from, range.finish)
  end
  return ranges, lines, firstline, lastline, firstcol, lastcol
end

local function deleteblockranges(editor, ranges)
  for index = #ranges, 1, -1 do
    local range = ranges[index]
    if range.finish > range.from then editor:DeleteRange(range.from, range.finish - range.from) end
  end
end

local function makeblockinsert(firstline, lastline, column)
  local lines = {}
  for line = firstline, lastline do lines[#lines + 1] = line end
  return {lines = lines, primary = firstline, column = column}
end

local function startvisualblockinsert(editor, state, after)
  local _, _, firstline, lastline, firstcol, lastcol = collectblock(editor, state)
  local column = after and lastcol + 1 or firstcol
  state.blockinsert = makeblockinsert(firstline, lastline, column)
  local pos = positionatcolumn(editor, firstline, column, true)
  enterinsert(editor, state, pos, false)
  return true
end

local function applyvisualblock(editor, state, operator)
  local ranges, lines, firstline, lastline, firstcol, lastcol = collectblock(editor, state)
  local text = table.concat(lines, geteol(editor))
  local cursor = positionatcolumn(editor, firstline, firstcol, false)
  if operator == "y" then
    saveregister(text, false, lines, lastcol - firstcol + 1, state, "yank")
    setmode(editor, state, "normal")
    gotonormal(editor, cursor)
    setstatus(editor, state, "Vim: yanked block " .. #lines .. "x" .. (lastcol - firstcol + 1))
    return true
  end
  if readonly(editor) then return false end
  if operator == ">" or operator == "<" then
    withundo(editor, function()
      indentlines(editor, firstline, lastline, operator == ">" and 1 or -1)
    end)
    setmode(editor, state, "normal")
    gotonormal(editor, firstnonblank(editor, firstline))
    return true
  elseif operator == "~" then
    withundo(editor, function()
      for index = #ranges, 1, -1 do
        local range = ranges[index]
        if range.finish > range.from then togglecase(editor, range.from, range.finish) end
      end
    end)
    setmode(editor, state, "normal")
    gotonormal(editor, cursor)
    return true
  elseif operator == "d" or operator == "c" then
    saveregister(text, false, lines, lastcol - firstcol + 1, state,
      operator == "c" and "change" or "delete")
    if operator == "c" then
      state.blockinsert = makeblockinsert(firstline, lastline, firstcol)
      beginchange(editor, state, function() deleteblockranges(editor, ranges) end, cursor)
    else
      withundo(editor, function() deleteblockranges(editor, ranges) end)
      state.mode = "normal"
      setmode(editor, state, "normal")
      gotonormal(editor, cursor)
    end
    return true
  end
  return false
end

local function applyvisual(editor, state, operator)
  if state.mode == "visual_block" then return applyvisualblock(editor, state, operator) end
  local from, finish, linewise, first, last = visualrange(editor, state)
  local text = linewise and linewisetext(editor, first, last) or editor:GetTextRange(from, finish)
  if operator == "y" then
    saveregister(text, linewise, nil, nil, state, "yank")
    setmode(editor, state, "normal")
    gotonormal(editor, from)
    setstatus(editor, state, linewise and ("Vim: yanked " .. (last - first + 1) .. " line(s)")
      or ("Vim: yanked " .. #text .. " byte(s)"))
    return true
  end
  if readonly(editor) then return false end
  if operator == ">" or operator == "<" then
    withundo(editor, function() indentlines(editor, first, last, operator == ">" and 1 or -1) end)
    setmode(editor, state, "normal")
    gotonormal(editor, firstnonblank(editor, first))
    return true
  elseif operator == "~" then
    withundo(editor, function() togglecase(editor, from, finish) end)
    setmode(editor, state, "normal")
    gotonormal(editor, from)
    return true
  elseif operator == "d" or operator == "c" then
    saveregister(text, linewise, nil, nil, state,
      operator == "c" and "change" or "delete")
    if operator == "c" and linewise then
      beginchange(editor, state, function() changelinewise(editor, first, last) end)
    else
      if operator == "c" then
        beginchange(editor, state, function() editor:DeleteRange(from, finish - from) end, from)
      else
        local cursor
        withundo(editor, function()
          cursor = linewise and deletelinewise(editor, first, last)
            or deletecharwise(editor, from, finish)
        end)
        state.mode = "normal"
        setmode(editor, state, "normal")
        gotonormal(editor, cursor)
      end
    end
    return true
  end
  return false
end

local function pastevisualblock(editor, state, register)
  if readonly(editor) or register.text == "" then return false end
  local ranges, _, firstline, _, firstcol = collectblock(editor, state)
  local source = register.lines or {register.text}
  local cursor = positionatcolumn(editor, firstline, firstcol, false)
  withundo(editor, function()
    deleteblockranges(editor, ranges)
    for index = 1, #ranges do
      local line = firstline + index - 1
      local pos = positionatcolumn(editor, line, firstcol, true)
      editor:InsertText(pos, source[(index - 1) % #source + 1])
    end
  end)
  state.mode = "normal"
  setmode(editor, state, "normal")
  gotonormal(editor, cursor)
  return true
end

local function pastevisual(editor, state)
  local register = getregister(state, editor)
  if readonly(editor) or register.text == "" then return false end
  consumeregister(state)
  if state.mode == "visual_block" then return pastevisualblock(editor, state, register) end
  local from, finish = visualrange(editor, state)
  local text = register.text
  withundo(editor, function()
    editor:DeleteRange(from, finish - from)
    editor:InsertText(from, text)
  end)
  state.mode = "normal"
  setmode(editor, state, "normal")
  gotonormal(editor, from)
  return true
end

local normaldispatch
local dispatch
local dispatchcore

local function validcharargument(key, allowreturn)
  if allowreturn and key == "<CR>" then return true end
  return not key:match("^<[^>]+>$")
end

local function handleoperatorpending(editor, state, key)
  local pending = state.pending
  if key == "<Esc>" then resetpending(state) setstatus(editor, state) return true end

  if pending.stage == "char" then
    if not validcharargument(key, false) then
      resetpending(state)
      setstatus(editor, state, "Vim: expected a character")
      return true
    end
    local motion, argument = pending.motion, key
    local count = pending.pre * countvalue(pending.post)
    local start = editor:GetCurrentPos()
    local result = resolvemotion(editor, state, motion, count, argument, pending.post ~= "")
    if result and applyoperator(editor, state, pending.op, result, start) and
      (motion == "f" or motion == "F" or motion == "t" or motion == "T") then
      state.lastfind = {kind = motion, char = argument}
    end
    resetpending(state)
    if not state.message then setstatus(editor, state) end
    return true
  elseif pending.stage == "g" then
    if key == "g" then
      local count = pending.pre * countvalue(pending.post)
      local start = editor:GetCurrentPos()
      local result = resolvemotion(editor, state, "gg", count, nil, pending.post ~= "" or pending.pre ~= 1)
      if result then applyoperator(editor, state, pending.op, result, start) end
    end
    resetpending(state)
    if not state.message then setstatus(editor, state) end
    return true
  end

  if key:match("^[1-9]$") or (key == "0" and pending.post ~= "") then
    pending.post = pending.post .. key
    setstatus(editor, state)
    return true
  end
  if key == "g" then pending.stage = "g" setstatus(editor, state) return true end
  if key == "f" or key == "F" or key == "t" or key == "T" then
    pending.stage, pending.motion = "char", key
    setstatus(editor, state)
    return true
  end

  local count = pending.pre * countvalue(pending.post)
  local start = editor:GetCurrentPos()
  if key == pending.op then
    local targetline = clamp(editor:LineFromPosition(start) + count - 1, 0, linecount(editor) - 1)
    applyoperator(editor, state, pending.op,
      {pos = linestart(editor, targetline), inclusive = true, linewise = true}, start)
  else
    local result = resolvemotion(editor, state, key, count, nil, pending.post ~= "")
    if result then applyoperator(editor, state, pending.op, result, start) end
  end
  resetpending(state)
  if not state.message then setstatus(editor, state) end
  return true
end

local function handlenormalpending(editor, state, key)
  local pending = state.pending
  if pending.kind == "register" then
    if key:match('^[%w"%+%*_%-%./:%%#]$') then
      state.selectedregister = key
      state.pending = nil
      setstatus(editor, state)
    else
      resetpending(state)
      setstatus(editor, state, "Vim: invalid register " .. key)
    end
    return true
  end
  if pending.kind == "operator" then return handleoperatorpending(editor, state, key) end
  if key == "<Esc>" then resetpending(state) setstatus(editor, state) return true end

  if pending.kind == "prefix" then
    local count, had = countvalue(pending.counttext), pending.counttext ~= ""
    if pending.key == "g" then
      if key == "g" then
        local result = resolvemotion(editor, state, "gg", count, nil, had)
        if result then moveresult(editor, state, result) end
      elseif key == "t" then
        switchtab(editor, 1, count, had)
      elseif key == "T" then
        switchtab(editor, -1, count, false)
      elseif key == "<Tab>" then
        switchalternatetab(editor)
      else
        setstatus(editor, state, "Vim: unknown command g" .. key)
      end
    elseif pending.key == "z" and (key == "z" or key == ".") then
      scrollposition(editor, "center")
    elseif pending.key == "z" and key == "t" then
      scrollposition(editor, "top")
    elseif pending.key == "z" and key == "b" then
      scrollposition(editor, "bottom")
    elseif pending.key == "Z" and (key == "Z" or key == "Q") then
      executeex(editor, state, key == "Z" and "wq" or "q!")
    else
      setstatus(editor, state, "Vim: unknown command " .. pending.key .. key)
    end
    resetpending(state)
    if not state.message then setstatus(editor, state) end
    return true
  end

  if pending.kind == "char" then
    local count = countvalue(pending.counttext)
    if not validcharargument(key, pending.action == "r") then
      resetpending(state)
      setstatus(editor, state, "Vim: expected a character")
      return true
    end
    if pending.action == "r" then
      replacechars(editor, state, key, count)
    else
      local result = resolvemotion(editor, state, pending.action, count, key,
        pending.counttext ~= "")
      if result then
        moveresult(editor, state, result)
        state.lastfind = {kind = pending.action, char = key}
      end
    end
    resetpending(state)
    setstatus(editor, state)
    return true
  end
  return false
end

local function replaylastchange(editor, state, count)
  local change = runtime.lastchange
  if not change then
    setstatus(editor, state, "Vim: no previous change")
    return false
  end
  runtime.replaying = true
  local ok, message = pcall(function()
    for _ = 1, count do
      if state.mode ~= "normal" then setmode(editor, state, "normal") end
      for _, key in ipairs(change.keys) do dispatchcore(editor, key) end
      if state.mode == "insert" or state.mode == "replace" then
        local delta = change.insertdelta
        local origin = editor:GetCurrentPos()
        if delta then
          local target = clamp(origin + delta.offset, 0, editor:GetLength())
          if delta.delete > 0 then editor:DeleteRange(target, delta.delete) end
          if delta.text ~= "" then editor:InsertText(target, delta.text) end
          editor:GotoPos(clamp(origin + delta.caretoffset, 0, editor:GetLength()))
          local blockinsert = state.blockinsert
          if blockinsert and delta.text ~= "" and not delta.text:find("[\r\n]") then
            for _, line in ipairs(blockinsert.lines) do
              if line ~= blockinsert.primary then
                local insert = positionatcolumn(editor, line, blockinsert.column, true)
                editor:InsertText(insert, delta.text)
              end
            end
          end
          state.blockinsert = nil
        end
        leaveinsert(editor, state)
      end
    end
  end)
  runtime.replaying = false
  if not ok then error(message, 0) end
  return true
end

local function simplenormal(editor, state, key, count, hadcount)
  local result = resolvemotion(editor, state, key, count, nil, hadcount)
  if result then moveresult(editor, state, result) return true end
  state.goalcol = nil

  if key == "i" then enterinsert(editor, state, editor:GetCurrentPos(), false)
  elseif key == "a" then enterinsert(editor, state, afteroncurrentline(editor, editor:GetCurrentPos()), false)
  elseif key == "I" then
    enterinsert(editor, state, firstnonblank(editor, editor:LineFromPosition(editor:GetCurrentPos())), false)
  elseif key == "A" then
    enterinsert(editor, state, lineend(editor, editor:LineFromPosition(editor:GetCurrentPos())), false)
  elseif key == "R" then enterinsert(editor, state, editor:GetCurrentPos(), true)
  elseif key == "o" then openline(editor, state, true)
  elseif key == "O" then openline(editor, state, false)
  elseif key == "v" then entervisual(editor, state, false)
  elseif key == "V" then entervisual(editor, state, true)
  elseif key == "<C-v>" then entervisualblock(editor, state)
  elseif key == "x" or key == "<Delete>" then deletechars(editor, state, false, count, false)
  elseif key == "X" then deletechars(editor, state, true, count, false)
  elseif key == "s" then deletechars(editor, state, false, count, true)
  elseif key == "D" then
    local motion = resolvemotion(editor, state, "$", 1)
    applyoperator(editor, state, "d", motion, editor:GetCurrentPos())
  elseif key == "C" then
    local motion = resolvemotion(editor, state, "$", 1)
    applyoperator(editor, state, "c", motion, editor:GetCurrentPos())
  elseif key == "Y" then
    local line = editor:LineFromPosition(editor:GetCurrentPos())
    local target = clamp(line + count - 1, 0, linecount(editor) - 1)
    applyoperator(editor, state, "y", {pos = linestart(editor, target), linewise = true}, editor:GetCurrentPos())
  elseif key == "p" or key == "P" then paste(editor, state, key == "P", count)
  elseif key == "u" then
    for _ = 1, count do if not editor.CanUndo or editor:CanUndo() then editor:Undo() end end
    gotonormal(editor, editor:GetCurrentPos())
  elseif key == "<C-r>" then
    for _ = 1, count do if not editor.CanRedo or editor:CanRedo() then editor:Redo() end end
    gotonormal(editor, editor:GetCurrentPos())
  elseif key == "." then replaylastchange(editor, state, count)
  elseif key == "~" then togglechars(editor, count)
  elseif key == "J" then joinlines(editor, hadcount and math.max(1, count - 1) or 1)
  elseif key == ":" then promptex(editor, state)
  elseif key == "/" or key == "?" then promptsearch(editor, state, key == "/", count)
  elseif key == "n" or key == "N" then
    if runtime.lastsearch then
      local forward = key == "n" and runtime.searchforward or not runtime.searchforward
      runsearch(editor, state, runtime.lastsearch, forward, count)
    end
  elseif key == "*" or key == "#" then
    local word = wordunder(editor, editor:GetCurrentPos())
    if word then runsearch(editor, state, word, key == "*", count) end
  elseif key == "<C-d>" or key == "<C-u>" or key == "<C-f>" or key == "<C-b>" then
    local visible = editor.LinesOnScreen and editor:LinesOnScreen() or 20
    local amount = (key == "<C-d>" or key == "<C-u>") and math.max(1, math.floor(visible / 2)) or visible
    local direction = (key == "<C-d>" or key == "<C-f>") and 1 or -1
    local moved = screenvertical(editor, state, editor:GetCurrentPos(), direction, amount * count)
    gotonormal(editor, moved)
  elseif key == "<C-e>" or key == "<C-y>" then
    if editor.LineScroll then editor:LineScroll(0, (key == "<C-e>" and 1 or -1) * count) end
  elseif key == "<Esc>" then
    resetpending(state)
    editor:SetEmptySelection(clampnormal(editor, editor:GetCurrentPos()))
  else
    return false
  end
  return true
end

normaldispatch = function(editor, state, key)
  state.message = nil
  if state.pending then return handlenormalpending(editor, state, key) end

  if key:match("^[1-9]$") or (key == "0" and state.count ~= "") then
    state.count = state.count .. key
    setstatus(editor, state)
    return true
  end

  local counttext = state.count
  local count, hadcount = countvalue(counttext), counttext ~= ""
  state.count = ""
  if key == '"' then
    state.pending = {kind = "register"}
    setstatus(editor, state)
    return true
  elseif key == "d" or key == "c" or key == "y" or key == ">" or key == "<" then
    state.pending = {kind = "operator", op = key, pre = count, post = "", stage = "motion"}
    setstatus(editor, state)
    return true
  elseif key == "g" or key == "z" or key == "Z" then
    state.pending = {kind = "prefix", key = key, counttext = counttext}
    setstatus(editor, state)
    return true
  elseif key == "f" or key == "F" or key == "t" or key == "T" or key == "r" then
    state.pending = {kind = "char", action = key, counttext = counttext}
    setstatus(editor, state)
    return true
  end

  local handled = simplenormal(editor, state, key, count, hadcount)
  if state.mode ~= "visual" and state.mode ~= "visual_line" and state.mode ~= "visual_block"
  and not state.pending then
    state.selectedregister = nil
  end
  resetpending(state)
  if handled and not state.message and state.mode == "normal" then setstatus(editor, state) end
  return true -- unknown printable keys are deliberately swallowed in Normal mode.
end

local function visualdispatch(editor, state, key)
  state.message = nil
  if key == "<Esc>" then
    local pos = state.visualcursor
    setmode(editor, state, "normal")
    gotonormal(editor, pos)
    return true
  elseif (key == "v" and state.mode == "visual")
  or (key == "V" and state.mode == "visual_line")
  or (key == "<C-v>" and state.mode == "visual_block") then
    local pos = state.visualcursor
    setmode(editor, state, "normal")
    gotonormal(editor, pos)
    return true
  elseif key == "v" then state.mode = "visual" refreshvisual(editor, state) setstatus(editor, state) return true
  elseif key == "V" then state.mode = "visual_line" refreshvisual(editor, state) setstatus(editor, state) return true
  elseif key == "<C-v>" then
    state.mode = "visual_block"
    refreshvisual(editor, state)
    setstatus(editor, state)
    return true
  elseif key == "o" then
    state.visualanchor, state.visualcursor = state.visualcursor, state.visualanchor
    refreshvisual(editor, state)
    return true
  elseif state.mode == "visual_block" and (key == "I" or key == "A") then
    return startvisualblockinsert(editor, state, key == "A")
  elseif key == "d" or key == "x" then return applyvisual(editor, state, "d")
  elseif key == "c" or key == "s" then return applyvisual(editor, state, "c")
  elseif key == "y" then return applyvisual(editor, state, "y")
  elseif key == "p" or key == "P" then return pastevisual(editor, state)
  elseif key == ">" or key == "<" or key == "~" then return applyvisual(editor, state, key)
  end

  if state.pending and state.pending.kind == "char" then
    local motion = state.pending.action
    local counttext = state.pending.counttext or ""
    state.pending = nil
    if not validcharargument(key, false) then
      setstatus(editor, state, "Vim: expected a character")
      return true
    end
    local result = resolvemotion(editor, state, motion, countvalue(counttext), key,
      counttext ~= "")
    if result then
      moveresult(editor, state, result)
      state.lastfind = {kind = motion, char = key}
    end
    setstatus(editor, state)
    return true
  end

  if key:match("^[1-9]$") or (key == "0" and state.count ~= "") then
    state.count = state.count .. key
    setstatus(editor, state)
    return true
  end
  local count, had = countvalue(state.count), state.count ~= ""
  state.count = ""

  if key == "f" or key == "F" or key == "t" or key == "T" then
    state.pending = {kind = "char", action = key, counttext = had and tostring(count) or ""}
    setstatus(editor, state)
    return true
  end

  local result = resolvemotion(editor, state, key, count, nil, had)
  if result then moveresult(editor, state, result) end
  setstatus(editor, state)
  return true
end

dispatchcore = function(editor, key)
  if not runtime.enabled then return false end
  local state = getstate(editor)
  if state.mode == "insert" or state.mode == "replace" then
    if key == "<Esc>" or key == "<C-[>" or key == "<C-c>" then
      leaveinsert(editor, state)
      return true
    end
    return false
  elseif state.mode == "visual" or state.mode == "visual_line" or state.mode == "visual_block" then
    return visualdispatch(editor, state, key)
  end
  return normaldispatch(editor, state, key)
end

dispatch = function(editor, key)
  local state = getstate(editor)
  local candidate = state.repeatcandidate
  local mode = state.mode
  local canstart = mode == "normal" or mode == "visual"
    or mode == "visual_line" or mode == "visual_block"
  if not runtime.replaying and key ~= "." and key ~= ":" and key ~= "/" and key ~= "?" then
    if not candidate and canstart then
      candidate = {before = editor:GetText(), keys = {}}
      state.repeatcandidate = candidate
    end
    if candidate and mode ~= "insert" and mode ~= "replace" then
      candidate.keys[#candidate.keys + 1] = key
    end
  end

  local handled = dispatchcore(editor, key)
  candidate = state.repeatcandidate
  if candidate and not runtime.replaying then
    local ongoing = state.mode == "insert" or state.mode == "replace"
      or state.mode == "visual" or state.mode == "visual_line" or state.mode == "visual_block"
      or state.pending ~= nil or state.count ~= "" or state.selectedregister ~= nil
    if not ongoing then
      if editor:GetText() ~= candidate.before then
        runtime.lastchange = {
          keys = candidate.keys,
          insertdelta = candidate.insertdelta,
        }
      end
      state.repeatcandidate = nil
    end
  end
  return handled
end

local function utf8char(code)
  if code < 0x80 then return string.char(code) end
  if code < 0x800 then
    return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
  end
  if code < 0x10000 then
    return string.char(0xE0 + math.floor(code / 0x1000),
      0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
  end
  return string.char(0xF0 + math.floor(code / 0x40000),
    0x80 + math.floor(code / 0x1000) % 0x40,
    0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
end

local function eventchar(event)
  local code = event.GetUnicodeKey and event:GetUnicodeKey() or event:GetKeyCode()
  if not code or code < 32 or code > 0x10FFFF then return nil end
  return utf8char(code)
end

local function specialkey(event)
  local wxlib = rawget(_G, "wx")
  if not wxlib then return nil end
  local code = event:GetKeyCode()
  local control = event.ControlDown and event:ControlDown()
  local alt = event.AltDown and event:AltDown()
  local meta = event.MetaDown and event:MetaDown()
  if alt or meta then return nil end
  if control then
    local value = code >= 0 and code <= 255 and string.char(code):lower() or ""
    local supported = {r = true, d = true, u = true, f = true, b = true,
      e = true, y = true, v = true, ["["] = true, c = true}
    return supported[value] and ("<C-" .. value .. ">") or nil
  end
  if code == wxlib.WXK_TAB then
    return event.ShiftDown and event:ShiftDown() and "<S-Tab>" or "<Tab>"
  end
  local keys = {
    [wxlib.WXK_ESCAPE] = "<Esc>", [wxlib.WXK_LEFT] = "<Left>",
    [wxlib.WXK_RIGHT] = "<Right>", [wxlib.WXK_UP] = "<Up>",
    [wxlib.WXK_DOWN] = "<Down>", [wxlib.WXK_HOME] = "<Home>",
    [wxlib.WXK_END] = "<End>", [wxlib.WXK_BACK] = "<BS>",
    [wxlib.WXK_DELETE] = "<Delete>", [wxlib.WXK_RETURN] = "<CR>",
    [wxlib.WXK_NUMPAD_ENTER] = "<CR>",
  }
  return keys[code]
end

local function connecteditor(editor)
  if charhandlers[editor] then return end
  local handler = function(event)
    if not runtime.registered or not runtime.enabled then event:Skip() return end
    local state = getstate(editor)
    if state.mode == "insert" or state.mode == "replace" then event:Skip() return end
    local control = event.ControlDown and event:ControlDown()
    local alt = event.AltDown and event:AltDown()
    local meta = event.MetaDown and event:MetaDown()
    -- Preserve IDE shortcuts, while still accepting AltGr (Ctrl+Alt) characters.
    if meta or (alt and not control) or (control and not alt) then event:Skip() return end
    local key = eventchar(event)
    if not key then event:Skip() return end
    dispatch(editor, key)
  end
  charhandlers[editor] = handler
  editor:Connect(wx.wxEVT_CHAR, handler)
  if runtime.enabled then
    local state = getstate(editor)
    setcaret(editor, state)
    setstatus(editor, state)
  end
end

local function disconnecteditor(editor)
  local handler = charhandlers[editor]
  if handler and rawget(_G, "wx") then
    pcall(function()
      editor:Disconnect(wx.wxID_ANY, wx.wxID_ANY, wx.wxEVT_CHAR, handler)
    end)
  end
  local state = states[editor]
  if state then
    endinsertundo(editor, state)
    if editor.SetOvertype then pcall(function() editor:SetOvertype(false) end) end
    if editor.SetCaretStyle then pcall(function() editor:SetCaretStyle(1) end) end
    if state.caretperiod ~= nil and editor.SetCaretPeriod then
      pcall(function() editor:SetCaretPeriod(state.caretperiod) end)
    end
  end
  charhandlers[editor], states[editor] = nil, nil
end

local function installctrlvhotkey()
  if runtime.config.visualblock == false or runtime.config.overridectrlv == false
  or not ide.GetHotKey or not ide.SetHotKey then return end
  local originalid, shortcut = ide:GetHotKey("Ctrl-V")
  local fakeid = ide:SetHotKey(function()
    local editor = (ide.GetEditorWithFocus and ide:GetEditorWithFocus()) or ide:GetEditor()
    if not editor then return end
    local state = getstate(editor)
    if state.mode == "insert" or state.mode == "replace" then
      if editor.PasteDyn then editor:PasteDyn()
      elseif editor.Paste then editor:Paste() end
    else
      dispatch(editor, "<C-v>")
    end
  end, shortcut or "Ctrl-V")
  runtime.ctrlvhotkey = {fakeid = fakeid, originalid = originalid, shortcut = shortcut or "Ctrl-V"}
end

local function restorectrlvhotkey()
  local hotkey = runtime.ctrlvhotkey
  if not hotkey then return end
  if hotkey.originalid and ide.SetHotKey then
    ide:SetHotKey(hotkey.originalid, hotkey.shortcut)
  elseif hotkey.fakeid and ide.SetAccelerator then
    ide:SetAccelerator(hotkey.fakeid)
  end
  runtime.ctrlvhotkey = nil
end

local plugin = {
  name = "Vim Mode",
  description = "Modal Vim-style editing for ZeroBrane Studio.",
  author = "ZoneBraneVim contributors",
  version = 0.3,
  dependencies = 1.61,

  onRegister = function(self)
    runtime.config = self:GetConfig() or {}
    runtime.enabled = runtime.config.enabled ~= false
    runtime.registered = true
    runtime.registers['"'] = runtime.register
    for _, document in ipairs(ide:GetDocumentList()) do connecteditor(document:GetEditor()) end
    if runtime.enabled then installctrlvhotkey() end
    ide:Print("Vim Mode " .. VERSION .. " registered")
  end,

  onUnRegister = function(self)
    runtime.registered = false
    if runtime.commandline and runtime.commandline.close then runtime.commandline.close(false) end
    restorectrlvhotkey()
    for _, document in ipairs(ide:GetDocumentList()) do disconnecteditor(document:GetEditor()) end
    if runtime.laststatus and ide:GetStatus(0) == runtime.laststatus then ide:SetStatus("", 0) end
    ide:Print("Vim Mode unregistered")
  end,

  onEditorLoad = function(self, editor) connecteditor(editor) end,
  onEditorNew = function(self, editor) connecteditor(editor) end,
  onEditorClose = function(self, editor) disconnecteditor(editor) end,
  onEditorFocusLost = function(self, editor)
    local state = states[editor]
    if state and (state.mode == "insert" or state.mode == "replace") then
      endinsertundo(editor, state)
    end
  end,
  onEditorFocusSet = function(self, editor)
    connecteditor(editor)
    if not runtime.enabled then return end
    local state = getstate(editor)
    if state.mode == "insert" or state.mode == "replace" then begininsertundo(editor, state) end
    setcaret(editor, state)
    setstatus(editor, state)
  end,

  onEditorAction = function(self, editor, event)
    if not runtime.enabled then return end
    local mode = getstate(editor).mode
    if mode == "insert" or mode == "replace" then return end
    local id = event:GetId()
    local cut = rawget(_G, "ID_CUT")
    local pasteid = rawget(_G, "ID_PASTE")
    if id == cut or id == pasteid then return false end
  end,

  onEditorKeyDown = function(self, editor, event)
    if not runtime.enabled then return end
    local key = specialkey(event)
    if key and dispatch(editor, key) then return false end
    return
  end,
}

-- A deliberately small test seam; ZeroBrane ignores non-event fields.
plugin._test = {
  dispatch = dispatch,
  getstate = getstate,
  executeex = executeex,
  visualrange = visualrange,
  runtime = runtime,
  reset = function()
    runtime.config = {status = false, clipboard = false, wrapscan = true, smartcase = true}
    runtime.enabled, runtime.registered = true, true
    runtime.register = {text = "", linewise = false, blockwise = false}
    runtime.registers = {['"'] = runtime.register}
    runtime.lastchange = nil
    runtime.replaying = false
    runtime.commandline = nil
    runtime.commandhistory = {}
    runtime.searchhistory = {}
    runtime.alternatedocument = nil
    runtime.lastcommand = nil
    runtime.ctrlvhotkey = nil
    runtime.lastsearch, runtime.searchforward = nil, true
    states = setmetatable({}, {__mode = "k"})
  end,
}

return plugin
