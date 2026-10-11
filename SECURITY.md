# Security

rp-framework is a hosted portal that holds communities' configuration,
player accounts and ledgers, and this Lua framework, which runs inside their
game servers. A vulnerability in either affects every community at once, so
please report one privately and give us time to fix it before it is public.

## Reporting a vulnerability

Report it privately through this repository's *Security* tab ("Report a
vulnerability"). That reaches the maintainers alone and gives the report a
tracked advisory in which the fix is prepared. It is the place for a
vulnerability in the hosted portal too, whose source is not public.

Please do not open a public issue for a vulnerability, and do not test
against the hosted portal with other communities' data: run your own
community's servers, or describe the request or frame and we will reproduce
it.

What helps: the release or commit, the request or frame that triggers it,
what you expected and what happened, and whether another community's data
was reached. A report that another community's record could be read or
written through a game server or player request is the highest severity
this project has.

## What to expect

We acknowledge a report within three working days, keep you informed as we
confirm and fix it, and credit you in the release notes if you wish. A fix
ships in a patch release of the portal and, where the Lua framework is
involved, of the framework; `CHANGELOG.md` names the advisory once it is
public.

## Supported versions

The hosted portal is always the latest release. For the Lua framework,
every protocol version the portal serves
([Compatibility](docs/compatibility.md)) receives security fixes.

## What is in place here

- Private vulnerability reporting, above.
- GitHub's secret scanning with push protection.
- Every key and token the portal issues has the shape
  `rpf_<kind>_<secret>`; one found in an issue, a pull request or a commit is
  revoked, whoever posted it.
- `main` and the release tags cannot be force-pushed or deleted, and only
  the mirror updates `main`.
- Each release's downloads are listed with their SHA-256 checksums.
