-- Run from the repository root with: lua tests/test_vim.lua

local script = (arg and arg[0] or "tests/test_vim.lua"):gsub("\\", "/")
local testdir = script:match("^(.*)/[^/]+$") or "tests"
local root = testdir == "tests" and "." or testdir:gsub("/tests$", "")
if root == "" then root = "." end
package.path = testdir .. "/?.lua;" .. package.path

local Mock = require("mock_editor")
local plugin = assert(loadfile(root .. "/vim.lua"))()
local seam = assert(plugin._test, "vim.lua must expose plugin._test")

local tests = {}
local passed, failed = 0, 0

local function quote(value)
  if type(value) == "string" then return string.format("%q", value) end
  return tostring(value)
end

local function equal(actual, expected, message)
  if actual ~= expected then
    error((message and message .. ": " or "") .. "expected " .. quote(expected)
      .. ", got " .. quote(actual), 2)
  end
end

local function truthy(value, message)
  if not value then error(message or "expected a truthy value", 2) end
end

local function test(name, callback)
  tests[#tests + 1] = {name = name, callback = callback}
end

local function editor(text, options)
  return Mock.new(text, options)
end

local function press(target, ...)
  for index = 1, select("#", ...) do
    seam.dispatch(target, select(index, ...))
  end
end

local function setup()
  _G.ide, _G.wx, _G.wxstc = nil, nil, nil
  seam.reset()
end

test("normal motions preserve a vertical goal column", function()
  local value = editor("abcdef\nxy\nabcdef")
  press(value, "$", "j")
  equal(value:GetCurrentPos(), 8, "short line clamps to its last character")
  press(value, "j")
  equal(value:GetCurrentPos(), 15, "the original column is restored")
  press(value, "k")
  equal(value:GetCurrentPos(), 8, "goal column survives repeated vertical motion")
  press(value, "0", "2", "l")
  equal(value:GetCurrentPos(), 8, "horizontal counts clamp to the short line")
  press(value, "j")
  equal(value:GetCurrentPos(), 11, "non-vertical motion resets the vertical goal column")
end)

test("motions use UTF-8 byte positions without landing inside a character", function()
  local value = editor("éx y")
  press(value, "l")
  equal(value:GetCurrentPos(), 2)
  press(value, "w")
  equal(value:GetCurrentPos(), 4)
  press(value, "b")
  equal(value:GetCurrentPos(), 0)
  press(value, "$", "h")
  equal(value:GetCurrentPos(), 3)
end)

test("small-word and WORD motions distinguish punctuation", function()
  local value = editor("one,two  three")
  press(value, "3", "w")
  equal(value:GetCurrentPos(), 9)
  press(value, "b")
  equal(value:GetCurrentPos(), 4)
  press(value, "e")
  equal(value:GetCurrentPos(), 6)
  value:GotoPos(0)
  press(value, "W")
  equal(value:GetCurrentPos(), 9)
end)

test("insert mode groups typing into one undo step", function()
  local value = editor("abc")
  press(value, "i")
  equal(seam.getstate(value).mode, "insert")
  equal(value.caretstyle, 1)
  value:TypeText("XY")
  press(value, "<Esc>")
  equal(value:GetText(), "XYabc")
  equal(value:GetCurrentPos(), 1)
  equal(seam.getstate(value).mode, "normal")
  equal(value.caretstyle, 2)
  press(value, "u")
  equal(value:GetText(), "abc")
  press(value, "<C-r>")
  equal(value:GetText(), "XYabc")
end)

test("Tab stays native and the caret does not blink", function()
  local value = editor("abc")
  press(value, "i")
  equal(value.caretperiod, 0)
  value:TypeText("X")
  equal(seam.dispatch(value, "<Tab>"), false, "Tab is passed to the native editor")
  equal(seam.getstate(value).mode, "insert")
  press(value, "<Esc>")
  equal(seam.getstate(value).mode, "normal")
  equal(value:GetText(), "Xabc")
  equal(value:GetCurrentPos(), 0)

  seam.runtime.config.cursorblink = true
  value = editor("abc")
  press(value, "i")
  equal(value.caretperiod, 500, "cursorblink=true preserves the original blink period")
end)

test("append and replace modes choose the expected insertion point", function()
  local value = editor("abcd")
  press(value, "a")
  value:TypeText("X")
  press(value, "<Esc>")
  equal(value:GetText(), "aXbcd")
  equal(value:GetCurrentPos(), 1)

  value = editor("abcd")
  value:GotoPos(1)
  press(value, "R")
  truthy(value.overtype)
  value:TypeText("XY")
  press(value, "<Esc>")
  equal(value:GetText(), "aXYd")
  equal(value:GetCurrentPos(), 2)
  equal(value.overtype, false)
end)

test("append and characterwise put do not cross an empty line", function()
  local value = editor("\nnext")
  press(value, "a")
  equal(value:GetCurrentPos(), 0)
  value:TypeText("X")
  press(value, "<Esc>")
  equal(value:GetText(), "X\nnext")

  value = editor("\nnext")
  seam.runtime.register = {text = "X", linewise = false}
  press(value, "p")
  equal(value:GetText(), "X\nnext")
  equal(value:GetCurrentPos(), 0)
end)

test("operator counts multiply and undo/redo restore the edit", function()
  local value = editor("one two three four five")
  press(value, "2", "d", "2", "w")
  equal(value:GetText(), "five")
  equal(seam.runtime.register.text, "one two three four ")
  equal(seam.runtime.register.linewise, false)
  equal(value:GetCurrentPos(), 0)
  press(value, "u")
  equal(value:GetText(), "one two three four five")
  press(value, "<C-r>")
  equal(value:GetText(), "five")
end)

test("linewise delete and put preserve register shape", function()
  local value = editor("one\ntwo\nthree")
  value:GotoPos(4)
  press(value, "d", "d")
  equal(value:GetText(), "one\nthree")
  equal(seam.runtime.register.text, "two\n")
  equal(seam.runtime.register.linewise, true)
  press(value, "P")
  equal(value:GetText(), "one\ntwo\nthree")

  value:GotoPos(8)
  press(value, "d", "d")
  equal(value:GetText(), "one\ntwo")
  equal(seam.runtime.register.text, "three\n")
end)

test("linewise put below the final line inserts a separating EOL", function()
  local value = editor("one\ntwo")
  press(value, "y", "y")
  value:GotoPos(4)
  press(value, "p")
  equal(value:GetText(), "one\ntwo\none\n")
  equal(value:GetCurrentPos(), 8)
end)

test("find motions repeat, reverse, and compose with an operator", function()
  local value = editor("abcXdefX")
  press(value, "f", "X")
  equal(value:GetCurrentPos(), 3)
  press(value, ";")
  equal(value:GetCurrentPos(), 7)
  press(value, ",")
  equal(value:GetCurrentPos(), 3)
  value:GotoPos(0)
  press(value, "d", "t", "X")
  equal(value:GetText(), "XdefX")
  equal(seam.runtime.register.text, "abc")
end)

test("semicolon advances repeated till motions past the previous target", function()
  local value = editor("abXcdXefX")
  press(value, "t", "X")
  equal(value:GetCurrentPos(), 1)
  press(value, ";")
  equal(value:GetCurrentPos(), 4)
  press(value, ";")
  equal(value:GetCurrentPos(), 7)
  press(value, ",")
  equal(value:GetCurrentPos(), 6)
end)

test("percent scans for a bracket then follows its match", function()
  local value = editor("x(a[b]c)d")
  press(value, "%")
  equal(value:GetCurrentPos(), 7)
  press(value, "%")
  equal(value:GetCurrentPos(), 1)
end)

test("replace, case toggle, delete, and join commands are count-aware", function()
  local value = editor("abcd")
  press(value, "2", "r", "x")
  equal(value:GetText(), "xxcd")
  equal(value:GetCurrentPos(), 1)
  value:GotoPos(0)
  press(value, "3", "~")
  equal(value:GetText(), "XXCd")
  equal(value:GetCurrentPos(), 2)
  press(value, "2", "x")
  equal(value:GetText(), "XX")
  equal(seam.runtime.register.text, "Cd")

  value = editor("one\n  two\nthree")
  press(value, "3", "J")
  equal(value:GetText(), "one two three")
end)

test("replace rejects special-key tokens and empty changes are motion-specific", function()
  local value = editor("abc")
  press(value, "r", "<Left>")
  equal(value:GetText(), "abc")
  equal(seam.getstate(value).mode, "normal")
  equal(seam.getstate(value).message, "Vim: expected a character")

  press(value, "c", "0")
  equal(seam.getstate(value).mode, "normal", "a failed c0 stays Normal")
  press(value, "c", "h")
  equal(seam.getstate(value).mode, "normal", "a failed ch stays Normal")

  value = editor("")
  press(value, "C")
  equal(seam.getstate(value).mode, "insert", "C on an empty line may insert")
end)

test("open-line commands inherit indentation and enter Insert mode", function()
  local value = editor("  one")
  value:GotoPos(2)
  press(value, "o")
  equal(value:GetText(), "  one\n  ")
  equal(value:GetCurrentPos(), 8)
  equal(seam.getstate(value).mode, "insert")
  value:TypeText("next")
  press(value, "<Esc>")
  equal(value:GetText(), "  one\n  next")

  value = editor("  one")
  value:GotoPos(2)
  press(value, "O")
  equal(value:GetText(), "  \n  one")
  equal(value:GetCurrentPos(), 2)
end)

test("visual character selection yanks an inclusive range", function()
  local value = editor("abcd")
  press(value, "v", "2", "l")
  equal(value:GetSelectedText(), "abc")
  local state = seam.getstate(value)
  local first, finish, linewise = seam.visualrange(value, state)
  equal(first, 0)
  equal(finish, 3)
  equal(linewise, false)
  press(value, "y")
  equal(seam.runtime.register.text, "abc")
  equal(state.mode, "normal")
  equal(value:GetCurrentPos(), 0)
end)

test("visual delete works in both characterwise and linewise modes", function()
  local value = editor("abcd")
  value:GotoPos(1)
  press(value, "v", "l", "d")
  equal(value:GetText(), "ad")
  equal(seam.runtime.register.text, "bc")

  value = editor("a\nb\nc")
  value:GotoPos(2)
  press(value, "V", "j", "d")
  equal(value:GetText(), "a")
  equal(seam.runtime.register.text, "b\nc\n")
  equal(seam.runtime.register.linewise, true)
end)

test("Visual Block yanks, deletes, and puts rectangular text", function()
  _G.wxstc = {wxSTC_SEL_STREAM = 0, wxSTC_SEL_RECTANGLE = 1, wxSTC_SEL_LINES = 2}
  local original = "abcd\nabXd\nabcd"
  local value = editor(original)
  value:GotoPos(1)
  press(value, "<C-v>", "2", "j", "2", "l", "y")
  equal(seam.runtime.register.blockwise, true)
  equal(table.concat(seam.runtime.register.lines, "|"), "bcd|bXd|bcd")
  equal(seam.runtime.register.width, 3)
  equal(seam.getstate(value).mode, "normal")

  value:GotoPos(1)
  press(value, "<C-v>", "2", "j", "2", "l", "d")
  equal(value:GetText(), "a\na\na")
  equal(seam.runtime.register.blockwise, true)
  press(value, "p")
  equal(value:GetText(), original)
end)

test("Visual Block tolerates short lines and supports case changes", function()
  local value = editor("abcd\nx\nABCD")
  value:GotoPos(1)
  press(value, "<C-v>", "2", "j", "l", "~")
  equal(value:GetText(), "aBCd\nx\nAbcD")
  equal(seam.getstate(value).mode, "normal")
end)

test("Visual Block put replaces each selected row", function()
  local source = editor("abcd\nABCD")
  source:GotoPos(1)
  press(source, "<C-v>", "j", "l", "y")
  equal(table.concat(seam.runtime.register.lines, "|"), "bc|BC")

  local target = editor("wxyz\nWXYZ")
  target:GotoPos(1)
  press(target, "<C-v>", "j", "l", "p")
  equal(target:GetText(), "wbcz\nWBCZ")
  equal(seam.getstate(target).mode, "normal")
end)

test("linewise shift operators apply the configured indentation", function()
  local value = editor("a\n  b\nc", {indent = 2})
  press(value, "2", ">", ">")
  equal(value:GetText(), "  a\n    b\nc")
  equal(value:GetCurrentPos(), 2)
  press(value, "2", "<", "<")
  equal(value:GetText(), "a\n  b\nc")
end)

test("star, n, N, and hash search with ignorecase and wrapping", function()
  seam.runtime.config.ignorecase = true
  seam.runtime.config.smartcase = true
  seam.runtime.config.wrapscan = true
  local value = editor("foo Foo foo")
  press(value, "*")
  equal(value:GetCurrentPos(), 4)
  equal(value.searchflags, 0)
  press(value, "n")
  equal(value:GetCurrentPos(), 8)
  press(value, "n")
  equal(value:GetCurrentPos(), 0)
  press(value, "N")
  equal(value:GetCurrentPos(), 8)
  press(value, "#")
  equal(value:GetCurrentPos(), 4)

  value = editor("Foo x Foo")
  press(value, "*")
  equal(value:GetCurrentPos(), 6)
  equal(value.searchflags, 4, "smartcase retains case sensitivity")
end)

test("gt, gT, counts, and Ex commands switch editor tabs", function()
  local first, second, third = editor("one"), editor("two"), editor("three")
  local active = 2
  local documents = {}
  for index, value in ipairs({first, second, third}) do
    documents[index] = {
      GetEditor = function() return value end,
      SetActive = function() active = index end,
    }
  end
  _G.ide = {
    GetDocumentList = function() return documents end,
    GetDocument = function() return nil end,
  }

  press(second, "g", "t")
  equal(active, 3)
  press(third, "g", "T")
  equal(active, 2)
  press(second, "1", "g", "t")
  equal(active, 1, "a count before gt jumps to an absolute tab")
  press(first, "2", "g", "T")
  equal(active, 2, "a count before gT moves backwards with wraparound")

  local state = seam.getstate(second)
  truthy(seam.executeex(second, state, "tablast"))
  equal(active, 3)
  truthy(seam.executeex(third, seam.getstate(third), "tab 2"))
  equal(active, 2)
  truthy(seam.executeex(second, state, "tabprevious"))
  equal(active, 1)
end)

test("zz, zt, and zb position the viewport without moving the caret", function()
  local lines = {}
  for index = 1, 30 do lines[index] = "line" .. index end
  local value = editor(table.concat(lines, "\n"), {visiblelines = 10})
  value:GotoPos(value:PositionFromLine(20))
  local caret = value:GetCurrentPos()
  press(value, "z", "t")
  equal(value.firstvisible, 20)
  press(value, "z", "z")
  equal(value.firstvisible, 15)
  equal(value.centercount, 1)
  press(value, "z", "b")
  equal(value.firstvisible, 11)
  equal(value:GetCurrentPos(), caret)
end)

test("Ex commands handle line jumps, settings, writes, and forced quits", function()
  local value = editor("one\n  two\nthree")
  local state = seam.getstate(value)
  truthy(seam.executeex(value, state, " 2 "))
  equal(value:GetCurrentPos(), 6)
  truthy(seam.executeex(value, state, "set ignorecase"))
  equal(seam.runtime.config.ignorecase, true)
  equal(seam.executeex(value, state, "definitely-not-a-command"), false)
  equal(state.message, "Vim: not an editor command: definitely-not-a-command")

  local saved, closed, modified = 0, 0, true
  local document = {
    Save = function(self) saved = saved + 1 return true end,
    Close = function(self) closed = closed + 1 end,
    SetModified = function(self, flag) modified = flag end,
  }
  _G.ide = {
    GetDocument = function(self, candidate)
      equal(candidate, value)
      return document
    end,
    DoWhenIdle = function(self, callback) callback() end,
  }
  truthy(seam.executeex(value, state, "w"))
  equal(saved, 1)
  truthy(seam.executeex(value, state, "q!"))
  equal(closed, 1)
  equal(modified, false)
end)

test("read-only buffers reject mutations but still allow yanks", function()
  local value = editor("one two", {readonly = true})
  press(value, "d", "w")
  equal(value:GetText(), "one two")
  equal(seam.runtime.register.text, "", "a rejected delete does not change the register")
  equal(seam.getstate(value).message, "Vim: document is read-only")
  press(value, "y", "w")
  equal(seam.runtime.register.text, "one ")
  equal(value:GetText(), "one two")
end)

test("empty buffers and a trailing empty line remain safe normal positions", function()
  local value = editor("")
  press(value, "$", "x", "%", "d", "d")
  equal(value:GetText(), "")
  equal(value:GetCurrentPos(), 0)

  value = editor("a\n")
  press(value, "G")
  equal(value:GetCurrentPos(), 2)
  press(value, "d", "d")
  equal(value:GetText(), "a")
  equal(value:GetCurrentPos(), 0)
end)

test("state is per editor and reset clears shared registers and searches", function()
  local first, second = editor("abc"), editor("xyz")
  press(first, "i")
  equal(seam.getstate(first).mode, "insert")
  equal(seam.getstate(second).mode, "normal")
  seam.runtime.register = {text = "saved", linewise = false}
  seam.runtime.lastsearch = "needle"
  seam.reset()
  equal(seam.getstate(first).mode, "normal")
  equal(seam.runtime.register.text, "")
  equal(seam.runtime.lastsearch, nil)
end)

test("plugin lifecycle connects character input and handles special keys", function()
  local value = editor("abc")
  local printed, ctrlvcallback, restored = {}, nil, nil
  _G.wx = {
    wxEVT_CHAR = 1, wxID_ANY = -1,
    WXK_TAB = 9,
    WXK_ESCAPE = 27, WXK_LEFT = 314, WXK_RIGHT = 316,
    WXK_UP = 315, WXK_DOWN = 317, WXK_HOME = 313, WXK_END = 312,
    WXK_BACK = 8, WXK_DELETE = 127, WXK_RETURN = 13, WXK_NUMPAD_ENTER = 370,
  }
  _G.ide = {
    GetDocumentList = function(self)
      return {{GetEditor = function() return value end}}
    end,
    Print = function(self, message) printed[#printed + 1] = message end,
    GetStatus = function() return "" end,
    SetStatus = function() end,
    GetHotKey = function(self, shortcut)
      equal(shortcut, "Ctrl-V")
      return 99, "Ctrl-V"
    end,
    SetHotKey = function(self, action, shortcut)
      equal(shortcut, "Ctrl-V")
      if type(action) == "function" then ctrlvcallback = action return 100 end
      restored = action
      return action
    end,
    GetEditorWithFocus = function() return value end,
    GetEditor = function() return value end,
  }
  local oldconfig = plugin.GetConfig
  plugin.GetConfig = function() return {status = false, clipboard = false} end
  plugin:onRegister()
  truthy(value.handler, "character handler was connected")
  truthy(ctrlvcallback, "Ctrl-V hotkey was connected")
  equal(value.caretperiod, 0)
  local character = {
    GetUnicodeKey = function() return string.byte("i") end,
    GetKeyCode = function() return string.byte("i") end,
    Skip = function(self) self.skipped = true end,
  }
  value.handler(character)
  equal(seam.getstate(value).mode, "insert")
  equal(value.undodepth, 1)
  plugin:onEditorFocusLost(value)
  equal(value.undodepth, 0, "focus loss closes the insert undo group")
  plugin:onEditorFocusSet(value)
  equal(value.undodepth, 1, "focus regain starts a fresh insert undo group")
  local escape = {
    GetKeyCode = function() return 27 end,
    ControlDown = function() return false end,
    AltDown = function() return false end,
    MetaDown = function() return false end,
  }
  equal(plugin:onEditorKeyDown(value, escape), false)
  equal(seam.getstate(value).mode, "normal")
  local tab = {
    GetKeyCode = function() return 9 end,
    ControlDown = function() return false end,
    AltDown = function() return false end,
    MetaDown = function() return false end,
    ShiftDown = function() return false end,
  }
  equal(plugin:onEditorKeyDown(value, tab), false, "Normal mode consumes Tab")
  ctrlvcallback()
  equal(seam.getstate(value).mode, "visual_block")
  press(value, "<Esc>")
  plugin:onUnRegister()
  equal(value.handler, nil)
  equal(value.caretperiod, 500, "unregister restores the original blink period")
  equal(restored, 99, "unregister restores the original Ctrl-V hotkey")
  equal(#printed, 2)
  plugin.GetConfig = oldconfig
end)

for _, entry in ipairs(tests) do
  setup()
  local ok, message = pcall(entry.callback)
  if ok then
    passed = passed + 1
    io.write("ok - ", entry.name, "\n")
  else
    failed = failed + 1
    io.write("not ok - ", entry.name, "\n  ", tostring(message), "\n")
  end
end

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
