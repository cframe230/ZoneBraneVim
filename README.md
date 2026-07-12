# ZoneBraneVim

[English](README.en.md) | 中文

一个面向 [ZeroBrane Studio](https://studio.zerobrane.com/) 的非官方 Vim 模式插件。它用单个 `vim.lua` 提供常用的模式化编辑、移动、操作符、搜索和少量 Ex 命令；不是 Vim/Neovim 的嵌入版本，也不追求完整兼容。

- 当前版本：`0.2.2`
- ZeroBrane Studio：`1.61+`
- 许可证：MIT

## 功能

| 类别 | 已实现 |
| --- | --- |
| 模式 | Normal、Insert、Replace、Visual、Visual Line、Visual Block |
| 移动 | 字符、单词、行、段落、屏幕、括号匹配、行内字符查找；支持计数 |
| 编辑 | `d`、`c`、`y`、`>`、`<` 操作符，粘贴、替换、大小写切换、合并行、撤销/重做 |
| 搜索 | 前后搜索、重复搜索、光标处文本搜索；可配置大小写与回绕 |
| 文件命令 | 保存、关闭、全部保存/关闭、打开文件和跳转行 |
| 集成 | 每个编辑器独立保存模式；标签页切换；视口定位；插入模式沿用 ZeroBrane 原生编辑能力 |
| 寄存器 | 一个内部匿名寄存器；复制/删除内容可同步到系统剪贴板 |

## 安装

推荐安装到用户插件目录，这样升级 ZeroBrane Studio 时不会被覆盖。下面的命令都应在本仓库根目录执行。

### Windows（PowerShell）

```powershell
$homeDir = if ($env:HOME) { $env:HOME } else { "$env:HOMEDRIVE$env:HOMEPATH" }
$packageDir = Join-Path $homeDir ".zbstudio\packages"
New-Item -ItemType Directory -Force $packageDir | Out-Null
Copy-Item .\vim.lua (Join-Path $packageDir "vim.lua")
```

通常目标文件是 `C:\Users\<用户名>\.zbstudio\packages\vim.lua`。

### macOS

```sh
mkdir -p "$HOME/.zbstudio/packages"
cp ./vim.lua "$HOME/.zbstudio/packages/vim.lua"
```

目标文件是 `/Users/<用户名>/.zbstudio/packages/vim.lua`。

### Linux

```sh
mkdir -p "$HOME/.zbstudio/packages"
cp ./vim.lua "$HOME/.zbstudio/packages/vim.lua"
```

目标文件是 `/home/<用户名>/.zbstudio/packages/vim.lua`。

也可把文件放进 ZeroBrane Studio 安装目录的 `packages/`，作为该安装实例的插件。完成后重启 IDE；Output 面板出现 `Vim Mode 0.2.2 registered` 即表示加载成功。

## 配置

打开 `Edit | Preferences | Settings: User`，加入以下 Lua 配置并重启 IDE。配置名 `vim` 对应文件名 `vim.lua`。

```lua
vim = {
  enabled = true,       -- 启用插件
  startinsert = false,  -- 新编辑器是否从 Insert 模式开始
  cursorblink = false,  -- 关闭光标闪烁
  visualblock = true,   -- 启用 Ctrl-V Visual Block
  overridectrlv = true, -- 接管 Ctrl-V；Insert/Replace 中仍执行粘贴
  status = true,        -- 在状态栏显示模式/提示
  clipboard = true,     -- yank/delete 时同步到系统剪贴板
  ignorecase = false,   -- 搜索忽略大小写
  smartcase = true,     -- ignorecase 开启时，大写查询恢复区分大小写
  wrapscan = true,      -- 搜索到文件边界后回绕
}
```

上述值就是插件的默认行为。`enabled = false` 可让插件加载但不接管编辑器按键。

## 键位

`[count]` 表示可选计数，例如 `3w`、`2dd`。操作符前后都可带计数并相乘，例如 `2d3w` 按 6 个单词处理。

### Normal 模式

| 键位 | 功能 |
| --- | --- |
| `h j k l`、方向键 | 左、下、上、右；`Backspace` 左移，`Space` 右移，`Enter` 下移 |
| `w W` / `b B` / `e E` | 下一个词首 / 上一个词首 / 词尾；大写版本按空白分词 |
| `0` / `^` / `$` | 行首 / 首个非空白 / 行尾 |
| `[count]\|` | 跳到当前行第 `[count]` 列 |
| `gg` / `[count]gg` | 首行 / 指定行 |
| `G` / `[count]G` | 末行 / 指定行 |
| `{` / `}` | 上一个 / 下一个空行分隔的段落 |
| `%` | 匹配 `() [] {} <>` |
| `f{char}` `F{char}` `t{char}` `T{char}` | 当前行字符查找 |
| `;` / `,` | 同向 / 反向重复最近的字符查找 |
| `H M L` | 屏幕顶部 / 中部 / 底部 |
| `zz` / `zt` / `zb` | 将当前行置于屏幕中央 / 顶部 / 底部 |
| `gt` / `gT` | 下一个 / 上一个标签页；`[count]gt` 跳到指定标签页 |
| `i a I A` | 在当前位置、之后、首个非空白、行尾进入 Insert |
| `o O` | 在下方 / 上方新开一行并进入 Insert |
| `R` | 进入 Replace |
| `v V` / `Ctrl-V` | 进入字符 / 行 / 块 Visual 模式 |
| `d c y > <` + 移动 | 删除、修改、复制、增加缩进、减少缩进 |
| `dd cc yy >> <<` | 对整行执行对应操作；支持计数 |
| `x X s` | 删除当前字符、删除前一字符、删除后进入 Insert |
| `D C Y` | 删除至行尾、修改至行尾、复制整行 |
| `p P` | 在之后 / 之前粘贴内部寄存器 |
| `r{char}` / `~` / `J` | 替换字符 / 切换大小写 / 合并行 |
| `u` / `Ctrl-R` | 撤销 / 重做 |
| `/` / `?` | 弹窗输入向前 / 向后搜索内容 |
| `n N` / `* #` | 重复搜索 / 搜索光标处文本 |
| `Ctrl-D` `Ctrl-U` | 向下 / 向上移动半屏 |
| `Ctrl-F` `Ctrl-B` | 向下 / 向上移动一屏 |
| `Ctrl-E` `Ctrl-Y` | 向下 / 向上滚动一行 |
| `:` | 弹窗输入 Ex 命令 |
| `ZZ` / `ZQ` | 保存并关闭 / 强制关闭当前文件 |

### Insert 与 Replace 模式

普通输入和 ZeroBrane Studio 的编辑功能保持原样，`Tab` 与 `Shift-Tab` 执行原生缩进。按 `Esc`、`Ctrl-[` 或 `Ctrl-C` 返回 Normal 模式。

### Visual / Visual Line / Visual Block 模式

三种 Visual 模式支持上表中的移动和计数，并支持：

| 键位 | 功能 |
| --- | --- |
| `v` / `V` / `Ctrl-V` | 切换字符选择 / 整行选择 / 矩形块选择；再次按当前模式键退出 |
| `o` | 交换选择区两端 |
| `d` 或 `x` | 删除选择区 |
| `c` 或 `s` | 修改选择区并进入 Insert |
| `y` | 复制选择区 |
| `p` / `P` | 用内部寄存器替换选择区 |
| `>` / `<` / `~` | 增加缩进 / 减少缩进 / 切换大小写 |
| `Esc` | 返回 Normal 模式 |

## Ex 命令

命令通过 ZeroBrane 的输入弹窗获取，不是在编辑器底部提供完整 Vim 命令行。

| 命令 | 功能 |
| --- | --- |
| `:{行号}` | 跳转到指定行 |
| `:w` / `:write` | 保存当前文件 |
| `:q` / `:quit`、`:q!` / `:quit!` | 关闭 / 强制关闭当前文件 |
| `:wq` / `:x` / `:xit` | 保存并关闭；`:x` / `:xit` 只在有改动或是新文件时保存 |
| `:wa` / `:wall` | 保存全部已修改或新建文件 |
| `:qa` / `:qall`、`:qa!` / `:qall!` | 关闭全部 / 强制关闭全部文件 |
| `:e {path}` / `:edit {path}` | 打开文件 |
| `:tabnext` / `:tabn`、`:tabprevious` / `:tabp` | 下一个 / 上一个标签页 |
| `:tabfirst` / `:tablast` / `:tab {n}` | 首个 / 末个 / 指定标签页 |
| `:bnext` / `:bn`、`:bprevious` / `:bp` | 标签页切换别名 |
| `:set (no)ignorecase`、`:set (no)ic` | 切换搜索大小写敏感性 |
| `:set (no)smartcase`、`:set (no)scs` | 切换智能大小写 |
| `:set (no)wrapscan`、`:set (no)ws` | 切换搜索回绕 |
| `:nohl` / `:nohlsearch` | 清除当前状态提示；插件目前不绘制搜索高亮 |

`:set` 所做的修改只影响当前 IDE 会话；如需持久化，请修改用户配置。

## 限制与冲突

- 这是常用 Vim 操作的子集：暂不支持 `.` 重复、文本对象、命名寄存器、宏、标记/跳转、窗口命令、替换命令、vimrc 或自定义映射。
- Visual Block 支持矩形 `y/d/x/c/p/P/~/>/<`；其中 `c` 删除整块后只在块左上角进入 Insert，尚未复制输入到所有选中行。
- 搜索是字面文本搜索，没有正则、增量搜索、历史、补全或结果高亮；搜索和 Ex 都使用模态弹窗。
- `y`、`d`、`c`、`x` 等会写入一个内部寄存器，并可向系统剪贴板复制；`p`/`P` 不会主动读取插件外部后来写入的剪贴板内容。
- Normal/Visual 模式会接管可打印字符以及它收到的导航和 `Ctrl` 键。插件默认安全接管 `Ctrl-V`：Normal/Visual 中进入块选择，Insert/Replace 中仍执行原生粘贴，卸载时恢复原快捷键；可设 `overridectrlv = false` 禁用。ZeroBrane 的其他全局快捷键会先于编辑器事件执行，2.01 的默认冲突包括 `Ctrl-R`（替换）、`Ctrl-U`（注释）、`Ctrl-F`（查找）、`Ctrl-B`（符号导航）、`Ctrl-Y`（重做）和 `Ctrl-C`（复制）。macOS 的 `Command` 组合键不由插件接管。
- 插件按单光标、单选择区工作；ZeroBrane 的多光标/多选择状态可能被折叠。
- 状态提示使用 ZeroBrane 状态栏的第一个区域，可能覆盖其他插件的临时消息；可设 `status = false`。
- `w/b/e` 会把非 ASCII 字符统一视作单词字符，因此相邻的 Unicode 标点/Emoji 也可能被归入同一词段；`~` 的大小写切换主要面向 ASCII 字母。
- `:edit` 直接把参数交给 ZeroBrane，未实现 Vim 的路径转义、环境变量和通配符展开。

如果希望这些 `Ctrl` 移动、重做和退出键优先，可在用户配置中解除相应全局快捷键；代价是 Insert 模式下也不再使用这些 IDE 快捷键：

```lua
keymap[ID.REPLACE] = ""          -- Ctrl-R：Vim redo
keymap[ID.COMMENT] = ""          -- Ctrl-U：Vim 半屏上移
keymap[ID.FIND] = ""             -- Ctrl-F：Vim 整屏下移
keymap[ID.NAVIGATETOSYMBOL] = "" -- Ctrl-B：Vim 整屏上移
keymap[ID.REDO] = ""             -- Ctrl-Y：Vim 向上滚动
keymap[ID.COPY] = ""             -- Ctrl-C：Insert/Replace 退出
```

也可临时设置 `vim.enabled = false` 并重启 IDE，或从用户插件目录移走 `vim.lua`。

## 测试

安装 Lua 5.1+ 后，在仓库根目录运行：

```sh
lua tests/test_vim.lua
```

测试使用模拟编辑器验证核心状态机和编辑操作，不启动 ZeroBrane Studio；GUI 事件与平台快捷键仍建议在目标 IDE 中手工验证。也可用 `luac -p vim.lua` 做快速语法检查。

## 参考与致谢

- 插件生命周期、安装目录和配置方式参考 [ZeroBrane Studio 插件文档](https://studio.zerobrane.com/doc-plugin) 与 [配置文档](https://studio.zerobrane.com/doc-configuration)。
- 键位名称和交互语义参考 [Vim 官方帮助索引](https://github.com/vim/vim/blob/master/runtime/doc/index.txt)。Vim 是 Bram Moolenaar 等贡献者的项目；本插件不包含 Vim 源代码。
- 编辑器操作建立在 ZeroBrane 暴露的 wxStyledTextCtrl/Scintilla 接口上；接口行为可参阅 [Scintilla 文档](https://www.scintilla.org/ScintillaDoc.html)。

本项目与 ZeroBrane Studio、Vim 官方均无隶属关系。项目代码按 [MIT License](LICENSE) 发布。
