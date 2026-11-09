"""Refuse a release whose default images do not resolve in the registry: the check the cut-release
workflow runs, with a pull-only credential, before it creates the tag.

A tag on this repository is the release, and a published version cannot be withdrawn. An install
that leaves `api_image` and `frontend_image` null pulls the images its release channel selects
from the module's own MANIFEST.json (`modules/release-channel/main.tf`). Every other release check
is offline, so modules 0.22.0 and 0.23.0 were tagged naming `release/api` and `release/frontend`
builds that did not exist in the registry, and every default install of them failed to pull.
This script asks the registry, for the release commit's manifest read as data:

  * stable is `latest`; previous is the newest release older than `latest` that carries no
    `known_issue`, or none. Versions sort as numbers, so 0.10.0 is newer than 0.9.0. This is
    `modules/release-channel/main.tf:12-46`, ported, not read.
  * each channel's default reference is `<registry>/release/<role>@<digest>` when the entry
    records digests, and `<registry>/release/<role>:<tag>` (the tag of the image it names) when it
    records none. Each must resolve.
  * where an entry records a digest, the tag of the image it names must also resolve to that
    digest: a tag that names another build is not the build that was released.

Any reference that does not resolve, or a tag at a digest the manifest does not record, fails with
an `::error::` that names it.

The credential is a repository-scoped ACR token on the `pull-product-images` scope map, which can
pull `release/api` and `release/frontend` and nothing else. It is read from the environment only —
`RELEASE_ACR_TOKEN_NAME` and `RELEASE_ACR_TOKEN_PASSWORD` — never from the command line, and the
password is never printed. When either is unset the check fails naming it: it is never skipped.
The password is exchanged once for a short-lived access token (`/oauth2/token`, pull scope on the
two repositories), which inside GitHub Actions is masked with `::add-mask::` before anything else
is printed. A 401 or 403 is reported as a refused credential, never as a missing image. Redirects
are not followed, so the credential is sent to the named registry and nowhere else.

The decision (`channel_versions`, `resolve`, `judge`) is pure. The network is one function,
`send`, that the selftest replaces with a fake registry, so everything above it — the token
exchange, the requests and the reading of the answers — is what the selftest runs.

Run:
    export RELEASE_ACR_TOKEN_NAME=pull-ci-cut-release
    read -rs RELEASE_ACR_TOKEN_PASSWORD && export RELEASE_ACR_TOKEN_PASSWORD
    python3 scripts/check_release_images.py --manifest MANIFEST.json
    python3 scripts/check_release_images.py --selftest      # it still refuses what it should

Standard library only, so the release workflow installs nothing.
"""

from __future__ import annotations

import argparse
import base64
import http.client
import io
import json
import os
import re
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Callable, NamedTuple, TextIO

DEFAULT_REGISTRY = "masterly.azurecr.io"
ROLES = ("api", "frontend")
CHANNELS = ("stable", "previous")
NAME_ENV = "RELEASE_ACR_TOKEN_NAME"
PASSWORD_ENV = "RELEASE_ACR_TOKEN_PASSWORD"
SCOPE_MAP = "pull-product-images"
VERSION_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
# The tag of an image reference, as the module reads it (main.tf:43).
TAG_RE = re.compile(r":([^:@/]+)$")
# What a reference may carry, so nothing from the manifest reaches a request or a log line unchecked.
TAG_SHAPE_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$")
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
# Every manifest type a release build can be stored as. Without the index types a multi-arch
# build's digest can answer 404, or another digest, and read as missing or moved.
MANIFEST_ACCEPT = ", ".join((
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.docker.distribution.manifest.v2+json",
))

# (status, lower-cased headers, body) for one request.
Send = Callable[[urllib.request.Request], "tuple[int, dict[str, str], bytes]"]


class Refused(Exception):
    """A reason not to create the tag, phrased for whoever has to fix it."""


class Check(NamedTuple):
    channel: str
    version: str
    role: str
    ref: str  # the module's default: <registry>/release/<role>@<digest>, or :<tag> with no digests
    expected_digest: str | None
    tag_ref: str | None  # with a digest: <registry>/release/<role>:<tag>, which must resolve to it


# ---------------------------------------------------------------------------
# The decision: pure
# ---------------------------------------------------------------------------


