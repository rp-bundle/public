# Contributing

Issues and pull requests are welcome here.

This repository is a one-way mirror of the framework's source, which lives
in a private repository beside the hosted portal, so a pull request is not
merged with GitHub's button. A maintainer applies its commits there,
keeping you as their author, and it reaches this repository with the next
mirror run. A pull request can change what this repository holds, and
nothing else: one that adds a file at a new path outside `lua/` is
discussed in an issue first.
Your pull request is then closed with a link to the commit that carries it.

Your commits are published as you wrote them, so author them with the
address you want public, such as your GitHub noreply address
(`<id>+<login>@users.noreply.github.com`).

A change to anything the portal sends or reads (a message, a config field, a
command) also needs the portal's side, which only a maintainer can write:
say what you need in an issue first.

Before you open one:

- Lua targets the 5.1/5.4 common subset and lives under the `rpf` global.
  `lua/core/` never calls a game API or branches on the engine
  ([`lua/core/README.md`](lua/core/README.md)).
- Every module, function, class and table field carries LuaLS annotations
  with a description.
- Run the specs under both Luas from `lua/`: `busted` (with LuaJIT 2.1 and
  Lua 5.4). They pass in a checkout of this repository. The few that
  cross-check a bound against the portal's own sources, which are not
  here, show as pending, and run when a maintainer applies your change.
