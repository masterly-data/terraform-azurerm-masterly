"""Fail when the public self-hosted docs pin an older module than the registry publishes.

masterlydata.com/docs/self-hosted tells a customer which version of this module to install:
a copy-paste `version = "X.Y.Z"` on the deploy page, and the tested-combination table on the
install page. Nothing links those two strings to a release here, so when a version is tagged
and published and nobody edits the docs, every new install is built from whatever the pages
last named — which is how the docs sat on 0.11.0 while 0.15.0 was on the registry, four
releases and two security fixes behind (MAS-199).

The check lives HERE because this is where the drift is made: a release is cut in this repo
and nothing about that event reaches the docs. It is also the reading that needs nothing of
anybody — the site is public and so is the registry, so this job holds no credential to
expire, which is the failure mode masterly-application-backend's public-docs-contract.yml
was built to avoid rather than repeat. It reads the PUBLISHED pages rather than masterly-web's
source, so it answers about what a customer can actually copy today, not about what is merged.

What it deliberately does NOT check: every other version this module is named at in those
pages. "Custom domains are not supported at module X" moves with the pin; "telemetry, from
your install bundle (module 0.11.0)" is provenance — the release an input arrived in — and
stays true whatever ships later. A checker that cannot tell those apart either forces a false
edit or teaches people to ignore it. Only the two pins a customer copies are gated.

Run: `python3 scripts/check_docs_module_pin.py`, or the scheduled workflow.
"""

from __future__ import annotations

import html
import json
import os
import re
import sys
import urllib.error
import urllib.request

REGISTRY_URL = os.environ.get(
    "MODULE_REGISTRY_URL",
    "https://registry.terraform.io/v1/modules/masterly-data/masterly/azurerm/versions",
)
INSTALL_URL = os.environ.get(
    "MODULE_DOCS_INSTALL_URL", "https://masterlydata.com/docs/self-hosted/install/"
)
DEPLOY_URL = os.environ.get(
    "MODULE_DOCS_DEPLOY_URL", "https://masterlydata.com/docs/self-hosted/deploy/"
)

TIMEOUT_S = 20
SEMVER_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
# Say who is calling. Not politeness: the site's edge answers the default
# `Python-urllib/x.y` agent with 403 -- including for pages that exist -- so the check would
# report a missing page every morning about one that is served fine.
USER_AGENT = (
    "masterly-docs-module-pin-check/1.0 "
    "(+https://github.com/masterly-data/terraform-azurerm-masterly)"
)

# The copy-paste module call on the deploy page, once the markup is squeezed out of it.
DEPLOY_PIN_RE = re.compile(
    r'"masterly-data/masterly/azurerm"\s*version\s*=\s*"(\d+\.\d+\.\d+)"'
)
# The tested-combination row on the install page, once the markup is turned into spaces.
INSTALL_PIN_RE = re.compile(
    r"masterly-data/masterly/azurerm\s+module\s+version\s+(\d+\.\d+\.\d+)"
)


def fail(msg: str) -> None:
    print(f"module-pin — {msg}", file=sys.stderr)
    sys.exit(1)


def semver(version: str) -> tuple[int, int, int] | None:
    """(major, minor, patch), or None if this is not an X.Y.Z version."""
    m = SEMVER_RE.match(version)
    return (int(m.group(1)), int(m.group(2)), int(m.group(3))) if m else None


def fetch(url: str) -> str:
    """The body at `url`. A value that is not http(s) is read as a local file, which is how
    this check is exercised against a working copy before it is trusted on a schedule."""
    if not url.startswith("http"):
        try:
            with open(url, encoding="utf-8") as handle:
                return handle.read()
        except OSError as exc:
            fail(f"could not read {url}: {exc}")
    try:
        request = urllib.request.Request(  # noqa: S310 - our own https URLs
            url, headers={"User-Agent": USER_AGENT}
        )
        with urllib.request.urlopen(request, timeout=TIMEOUT_S) as resp:  # noqa: S310
            return resp.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        fail(f"{url} returned HTTP {exc.code} — has the page moved?")
    except (urllib.error.URLError, TimeoutError) as exc:
        fail(f"could not reach {url}: {exc}")
    raise AssertionError("unreachable")