def _sort_key(version: str) -> tuple[int, int, int]:
    match = VERSION_RE.match(version)
    if not match:
        raise Refused(
            f"release {version!r} in the manifest is not X.Y.Z, so its channels cannot be "
            f"ordered — the module's own sort fails the plan on it too."
        )
    major, minor, patch = (int(part) for part in match.groups())
    return major, minor, patch


def channel_versions(manifest: dict) -> dict[str, str | None]:
    """The release each channel selects, as modules/release-channel/main.tf:12-33 selects it."""
    releases = manifest.get("releases")
    if not isinstance(releases, dict) or not releases:
        raise Refused("the manifest has no 'releases', so no channel selects any image.")
    latest = manifest.get("latest")
    newest_first = sorted(releases, key=_sort_key, reverse=True)
    previous = None
    if latest in newest_first:
        for version in newest_first[newest_first.index(latest) + 1:]:
            entry = releases[version]
            if not isinstance(entry, dict) or entry.get("known_issue") is None:
                previous = version
                break
    return {"stable": latest if isinstance(latest, str) else None, "previous": previous}


def resolve(manifest: dict, registry: str) -> tuple[dict[str, str | None], list[Check]]:
    """Every default image reference of the stable and previous channels (main.tf:40-46)."""
    versions = channel_versions(manifest)
    releases = manifest["releases"]
    checks: list[Check] = []
    for channel in CHANNELS:
        version = versions[channel]
        if version is None and channel == "previous":
            continue
        entry = releases.get(version) if version is not None else None
        if not isinstance(entry, dict):
            raise Refused(
                f"'latest' is {version!r}, which is no release in the manifest, so the stable "
                f"channel has no default image and every default install fails its plan."
            )
        images = entry.get("images") if isinstance(entry.get("images"), dict) else {}
        digests = entry.get("digests") if isinstance(entry.get("digests"), dict) else {}
        for role in ROLES:
            repository = f"{registry}/release/{role}"
            image = images.get(role)
            match = TAG_RE.search(image) if isinstance(image, str) else None
            if match and not TAG_SHAPE_RE.match(match.group(1)):
                raise Refused(f"release {version} names its {role} image {image!r}, whose tag is "
                              f"not a registry tag.")
            tag_ref = f"{repository}:{match.group(1)}" if match else None
            if role in digests:
                digest = digests[role]
                if not isinstance(digest, str) or not DIGEST_RE.match(digest):
                    raise Refused(f"release {version} records its {role} digest as {digest!r}, "
                                  f"which is not sha256:<64 hex>.")
                checks.append(Check(channel, version, role, f"{repository}@{digest}", digest,
                                    tag_ref))
            elif tag_ref:
                checks.append(Check(channel, version, role, tag_ref, None, None))
            else:
                raise Refused(
                    f"release {version} ({channel}) records neither a digest nor a tagged image "
                    f"for {role}, so the module has no default {role} image for it."
                )
    return versions, checks


def references(checks: list[Check]) -> list[str]:
    """Each reference to ask the registry about, once, in order."""
    seen: dict[str, None] = {}
    for check in checks:
        seen.setdefault(check.ref, None)
        if check.tag_ref:
            seen.setdefault(check.tag_ref, None)
    return list(seen)


def judge(checks: list[Check], observed: dict[str, str | None]) -> list[str]:
    """One failure per reference that does not resolve, or resolves to an unrecorded digest.

    `observed` maps a reference to the digest the registry answered, or None for not found. A
    reference missing from it counts as not found, so a gap in the reading fails closed.
    """
    groups: dict[tuple, list[Check]] = {}
    for check in checks:
        groups.setdefault((check.ref, check.expected_digest, check.tag_ref, check.role),
                          []).append(check)
    failures: list[str] = []
    for (ref, expected, tag_ref, role), group in groups.items():
        where = " and ".join(f"{check.channel} {check.version}" for check in group)
        got = observed.get(ref)
        if got is None:
            failures.append(
                f"{ref} does not resolve in the registry. It is the default {role} image of "
                f"{where}, so every default install of that release fails to pull it."
            )
        elif expected is not None and got != expected:
            failures.append(
                f"{ref} resolves to {got}, not the {expected} the manifest records ({where})."
            )
        if tag_ref is None:
            continue
        tag_got = observed.get(tag_ref)
        if tag_got is None:
            failures.append(
                f"{tag_ref} does not resolve in the registry, but the manifest records its {role} "
                f"image at {expected} under that tag ({where})."
            )
        elif tag_got != expected:
            failures.append(
                f"{tag_ref} resolves to {tag_got}, but the manifest records {expected} for it "
                f"({where}): the tag names another build than the one released."
            )
    return failures


