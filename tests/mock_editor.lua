-- A small, byte-positioned stand-in for wxStyledTextCtrl.
-- It intentionally implements only the API surface exercised by vim.lua.

local Editor = {}
Editor.__index = Editor

local function clamp(value, low, high)
  if value < low then return low end
  if value > high then return high end
  return value
end

local function utf8width(byte)
  if not byte or byte < 0x80 then return 1 end
  if byte < 0xE0 then return 2 end
  if byte < 0xF0 then return 3 end
  return 4
end

local function iscontinuation(byte)
  return byte and byte >= 0x80 and byte < 0xC0
end

local function linestarts(text)
  local starts, index, length = {0}, 1, #text
  while index <= length do
    local byte = text:byte(index)
    if byte == 13 then
      if text:byte(index + 1) == 10 then index = index + 1 end
      starts[#starts + 1] = index
    elseif byte == 10 then
      starts[#starts + 1] = index
    end
    index = index + 1
  end
  return starts
end

local function snapshot(editor)
  return {
    text = editor.text,
    current = editor.current,
    anchor = editor.anchor,
  }
end

local function restore(editor, value)
  editor.text = value.text
  editor.current = value.current
  editor.anchor = value.anchor
end

local function differs(left, right)
  return left.text ~= right.text or left.current ~= right.current
    or left.anchor ~= right.anchor
end

function Editor.new(text, options)
  options = options or {}
  local self = setmetatable({}, Editor)
  self.text = text or ""
  self.current, self.anchor = 0, 0
  self.readonly = options.readonly or false
  self.indent = options.indent or 2
  self.tabwidth = options.tabwidth or 2
  self.eolmode = options.eolmode or 2
  self.firstvisible = options.firstvisible or 0
  self.visiblelines = options.visiblelines or 20
  self.caretstyle, self.caretperiod, self.overtype = 1, 500, false
  self.undo, self.redo = {}, {}
  self.undodepth, self.undobefore = 0, nil
  self.targetstart, self.targetend, self.searchflags = 0, 0, 4
  self.scrollx, self.scrolly = 0, 0
  self.ensurecount = 0
  self.selectionmode = 0
  self.rectanchor, self.rectcaret = 0, 0
  self.centercount = 0
  return self
end

function Editor:GetLength()
  return #self.text
end

function Editor:GetText()
  return self.text
end

function Editor:GetTextRange(first, finish)
  first = clamp(first, 0, #self.text)
  finish = clamp(finish, 0, #self.text)
  if finish <= first then return "" end
  return self.text:sub(first + 1, finish)
end

function Editor:PositionAfter(position)
  position = clamp(position, 0, #self.text)
  if position >= #self.text then return #self.text end
  return math.min(#self.text, position + utf8width(self.text:byte(position + 1)))
end

function Editor:PositionBefore(position)
  position = clamp(position, 0, #self.text)
  if position <= 0 then return 0 end
  local previous = position - 1
  while previous > 0 and iscontinuation(self.text:byte(previous + 1)) do
    previous = previous - 1
  end
  return previous
end

function Editor:GetLineCount()
  return #linestarts(self.text)
end

function Editor:PositionFromLine(line)
  local starts = linestarts(self.text)
  if line < 0 then return 0 end
  if line >= #starts then return #self.text end
  return starts[line + 1]
end

function Editor:GetLineEndPosition(line)
  local starts = linestarts(self.text)
  if line < 0 then line = 0 end
  if line >= #starts then return #self.text end
  local finish = line + 1 < #starts and starts[line + 2] or #self.text
  while finish > starts[line + 1] do
    local byte = self.text:byte(finish)
    if byte ~= 10 and byte ~= 13 then break end
    finish = finish - 1
  end
  return finish
end

function Editor:LineFromPosition(position)
  position = clamp(position, 0, #self.text)
  local starts, line = linestarts(self.text), 0
  for index = 2, #starts do
    if starts[index] > position then break end
    line = index - 1
  end
  return line
end

function Editor:GetColumn(position)
  position = clamp(position, 0, #self.text)
  local start = self:PositionFromLine(self:LineFromPosition(position))
  local cursor, column = start, 0
  while cursor < position do
    local value = self:GetTextRange(cursor, self:PositionAfter(cursor))
    if value == "\t" then
      column = column + self.tabwidth - column % self.tabwidth
    else
      column = column + 1
    end
    cursor = self:PositionAfter(cursor)
  end
  return column
end

function Editor:FindColumn(line, wanted)
  local cursor, finish = self:PositionFromLine(line), self:GetLineEndPosition(line)
  local column = 0
  while cursor < finish and column < wanted do
    local nextposition = self:PositionAfter(cursor)
    local value = self:GetTextRange(cursor, nextposition)
    local nextcolumn = value == "\t"
      and column + self.tabwidth - column % self.tabwidth or column + 1
    if nextcolumn > wanted then break end
    cursor, column = nextposition, nextcolumn
  end
  return cursor
end

function Editor:GetCurrentPos()
  return self.current
end

function Editor:GotoPos(position)
  self.current = clamp(position, 0, #self.text)
  self.anchor = self.current
end

function Editor:SetCurrentPos(position)
  self.current = clamp(position, 0, #self.text)
end

function Editor:SetEmptySelection(position)
  self:GotoPos(position)
end

function Editor:SetSelection(first, finish)
  self.anchor = clamp(first, 0, #self.text)
  self.current = clamp(finish, 0, #self.text)
end

function Editor:SetSelectionMode(mode)
  self.selectionmode = mode
end

function Editor:SetRectangularSelectionAnchor(position)
  self.rectanchor = clamp(position, 0, #self.text)
end

function Editor:SetRectangularSelectionCaret(position)
  self.rectcaret = clamp(position, 0, #self.text)
end

function Editor:GetSelectionStart()
  return math.min(self.anchor, self.current)
end

function Editor:GetSelectionEnd()
  return math.max(self.anchor, self.current)
end

function Editor:GetSelectedText()
  return self:GetTextRange(self:GetSelectionStart(), self:GetSelectionEnd())
end

function Editor:EnsureCaretVisible()
  self.ensurecount = self.ensurecount + 1
end

function Editor:SetCaretStyle(style)
  self.caretstyle = style
end

function Editor:GetCaretPeriod()
  return self.caretperiod
end

function Editor:SetCaretPeriod(period)
  self.caretperiod = period
end

function Editor:SetOvertype(value)
  self.overtype = value and true or false
end

function Editor:GetReadOnly()
  return self.readonly
end

function Editor:SetReadOnly(value)
  self.readonly = value and true or false
end

local function adjustposition(position, first, finish, replacementlength)
  if position <= first then return position end
  if position < finish then return first + replacementlength end
  return position - (finish - first) + replacementlength
end

function Editor:DeleteRange(first, length)
  if self.readonly then return end
  first = clamp(first, 0, #self.text)
  local finish = clamp(first + math.max(0, length), first, #self.text)
  self.text = self.text:sub(1, first) .. self.text:sub(finish + 1)
  self.current = adjustposition(self.current, first, finish, 0)
  self.anchor = adjustposition(self.anchor, first, finish, 0)
end

function Editor:InsertText(position, value)
  if self.readonly or value == "" then return end
  position = clamp(position, 0, #self.text)
  self.text = self.text:sub(1, position) .. value .. self.text:sub(position + 1)
  if self.current > position then self.current = self.current + #value end
  if self.anchor > position then self.anchor = self.anchor + #value end
end

-- Simulates text accepted by Scintilla while Vim is in Insert/Replace mode.
function Editor:TypeText(value)
  local position = self.current
  if self.overtype then
    local finish = position
    local cursor = 1
    while cursor <= #value and finish < self:GetLineEndPosition(self:LineFromPosition(finish)) do
      finish = self:PositionAfter(finish)
      cursor = cursor + utf8width(value:byte(cursor))
    end
    self:DeleteRange(position, finish - position)
  end
  self:InsertText(position, value)
  self:GotoPos(position + #value)
end

function Editor:BeginUndoAction()
  if self.undodepth == 0 then self.undobefore = snapshot(self) end
  self.undodepth = self.undodepth + 1
end

function Editor:EndUndoAction()
  if self.undodepth <= 0 then return end
  self.undodepth = self.undodepth - 1
  if self.undodepth == 0 then
    local after = snapshot(self)
    if self.undobefore and differs(self.undobefore, after) then
      self.undo[#self.undo + 1] = self.undobefore
      self.redo = {}
    end
    self.undobefore = nil
  end
end

function Editor:CanUndo()
  return #self.undo > 0
end

function Editor:CanRedo()
  return #self.redo > 0
end

function Editor:Undo()
  local before = self.undo[#self.undo]
  if not before then return end
  self.undo[#self.undo] = nil
  self.redo[#self.redo + 1] = snapshot(self)
  restore(self, before)
end

function Editor:Redo()
  local after = self.redo[#self.redo]
  if not after then return end
  self.redo[#self.redo] = nil
  self.undo[#self.undo + 1] = snapshot(self)
  restore(self, after)
end

function Editor:GetIndent()
  return self.indent
end

function Editor:GetTabWidth()
  return self.tabwidth
end

function Editor:GetLineIndentation(line)
  local cursor, finish = self:PositionFromLine(line), self:GetLineEndPosition(line)
  local column = 0
  while cursor < finish do
    local value = self:GetTextRange(cursor, self:PositionAfter(cursor))
    if value == " " then column = column + 1
    elseif value == "\t" then column = column + self.tabwidth - column % self.tabwidth
    else break end
    cursor = self:PositionAfter(cursor)
  end
  return column
end

function Editor:SetLineIndentation(line, indentation)
  local first, finish = self:PositionFromLine(line), self:GetLineEndPosition(line)
  local cursor = first
  while cursor < finish do
    local value = self:GetTextRange(cursor, self:PositionAfter(cursor))
    if value ~= " " and value ~= "\t" then break end
    cursor = self:PositionAfter(cursor)
  end
  self:DeleteRange(first, cursor - first)
  self:InsertText(first, string.rep(" ", math.max(0, indentation)))
end

function Editor:GetEOLMode()
  return self.eolmode
end

function Editor:GetFirstVisibleLine()
  return self.firstvisible
end

function Editor:LinesOnScreen()
  return self.visiblelines
end

function Editor:VisibleFromDocLine(line)
  return line
end

function Editor:DocLineFromVisible(line)
  return line
end

function Editor:SetFirstVisibleLine(line)
  self.firstvisible = math.max(0, line)
end

function Editor:VerticalCentreCaret()
  self.centercount = self.centercount + 1
  local line = self:LineFromPosition(self.current)
  self.firstvisible = math.max(0, line - math.floor(self.visiblelines / 2))
end

function Editor:LineScroll(horizontal, vertical)
  self.scrollx = self.scrollx + horizontal
  self.scrolly = self.scrolly + vertical
  self.firstvisible = math.max(0, self.firstvisible + vertical)
end

function Editor:SetSearchFlags(flags)
  self.searchflags = flags
end

function Editor:SetTargetStart(position)
  self.targetstart = clamp(position, 0, #self.text)
end

function Editor:SetTargetEnd(position)
  self.targetend = clamp(position, 0, #self.text)
end

function Editor:SearchInTarget(query)
  local forward = self.targetstart <= self.targetend
  local low = math.min(self.targetstart, self.targetend)
  local high = math.max(self.targetstart, self.targetend)
  local haystack = self.text:sub(low + 1, high)
  local needle = query
  if self.searchflags == 0 then
    haystack, needle = haystack:lower(), needle:lower()
  end
  if forward then
    local found = haystack:find(needle, 1, true)
    return found and low + found - 1 or -1
  end
  local from, found = 1, nil
  while true do
    local match = haystack:find(needle, from, true)
    if not match then break end
    found, from = match, match + 1
  end
  return found and low + found - 1 or -1
end

function Editor:BraceMatch(position)
  local opening = {['('] = ')', ['['] = ']', ['{'] = '}', ['<'] = '>'}
  local closing = {[')'] = '(', [']'] = '[', ['}'] = '{', ['>'] = '<'}
  local value = self:GetTextRange(position, self:PositionAfter(position))
  local mate, direction = opening[value], 1
  if not mate then mate, direction = closing[value], -1 end
  if not mate then return -1 end
  local depth, cursor = 1, position
  while true do
    cursor = direction > 0 and self:PositionAfter(cursor) or self:PositionBefore(cursor)
    if cursor < 0 or cursor >= #self.text then break end
    local found = self:GetTextRange(cursor, self:PositionAfter(cursor))
    if found == value then depth = depth + 1
    elseif found == mate then
      depth = depth - 1
      if depth == 0 then return cursor end
    end
    if direction < 0 and cursor == 0 then break end
  end
  return -1
end

function Editor:Connect(event, handler)
  self.connectedevent, self.handler = event, handler
end

function Editor:Disconnect(idfirst, idlast, event, handler)
  if handler == self.handler then self.handler = nil end
  return true
end

return {
  Editor = Editor,
  new = Editor.new,
}
