# nvim-dapper

A UI for [nvim-dap](https://github.com/mfussenegger/nvim-dap), made of plain Neovim windows:
a column of **panes**, each showing one view, with the views as tabs in its window bar: the
view shown by its name, the others by the key that shows them (`Watches  S  E  B  C …`). Any
pane shows any view, and panes split and close like windows, so you see as much (or as little)
as you want at once.

Inspired by [nvim-dap-view](https://github.com/igorlfs/nvim-dap-view) and
[raddebugger](https://github.com/EpicGamesExt/raddebugger).

## Getting started

```lua
require("dapper").setup() -- optional: the defaults apply on first use
vim.keymap.set("n", "<leader>dd", "<Cmd>Dapper<CR>") -- every action, to pick from
```

Start debugging with nvim-dap as usual: the panes open (Watches above the call stack) and close
when it ends. `g?` in any pane lists its keys, and `:Dapper` alone lists everything you can do
now. For gdb (C, C++, ...) there is nothing more to set up: if you have no gdb adapter, `setup()`
adds one. `:checkhealth dapper` checks it all, with the fix for what is missing.

## Views

| Key | View | |
|---|---|---|
| `W` | Watches | expressions, evaluated at each stop (in the selected frame); kept per project |
| `S` | Scopes | the variables of the selected frame (the registers collapsed) |
| `E` | Exceptions | when to stop on them (C++ throw, …) |
| `B` | Breakpoints | all of them: on lines (their code highlighted as in the file), functions, instructions, values changing |
| `C` | Call stack | the frames of the stopped thread; the selected one marked |
| `T` | Threads | all threads, with their frames (filterable) |
| `K` | Sessions | the programs being debugged |
| `R` | REPL | nvim-dap's (gdb: `p/x var`, `x/8xb &var`, …) |
| `O` | Program I/O | the program's terminal: type in it to give it input |

- Variables show as `name = value  type`, the values of siblings lined up.
- A watched pointer shows its address, and what it points to below it; a struct or array what it
  holds, in one line, also collapsed (`{mass = 20, id = 7, pos = {…}}`, `{1, 2, 3}`).
- Values that changed since the last stop are highlighted.
- Watches also take the debugger's own commands, as typed in its REPL: with gdb, `p/t n`,
  `x/8xb &n`, `info frame`, and `/t n` for short (`print/t n`). (A division is written with
  spaces, `x / 2`: `x/2` is gdb's `x` command.)
- Optionally (`virtual_text = true`), the variables' values are also shown at the end of their
  lines in the code.

## Breakpoints, of every kind

- **On a line**: nvim-dap's own (`toggle_breakpoint`). With a condition or as a log point:
  `require("dapper").conditional_breakpoint()` / `log_point()` (or `:Dapper condition` / `log`):
  they ask for it with completion, offer the line's own to edit, and `<Esc>` sets nothing.
- **On a function**, by name: `:Dapper break malloc` (completes the program's functions). Kept
  per project.
- **When a value changes**: `x` on a variable (Watches, Scopes, hover), or `:Dapper break-change
  n`: the program stops right after something changes it. (gdb: `watch -location`, so it also
  catches changes after the function returned.)
- **On an instruction**: `x` in Disassembly.

All are listed in the Breakpoints view; `d` deletes one there.

## Pins

`:Dapper pin [expr]` pins an expression to the cursor's line: its value is shown at the end of
that line at each stop (only what you chose, unlike virtual text). The same again removes it.
Pins move with their line when you edit, and are kept per project.

## Memory and Disassembly

Each in a **tab page** of its own (the code's tab page stays as it is; `:q` closes them, as any
window):

- **Memory** (`:Dapper memory [expr]`): the bytes at an address, 16 a row, in hex and as text.
  Opened without an expression, it goes to the selected frame's variables and follows them. Each
  variable's bytes have a colour, each frame's part of the stack is labelled with its function
  (`⟨main⟩`), and changed bytes are highlighted. The window bar is the columns' header.
  - Moving the cursor: its column lights up in the header, the byte's twin (hex / text) too, and
    its row says what is under it: the variable, in its colour (`n = 21  int`), down to the member
    of a struct or array (`frogs[1].temperature_C = 25.5  double`), else what the bytes read as
    (`u8 200 (-56)  u16 456  u32 …  f32 …  f64 …`).
  - `f` (find) goes to an address, a variable or any expression (`*p`, `$sp`), with completion;
    nothing goes back to the frame's variables. Vim's `/` searches the rows shown.
  - `r` writes bytes at the cursor (hex: `c8`, or `c8 01 ff`); `[[` / `]]` page; `.` back to what
    is followed.
- **Disassembly** (`:Dapper disassembly [expr]`): the function's instructions with its source
  lines between them, the current instruction marked `→`. From a file, it opens at the cursor's
  line, its instructions highlighted.
  - `<CR>` on an instruction shows its source line (and highlights that line's instructions); on
    a source line, goes to it.
  - `x` toggles a breakpoint on an instruction; `f` (find) goes to a function, an address or an
    expression; `.` back to the current instruction.
  - **While the cursor is in it, stepping goes one instruction at a time.**

## Keys

In every pane (the REPL and Program I/O too):

| Key | |
|---|---|
| `W` `S` `E` `B` `C` `T` `K` `R` `O` | show that view |
| `]v` / `[v` | the next / previous view |
| `<C-w>s` / `<C-w>v` | split the pane: a new one below / to the side (`:split` / `:vsplit` too) |
| `:q` | close the pane, as any window (they open again as you left them) |
| `g?` | the keys (also in the tab pages and the hover float; `q` closes the list) |

The same key does the same everywhere:

| Key | Does |
|---|---|
| `<CR>` | the main action: expand, select the frame, go to it, toggle |
| `d` | delete (a watch, a breakpoint) |
| `x` | break on it: when the value changes (a variable), on the instruction (Disassembly) |
| `m` | its memory (a variable) |
| `D` | its disassembly (a frame) |
| `s` / `c` | set / copy a value |
| `f` | find (Memory, Disassembly); filter the frames (Threads) |

And: Watches `i` / `a` add above / below, `e` edit; `[[` the parent of a value; Breakpoints `p`
shows it without leaving; Call stack `o` goes to the frame's line, `t` hides library frames;
Threads `F` inverts the filter.

## Commands

`:Dapper` alone lists the actions available now, to pick from, with the keys you mapped to
them (to learn them). Or directly:

| Command | |
|---|---|
| `:Dapper toggle` / `open` / `close` | the panes |
| `:Dapper show {view}` | a view, in a pane |
| `:Dapper watch [expr]` | watch it (default: the expression under the cursor, or the selection) |
| `:Dapper hover [expr]` | its value in a float, as a tree; again: into it (`q` closes it) |
| `:Dapper memory [expr]` / `disassembly [expr]` | see above |
| `:Dapper break {function}` / `break-change [expr]` | break on a function / when a value changes |
| `:Dapper condition` / `log` | a breakpoint on the cursor's line with a condition / a log point |
| `:Dapper pin [expr]` | pin a value to the cursor's line |
| `:Dapper jump` | set next statement: go on from the cursor's line (the lines between are not run) |
| `:Dapper virtual-text` | the values in the code, on or off |

They complete: views, the program's functions, and expressions: the selected frame's variables,
the members after `.` or `->`, and the names of the file you are in (so a condition can be
completed before the program runs). Nothing is mapped for you; for example:

```lua
vim.keymap.set("n", "<leader>dd", "<Cmd>Dapper<CR>")
vim.keymap.set("n", "<leader>dv", "<Cmd>Dapper toggle<CR>")
vim.keymap.set("n", "<leader>dB", require("dapper").conditional_breakpoint)
vim.keymap.set("n", "<leader>dl", require("dapper").log_point)
vim.keymap.set({ "n", "x" }, "<leader>dw", "<Cmd>Dapper watch<CR>")
vim.keymap.set({ "n", "x" }, "<leader>dk", "<Cmd>Dapper hover<CR>")
vim.keymap.set({ "n", "x" }, "<leader>dm", "<Cmd>Dapper memory<CR>")
vim.keymap.set("n", "<leader>da", "<Cmd>Dapper disassembly<CR>")
```

The same completion, for prompts of your own:

```lua
vim.fn.input({ prompt = "Condition: ", completion = "customlist,v:lua.require'dapper'.complete" })
```

## Status line

`require("dapper").status()` says what the debugger is doing: `⏸ stats.c:42 maximum`,
`▶ running`, or nothing when not debugging:

```lua
vim.o.statusline = "%f %= %{v:lua.require'dapper'.status()}"
```

## Setup

`setup()` is optional (without it, the defaults apply on first use). Its options, with their
defaults:

```lua
require("dapper").setup({
  position = "right",      -- "right", "left" or "below"
  size = 0.4,              -- of the column: a fraction, or columns (lines, "below")
  layout = {               -- the panes it opens with; then, as you left them
    { view = "watches" },
    { view = "stack", split = "below" }, -- "below" or "right" of the pane before
  },
  views = { "watches", "scopes", "exceptions", "breakpoints", "stack", "threads", "sessions", "repl", "io" },
  auto_open = true,        -- with a debug session
  auto_close = true,       -- when it ends
  follow_tab = false,      -- move the panes to the tab you enter, while debugging
  keep_cursor = true,      -- the program stops: show its line without moving the cursor
  signs = true,            -- ● ◆ ◉ → ✗ for breakpoints and the stop
  virtual_text = false,    -- the values of the variables at the end of their lines
  controls = false,        -- continue/step/stop buttons in the panes' bar (for the mouse)
  icons = { collapsed = "▸", expanded = "▾", enabled = "●", disabled = "○", current = "→" },
  memory = { columns = 16, rows = 64 },                -- bytes a row, rows shown
  disassembly = { instructions = 100, bytes = false }, -- instructions shown; their bytes too
})
```

The highlight groups (`DapperTab`, `DapperName`, `DapperChanged`, …: see `:help
dapper-highlights`) link to Neovim's own (`TabLine`, `Identifier`, `DiagnosticVirtualTextWarn`
for changed values, …), so it follows your colorscheme.

## gdb

gdb 14 and later speak DAP; gdb 16 or later is best: 14 and 15 start the program as soon as it is
launched, before the breakpoints are set, so it can run past some set beforehand (dapper's
function breakpoints come too late). `setup()` gives nvim-dap a gdb adapter if you have none: like
`require("dapper").gdb()`, which gives the program the "Program I/O" terminal (gdb gives it none,
so `scanf()` would read nothing). Debuggers that run programs in a terminal themselves, like
debugpy, get theirs there too. dapper also works around gdb answering breakpoints set before the
program loads without their line (nvim-dap then marked all but one as rejected).

## Kept per project

The watches, pins and function breakpoints of each project (its git root, else the working
directory) are kept in `stdpath("data")/dapper.json`.

## Tests

`scripts/test.sh` (it clones plenary.nvim and nvim-dap into `.deps/` on the first run; the
debugging tests need gcc and gdb 14 or later).