# ---------------------------------------------------------------------------
# The network: one thin layer
# ---------------------------------------------------------------------------


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    # urllib forwards the Authorization header on a redirect; refuse to follow one instead.
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def urllib_send(request: urllib.request.Request) -> tuple[int, dict[str, str], bytes]:
    opener = urllib.request.build_opener(_NoRedirect)
    try:
        with opener.open(request, timeout=30) as response:
            return (response.status, {k.lower(): v for k, v in response.headers.items()},
                    response.read())
    except urllib.error.HTTPError as error:
        headers = error.headers.items() if error.headers is not None else []
        return error.code, {k.lower(): v for k, v in headers}, b""
    except (urllib.error.URLError, http.client.HTTPException, OSError) as error:
        raise Refused(f"could not reach {request.host}: {error}. Refusing rather than assuming "
                      f"the images exist.") from None


def _credential_refused(name: str, status: int, doing: str) -> Refused:
    return Refused(
        f"the registry refused the credential {NAME_ENV}={name!r} (HTTP {status}) while "
        f"{doing}. That is no answer about the images, so none is given: check that the "
        f"`release` Environment's variable {NAME_ENV} and secret {PASSWORD_ENV} hold a current "
        f"token on the {SCOPE_MAP} scope map."
    )


class Registry:
    def __init__(self, host: str, name: str, password: str, send: Send):
        self.host = host
        self.name = name
        self._password = password
        self._send = send

    def login(self) -> str:
        """Exchange the token's password for an access token that can pull the two repositories."""
        query = urllib.parse.urlencode(
            [("service", self.host)]
            + [("scope", f"repository:release/{role}:pull") for role in ROLES]
        )
        basic = base64.b64encode(f"{self.name}:{self._password}".encode()).decode()
        status, _, body = self._send(urllib.request.Request(
            f"https://{self.host}/oauth2/token?{query}",
            headers={"Authorization": f"Basic {basic}"},
        ))
        if status in (401, 403):
            raise _credential_refused(self.name, status, "exchanging it for an access token")
        if status != 200:
            raise Refused(f"the registry's token exchange answered HTTP {status}. Refusing "
                          f"rather than assuming the images exist.")
        try:
            answer = json.loads(body)
            token = answer.get("access_token") or answer.get("token")
        except (ValueError, AttributeError):
            token = None
        if not isinstance(token, str) or not token:
            raise Refused("the registry's token exchange returned no access token. Refusing "
                          "rather than assuming the images exist.")
        return token

    def digest(self, token: str, ref: str) -> str | None:
        """The digest `ref` resolves to, or None when the registry has no such manifest."""
        path = ref[len(self.host) + 1:]
        if "@" in path:
            repository, reference = path.split("@", 1)
        else:
            repository, reference = path.rsplit(":", 1)
        status, headers, _ = self._send(urllib.request.Request(
            f"https://{self.host}/v2/{repository}/manifests/"
            f"{urllib.parse.quote(reference, safe=':')}",
            method="HEAD",
            headers={"Authorization": f"Bearer {token}", "Accept": MANIFEST_ACCEPT},
        ))
        if status == 404:
            return None
        if status in (401, 403):
            raise _credential_refused(self.name, status, f"reading {ref}")
        if status != 200:
            raise Refused(f"the registry answered HTTP {status} for {ref}. Refusing rather than "
                          f"assuming it exists.")
        digest = headers.get("docker-content-digest")
        if not digest:
            raise Refused(f"{ref} answered with no Docker-Content-Digest, so the build it names "
                          f"cannot be confirmed.")
        return digest


# ---------------------------------------------------------------------------
# The check
# ---------------------------------------------------------------------------


