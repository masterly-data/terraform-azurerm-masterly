# Security policy

Thank you for taking the time to report a problem. This module provisions a customer's whole
Masterly install, so a flaw in it can affect every install pinned to the affected version — we
would much rather hear from you privately first.

## Reporting a vulnerability

**Please do not open a public issue.** A public report is visible to everyone running an affected
version before any of them can act on it.

Use either of these instead:

1. **GitHub private vulnerability reporting** (preferred) — the **Report a vulnerability** button
   on this repository's [Security tab](https://github.com/masterly-data/terraform-azurerm-masterly/security).
   It opens a private draft advisory only you and the maintainers can see, and it keeps the
   discussion attached to the code.
2. **Email** — [christer.larsson@masterlydata.com](mailto:christer.larsson@masterlydata.com),
   with `SECURITY` in the subject line.

Please do not use `support@` or `privacy@` for vulnerability reports. They are real addresses
handled on a normal support rhythm, which is the wrong one for this.

## What to include

Whatever you have. A partial report is worth sending — we would rather triage something thin than
never hear about it. If you can, the most useful things are:

- The module version (or commit) and the Terraform and provider versions.
- What an attacker gains, and who has to be who for it to work.
- The relevant `.tf` inputs — with any real secrets, subscription ids or tenant ids removed.
- Steps to reproduce, or a `plan` output showing the resulting configuration.

## What to expect

Masterly is a small team, so these are windows we can actually hold rather than aspirational ones:

| | |
|---|---|
| Acknowledgement | Within **5 business days** |
| Initial assessment | Within **10 business days** — severity, whether we can reproduce it, and a rough plan |
| Fix and disclosure | By agreement with you. We will tell you when a fix ships and credit you unless you would rather we did not |

If you have not heard back inside the acknowledgement window, please assume the message went
astray and send it again — persistence is welcome, not a nuisance.

## Scope

**In scope** — this repository: the Terraform module, its examples, and its CI workflows.

Especially interesting: anything that weakens an install's isolation or exposes it more widely
than its inputs ask for. The module tries to make unsafe combinations unrepresentable — for
example, the evaluation identity binding cannot be selected without an ingress allow-list, and
`mode = "production"` refuses the development-grade seams. A way around one of those guards is
exactly the kind of report we want.

**Out of scope** — an install you or your organisation runs. Those live in your own Azure
subscription, under your own network and identity controls. If you believe a Masterly-operated
service is affected, say so in the report and we will route it.

## Supported versions

Fixes land on the latest published version. The module is consumed at a pinned semver tag from
the Terraform Registry, so remediation means upgrading to a patched release rather than a patch
to an older tag.
