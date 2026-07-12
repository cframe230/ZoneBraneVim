# ZoneBraneVim

English | [中文](README.md)

An unofficial Vim-mode plugin for [ZeroBrane Studio](https://studio.zerobrane.com/). The single `vim.lua` file provides commonly used modal editing, motions, operators, search, tab navigation, and a small set of Ex commands. It is not an embedded Vim/Neovim instance and does not aim for complete Vim compatibility.

- Current version: `0.2.2`
- ZeroBrane Studio: `1.61+`
- License: MIT

## Features

| Category | Implemented |
| --- | --- |
| Modes | Normal, Insert, Replace, Visual, Visual Line, Visual Block |
| Motions | Character, word, line, paragraph, screen, bracket matching, and in-line character search; counts are supported |
| Editing | `d`, `c`, `y`, `>`, and `<` operators; paste, replace, case toggle, line join, undo, and redo |
| Search | Forward/backward and repeated search, search under cursor, configurable case sensitivity and wrapping |
| File commands | Save, close, save/close all, open a file, and jump to a line |
| Integration | Per-editor mode state, tab navigation, viewport positioning, and native ZeroBrane editing in Insert mode |
| Registers | One internal unnamed register; yanked/deleted text can also be copied to the system clipboard |

## Installation

Installing into the user package directory is recommended, as it won't be overwritten by a ZeroBrane Studio upgrade. Run the commands below from the repository root.

### Windows (PowerShell)

```powershell
$homeDir = if ($env:HOME) { $env:HOME } else { "$env:HOMEDRIVE$env:HOMEPATH" }
$packageDir = Join-Path $homeDir ".zbstudio\packages"
New-Item -ItemType Directory -Force $packageDir | Out-Null
Copy-Item .\vim.lua (Join-Path $packageDir "vim.lua")
```

The destination is usually `C:\Users\<username>\.zbstudio\packages\vim.lua`.

### macOS and Linux

```sh
mkdir -p "$HOME/.zbstudio/packages"
cp ./vim.lua "$HOME/.zbstudio/packages/vim.lua"
```

You may alternatively copy the file into the `packages/` directory of a specific ZeroBrane Studio installation. Restart the IDE after installation. `Vim Mode 0.2.2 registered` in the Output panel confirms that the plugin loaded.

## Configuration

Open `Edit | Preferences | Settings: User`, add the Lua configuration below, and restart the IDE. The configuration name `vim` corresponds to `vim.lua`.

```lua
vim = {
  enabled = true,       -- enable the plugin
  startinsert = false,  -- start new editors in Insert mode
  cursorblink = false,  -- disable caret blinking
  visualblock = true,   -- enable Ctrl-V Visual Block
  overridectrlv = true, -- claim Ctrl-V; it still pastes in Insert/Replace
  status = true,        -- show mode/messages in the status bar
  clipboard = true,     -- copy yank/delete operations to the system clipboard
  ignorecase = false,   -- ignore case when searching
  smartcase = true,     -- uppercase queries become case-sensitive with ignorecase
  wrapscan = true,      -- wrap searches at document boundaries
}
```

These values are the defaults. Set `enabled = false` to load the plugin without taking over editor keys.

## Key Bindings

`[count]` indicates an optional count, as in `3w` or `2dd`. Counts before and after an operator are multiplied, so `2d3w` applies to six words.

### Normal Mode

| Keys | Action |
| --- | --- |
| `h j k l`, arrow keys | Move left/down/up/right; `Backspace` moves left, `Space` right, and `Enter` down |
| `w W` / `b B` / `e E` | Next word start / previous word start / word end; uppercase variants split only on whitespace |
| `0` / `^` / `$` | Line start / first non-blank / line end |
| `[count]\|` | Jump to column `[count]` on the current line |
| `gg` / `[count]gg` | First line / specified line |
| `G` / `[count]G` | Last line / specified line |
| `{` / `}` | Previous / next blank-line-separated paragraph |
| `%` | Match `() [] {} <>` |
| `f{char}` `F{char}` `t{char}` `T{char}` | Find a character on the current line |
| `;` / `,` | Repeat the latest character search forward / in reverse |
| `H M L` | Move to the top / middle / bottom of the screen |
| `zz` / `zt` / `zb` | Position the current line at the center / top / bottom of the screen |
| `gt` / `gT` | Next / previous tab; `[count]gt` jumps to a numbered tab |
| `i a I A` | Enter Insert at the cursor / after it / first non-blank / line end |
| `o O` | Open a line below / above and enter Insert |
| `R` | Enter Replace mode |
| `v V` / `Ctrl-V` | Enter character / line / block Visual mode |
| `d c y > <` + motion | Delete, change, yank, indent, or unindent |
| `dd cc yy >> <<` | Apply the corresponding operation linewise; counts are supported |
| `x X s` | Delete current character / previous character / delete then Insert |
| `D C Y` | Delete to line end / change to line end / yank whole line |
| `p P` | Paste the internal register after / before |
| `r{char}` / `~` / `J` | Replace character / toggle case / join lines |
| `u` / `Ctrl-R` | Undo / redo |
| `/` / `?` | Open the forward / backward search prompt |
| `n N` / `* #` | Repeat search / search for text under the cursor |
| `Ctrl-D` `Ctrl-U` | Move down / up half a screen |
| `Ctrl-F` `Ctrl-B` | Move down / up one screen |
| `Ctrl-E` `Ctrl-Y` | Scroll down / up one line |
| `:` | Open the Ex command prompt |
| `ZZ` / `ZQ` | Save and close / force-close the current file |

### Insert and Replace Modes

Regular input and ZeroBrane Studio's native editing behavior remain available. `Tab` and `Shift-Tab` perform native indentation. Press `Esc`, `Ctrl-[`, or `Ctrl-C` to return to Normal mode.

### Visual, Visual Line, and Visual Block Modes

All three Visual modes support the motions and counts listed above, plus:

| Keys | Action |
| --- | --- |
| `v` / `V` / `Ctrl-V` | Switch to character / line / rectangular block selection; press the active mode key again to exit |
| `o` | Swap the selection endpoints |
| `d` or `x` | Delete the selection |
| `c` or `s` | Change the selection and enter Insert |
| `y` | Yank the selection |
| `p` / `P` | Replace the selection with the internal register |
| `>` / `<` / `~` | Indent / unindent / toggle case |
| `Esc` | Return to Normal mode |

## Ex Commands

Commands are entered through a ZeroBrane input dialog; this is not a full Vim command line.

| Command | Action |
| --- | --- |
| `:{line}` | Jump to a line |
| `:w` / `:write` | Save the current file |
| `:q` / `:quit`, `:q!` / `:quit!` | Close / force-close the current file |
| `:wq` / `:x` / `:xit` | Save and close; `:x` / `:xit` saves only modified or new files |
| `:wa` / `:wall` | Save all modified or new files |
| `:qa` / `:qall`, `:qa!` / `:qall!` | Close all / force-close all files |
| `:e {path}` / `:edit {path}` | Open a file |
| `:tabnext` / `:tabn`, `:tabprevious` / `:tabp` | Next / previous tab |
| `:tabfirst` / `:tablast` / `:tab {n}` | First / last / specified tab |
| `:bnext` / `:bn`, `:bprevious` / `:bp` | Tab-navigation aliases |
| `:set (no)ignorecase`, `:set (no)ic` | Toggle search case sensitivity |
| `:set (no)smartcase`, `:set (no)scs` | Toggle smart case |
| `:set (no)wrapscan`, `:set (no)ws` | Toggle search wrapping |
| `:nohl` / `:nohlsearch` | Clear the current status message; search highlighting is not currently drawn |

`:set` changes apply only to the current IDE session. Edit the user configuration to make them persistent.

## Limitations and Shortcut Conflicts

- This is a subset of Vim. Dot repeat, text objects, named registers, macros, marks/jumps, window commands, substitute commands, vimrc, and custom mappings are not implemented.
- Visual Block supports rectangular `y/d/x/c/p/P/~/>/<`. Block `c` deletes the rectangle but enters Insert only at the top-left corner; typed text is not yet replicated to every selected row.
- Search is literal and has no regex, incremental mode, history, completion, or result highlighting. Search and Ex commands use modal dialogs.
- `y`, `d`, `c`, and `x` write to one internal register and may also copy to the system clipboard. `p`/`P` do not automatically read later clipboard changes made outside the plugin.
- The plugin safely claims `Ctrl-V` by default: it enters Visual Block in Normal/Visual modes, performs native paste in Insert/Replace, and restores the original shortcut when unloaded. Set `overridectrlv = false` to disable this behavior.
- Other ZeroBrane global shortcuts are processed before editor events. ZeroBrane 2.01 conflicts include `Ctrl-R` (Replace), `Ctrl-U` (Comment), `Ctrl-F` (Find), `Ctrl-B` (Navigate to Symbol), `Ctrl-Y` (Redo), and `Ctrl-C` (Copy). macOS Command shortcuts are not intercepted.
- The plugin assumes one caret and one selection. ZeroBrane multi-selection state may be collapsed.
- Mode messages use the first status-bar field and may overwrite temporary messages from other plugins. Set `status = false` to disable them.
- `w/b/e` classify all non-ASCII characters as word characters, so adjacent Unicode punctuation or emoji may be grouped into the same word. `~` case conversion primarily targets ASCII letters.
- `:edit` passes its argument directly to ZeroBrane and does not implement Vim path escaping, environment expansion, or globbing.

To prioritize Vim's conflicting Ctrl bindings, clear the matching ZeroBrane shortcuts in the user configuration. This also disables those IDE shortcuts in Insert mode:

```lua
keymap[ID.REPLACE] = ""          -- Ctrl-R: Vim redo
keymap[ID.COMMENT] = ""          -- Ctrl-U: half-page up
keymap[ID.FIND] = ""             -- Ctrl-F: page down
keymap[ID.NAVIGATETOSYMBOL] = "" -- Ctrl-B: page up
keymap[ID.REDO] = ""             -- Ctrl-Y: scroll up
keymap[ID.COPY] = ""             -- Ctrl-C: leave Insert/Replace
```

You can also set `vim.enabled = false` and restart the IDE, or remove `vim.lua` from the user package directory.

## Testing

With Lua 5.1+ installed, run from the repository root:

```sh
lua tests/test_vim.lua
```

The tests use a mock editor to verify the core state machine and editing operations without launching ZeroBrane Studio. GUI events and platform shortcuts should still be checked manually in the target IDE. For a quick syntax check, run `luac -p vim.lua`.

## References and Acknowledgements

- Plugin lifecycle, installation paths, and configuration follow the [ZeroBrane Studio plugin documentation](https://studio.zerobrane.com/doc-plugin) and [configuration documentation](https://studio.zerobrane.com/doc-configuration).
- Key names and interaction semantics follow the [Vim help index](https://github.com/vim/vim/blob/master/runtime/doc/index.txt). Vim is a project by Bram Moolenaar and contributors; this plugin contains no Vim source code.
- Editor operations use ZeroBrane's wxStyledTextCtrl/Scintilla interface; see the [Scintilla documentation](https://www.scintilla.org/ScintillaDoc.html).

This project is not affiliated with ZeroBrane Studio or Vim. It is distributed under the [MIT License](LICENSE).