def run(manifest_path: str, registry: str, environ: dict, send: Send, out: TextIO) -> int:
    def say(line: str) -> None:
        print(line, file=out, flush=True)

    try:
        try:
            manifest = json.loads(Path(manifest_path).read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            raise Refused(f"cannot read the manifest {manifest_path}: {error}") from None
        if not isinstance(manifest, dict):
            raise Refused(f"{manifest_path} is not a JSON object.")
        versions, checks = resolve(manifest, registry)
        say(f"Default images of {manifest_path} in {registry}:")
        say(f"  stable    {versions['stable']}")
        if versions["previous"] is None:
            say(f"  previous  none — no release older than {versions['stable']} without a "
                f"known_issue")
        else:
            say(f"  previous  {versions['previous']}")
        refs = references(checks)
        for ref in refs:
            say(f"  check     {ref}")

        missing = [
            what for what, value in (
                (f"the `release` Environment variable {NAME_ENV}", environ.get(NAME_ENV, "")),
                (f"the `release` Environment secret {PASSWORD_ENV}", environ.get(PASSWORD_ENV, "")),
            ) if not value
        ]
        if missing:
            raise Refused(
                f"{' and '.join(missing)} {'is' if len(missing) == 1 else 'are'} not set, so the "
                f"registry cannot be read. The check is never skipped: no tag is created until it "
                f"passes. Set the pull-only token on the {SCOPE_MAP} scope map as "
                f"docs/releasing.md, 'The release Environment', describes."
            )

        client = Registry(registry, environ[NAME_ENV], environ[PASSWORD_ENV], send)
        token = client.login()
        if environ.get("GITHUB_ACTIONS") == "true":
            say(f"::add-mask::{token}")
        observed = {ref: client.digest(token, ref) for ref in refs}
    except Refused as reason:
        say(f"::error::{reason}")
        return 1

    for ref in refs:
        say(f"  {'found  ' if observed[ref] else 'MISSING'}   {ref}"
            + (f" -> {observed[ref]}" if observed[ref] and "@" not in ref else ""))
    failures = judge(checks, observed)
    for failure in failures:
        say(f"::error::{failure}")
    if failures:
        say(f"Refused: {len(failures)} default image reference(s) of the stable and previous "
            f"channels do not resolve as the manifest records them.")
        return 1
    say(f"Every default image of the stable and previous channels resolves in {registry} at the "
        f"digest the manifest records.")
    return 0


# ---------------------------------------------------------------------------
# The selftest: watching the check refuse, against a fake registry
# ---------------------------------------------------------------------------
#
# The fake answers the same requests the registry does — the token exchange with HTTP Basic, then
# HEAD on /v2/<repository>/manifests/<reference> with the Bearer token — so the real client, not a
# stand-in for it, is what each scenario runs. Each scenario asserts the exit code and the message
# that names the fault, so one failing for an unrelated reason does not read as proof. Every
# scenario also asserts that the password is never printed, and that the access token appears only
# on an `::add-mask::` line.
#
REG = DEFAULT_REGISTRY
NAME = "pull-ci-cut-release"
PASSWORD = "selftest-password-never-printed"
TOKEN = "selftest-access-token-only-masked"
# main's current stable release (0.23.0): the release/api build MAS-4228 restores.
API_NOW = "sha256:00b0c775ff83cd4b1d0a9c79e9290d3166f471b5576f43e4272ab0d031a9ed04"
FRONTEND_NOW = "sha256:e1e59d896125ee033a461297b9c36b57507320d7cb8c4b0897011aa7066e6a2b"


def _d(char: str) -> str:
    return "sha256:" + char * 64


class _FakeRegistry:
    def __init__(self, images: dict[str, dict[str, str]], head_status: int | None = None):
        self.images = images  # repository -> {tag: digest}; a digest resolves if any tag names it
        self.head_status = head_status
        self.requests = 0

    def __call__(self, request: urllib.request.Request) -> tuple[int, dict[str, str], bytes]:
        self.requests += 1
        url = urllib.parse.urlsplit(request.full_url)
        if url.scheme != "https" or url.hostname != REG:
            return 400, {}, b""
        auth = request.get_header("Authorization")
        if url.path == "/oauth2/token":
            query = urllib.parse.parse_qs(url.query)
            basic = base64.b64encode(f"{NAME}:{PASSWORD}".encode()).decode()
            if auth != f"Basic {basic}":
                return 401, {}, b""
            wanted = sorted(f"repository:release/{role}:pull" for role in ROLES)
            if query.get("service") != [REG] or sorted(query.get("scope", [])) != wanted:
                return 400, {}, b""
            return 200, {}, json.dumps({"access_token": TOKEN}).encode()
        match = re.match(r"^/v2/(.+)/manifests/([^/]+)$", url.path)
        if request.get_method() != "HEAD" or not match:
            return 405, {}, b""
        if auth != f"Bearer {TOKEN}":
            return 401, {}, b""
        if self.head_status is not None:
            return self.head_status, {}, b""
        accept = request.get_header("Accept") or ""
        if "image.index.v1+json" not in accept or "manifest.v2+json" not in accept:
            return 406, {}, b""
        repository, reference = match.group(1), urllib.parse.unquote(match.group(2))
        tags = self.images.get(repository, {})
        digest = reference if reference in tags.values() else tags.get(reference)
        if digest is None:
            return 404, {}, b""
        return 200, {"docker-content-digest": digest}, b""


def _release(api_tag: str, frontend_tag: str, api_digest: str | None = None,
             frontend_digest: str | None = None, known_issue: str | None = None) -> dict:
    entry: dict = {
        "date": "2026-01-01",
        "images": {"api": f"{REG}/release/api:{api_tag}",
                   "frontend": f"{REG}/release/frontend:{frontend_tag}"},
    }
    if api_digest:
        entry["digests"] = {"api": api_digest, "frontend": frontend_digest}
    if known_issue:
        entry["known_issue"] = known_issue
    return entry


def _manifest(latest: str, **releases: dict) -> dict:
    return {"schema_version": 1, "latest": latest,
            "releases": {k[1:].replace("_", "."): v for k, v in releases.items()}}


def _selftest_scenarios() -> list[tuple]:
    """(name, manifest, env, registry, expected exit, must print, must not print)."""
    env = {NAME_ENV: NAME, PASSWORD_ENV: PASSWORD, "GITHUB_ACTIONS": "true"}
    two = _manifest("0.2.0", v0_2_0=_release("v2", "v20", _d("a"), _d("b")),
                    v0_1_0=_release("v1", "v10", _d("c"), _d("e")))
    both_there = {"release/api": {"v2": _d("a"), "v1": _d("c")},
                  "release/frontend": {"v20": _d("b"), "v10": _d("e")}}
    # main's MANIFEST.json today: 0.23.0 (stable) and 0.22.0 (previous) record the same pair.
    now = _manifest("0.23.0", v0_23_0=_release("v0.135.0", "v0.143.0", API_NOW, FRONTEND_NOW),
                    v0_22_0=_release("v0.135.0", "v0.143.0", API_NOW, FRONTEND_NOW))
    by_tag = _manifest("0.2.0", v0_2_0=_release("v2", "v20"), v0_1_0=_release("v1", "v10"))
    known = _manifest("0.3.0", v0_3_0=_release("v3", "v30", _d("1"), _d("2")),
                      v0_2_0=_release("v2", "v20", _d("3"), _d("4"), known_issue="broken"),
                      v0_1_0=_release("v1", "v10", _d("5"), _d("6")))
    known_there = {"release/api": {"v3": _d("1"), "v1": _d("5")},
                   "release/frontend": {"v30": _d("2"), "v10": _d("6")}}
    tens = _manifest("0.10.0", v0_10_0=_release("v10", "v100", _d("1"), _d("2")),
                     v0_9_0=_release("v9", "v90", _d("3"), _d("4")),
                     v0_8_0=_release("v8", "v80", _d("5"), _d("6")))
    tens_there = {"release/api": {"v10": _d("1"), "v9": _d("3")},
                  "release/frontend": {"v100": _d("2"), "v90": _d("4")}}
    alone = _manifest("0.2.0", v0_2_0=_release("v2", "v20", _d("a"), _d("b")),
                      v0_1_0=_release("v1", "v10", _d("c"), _d("e"), known_issue="broken"))
    no_name = {k: v for k, v in env.items() if k != NAME_ENV}
    no_password = {k: v for k, v in env.items() if k != PASSWORD_ENV}
    return [
        ("every default stable and previous image resolves at its digest: passes",
         two, env, _FakeRegistry(both_there), 0,
         [f"check     {REG}/release/api@{_d('a')}", f"check     {REG}/release/frontend@{_d('e')}",
          f"::add-mask::{TOKEN}", "Every default image"], ["::error::"]),
        ("an entry with no digests resolves by tag, release/<role>:<tag>: passes",
         by_tag, env, _FakeRegistry({"release/api": {"v2": _d("a"), "v1": _d("c")},
                                     "release/frontend": {"v20": _d("b"), "v10": _d("e")}}), 0,
         [f"check     {REG}/release/api:v2", f"check     {REG}/release/frontend:v10"],
         ["::error::", "@sha256"]),
        ("a missing tag-form reference fails naming release/<role>:<tag>",
         by_tag, env, _FakeRegistry({"release/api": {"v1": _d("c")},
                                     "release/frontend": {"v20": _d("b"), "v10": _d("e")}}), 1,
         [f"::error::{REG}/release/api:v2 does not resolve"], ["release/frontend:v20 does not"]),
        ("main's current stable release/api is missing (404): fails naming "
         f"{REG}/release/api@{API_NOW[:15]}…",
         now, env, _FakeRegistry({"release/frontend": {"v0.143.0": FRONTEND_NOW}}), 1,
         [f"::error::{REG}/release/api@{API_NOW} does not resolve",
          "stable 0.23.0 and previous 0.22.0"],
         [f"release/frontend@{FRONTEND_NOW} does not", "release/frontend:v0.143.0 does not"]),
        ("a tag at a digest the manifest does not record fails naming both digests",
         two, env, _FakeRegistry({"release/api": {"v2": _d("f"), "old": _d("a"), "v1": _d("c")},
                                  "release/frontend": {"v20": _d("b"), "v10": _d("e")}}), 1,
         [f"::error::{REG}/release/api:v2 resolves to {_d('f')}, but the manifest records "
          f"{_d('a')}"], ["does not resolve"]),
        ("a digest that resolves under no tag the entry names fails naming the tag",
         two, env, _FakeRegistry({"release/api": {"old": _d("a"), "v1": _d("c")},
                                  "release/frontend": {"v20": _d("b"), "v10": _d("e")}}), 1,
         [f"::error::{REG}/release/api:v2 does not resolve in the registry, but the manifest "
          f"records its api image at {_d('a')}"], [f"release/api@{_d('a')} does not"]),
        ("a digest that is not sha256:<64 hex> is refused before anything is read",
         _manifest("0.2.0", v0_2_0=_release("v2", "v20", "sha256:abc\n::warning::x", _d("b"))),
         env, _FakeRegistry(both_there), 1,
         ["which is not sha256:<64 hex>"], ["\n::warning::x"]),
        ("previous skips a known_issue release just below latest and checks the one below it",
         known, env, _FakeRegistry(known_there), 0,
         ["previous  0.1.0", f"check     {REG}/release/api@{_d('5')}"],
         ["::error::", _d("3")]),
        ("0.10.0 sorts after 0.9.0, so the previous of 0.10.0 is 0.9.0",
         tens, env, _FakeRegistry(tens_there), 0,
         ["stable    0.10.0", "previous  0.9.0", f"check     {REG}/release/api@{_d('3')}"],
         ["::error::", _d("5")]),
        ("no qualifying older release: previous is none, and stable is still checked",
         alone, env, _FakeRegistry(both_there), 0,
         ["previous  none", f"check     {REG}/release/api@{_d('a')}"], ["::error::", _d("c")]),
        ("the token name is unset: fails naming the release Environment variable",
         two, no_name, _FakeRegistry(both_there), 1,
         [f"::error::the `release` Environment variable {NAME_ENV} is not set"], ["add-mask"]),
        ("the password is unset: fails naming the release Environment secret",
         two, no_password, _FakeRegistry(both_there), 1,
         [f"::error::the `release` Environment secret {PASSWORD_ENV} is not set"], ["add-mask"]),
        ("both are unset: fails naming both",
         two, {}, _FakeRegistry(both_there), 1,
         [f"variable {NAME_ENV} and the `release` Environment secret {PASSWORD_ENV} are not set"],
         ["add-mask"]),
        ("a refused credential (401) fails naming the credential, not an image",
         two, {**env, PASSWORD_ENV: "wrong"}, _FakeRegistry(both_there), 1,
         [f"::error::the registry refused the credential {NAME_ENV}='{NAME}' (HTTP 401)"],
         ["does not resolve", "add-mask"]),
        ("a 403 on an image read fails naming the credential, not a missing image",
         two, env, _FakeRegistry(both_there, head_status=403), 1,
         ["(HTTP 403) while reading"], ["does not resolve"]),
        ("a 401 on an image read fails naming the credential, not a missing image",
         two, env, _FakeRegistry(both_there, head_status=401), 1,
         ["(HTTP 401) while reading"], ["does not resolve"]),
        ("any other registry answer fails closed",
         two, env, _FakeRegistry(both_there, head_status=500), 1,
         ["answered HTTP 500"], ["Every default image"]),
        ("outside GitHub Actions the access token is never printed, not even to mask it",
         two, {NAME_ENV: NAME, PASSWORD_ENV: PASSWORD}, _FakeRegistry(both_there), 0,
         ["Every default image"], ["add-mask"]),
        ("'latest' naming no release fails",
         _manifest("0.3.0", v0_2_0=_release("v2", "v20")), env, _FakeRegistry(both_there), 1,
         ["::error::'latest' is '0.3.0', which is no release"], []),
    ]


def selftest() -> int:
    scenarios = _selftest_scenarios()
    failures: list[str] = []
    with tempfile.TemporaryDirectory() as tmp:
        manifest_file = Path(tmp) / "MANIFEST.json"
        for name, manifest, env, registry, expected_exit, present, absent in scenarios:
            manifest_file.write_text(json.dumps(manifest), encoding="utf-8")
            out = io.StringIO()
            code = main(["--manifest", str(manifest_file), "--registry", REG],
                        environ=env, send=registry, out=out)
            output = out.getvalue()
            verdict = "ok"
            if code != expected_exit:
                verdict = f"expected exit {expected_exit}, got {code}:\n{output}"
            elif missing := [p for p in present if p not in output]:
                # Right verdict, wrong reason — which would make the scenario prove nothing.
                verdict = f"exited {code} but never printed {missing[0]!r}:\n{output}"
            elif found := [a for a in absent if a in output]:
                verdict = f"printed {found[0]!r}, which must not be there:\n{output}"
            elif PASSWORD in output:
                verdict = f"printed the password:\n{output}"
            elif any(TOKEN in line and not line.startswith("::add-mask::")
                     for line in output.splitlines()):
                verdict = f"printed the access token unmasked:\n{output}"
            elif expected_exit == 1 and "::error::" not in output:
                verdict = f"refused without an ::error:: line:\n{output}"
            if verdict != "ok":
                failures.append(f"{name}: {verdict}")
            print(f"  {'PASS' if verdict == 'ok' else 'FAIL'}  {name}")
            refusal = next((line for line in output.splitlines()
                            if line.startswith("::error::")), None)
            if verdict == "ok" and refusal:
                print(f"          refused: {refusal[len('::error::'):]}")

    if failures:
        print(
            f"\nrelease-images selftest — {len(failures)} of {len(scenarios)} scenarios did not "
            f"behave as required:",
            file=sys.stderr,
        )
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print(
        f"\nrelease-images selftest — {len(scenarios)} scenarios: every default stable and "
        f"previous image resolving passes; a missing image, a tag at an unrecorded digest, a "
        f"missing or refused credential and any other registry answer are each refused by name."
    )
    return 0


def main(argv: list[str] | None = None, environ: dict | None = None, send: Send | None = None,
         out: TextIO | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument(
        "--manifest",
        default=str(Path(__file__).resolve().parent.parent / "MANIFEST.json"),
        help="the release commit's MANIFEST.json (default: this checkout's)",
    )
    parser.add_argument("--registry", default=DEFAULT_REGISTRY,
                        help=f"the registry host the module defaults to (default {DEFAULT_REGISTRY})")
    parser.add_argument(
        "--selftest",
        action="store_true",
        help="run against a fake registry and assert the bad cases are still refused",
    )
    args = parser.parse_args(argv)
    if args.selftest:
        return selftest()
    return run(args.manifest, args.registry,
               dict(os.environ) if environ is None else environ,
               urllib_send if send is None else send,
               sys.stdout if out is None else out)


if __name__ == "__main__":
    sys.exit(main())
