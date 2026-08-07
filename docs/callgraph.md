# Call graph

erlsp can compute and show your workspace's call graph: which function
calls which, across every project in the workspace.

Run it via the command palette: **erlsp: Show Call Graph**.

## What's in the graph

Every function defined in your workspace is a node. An edge is drawn from
a function to everything it calls, as long as the call site is
statically resolvable — a plain local call, or a remote call with a
literal `Module:Function(...)`. Calls into OTP/stdlib/dependencies are shown
as **external** nodes.

### What isn't in the graph: dynamic dispatch

A call whose module or function is a variable rather than a literal atom
— `Mod:F(Args)`, `F(Args)`, `apply/2,3` with a non-literal target — is
**dynamic dispatch**, and erlsp does not attempt to resolve it.
A dynamic call site simply produces no edge, rather than a guessed one.

## The view

The call graph opens in a webview tab with two levels:

- **Module view** (the default): one node per module, sized by how many
  functions it defines, with edges aggregated between modules. This is
  the view you land on, since a whole-project per-function graph is
  usually too dense to be readable at a glance.
- **Function view**: click any workspace module to drill into its own
  functions, plus everything exactly one hop away. A back button
  returns to the module view.

Both views support:

- **Pan and zoom** (scroll/pinch, or drag the background).
- **Dragging** individual nodes to reposition them.
- **Search** (top-left): filters/highlights nodes by module (module view)
  or `module:function` (function view) as you type.
- **Click-to-jump**: in the function view, clicking a workspace function
  jumps to its definition in the editor.
- **Directional edges**: arrows point from caller to callee.

## Caching and reindexing

The graph is computed once and cached in the server; reopening the "Show
Call Graph" command reuses the cached graph rather than recomputing it.
It's invalidated together with the rest of the workspace index by
**erlsp: Reindex Workspace** — run that after making changes you want
reflected in the graph.
