# Upgrading

What a server owner changes when moving a game server from one release to
the next. Each release has a section here, newest first, and the release
workflow refuses a tag without one. A section says what the owner must
change: convars, files, requirements (the artifact, OneSync, GWSockets), and
whether the protocol changed, which decides how long a server that has not
upgraded is still served ([Compatibility](compatibility.md)). A release with
nothing to change says that.

Upgrading itself is the same every time:

- **FiveM:** replace the `[rpf]` folder in `resources/` with the new
  release's, and restart the server.
- **Garry's Mod:** replace `garrysmod/addons/rpf` with the new release's,
  and restart the server.

Anything else is in the release's section below. Skipping releases is
fine: read every section between the release you run and the one you
install.

## Unreleased

The first release with the FiveM resources and the Garry's Mod addon. 0.1.0
had neither, so there is nothing to upgrade from: install it as
[Installing](installing.md) says.

- **Protocol:** speaks protocol 2, the only one the portal serves.
- **Requirements:** on FiveM, OneSync on and an artifact with routing
  buckets. On Garry's Mod, the GWSockets binary module.
- **Settings:** `rpf_url` and `rpf_api_key` on FiveM, and `rpf_ws_url` and
  `rpf_api_key` on Garry's Mod, from the server's **API keys** page in the
  portal.
