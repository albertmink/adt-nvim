# adt-nvim

A Neovim client for the ADT Language Server — browse and navigate ABAP without leaving the terminal.

![demo](demo-nvim.gif)

- **A personal study** — a hands-on way to learn how an LSP client actually works.
- **A years-old dream** — never leaving the terminal to edit ABAP code.
- **Just fun** — built for the joy of it, nothing more.
- **...and maybe** — run Neovim headless and hand its `M.api` to an AI agent as tools. 😉

## Requirements

- **Neovim 0.10+**
- **The `adt-ls` binary.** It ships with the [SAP ADT extension for VSCode](https://marketplace.visualstudio.com/items?itemName=SAPSE.adt-vscode) — install that once, and adt-nvim finds the binary automatically under `~/.vscode/extensions/`. Alternatively, point the `ADT_LS_PATH` environment variable at the binary yourself.
- **`python3`** on your `PATH` (used to hand credentials to the language server securely).
- Optional: [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) for a nicer object picker, [nvim-navic](https://github.com/SmiteshP/nvim-navic) for breadcrumbs. Both are used if present, and plain `vim.ui` fallbacks kick in if they aren't.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "albertmink/adt-nvim",
  dependencies = {
    "nvim-telescope/telescope.nvim", -- optional
    "SmiteshP/nvim-navic",           -- optional
  },
  config = function()
    require("adt").setup()
  end,
}
```

## Authentication

On first use you'll pick a SAP destination. Depending on how it authenticates, supply credentials in one of these ways:

- **SSO** (SAP Secure Login Client) — works out of the box; `SNC_LIB` is resolved automatically.
- **Password via `setup()`** — `require("adt").setup({ password = "..." })`.
- **Password via environment** — export `ADT_PASSWORD` before launching Neovim.

You can also pre-select a destination with `require("adt").setup({ destination = "MY_DEST" })`.

### Destination store

Destinations aren't managed by adt-nvim — they live in a store owned by the language server, under `~/.adtls/` (holding `destinations.json`). The plugin only points the server at that directory and reads the list back; it never writes destinations itself. Whatever destinations exist in the store show up in `:AdtOpen` and `:AdtSwitch` automatically, since the list is always fetched fresh from the server.

This means the store is shared across sessions but *not* with your VSCode ADT setup unless both point at the same directory — VSCode's ADT extension typically uses its own location, so destinations configured there won't appear in Neovim automatically.

## Usage

Run `:AdtOpen` to search for and open an ABAP object. Once a buffer is open, these keymaps are active:

| Key   | Action              |
| ----- | ------------------- |
| `gd`  | Go to definition    |
| `gD`  | Go to declaration   |
| `gr`  | Find references     |
| `gi`  | Go to implementation|
| `go`  | Document symbols    |
| `K`   | Hover info          |
| `gth` | Type hierarchy      |

Other commands: `:AdtSwitch` (change destination), and `:AdtApi` — the programmatic entry point behind the "hand `M.api` to an AI agent" idea above.
