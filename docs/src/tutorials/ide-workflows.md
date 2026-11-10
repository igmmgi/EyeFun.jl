# IDE Workflows for Julia

Most Julia workflows pair an editor with a live REPL session, providing syntax highlighting, inline documentation, and keybindings to evaluate lines or selections directly in the running session.

## VS Code/VSCodium

[Visual Studio Code](https://code.visualstudio.com/) is a widely used editor for Julia development.
[VSCodium](https://vscodium.com/) is an open-source build of VS Code without Microsoft telemetry and is compatible with the same Julia extensions.

Install the **[Julia extension](https://marketplace.visualstudio.com/items?itemName=julialang.language-julia)** (`julialang.language-julia`) for:

- Integrated REPL (`Shift+Enter` to evaluate lines or selections)
- Inline evaluation results and variable display
- Debugger, profiler, and plot pane
- Workspace variable explorer and data viewer

The extension can be installed from within the IDE via the **Extensions panel** (`Ctrl+Shift+X`) by searching for `Julia`.

:::tip Windows shell mode fix
If Julia's shell mode (`;` in the REPL) doesn't work inside VS Code, installing [Git Bash](https://git-scm.com/install/) and adding the following to your VS Code `settings.json` (open via `Ctrl+Shift+P` → *Preferences: Open User Settings (JSON)*) has been reported to fix the issue. This was found via trial and error and may not be the only/best solution:

```json
{
    "terminal.integrated.env.windows": {
        "SHELL": "C:\\Program Files\\Git\\bin\\bash.exe",
        "Path": "${env:Path};C:\\Program Files\\Git\\usr\\bin"
    },
    "terminal.integrated.profiles.windows": {
        "Git Bash": {
            "path": "C:\\Program Files\\Git\\bin\\bash.exe"
        }
    },
    "terminal.integrated.defaultProfile.windows": "Git Bash"
}
```

:::

## Positron

[Positron](https://positron.posit.co/) is an open-source fork of VS Code by Posit (makers of RStudio) designed for R and Python data workflows. It includes dedicated *Connections*, *Variables*, and *Plots* panes similar to RStudio.

There is also a **[positron-julia extension](https://open-vsx.org/extension/ntluong95/positron-julia)** available on Open VSX via the Extensions panel. The `positron-julia` extension is in early development and may be unstable.

## JetBrains IDEs

[JetBrains](https://www.jetbrains.com/) offer Julia support via the **[Flexible Julia plugin](https://plugins.jetbrains.com/plugin/29356-flexible-julia)**. It works in JetBrains IDEs (e.g., IntelliJ IDEA, PyCharm) and provides:

- Language server support (completion, go-to-definition, refactoring)
- Integrated Julia REPL within the IDE
- Package manager UI

> [!NOTE]
> JetBrains IDEs are commercial software, though free community editions and academic licences are available.

## Neovim + Iron.nvim

For terminal-based workflows, [Neovim](https://neovim.io/) can be combined with **[Iron.nvim](https://github.com/Vigemus/iron.nvim)**:

- `iron.nvim` opens a Julia REPL split and lets you send lines, visual selections, or entire files with configurable keymaps
- Pair with **[nvim-lspconfig](https://github.com/neovim/nvim-lspconfig)** + the Julia language server (`julials`) for completion and diagnostics