def strip_markup(document: str) -> tuple[str, str]:
    """Two readings of the same page with the tags removed: one squeezed (tag boundaries
    vanish, so a syntax-highlighted code line reads as the line the customer copies), one
    spaced (tag boundaries become whitespace, so table cells stay separate words)."""
    without_tags = re.sub(r"<[^>]*>", "\x00", document)
    squeezed = html.unescape(without_tags.replace("\x00", ""))
    spaced = html.unescape(re.sub(r"\x00+", " ", without_tags))
    return squeezed, re.sub(r"\s+", " ", spaced)


def docs_pin(url: str, pattern: re.Pattern[str], squeezed: bool, what: str) -> str:
    """The single module version `pattern` finds on the page at `url`."""
    body = fetch(url)
    reading = strip_markup(body)[0 if squeezed else 1]
    found = sorted(set(pattern.findall(reading)))
    if not found:
        fail(
            f"found no {what} on {url}. Either the page changed shape or the pin is gone; "
            f"this check cannot tell which, so it refuses rather than passing quietly."
        )
    if len(found) > 1:
        fail(f"{url} names more than one module version as its {what}: {', '.join(found)}.")
    return found[0]


def latest_published() -> str:
    """The newest version the Terraform Registry actually serves. A tag pushed here is not
    the same event as a version customers can consume — the registry ingests it minutes
    later — and the docs are only wrong once the newer version is fetchable."""
    payload = fetch(REGISTRY_URL)
    try:
        document = json.loads(payload)
        entries = document["modules"][0]["versions"]
        versions = [str(entry["version"]) for entry in entries]
    except (json.JSONDecodeError, KeyError, IndexError, TypeError) as exc:
        fail(f"{REGISTRY_URL} did not answer with the registry's version list: {exc}")
    parsed = [(parts, v) for v in versions if (parts := semver(v))]
    if not parsed:
        fail(f"{REGISTRY_URL} listed no X.Y.Z versions")
    return max(parsed)[1]


def main() -> None:
    deploy = docs_pin(DEPLOY_URL, DEPLOY_PIN_RE, True, "module call pin")
    install = docs_pin(INSTALL_URL, INSTALL_PIN_RE, False, "tested-combination pin")

    if deploy != install:
        fail(
            f"the self-hosted docs pin two different module versions: {deploy} on the deploy "
            f"page, {install} in the tested-combination table. A half-done bump leaves the "
            f"walkthrough and the upgrade guidance disagreeing — fix both."
        )

    published = latest_published()
    docs, newest = semver(deploy), semver(published)
    if docs is None or newest is None:  # pragma: no cover - both are matched as X.Y.Z above
        fail(f"could not compare {deploy} with {published}")

    if docs == newest:
        print(
            f"module-pin — the self-hosted docs pin {deploy}, "
            f"the newest version on the registry."
        )
        return

    if docs > newest:
        fail(
            f"the self-hosted docs pin {deploy}, which the registry does not publish "
            f"(newest: {published}). Either a release was never tagged, or the docs named a "
            f"version before it shipped — a customer copying that pin cannot fetch it."
        )

    fail(
        f"the self-hosted docs pin module {deploy}; the registry publishes {published}.\n"
        f"module-pin — a customer following the self-hosted pages today builds an install "
        f"that is behind by every release in between. In masterly-web, update both pins:\n"
        f"module-pin —   src/content/docs/docs/self-hosted/deploy.mdx   (the module call)\n"
        f"module-pin —   src/content/docs/docs/self-hosted/install.mdx  (which versions go "
        f"together)\n"
        f"module-pin — and say what the jump needs, if anything, under \"Coming from module "
        f"{deploy.rsplit('.', 1)[0]}.x\"."
    )


if __name__ == "__main__":
    main()
