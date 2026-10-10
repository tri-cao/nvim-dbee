<!-- DOCGEN_IGNORE_START -->

<!-- This tag controlls what's ignored by the docgen workflow. -->

![Linting Status](https://img.shields.io/github/actions/workflow/status/kndndrj/nvim-dbee/lint.yml?label=linting&style=for-the-badge)
![Docgen Status](https://img.shields.io/github/actions/workflow/status/kndndrj/nvim-dbee/docgen.yml?label=docgen&logo=neovim&logoColor=white&style=for-the-badge)
![Backend](https://img.shields.io/badge/go-backend-lightblue?style=for-the-badge&logo=go&logoColor=white)
![Frontend](https://img.shields.io/badge/lua-frontend-blue?style=for-the-badge&logo=lua&logoColor=white)

[!["Buy Me A Coffee"](https://www.buymeacoffee.com/assets/img/custom_images/yellow_img.png)](https://www.buymeacoffee.com/kndndrj)

<!-- DOCGEN_IGNORE_END -->

# Neovim DBee

**Database Client for NeoVim!**

**Execute Your Favourite Queries From the Comfort of Your Editor!**

**Backend in Go!**

**Frontend in Lua!**

**Doesn't rely on CLI tools!**

**Get Results FAST With Under-the-hood Iterator!**

Queries run from the editor are sent as written. Add an explicit `LIMIT` when you want to restrict
the number of rows returned.

**Bees Love It!**

***Alpha Software - Expect Breaking Changes!***

<!-- DOCGEN_IGNORE_START -->

![Screenshot](assets/screenshot.jpg)

<!-- DOCGEN_IGNORE_END -->

<!-- DOCGEN_IGNORE_START -->

### Video Introduction

If you prefer to watch a video than to browse through docs, I made a video, which you can watch
[here](https://youtu.be/MDlYsGbKJyQ)

<!-- DOCGEN_IGNORE_END -->

## Installation

**requires nvim>=0.10**

- packer.nvim:

  ```lua
  use {
    "kndndrj/nvim-dbee",
    requires = {
      "MunifTanjim/nui.nvim",
    },
    run = function()
      -- Install tries to automatically detect the install method.
      -- if it fails, try calling it with one of these parameters:
      --    "curl", "wget", "bitsadmin", "go"
      require("dbee").install()
    end,
    config = function()
      require("dbee").setup(--[[optional config]])
    end
  }
  ```

- lazy.nvim:

  ```lua
  {
    "kndndrj/nvim-dbee",
    dependencies = {
      "MunifTanjim/nui.nvim",
    },
    build = function()
      -- Install tries to automatically detect the install method.
      -- if it fails, try calling it with one of these parameters:
      --    "curl", "wget", "bitsadmin", "go"
      require("dbee").install()
    end,
    config = function()
      require("dbee").setup(--[[optional config]])
    end,
  },
  ```

### Platform Support

<!-- DOCGEN_IGNORE_START -->

<details>
  <summary>Click to expand</summary>
<!-- DOCGEN_IGNORE_END -->

This project aims to be as cross-platform as possible, but there are some limitations (for example
some of the go dependencies only work on certain platforms). To address this issue, the client
implementations are detached from the main logic and they register themselves to dbee backend on
plugin start. This allows the use of build constraints, which we use to exclued certain client
implementations on certain platforms.

The CI pipeline tries building the binary for GOARCH/GOOS combinations specified in
[targets.json](ci/targets.json) - if the builds succeed, they are stored in a
[remote bucket](https://github.com/kndndrj/nvim-dbee-bucket) on a separate branch per run.
Additionally, the [install manifest](lua/dbee/install/__manifest.lua) gets created.

To increase cgo cross-platform support, the pipeline uses zig as a C compiler.

To check if your platform is currently supported, check out the mentioned manifest and the targets
file.

<!-- DOCGEN_IGNORE_START -->

</details>
<!-- DOCGEN_IGNORE_END -->

### Manual Binary Installation

<!-- DOCGEN_IGNORE_START -->

<details>
  <summary>Click to expand</summary>
<!-- DOCGEN_IGNORE_END -->

The installation examples include the `build`/`run` functions, which get triggered once the plugin
updates. This should be sufficient for the majority of users. If that doesn't include you, then you
have a few options:

- just install with the `"go"` option (this performs `go build` under the hood):
  ```lua
  require("dbee").install("go")
  ```
- Download an already compiled binary from one of urls in the
  [install manifest](lua/dbee/install/__manifest.lua)
- `go install` (the install location will vary depending on your local go configuration):
  ```sh
  go install github.com/kndndrj/nvim-dbee/dbee@<version>
  ```
- Clone and build
  ```sh
  # Clone the repository and cd into the "go subfolder"
  git clone <this_repo>
  cd <this_repo>/dbee
  # Build the binary (optional output path)
  go build [-o ~/.local/share/nvim/dbee/bin/dbee]
  ```

<!-- DOCGEN_IGNORE_START -->

</details>
<!-- DOCGEN_IGNORE_END -->

## Configuration

You can pass an optional table parameter to `setup()` function.

Here are the defaults:

<!--DOCGEN_CONFIG_START-->

<!-- Contents from lua/dbee/config.lua are inserted between these tags for docgen. -->

[`config.lua`](lua/dbee/config.lua)

<!--DOCGEN_CONFIG_END-->

## Usage

Call the `setup()` function with an optional config parameter.

<!-- DOCGEN_IGNORE_START -->

<details>
  <summary>Brief reference (click to expand):</summary>
<!-- DOCGEN_IGNORE_END -->

```lua
-- Open/close/toggle the UI.
require("dbee").open()
require("dbee").close()
require("dbee").toggle()
-- Search connections, schemas, datasets, and tables with Snacks picker.
require("dbee").search()
-- Run a query on the currently active connection.
require("dbee").execute(query)
-- Store the current result to file/buffer/yank-register (see "Getting Started").
require("dbee").store(format, output, opts)
```

The same functions are also available through the `:Dbee` user command.

With [snacks.nvim](https://github.com/folke/snacks.nvim) installed and its picker enabled,
press `/` in the drawer or run `:Dbee search` to search across all configured connections,
including collapsed schemas and BigQuery datasets. Type to filter results; table and view
previews show cached DDL, while connection, schema, and dataset previews are empty.
Press Enter on a connection, schema, or dataset to open that connection's scratchpad;
on a table or view, Enter runs the adapter's `List` query and displays its data.
Use `:Dbee search users` or `require("dbee").search("users")` to start with a search term.

By default, DBee opens its editor, results, drawer, and call log as windows in a dedicated tab.
Calling `open()` again focuses that tab and resets the pane sizes. Closing DBee returns to the
previous window and preserves unsaved notes in their buffers.
With bufferline.nvim active, the bufferline starts after the drawer and follows its width when resized.
Inside DBee, `[b` and `]b` cycle through open scratchpads, skipping unrelated buffers and focusing
the editor. Selecting a connection's scratchpad also activates that connection.

<!-- DOCGEN_IGNORE_START -->

</details>
<!-- DOCGEN_IGNORE_END -->

### Getting Started

Here are a few steps to quickly get started:

- call the `setup()` function in your `init.lua`

- Specify connections using one or more sources (reffer to [this section](#specifying-connections)).

- When you restart the editor, call `lua require("dbee").open()` to open the UI.

- Navigate to the drawer (tree) and use the following key-bindings to perform different actions
  depending on the context (the mappings can all be changed in the config):

  - All nodes:

    - Press `<CR>` to toggle grouping nodes.
    - Double click a node to perform its `<CR>` action: open a note buffer, expand / collapse a
      group or connection, or run a table / view's `List` query. Enable mouse support with
      `:set mouse=a` if needed.
    - Press `r` to manually refresh the tree.
    - Press `?` to show all configured drawer keybindings in a popup. Press `q`, `<Esc>`, or `?`
      to close it.

  - Connections:

    - Press `a` on a source or one of its descendants to add a connection (if supported).
    - Press `e` on a connection node to edit its source file (if supported). This key does not
      apply to the connection's schema, table, or column nodes.
    - Press `cw` to edit the connection
    - Press `dd` to delete it (if source supports saving, it's also removed from there - see more
      below.)
    - Press `<CR>` on a connection to activate it and expand / collapse it; on a dataset, schema,
      or database group to expand / collapse it; on a table or view to run its `List` query directly.
    - Press `o` on a connection or any dataset, database, table, or column inside it to open that
      connection's scratchpad and focus the editor. Its name is `<connection name>.sql`, and its
      buffer appears in the bufferline. The scratchpad is created once and reused. Existing
      `scratchpad.sql` notes remain available in the drawer.

  - Scratchpads:

    - Press `<CR>` on the `new` node to create a new scratchpad.
    - When you try to save it to disk (`:w`), the path is automatically filled for you. You can
      change the name to anything you want, if you save it to the suggested directory, it will load
      the next time you open DBee.
    - Press `cw` to rename the scratchpad.
    - Press `dd` to delete it (also from disk).
    - Pressing `<CR>` on an existing scratchpad in the drawer will open it in the editor pane.

- Once you selected the connection and created a scratchpad, you can navigate to the editor pane
  (top-right by default) and start writing queries. In editor pane, you can use the following
  actions:

  - SQL suggestions appear automatically as you type. FROM and JOIN suggest projects, databases,
    datasets, schemas, tables, views, and CTEs from the active connection. Other clauses suggest
    columns from the current query's sources, including aliases and subquery/CTE output columns.
    Shared column names are qualified with their table alias to avoid ambiguous SQL.
    BigQuery paths such as `my-project.dataset.table` work without typing backticks first;
    accepting a table suggestion adds identifier quotes when needed.
  - Press `<C-Space>` or `<C-x><C-o>` in insert mode to request suggestions. Use `<C-n>` / `<C-p>`
    to select, `<C-y>` to accept, and `<C-e>` to dismiss. Opening the menu preserves your text.
    Completion uses cached table/column metadata; refresh it with `R` in the drawer when needed.
    Only the selected database's cached tables are available when an adapter switches databases.
  - Configure `editor.completion = { enabled = true, auto = true, delay = 100 }` to adjust the popup
    delay in milliseconds. Set `auto = false` for manual completion, or `enabled = false` to keep
    your existing completion setup. Built-in completion needs no additional plugin.
  - Blink can use the `dbee.completion.blink` provider in `sources.providers`. Enable it for SQL
    filetypes to complete both scratchpads and ordinary SQL files using DBee's active connection.
    Set `editor.completion.auto = false` when Blink manages the completion menu.

  - Press Enter in normal mode to run the SQL statement under the cursor.
  - Highlight some text in visual mode and press `BB` - this will run the selected query on the
    active connection.
  - If you press `BB` in normal mode, you run the whole scratchpad on the active connection.
  - When a query finishes, its first line shows a green `✓` for success or a red `✗` for failure
    in the sign column before the line number. Each scratchpad shows only its latest query's status;
    starting another query clears the previous sign immediately.

- In the call log, press `>` to append the selected query to its connection's scratchpad and
  focus the editor. Existing SQL is preserved, and the cursor moves to the inserted query.

- Results are first saved to a temporary disk cache while the result buffer shows a loading
  indicator. Once retrieval finishes, the "result" buffer (bottom right by default) reads only
  the chunks needed for the current page. Values longer than 50 characters show their first
  50 characters followed by `...`; copying and exporting still use the full values.
  Tabs and line breaks appear as `\t` and `\n` in the preview to keep columns aligned.
  Each connection keeps results for its 10 most recent queries in `/tmp/dbee-results/`,
  available from the call log even after restarting. Starting an 11th query replaces the oldest
  result; failed and canceled queries also count toward this limit. The metadata cache stays separate
  in `metadata.sqlite3` and is unaffected by query execution.
  If the total number of results was lower than the `page_size` parameter in config (100
  by default), all results should already be present. If there are more than `page_size` results,
  you can "page" through them using one of the following:

| Navigation using lua script <br/> (even if your cursor is outside the result buffer) |       Description       | Default key mapping <br/> (cursor should be inside result buffer) |
| ------------------------------------------------------------------------------------ | :---------------------: | :---------------------------------------------------------------: |
| `require("dbee").api.ui.result_page_next()`                                          |     Go to next page     |                                 L                                 |
| `require("dbee").api.ui.result_page_prev()`                                          | Go to the previous page |                                 H                                 |
| `require("dbee").api.ui.result_page_last()`                                          |   Go to the last page   |                                 E                                 |
| `require("dbee").api.ui.result_page_first()`                                         |  Go to the first page   |                                 F                                 |

- In the "result" buffer, `w`, `b`, `W`, and `B` move between words within the current row in
  normal and visual mode. They stop at the end or start of the row, including counted motions
  such as `3w` or `3W`. `W` and `B` treat each sequence of non-whitespace characters as a word.

- Column names stay pinned at the top when scrolling results and follow horizontal scrolling.
  Set `result.pin_header = false` to disable this. Pinning requires `wrap = false` (the default).

- In the "result" buffer, press `>` in normal mode to show the current row as JSON in
  a split to the right, 50 columns wide. The new buffer has filetype `json`.
  In visual mode, `>` shows the full value of the column under the cursor;
  `v>` inspects a cell without selecting its text. Strings containing JSON are formatted as JSON.

- Once in the "result" buffer, you can yank the results with the following keys:

  - `yaj` yank current row as json (or row range in visual mode)
  - `yac` yank current row as CSV (or row range in visual mode)
  - `yaJ` to yank all rows as json
  - `yaC` to yank all rows as CSV

- The current result (of the active connection) can also be saved to a file, yank-register or buffer
  using `require("dbee").store()` lua function or `:Dbee store` Ex command. Here are some examples:

  ```lua
  -- All rows as CSV to current buffer:
  require("dbee").store("csv", "buffer", { extra_arg = 0 })
  -- Results from row 2 to row 7 as json to file (index is zero based):
  require("dbee").store("json", "file", { from = 2, to = 7, extra_arg = "path/to/file.json"  })
  -- Yank the first row as table
  require("dbee").store("table", "yank", { from = 0, to = 1 })
  -- Yank the last 2 rows as CSV
  -- (negative indices are interpreted as length+1+index - same as nvim_buf_get_lines())
  -- Be aware that using negative indices requires for the
  -- iterator of the result to be drained completely, which might affect large result sets.
  require("dbee").store("csv", "yank", { from = -3, to = -1 })
  ```

- Once you are done or you want to go back to where you were, you can call
  `require("dbee").close()`.

### Specifying Connections

Connection represents an instance of the database client (i.e. one database). This is how it looks
like:

```lua
{
  id = "optional_identifier" -- only mandatory if you edit a file by hand. IT'S YOUR JOB TO KEEP THESE UNIQUE!
  name = "My Database",
  type = "sqlite", -- type of database driver
  url = "~/path/to/mydb.db",
}
```

The connections are loaded to dbee using so-called "sources". They can be added to dbee using the
`setup()` function:

```lua
  require("dbee").setup {
    sources = {
      require("dbee.sources").MemorySource:new({
        {
          name = "...",
          type = "...",
          url = "...",
        },
        -- ...
      }),
      require("dbee.sources").EnvSource:new("DBEE_CONNECTIONS"),
      require("dbee.sources").FileSource:new(vim.fn.stdpath("cache") .. "/dbee/persistence.json"),
    },
    -- ...
  },
```

The above sources are just built-ins. Here is a short description of them:

- `MemorySource` just loads the connections you give it as an argument.

- `EnvSource` loads connection from an environment variable Just export the variable you gave to the
  loader and you are good to go:

  ```sh
    export DBEE_CONNECTIONS='[
        {
            "name": "DB from env",
            "url": "username:password@tcp(host)/database-name",
            "type": "mysql"
        }
    ]'
  ```

- `FileSource` loads connections from a given json file. It also supports editing and adding
  connections interactively

The default file source is displayed as `connections` in the drawer. If the source supports saving
and editing you can add connections manually by pressing `a` on the source or one of its descendants.
Fill in the values and write the buffer (`:w`) to save the connection. By default, this
will save the connection to the global connections file and will persist over restarts (because
default `FileSource` supports saving)

Another option is to press `e` on a connection node and edit its source file manually.

If you aren't satisfied with the default capabilities, you can implement your own source. You just
need to fill the `Source` interface and pass it to config at setup (`:h dbee.sources`).

#### Metadata cache

Opening a connection for the first time fetches its tables, views, columns, and available DDL and stores a complete
snapshot in `stdpath("state") .. "/dbee/metadata.sqlite3"`. All connections share this one file;
snapshots are compressed MessagePack blobs indexed by connection and selected database. Later opens,
including after restarting Neovim, reuse the snapshot without fetching metadata or DDL again.

The first fetch can take longer for large databases because it collects all column schemas and DDL.
BigQuery uses the table metadata API for columns and one `INFORMATION_SCHEMA.TABLES` query per dataset
for DDL. These DDL queries use GoogleSQL and require permission to run query jobs; they respect
`max-bytes-billed`. The cache has no automatic expiry. Older snapshots without DDL are rebuilt once.

Native table/view DDL collection is supported for BigQuery, MySQL, SQLite, DuckDB, ClickHouse,
Oracle, Redshift, and Databricks. Other adapters continue to cache structure and columns. You can
provide a custom `DDL` table helper for another database type; it must return DDL text in the first
column (or a column named `ddl`). Rows are joined with newlines. DDL queries run during metadata
collection and do not enter query history or overwrite cached query results.

Read a cached definition from Lua:

```lua
local ddl = require("dbee").api.core.connection_get_ddl("connection-id", {
  schema = "public", table = "users", materialization = "table",
})
```

This raises an error if the database does not supply DDL for the object.

Press `R` in the drawer to refresh the selected connection, database/dataset/schema, or table/view in
the background. A column refreshes its parent table. Only metadata within that scope is replaced;
other cached schemas and tables stay unchanged. A spinner after the selected node shows progress.
`r` only redraws the drawer using cached data. From Lua, `refresh_metadata()` follows the drawer
selection when called there and refreshes the active connection elsewhere:

```lua
require("dbee").refresh_metadata()
-- Or refresh a specific connection:
require("dbee").refresh_metadata("connection-id")
```

A failed refresh preserves the previous snapshot. Editing the connection URL or switching databases
uses a separate snapshot; renaming a connection does not discard its cache.

#### Secrets

If you don't want to have secrets laying around your disk in plain text, you can use the special
placeholders in connection strings (this works using any method for specifying connections).

Each connection parameter is passed through go templating engine, which has two available functions:

- `env` for retrieving environment variables and
- `exec` for evaluating shell commands.

The template syntax for functions is the following: `{{ <func> "<param>" }}`. If you are dealing
with json, you need to escape double quotes, so it's sometimes better to use backticks instead
(`` {{ <func> `<param>` }} ``).

Example:

Using the `DBEE_CONNECTIONS` environment variable for specifying connections and exporting secrets
to environment:

```sh
# Define connections
export DBEE_CONNECTIONS='[
    {
        "name": "{{ exec `echo Hidden Database` }}",
        "url": "postgres://{{ env \"SECRET_DB_USER\" }}:{{ env `SECRET_DB_PASS` }}@localhost:5432/{{ env `SECRET_DB_NAME` }}?sslmode=disable",
        "type": "postgres"
    }
]'

# Export secrets
export SECRET_DB_NAME="secretdb"
export SECRET_DB_USER="secretuser"
export SECRET_DB_PASS="secretpass"
```

If you start neovim in the same shell, this will evaluate to the following connection:

```lua
{ {
  name = "Hidden Database",
  url = "postgres://secretuser:secretpass@localhost:5432/secretdb?sslmode=disable",
  type = "postgres",
} }
```

## API

Dbee comes with it's own API interface. It is split into two parts:

- core (interacting with core of the plugin),
- ui (interacting with ui of the plugin).

You can access it like this:

```lua
require("dbee").api.core.some_func()
require("dbee").api.ui.some_func()
```

## Extensions

- [`nvim-projector`](https://github.com/kndndrj/nvim-projector) To use dbee with projector, use
  [this extension](https://github.com/kndndrj/projector-dbee).

- [`nvim-cmp`](https://github.com/hrsh7th/nvim-cmp) [Here](https://github.com/MattiasMTS/cmp-dbee),
  a completion plugin with dbee support.

<!-- DOCGEN_IGNORE_START -->

## Development

Reffer to [ARCHITECTURE.md](ARCHITECTURE.md) for a brief overview of the architecture.

## Contributing

Contributions are more than welcome!

Do so by creating an `issue` or a `PR`.

You are also welcome to join the [#nvim-dbee:matrix.org](https://matrix.to/#/#nvim-dbee:matrix.org)
chat for more direct communication.

<!-- DOCGEN_IGNORE_END -->
