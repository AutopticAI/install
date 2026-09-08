#!/usr/bin/env python3
"""Move environments/agents/skills/tools between Autoptic instances.

Operator script, not product functionality. It calls the server HTTP API
directly, with no MCP dependency and no third-party package. README.md
holds the command reference. The notes at the top of each section below
explain why each resource type needs its own handling.

The route table, the encodings, and the dependency graph come from a
design written against the real server source (main.go registerAPIRoutes,
handlers/*.go, dal/*.go), which this repository does not contain. Every
shape was then confirmed against a running server, which corrected one of
them (see list_ids) and added three fields worth ignoring (see
_VOLATILE_FIELDS).
"""

import argparse
import base64
import difflib
import fnmatch
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# HTTP client
# ---------------------------------------------------------------------------


class ApiError(Exception):
    def __init__(self, message, status=None, body=None):
        super().__init__(message)
        self.status = status
        # Full response body, kept so callers can read structured error
        # fields (see missing_secret_keys) rather than guessing from the
        # status code. None for a transport failure, where there is none.
        self.body = body


def _not_json_message(url, raw, err):
    """A 200 that is not JSON almost always means the URL is the UI host, not
    the API host. The UI is a SvelteKit SPA with a catch-all route: it answers
    EVERY path -- API paths included -- with HTTP 200 and its HTML shell. The
    bare JSONDecodeError that falls out of that ("Expecting value: line 1
    column 1") points at nothing, so name the likely cause instead. Confirmed
    live against chaos.dev.autoptic.com (UI) vs api.dev.autoptic.com (API)."""
    head = raw[:200].lstrip()
    looks_html = head[:1] == "<" or head[:9].lower() == "<!doctype"
    lines = [f"GET {url} returned HTTP 200 but the body is not JSON ({err})."]
    if looks_html:
        lines.append(
            "The body is HTML. This URL is almost certainly the UI host rather than the "
            "API host. The UI serves its HTML shell with HTTP 200 for every path, so it "
            "never 404s and a JSON client dies here instead."
        )
    lines.append("Confirm which host you have -- the API answers with a JSON array:")
    lines.append(f"    curl -s {url}")
    return "\n".join(lines)


class Client:
    """One instance: a base URL + endpoint_id + token.

    Auth is a single header, `x-api-token` (server/middleware/auth.go
    prefix-scans the endpoint's secret dict for api.autoptic.token.* keys).
    auth.enforce defaults to false, so the token is often not required, but
    sending it is harmless and forward-compatible.
    """

    def __init__(self, base_url, endpoint_id, token=None, timeout=30):
        # quote() the endpoint_id for the same reason as item ids below: an
        # unescaped "#" would truncate the URL and silently retarget every
        # call at the wrong endpoint.
        self.base = base_url.rstrip("/") + f"/story/ep/{urllib.parse.quote(endpoint_id, safe='')}"
        self.token = token
        self.timeout = timeout

    def _headers(self, has_body):
        h = {}
        if self.token:
            h["x-api-token"] = self.token
        if has_body:
            h["Content-Type"] = "application/json"
        return h

    def request(self, method, path, body=None):
        """Returns (status, raw_bytes). Raises ApiError on transport failure
        or a non-2xx response -- callers that want to tolerate a specific
        status (e.g. GET /pql's 404-on-empty) must catch ApiError and check
        .status themselves."""
        url = self.base + path
        data = body.encode() if isinstance(body, str) else body
        req = urllib.request.Request(url, data=data, method=method, headers=self._headers(data is not None))
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return resp.status, resp.read()
        except urllib.error.HTTPError as e:
            raw = e.read().decode("utf-8", "replace")
            raise ApiError(f"{method} {path} -> HTTP {e.code}: {raw[:500]}", status=e.code, body=raw) from None
        except urllib.error.URLError as e:
            raise ApiError(f"{method} {path} -> connection error: {e}") from None

    def get_json(self, path, treat_404_as_empty=False):
        try:
            status, raw = self.request("GET", path)
        except ApiError as e:
            if treat_404_as_empty and e.status == 404:
                return []
            raise
        if not raw.strip():
            return None
        try:
            return json.loads(raw)
        except json.JSONDecodeError as e:
            raise ApiError(_not_json_message(self.base + path, raw, e), status=status, body=raw) from None


# ---------------------------------------------------------------------------
# Per-resource-type adapters
#
# The four content types do NOT share one shape. Route, list shape, and
# POST encoding all differ per type -- this table is the load-bearing part
# of the whole script:
#
#   type   | list route      | list returns          | GET returns       | POST body
#   -------|------------------|------------------------|--------------------|---------------------------
#   env    | GET /env         | []string ids           | raw JSON, decoded  | base64(json.dumps(body))
#   skill  | GET /skill       | []SkillObject (full)    | SkillObject JSON   | raw JSON (SkillObject)
#   tool   | GET /pql         | [{"pql_id",             | full pql object,   | {"body": base64(src),
#          |                  |   "description"}] (404=[])| body PLAINTEXT  |  "doc","description","tags"}
#   agent  | GET /agent/config| []string ids, ALL BRIEFS| raw JSON body      | raw JSON body
#
# The tool row is confirmed live, against a real server -- it differs from
# what the design doc this script was built from claimed (bare id strings).
# Everything else in this table matches that doc exactly.
#
# "tool" is PQL under a friendlier name. catalog/* routes are a read-only
# library baked into the binary, not tenant content -- never touched here.
# ---------------------------------------------------------------------------

KINDS = ("env", "tool", "skill", "agent")  # import/push order: env+tool first (agents/skills reference them)

_ROUTE = {
    "env": "/env",
    "tool": "/pql",
    "skill": "/skill",
    "agent": "/agent/config",
}


def _item_path(kind, item_id):
    # Ids are caller-supplied names, not slugs, and nothing on the server
    # constrains them. Unescaped, a "#" truncates the path (urllib treats the
    # rest as a fragment and never sends it) and a "?" turns the tail into a
    # query string -- so a GET silently reads a DIFFERENT object and a POST
    # silently overwrites one. safe="" because even "/" must be escaped: an id
    # containing a slash would otherwise address a route that does not exist.
    return f"{_ROUTE[kind]}/{urllib.parse.quote(str(item_id), safe='')}"


def list_ids(client, kind):
    """Returns the set of ids worth fetching for this kind. For skills this
    already IS the full object list (one call gets everything); for agents
    this is every brief id, not filtered to agents yet -- see fetch_one.
    Confirmed live: env/agent/skill list ids as bare strings, but pql lists
    summary objects ({"pql_id": ..., "description": ...}), not ids -- the
    design doc this script was built from got this one wrong."""
    items = client.get_json(_ROUTE[kind], treat_404_as_empty=(kind == "tool")) or []
    if kind == "tool":
        return [i["pql_id"] if isinstance(i, dict) else i for i in items]
    return items


def fetch_raw(client, kind, item_id):
    """The object's body exactly as GET returns it, with no shape
    filtering. Used wherever "something is already there, of some shape"
    must be distinguishable from "nothing is there" (404) -- collision
    detection and rollback capture, in particular, must never conflate a
    non-agent brief sitting at an agent path with an absent path, or a
    collision silently becomes an overwrite and a rollback silently
    becomes a delete."""
    _, raw = client.request("GET", _item_path(kind, item_id))
    return json.loads(raw)


def fetch_one(client, kind, item_id):
    """Fetch and normalize one object to its bundle/re-postable shape.
    Returns None for an agent id that turns out not to be an agent (a
    non-agent brief) -- GET /agent/config lists ALL briefs, not just
    agents; the only way to tell them apart is to fetch and inspect. Only
    for enumeration, where "not actually an agent" must be filtered out;
    see fetch_raw for existence checks."""
    obj = fetch_raw(client, kind, item_id)
    if kind == "agent":
        if not (isinstance(obj, dict) and "config" in obj and ("skill" in obj or "task" in obj)):
            return None
    return obj


def push_one(client, kind, item_id, body):
    if kind == "env":
        payload = base64.b64encode(json.dumps(body).encode()).decode()
    elif kind == "tool":
        payload = json.dumps({
            "body": base64.b64encode((body.get("body") or "").encode()).decode(),
            "doc": body.get("doc", ""),
            "description": body.get("description", ""),
            "tags": body.get("tags") or {},
        })
    else:  # skill, agent: raw JSON, as-is
        payload = json.dumps(body)
    status, _ = client.request("POST", _item_path(kind, item_id), body=payload)
    return status


def delete_one(client, kind, item_id):
    status, _ = client.request("DELETE", _item_path(kind, item_id))
    return status


# ---------------------------------------------------------------------------
# Enumeration: every real object of each kind on an instance
# ---------------------------------------------------------------------------


def enumerate_all(client, kinds=KINDS, report=print):
    """Returns ({kind: {id: body}}, [failures]). Skips non-agent briefs
    silently in the result but reports them, so a misclassification is
    visible rather than silently dropped.

    An object that could not be fetched is reported AND returned in
    failures: it silently shrinks the set every later step works from, so
    the caller has to be able to refuse to treat the run as a success."""
    out = {}
    failures = []
    for kind in kinds:
        ids = list_ids(client, kind)
        if kind == "skill":
            # list_ids already returned full objects for skills.
            out[kind] = {obj.get("name"): obj for obj in ids if isinstance(obj, dict) and obj.get("name")}
            continue
        objs = {}
        skipped = []
        for item_id in ids:
            try:
                obj = fetch_one(client, kind, item_id)
            except ApiError as e:
                report(f"WARN: {kind} '{item_id}': fetch failed, skipping this one: {e}")
                failures.append(f"{kind} '{item_id}': {e}")
                continue
            if obj is None:
                skipped.append(item_id)
                continue
            objs[item_id] = obj
        if kind == "agent" and skipped:
            shown = ", ".join(skipped[:10]) + (" ..." if len(skipped) > 10 else "")
            report(f"{len(skipped)} brief(s) under /agent/config were not agents (no config+skill/task), skipped: {shown}")
        out[kind] = objs
    return out, failures


# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------


def select(all_objects, all_flag, patterns_by_kind):
    """all_objects: {kind: {id: body}}. Returns ({kind: {id: body}}, unmatched),
    the selection plus every pattern that matched nothing. --all takes everything; otherwise each --env/--agent/
    --skill/--tool pattern (glob, repeatable) is matched against ids."""
    if all_flag:
        return {k: dict(v) for k, v in all_objects.items()}, []
    selected = {k: {} for k in KINDS}
    unmatched = []
    for kind, patterns in patterns_by_kind.items():
        if not patterns:
            continue
        for pattern in patterns:
            hits = [i for i in all_objects.get(kind, {}) if fnmatch.fnmatch(i, pattern)]
            if not hits:
                # A typo'd selector otherwise selects nothing, resolves an
                # empty closure, prints an empty summary and exits 0 -- an
                # unnoticed no-op that reads exactly like success.
                unmatched.append(f"--{kind} '{pattern}' matched no {kind} on the source")
            for item_id in hits:
                selected[kind][item_id] = all_objects[kind][item_id]
    return selected, unmatched


# ---------------------------------------------------------------------------
# Dependency closure
#
# Objects reference each other by bare name string; the server never
# validates these at save time (server/services/agent.go's
# ResolutionWarning{reason:"not_found"} only surfaces at RUN time). So this
# script computes and reports the closure itself, and treats a dangling
# reference as a warning, not a fatal error -- it may already be dangling
# on the source.
# ---------------------------------------------------------------------------

SECRET_TEMPLATE_RE = re.compile(r"\{\{\s*secret\s+'([^']+)'\s*\}\}")
PQL_PROVIDER_RE = re.compile(r'#provider\s*=\s*"@([^"]+)"')
LOOKS_SECRET_KEY_RE = re.compile(r"(key|token|secret|password|credential|webhook|auth)", re.I)
# A key ending this way names a classifier (e.g. "auth_type": "token"), not
# a credential -- confirmed live on real production data, right next to the
# real secret it describes: {"auth_type": "token", "api_token": "{{ secret
# 'jira.token' }}"}. Without this, "auth_type" false-positives on "auth".
BENIGN_KEY_SUFFIX_RE = re.compile(r"(_type|_method)$", re.I)


def _is_reference(entry):
    """The server matches this discriminator with
    strings.EqualFold(strings.TrimSpace(...)) (server/dal/brief.go), so
    "Reference" and " reference " are references too. Matching it exactly
    would misclassify them as INLINE skills, and the referenced skill would
    then never be migrated -- silently, because an inline skill legitimately
    contributes no skill id."""
    return str(entry.get("type") or "").strip().lower() == "reference"


def _skill_refs(skill_ref_list):
    """An agent's skill[] entries: str (skill id), {"type":"reference",
    "name":N} (skill id), or an inline object (not a reference at all --
    its steps are already inline, so it contributes no skill id -- but its
    own tool/env/skill references still need walking, see _inline_skills)."""
    ids = []
    for entry in skill_ref_list or []:
        if isinstance(entry, str):
            ids.append(entry)
        elif isinstance(entry, dict) and _is_reference(entry) and entry.get("name"):
            ids.append(entry["name"])
    return ids


def _inline_skills(skill_ref_list):
    """The skill[] entries that are inline skill bodies, embedded directly
    in the agent rather than referenced by name -- confirmed live as the
    common real-world shape, not an edge case. Not a separate object to
    migrate (it travels with the agent), but its steps[].tool /
    parameters.data_source.provider / runtime.allowed_skills / lead_skill
    still reference real dependencies that must be pulled in or checked,
    exactly as if it were a standalone skill."""
    return [
        entry for entry in skill_ref_list or []
        if isinstance(entry, dict) and not _is_reference(entry)
    ]


def _skill_tool_and_env_refs(skill_obj):
    """From one skill body: (tool_ids, env_names, more_skill_ids)."""
    tools, envs, skills = set(), set(), set()
    for step in skill_obj.get("steps") or []:
        if step.get("type") == "pql" and step.get("tool"):
            tools.add(step["tool"])
        # data_source is usually {"provider": name}, but confirmed live as
        # a bare string too (e.g. "autoptic_mcp") -- the string form IS the
        # provider name directly.
        data_source = (step.get("parameters") or {}).get("data_source")
        provider = data_source.get("provider") if isinstance(data_source, dict) else data_source
        if provider:
            envs.add(provider)
    runtime = skill_obj.get("runtime") or {}
    for s in runtime.get("allowed_skills") or []:
        skills.add(s)
    if runtime.get("lead_skill"):
        skills.add(runtime["lead_skill"])
    return tools, envs, skills


def required_secret_keys(env_bodies):
    """The `{{ secret 'key' }}` templates referenced by a set of env bodies."""
    return sorted({
        m.group(1)
        for body in env_bodies
        for m in SECRET_TEMPLATE_RE.finditer(json.dumps(body))
    })


def resolve_closure(all_objects, seed, report=print):
    """seed: {kind: {id: body}} (the initial selection). Returns
    (closure, warnings, required_secrets) where closure is {kind: {id: body}}
    (seed plus everything it pulls in, objects that exist on source) and
    warnings is a list of human-readable strings: dangling refs and expected
    env entries that are missing."""
    closure = {k: dict(v) for k, v in seed.items()}
    warnings = []
    expected_env_entries = {}  # env_id -> set of "field[]: name" expected inside it
    provider_refs = set()  # data_source/#provider names from skills/tools, checked against every env in the closure once resolution finishes

    def add(kind, item_id, why):
        if item_id in closure[kind]:
            return
        body = all_objects.get(kind, {}).get(item_id)
        if body is None:
            warnings.append(f"dangling {kind} ref '{item_id}' ({why}) -- not found on source, skipped")
            return
        closure[kind][item_id] = body
        pending.append((kind, item_id))

    pending = [(k, i) for k, d in seed.items() for i in d]
    while pending:
        kind, item_id = pending.pop()
        body = closure[kind][item_id]
        if kind == "agent":
            cfg = body.get("config") or {}
            # The server accepts "environment" as a first-class alias for
            # "env" (dal.AgentConfigSettings; validateAgentConfig,
            # mcpEnvironmentDataSources). Reading only "env" migrates such an
            # agent WITHOUT its environment, and the secrets preflight then
            # passes too, because it only scans envs that made it into the
            # closure.
            env_id = cfg.get("env") or cfg.get("environment")
            if env_id:
                add("env", env_id, f"agent '{item_id}' config.env")
                for field in ("prompt", "slack"):
                    name = cfg.get(field)
                    if name:
                        expected_env_entries.setdefault(env_id, set()).add(f"{field}[]: {name}")
                for n in cfg.get("notifications") or []:
                    expected_env_entries.setdefault(env_id, set()).add(f"notifications[]: {n}")
            for prov in body.get("providers") or []:
                if isinstance(prov, str) and prov:
                    provider_refs.add(prov)
            skill_list = body.get("skill") or body.get("task")
            for skill_id in _skill_refs(skill_list):
                add("skill", skill_id, f"agent '{item_id}' skill[]")
            for inline in _inline_skills(skill_list):
                tools, env_names, more_skills = _skill_tool_and_env_refs(inline)
                where = f"agent '{item_id}' inline skill '{inline.get('name', '?')}'"
                for tool_id in tools:
                    add("tool", tool_id, f"{where} steps[].tool")
                provider_refs.update(env_names)
                for skill_id in more_skills:
                    add("skill", skill_id, f"{where} runtime.allowed_skills/lead_skill")
        elif kind == "skill":
            tools, env_names, more_skills = _skill_tool_and_env_refs(body)
            for tool_id in tools:
                add("tool", tool_id, f"skill '{item_id}' steps[].tool")
            provider_refs.update(env_names)
            for skill_id in more_skills:
                add("skill", skill_id, f"skill '{item_id}' runtime.allowed_skills/lead_skill")
        elif kind == "tool":
            provider_refs.update(m.group(1) for m in PQL_PROVIDER_RE.finditer(body.get("body") or ""))

    # A provider name is an entry inside SOME environment's where[], not an
    # environment id itself -- there is no env to pull in for it. If the
    # closure has no environment at all, that expectation can never be
    # checked, so say so explicitly instead of silently dropping it.
    if provider_refs:
        if closure.get("env"):
            for env_id in closure["env"]:
                expected_env_entries.setdefault(env_id, set()).update(f"where[]: {p}" for p in provider_refs)
        else:
            warnings.append(f"provider reference(s) {', '.join(sorted(provider_refs))} found in the selected skills/tools, but no environment is included in this export to check them against -- pass the right --env explicitly if this needs verifying")

    for env_id, names in expected_env_entries.items():
        env_body = closure.get("env", {}).get(env_id)
        if env_body is None:
            continue
        # Per-field, NOT a merged set of every name in the env. An agent's
        # config.prompt names an entry in the env's prompt[]; a where[] data
        # source that happens to share the name does not satisfy it. Merging
        # them made a missing prompt look present.
        have = {}
        for key in ("prompt", "slack", "notifications", "where"):
            names_in_field = set()
            for entry in env_body.get(key) or []:
                if isinstance(entry, dict) and entry.get("name"):
                    names_in_field.add(entry["name"])
                elif isinstance(entry, str):
                    names_in_field.add(entry)
            have[f"{key}[]"] = names_in_field
        for expectation in sorted(names):
            field, _, name = expectation.partition(": ")
            if name and name not in have.get(field, set()):
                warnings.append(f"env '{env_id}' is missing an expected entry named '{name}' ({field})")

    return closure, warnings, required_secret_keys(closure.get("env", {}).values())


def scan_literal_secrets(env_body):
    """Best-effort: a value under a credential-ish key that is NOT a
    `{{ secret '...' }}` template is a real, live secret sitting in the
    env body -- warn loudly, don't block (nothing forbids it server-side)."""
    hits = []

    def walk(o, path):
        if isinstance(o, dict):
            for k, v in o.items():
                p = f"{path}.{k}" if path else k
                if (
                    isinstance(v, str)
                    and LOOKS_SECRET_KEY_RE.search(k)
                    and not BENIGN_KEY_SUFFIX_RE.search(k)
                    and not SECRET_TEMPLATE_RE.fullmatch(v.strip())
                ):
                    hits.append(p)
                else:
                    walk(v, p)
        elif isinstance(o, list):
            for i, v in enumerate(o):
                walk(v, f"{path}[{i}]")

    walk(env_body, "")
    return hits


# ---------------------------------------------------------------------------
# Secrets preflight
# ---------------------------------------------------------------------------


def missing_secret_keys(err):
    """The secret key names a failed save reports as missing, or [] if it
    reports something else entirely.

    SaveEnvironment rejects a body referencing an unprovisioned key with a
    400 carrying secret_key/secret_keys. 400 on its own means nothing: it
    is the generic client-error status, returned for any agent config
    validation failure, invalid skill JSON, or a bad pql body field too.
    Reading the fields is the only way to tell a real secrets problem from
    an ordinary schema rejection -- sending an operator off to provision
    unrelated secrets because their agent was missing config.prompt is
    worse than saying nothing."""
    if err.status != 400 or not err.body:
        return []
    try:
        payload = json.loads(err.body)
    except ValueError:
        return []
    if not isinstance(payload, dict):
        return []
    keys = payload.get("secret_keys")
    if keys is None:
        keys = payload.get("secret_key")
    if isinstance(keys, str):
        return [keys]
    if isinstance(keys, list):
        return [k for k in keys if isinstance(k, str)]
    return []


def _secret_key_names(raw):
    """The key names in a GET /secret/default body. The stored value is
    whatever was last POSTed, so it is not guaranteed to be a JSON object --
    a bare string or a list would have raised AttributeError/TypeError here
    and aborted the run with a traceback instead of a diagnosis."""
    if not raw.strip():
        return set()
    try:
        payload = json.loads(raw)
    except ValueError as e:
        raise ApiError(f"the target's /secret/default is not valid JSON ({e}) -- it cannot be checked against") from None
    if not isinstance(payload, dict):
        raise ApiError(f"the target's /secret/default is a {type(payload).__name__}, not a JSON object of key -> {{\"value\": ...}} -- it cannot be checked against")
    return set(payload.keys())


def looks_like_env_secret_error(kind, err):
    """Fallback for a server build whose missing-secret 400 carries no
    secret_key/secret_keys field. Deliberately narrow: environments only,
    so an agent/skill/pql validation failure can never be misreported as a
    secrets problem, which is the whole point of not keying off the status
    code alone."""
    return kind == "env" and err.status == 400 and err.body and "secret" in err.body.lower()


def secrets_preflight(dst_client, required_keys, assume_ready, report=print):
    """Compares the keys the plan's environments reference against the keys
    the target already holds. Returns True if it's safe to proceed.

    GET /secret/default DOES return the target's whole plaintext secret
    dictionary -- this function reads only .keys() off it, and never prints,
    stores, or transports a VALUE. The response is dropped immediately below
    for that reason; do not widen its scope."""
    if not required_keys:
        return True
    report(f"{len(required_keys)} secret key(s) referenced by the environments in this plan: {', '.join(required_keys)}")

    def blocked(reason):
        report(reason)
        if not assume_ready:
            report("set up these secrets yo -- provision the keys above on the target, then rerun (or pass --assume-secrets-ready to push anyway and let SaveEnvironment reject each one that's still missing).")
            return False
        report("Proceeding anyway: --assume-secrets-ready was passed.")
        return True

    try:
        status, raw = dst_client.request("GET", "/secret/default")
        # Read the key names, then let the dict (which holds every plaintext
        # secret value on the target) go out of scope immediately.
        target_keys = _secret_key_names(raw)
    except ApiError as e:
        if e.status == 404:
            target_keys = set()  # nothing provisioned on the target yet -- every required key is missing, not "unverifiable"
        elif e.status in (401, 403):
            # The secret routes are admin-only, over and above scopes, so an
            # operator token cannot read them. Confirmed live: the server
            # answers 401 here, not the 403 the design predicted, and a
            # wholly invalid token answers 401 too. Name both readings,
            # because this is also the first call `import` makes.
            return blocked(
                f"Could not read the target's /secret/default ({e.status}). The secret routes are admin-only, "
                "so an operator token cannot read them. Check that the token is valid for this instance as well."
            )
        else:
            return blocked(f"Could not read target's /secret/default to verify: {e}")

    missing = sorted(set(required_keys) - target_keys)
    if missing:
        return blocked(f"Missing on target: {', '.join(missing)}")
    report("All required secret keys are already present on the target.")
    return True


# ---------------------------------------------------------------------------
# Collisions
# ---------------------------------------------------------------------------


# Fields GET adds that are not part of the object's real content, confirmed
# live: pql carries a write-time "created_on" timestamp that necessarily
# differs between two servers even for identical content, and both pql and
# skill echo back "endpoint_id", which is redundant with the id path and
# can legitimately differ between a source and target endpoint. Comparing
# these raw would make identical content look different on every push.
_VOLATILE_FIELDS = {
    "tool": {"created_on", "endpoint_id"},
    "skill": {"endpoint_id"},
}


def _comparable(kind, obj):
    drop = _VOLATILE_FIELDS.get(kind)
    if drop and isinstance(obj, dict):
        obj = {k: v for k, v in obj.items() if k not in drop}
    return obj


def _normalize(kind, obj):
    return json.dumps(_comparable(kind, obj), sort_keys=True, indent=2)


def fetch_existing(dst_client, kind, item_id):
    """The object as it currently stands on the target, raw (no shape
    filtering -- see fetch_raw), or None if nothing is there (404)."""
    try:
        return fetch_raw(dst_client, kind, item_id)
    except ApiError as e:
        if e.status == 404:
            return None
        raise


def diff_and_decide(kind, item_id, existing, incoming, on_conflict, state, interactive=True, report=print):
    """state carries the sticky overwrite-all/skip-all decision across calls
    within one run. Returns "unchanged", "overwrite", "skip", or (dry runs
    only) "undecided", meaning the real run will have to ask."""
    on_target, from_source = _normalize(kind, existing), _normalize(kind, incoming)
    if on_target == from_source:
        return "unchanged"

    if state.get("all") is not None:
        return state["all"]
    if on_conflict == "overwrite":
        return "overwrite"
    if on_conflict == "skip":
        return "skip"

    if not interactive:
        # A dry run must not prompt. Any answer given here would be thrown
        # away: the real run builds its own conflict state, so the operator
        # would be asked everything again, with nothing forcing the two
        # sets of answers to match.
        return "undecided"

    if not sys.stdin.isatty():
        report(f"{kind} '{item_id}' already exists on target and differs -- non-interactive, skipping (pass --on-conflict overwrite to force).")
        return "skip"

    print("\n".join(difflib.unified_diff(
        on_target.splitlines(), from_source.splitlines(),
        fromfile=f"target/{kind}/{item_id}", tofile=f"source/{kind}/{item_id}", lineterm="",
    )))
    while True:
        choice = input(f"{kind} '{item_id}': [o]verwrite / [s]kip / overwrite-[a]ll / skip-a[l]l / [q]uit? ").strip().lower()
        if choice == "o":
            return "overwrite"
        if choice == "s":
            return "skip"
        if choice == "a":
            state["all"] = "overwrite"
            return "overwrite"
        if choice == "l":
            state["all"] = "skip"
            return "skip"
        if choice == "q":
            report("Quit at user request.")
            sys.exit(1)


# ---------------------------------------------------------------------------
# Bundle I/O
# ---------------------------------------------------------------------------

_DIRNAME = {"env": "environments", "tool": "tools", "skill": "skills", "agent": "agents"}


def _safe_filename(item_id):
    return re.sub(r"[^A-Za-z0-9_.-]", "_", item_id) + ".json"


def write_bundle(out_dir, objects, manifest_extra, report=print):
    """Filenames are sanitized from item ids and are lossy (any character
    outside [A-Za-z0-9_.-] collapses to '_', and two different ids can
    collide onto the same filename), so the manifest's "ids" map is the
    authoritative filename -> item_id record read_bundle relies on. Each
    object file still holds the raw, untouched body -- same shape the
    UI's own download button produces -- so a hand-added file with no
    manifest entry still round-trips, via the id fields inside it."""
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    manifest = dict(manifest_extra)
    manifest["written_at"] = datetime.now(timezone.utc).isoformat()
    manifest["counts"] = {}
    manifest["ids"] = {}
    for kind, items in objects.items():
        d = out_dir / _DIRNAME[kind]
        d.mkdir(exist_ok=True)
        manifest["counts"][kind] = len(items)
        id_map = {}
        for item_id, body in items.items():
            filename = _safe_filename(item_id)
            if filename in id_map:
                # Loop, don't suffix once: len(id_map) grows with EVERY id, not
                # with the collisions, so a single pass can land on a name a
                # later id already took -- and the second write would silently
                # clobber the first, dropping an object from the bundle.
                stem, suffix = filename.rsplit(".", 1)
                n = 1
                while f"{stem}-{n}.{suffix}" in id_map:
                    n += 1
                filename = f"{stem}-{n}.{suffix}"
            id_map[filename] = item_id
            (d / filename).write_text(json.dumps(body, indent=2, sort_keys=True))
        manifest["ids"][kind] = id_map
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2))
    report(f"Wrote bundle to {out_dir} ({', '.join(f'{k}={v}' for k, v in manifest['counts'].items())})")


def _bundle_item_id(kind, body, fallback):
    # Fallback only, for a file with no entry in manifest["ids"] (e.g.
    # hand-added after the fact) -- prefer whatever the object's own id
    # field says over the (possibly lossy) sanitized filename.
    if kind == "skill":
        return body.get("name") or fallback
    for key in ("env_id", "pql_id", "agent_id", "id"):
        if body.get(key):
            return body[key]
    return fallback


class BundleError(Exception):
    """A bundle directory that cannot be read as one. Raised rather than
    letting FileNotFoundError/JSONDecodeError reach the user as a traceback:
    a mistyped --in path and a hand-edited file with a trailing comma are
    both ordinary operator mistakes, and both deserve a sentence."""


def read_bundle(in_dir):
    in_dir = Path(in_dir)
    if not in_dir.is_dir():
        raise BundleError(f"{in_dir} is not a directory -- --in takes the bundle directory itself, not a file inside it")
    manifest_path = in_dir / "manifest.json"
    if not manifest_path.is_file():
        raise BundleError(f"{manifest_path} not found -- {in_dir} is not a bundle (a bundle always carries manifest.json)")
    try:
        manifest = json.loads(manifest_path.read_text())
    except ValueError as e:
        raise BundleError(f"{manifest_path} is not valid JSON: {e}") from None
    if not isinstance(manifest, dict):
        raise BundleError(f"{manifest_path} must contain a JSON object, found {type(manifest).__name__}")
    ids_by_kind = manifest.get("ids") or {}
    objects = {k: {} for k in KINDS}
    for kind, dirname in _DIRNAME.items():
        d = in_dir / dirname
        if not d.is_dir():
            continue
        known_ids = ids_by_kind.get(kind, {})
        for f in sorted(d.glob("*.json")):
            try:
                body = json.loads(f.read_text())
            except ValueError as e:
                raise BundleError(f"{f} is not valid JSON: {e}") from None
            item_id = known_ids.get(f.name) or _bundle_item_id(kind, body, f.stem)
            objects[kind][item_id] = body
    return manifest, objects


# ---------------------------------------------------------------------------
# Import (push a set of objects to a target, with collisions + rollback)
# ---------------------------------------------------------------------------


def do_import(dst_client, objects, apply_, on_conflict, report=print):
    """objects: {kind: {id: body}}, already in KINDS import order by caller.
    Returns a summary dict. With apply_ false this never prompts and never
    writes -- see diff_and_decide's "undecided"."""
    summary = {k: {"created": 0, "updated": 0, "unchanged": 0, "skipped": 0, "conflicts": 0, "failed": 0} for k in KINDS}
    conflict_state = {"all": None}

    for kind in KINDS:
        for item_id, body in objects.get(kind, {}).items():
            try:
                existing = fetch_existing(dst_client, kind, item_id)
            except ApiError as e:
                report(f"WARN: {kind} '{item_id}': could not check target, skipping this one: {e}")
                summary[kind]["failed"] += 1
                continue

            if existing is None:
                action = "create"
            else:
                decision = diff_and_decide(kind, item_id, existing, body, on_conflict, conflict_state, apply_, report)
                if decision == "unchanged":
                    summary[kind]["unchanged"] += 1
                    continue
                if decision == "undecided":
                    report(f"[dry-run] {kind} '{item_id}': exists on target and differs -- the real run will ask whether to overwrite it")
                    summary[kind]["conflicts"] += 1
                    continue
                if decision == "skip":
                    report(f"{kind} '{item_id}': exists on target and differs, skipped (not overwritten).")
                    summary[kind]["skipped"] += 1
                    continue
                action = "overwrite"

            if not apply_:
                report(f"[dry-run] would {action} {kind} '{item_id}'")
                summary[kind]["created" if action == "create" else "updated"] += 1
                continue

            try:
                push_one(dst_client, kind, item_id, body)
            except ApiError as e:
                missing = missing_secret_keys(e)
                if missing:
                    report(f"set up these secrets yo -- {kind} '{item_id}' needs secret key(s) not provisioned on the target: {', '.join(missing)}")
                elif looks_like_env_secret_error(kind, e):
                    report(f"set up these secrets yo -- {kind} '{item_id}' was rejected over its secret references: {e}")
                else:
                    report(f"WARN: {kind} '{item_id}': save failed: {e}")
                summary[kind]["failed"] += 1
                continue

            try:
                verify = fetch_raw(dst_client, kind, item_id)
                if _normalize(kind, verify) != _normalize(kind, body):
                    report(f"WARN: {kind} '{item_id}': saved, but re-GET does not match what was sent (server-side normalization?).")
            except ApiError as e:
                report(f"WARN: {kind} '{item_id}': saved, but post-write verify GET failed: {e}")

            summary[kind]["created" if action == "create" else "updated"] += 1
            report(f"{kind} '{item_id}': {'created' if action == 'create' else 'overwritten'}")

    return summary


class RollbackCaptureError(Exception):
    """The target's pre-run state could not be fully captured."""


def capture_rollback(dst_client, objects, dst_endpoint_id, report=print):
    """Snapshot the target's CURRENT state for every object in the plan,
    including ones that don't exist yet (recorded as an explicit absent
    marker), before any write happens.

    Raises RollbackCaptureError, without writing a partial snapshot, if any
    object's current state could not be read. An object missing from both
    captured and absent is invisible to rollback: it would neither be
    restored nor deleted, so a later overwrite of it is permanent. A flaky
    network is exactly when that matters, so the run must stop instead."""
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    rollback_dir = Path(f"rollback-{dst_endpoint_id}-{stamp}")
    captured = {k: {} for k in KINDS}
    absent = {k: [] for k in KINDS}
    failures = []
    for kind in KINDS:
        for item_id in objects.get(kind, {}):
            try:
                existing = fetch_existing(dst_client, kind, item_id)
            except ApiError as e:
                failures.append(f"{kind} '{item_id}': {e}")
                continue
            if existing is None:
                absent[kind].append(item_id)
            else:
                captured[kind][item_id] = existing
    if failures:
        for f in failures:
            report(f"ERROR: could not read target's current state for {f}")
        raise RollbackCaptureError(
            f"{len(failures)} object(s) could not be captured, so this run would not be undoable"
        )
    write_bundle(rollback_dir, captured, {"kind": "rollback", "dst_endpoint_id": dst_endpoint_id, "absent": absent}, report=report)
    return rollback_dir


def print_summary(summary, report=print):
    report("\n=== Summary ===")
    for kind in KINDS:
        s = summary[kind]
        if sum(s.values()) == 0:
            continue
        line = f"{kind}: created={s['created']} updated={s['updated']} unchanged={s['unchanged']} skipped={s['skipped']} failed={s['failed']}"
        if s["conflicts"]:
            line += f" conflicts={s['conflicts']}"
        report(line)


def failure_count(summary):
    return sum(s["failed"] for s in summary.values())


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _client_from_args(url, endpoint, token_flag, token_env):
    token = token_flag or os.environ.get(token_env)
    return Client(url, endpoint, token=token)


def _selection_patterns(args):
    return {"env": args.env, "agent": args.agent, "skill": args.skill, "tool": args.tool}


def add_common_selection_args(p):
    p.add_argument("--all", action="store_true", help="Select everything on the source.")
    p.add_argument("--env", action="append", default=[], help="Select environments by id (glob, repeatable).")
    p.add_argument("--agent", action="append", default=[], help="Select agents by id (glob, repeatable).")
    p.add_argument("--skill", action="append", default=[], help="Select skills by name (glob, repeatable).")
    p.add_argument("--tool", action="append", default=[], help="Select tools/PQL by id (glob, repeatable).")
    p.add_argument("--no-deps", action="store_true", help="Move exactly the selection. Do not pull in the skills, tools, or environments it references.")


def add_secrets_args(p):
    p.add_argument("--assume-secrets-ready", action="store_true", help="Proceed even when the required secret keys are missing from the target, or cannot be read to verify.")


def cmd_list(args):
    client = _client_from_args(args.src_url, args.src_ep, args.src_token, "AUTOPTIC_SRC_TOKEN")
    objs, failures = enumerate_all(client)
    for kind in KINDS:
        ids = sorted(objs[kind])
        print(f"{kind} ({len(ids)}):")
        for i in ids:
            print(f"  {i}")
    return _report_source_failures(failures)


def _report_source_failures(failures):
    """A source object that could not be read is missing from everything
    downstream -- the listing, the closure, the bundle, the push. Say so on
    stderr and fail the run, rather than quietly working from a short set."""
    if not failures:
        return 0
    print(f"\n{len(failures)} object(s) could not be read from the source and are missing from this result:", file=sys.stderr)
    for f in failures:
        print(f"  - {f}", file=sys.stderr)
    return 1


def _plan(args):
    src = _client_from_args(args.src_url, args.src_ep, args.src_token, "AUTOPTIC_SRC_TOKEN")
    all_objects, source_failures = enumerate_all(src)
    seed, unmatched = select(all_objects, args.all, _selection_patterns(args))
    if args.no_deps:
        closure, warnings = seed, []
        required_secrets = required_secret_keys(seed.get("env", {}).values())
    else:
        closure, warnings, required_secrets = resolve_closure(all_objects, seed)
    literal_secret_warnings = []
    for env_id, body in closure.get("env", {}).items():
        hits = scan_literal_secrets(body)
        if hits:
            literal_secret_warnings.append(f"env '{env_id}' has literal-looking secret value(s), not templates, at: {', '.join(hits)}")
    # Sort the warnings. The server does not guarantee list order, so two
    # consecutive runs against an unchanged instance were emitting the same
    # warnings in a different order, which made the output impossible to diff
    # against a previous run. Unmatched selectors stay first: they mean the
    # command did not do what was asked, which outranks a pre-existing
    # dangling ref on the source.
    return closure, unmatched + sorted(warnings) + sorted(literal_secret_warnings), required_secrets, source_failures


def cmd_plan(args):
    closure, warnings, required_secrets, source_failures = _plan(args)
    for kind in KINDS:
        ids = sorted(closure[kind])
        print(f"{kind} ({len(ids)}): {', '.join(ids) if ids else '(none)'}")
    if required_secrets:
        print(f"\nRequired secret keys: {', '.join(required_secrets)}")
    if warnings:
        print("\nWarnings:")
        for w in warnings:
            print(f"  - {w}")
    print("\nNothing written -- plan is read-only.")
    return _report_source_failures(source_failures)


def cmd_export(args):
    closure, warnings, required_secrets, source_failures = _plan(args)
    for w in warnings:
        print(f"WARN: {w}")
    write_bundle(args.out, closure, {
        "kind": "export",
        "source": {"url": args.src_url, "endpoint_id": args.src_ep},
        "required_secrets": required_secrets,
        "warnings": warnings,
    })
    return _report_source_failures(source_failures)


def _run_import(dst, objects, apply_, on_conflict, dst_ep):
    """Returns a process exit code: non-zero if anything failed, so a
    partial run can never look like success to a wrapper or a CI step."""
    if apply_:
        try:
            rollback_dir = capture_rollback(dst, objects, dst_ep)
        except RollbackCaptureError as e:
            print(f"ERROR: {e}.", file=sys.stderr)
            print("Nothing was written. Fix the errors above, then rerun.", file=sys.stderr)
            return 1
        print(f"Rollback snapshot: {rollback_dir}  (run: rollback --dst-url ... --dst-ep {dst_ep} --in {rollback_dir})")
    summary = do_import(dst, objects, apply_, on_conflict)
    print_summary(summary)
    failed = failure_count(summary)
    if not apply_:
        print("\nDry run -- nothing written. Pass --apply to actually push.")
    if failed:
        print(f"\n{failed} object(s) failed.", file=sys.stderr)
        return 1
    return 0


def cmd_import(args):
    manifest, objects = read_bundle(args.in_)
    # Recompute from the environment bodies actually in the bundle, and union
    # with what the manifest recorded. read_bundle deliberately accepts a file
    # that was added by hand after the export (that's why the id fallback in
    # _bundle_item_id exists), but the manifest's list is frozen at export
    # time -- so trusting it alone lets a hand-added env's secret keys through
    # the preflight entirely unchecked. The union keeps the manifest's entries
    # too, in case an env was removed from the bundle but its keys still
    # matter to something else in it.
    required_secrets = sorted(
        set(manifest.get("required_secrets") or [])
        | set(required_secret_keys(objects.get("env", {}).values()))
    )
    dst = _client_from_args(args.dst_url, args.dst_ep, args.dst_token, "AUTOPTIC_DST_TOKEN")
    if not secrets_preflight(dst, required_secrets, args.assume_secrets_ready):
        return 1
    return _run_import(dst, objects, args.apply, args.on_conflict, args.dst_ep)


def cmd_migrate(args):
    if args.src_url.rstrip("/") == args.dst_url.rstrip("/") and args.src_ep == args.dst_ep and not args.allow_same:
        print("ERROR: source and destination are identical (same url + endpoint). Pass --allow-same if that's intentional.", file=sys.stderr)
        return 1
    closure, warnings, required_secrets, source_failures = _plan(args)
    for w in warnings:
        print(f"WARN: {w}")
    dst = _client_from_args(args.dst_url, args.dst_ep, args.dst_token, "AUTOPTIC_DST_TOKEN")
    if not secrets_preflight(dst, required_secrets, args.assume_secrets_ready):
        return 1
    rc = _run_import(dst, closure, args.apply, args.on_conflict, args.dst_ep)
    return rc or _report_source_failures(source_failures)


def cmd_rollback(args):
    manifest, objects = read_bundle(args.in_)
    if manifest.get("kind") != "rollback":
        print(f"ERROR: {args.in_} is not a rollback snapshot (manifest kind={manifest.get('kind')!r}).", file=sys.stderr)
        return 1
    dst = _client_from_args(args.dst_url, args.dst_ep, args.dst_token, "AUTOPTIC_DST_TOKEN")
    absent = manifest.get("absent", {})
    summary = {k: {"restored": 0, "deleted": 0, "failed": 0} for k in KINDS}
    for kind in KINDS:
        for item_id, body in objects.get(kind, {}).items():
            try:
                push_one(dst, kind, item_id, body)
                summary[kind]["restored"] += 1
                print(f"{kind} '{item_id}': restored")
            except ApiError as e:
                print(f"WARN: {kind} '{item_id}': restore failed: {e}")
                summary[kind]["failed"] += 1
        for item_id in absent.get(kind, []):
            try:
                delete_one(dst, kind, item_id)
                summary[kind]["deleted"] += 1
                print(f"{kind} '{item_id}': deleted (was absent before the run being rolled back)")
            except ApiError as e:
                print(f"WARN: {kind} '{item_id}': rollback delete failed: {e}")
                summary[kind]["failed"] += 1
    print("\n=== Rollback summary ===")
    for kind in KINDS:
        s = summary[kind]
        if sum(s.values()):
            print(f"{kind}: restored={s['restored']} deleted={s['deleted']} failed={s['failed']}")
    failed = failure_count(summary)
    if failed:
        print(f"\n{failed} object(s) failed to roll back -- the target is in a mixed state.", file=sys.stderr)
        return 1
    return 0


def build_parser():
    p = argparse.ArgumentParser(prog="autoptic_migrate.py", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="command", required=True)

    def add_src(sp, required=True):
        sp.add_argument("--src-url", required=required, help="Source instance base URL, for example http://127.0.0.1:19999")
        sp.add_argument("--src-ep", default="default", help="Source endpoint_id (default: 'default')")
        sp.add_argument("--src-token", help="Source API token (or $AUTOPTIC_SRC_TOKEN)")

    def add_dst(sp, required=True):
        sp.add_argument("--dst-url", required=required, help="Target instance base URL")
        sp.add_argument("--dst-ep", default="default", help="Target endpoint_id (default: 'default')")
        sp.add_argument("--dst-token", help="Target API token (or $AUTOPTIC_DST_TOKEN)")

    sp = sub.add_parser("list", help="List everything on an instance. Read-only.")
    add_src(sp)
    sp.set_defaults(func=cmd_list)

    sp = sub.add_parser("plan", help="Resolve a selection's dependency closure. Report collisions and required secrets. Writes nothing.")
    add_src(sp)
    add_common_selection_args(sp)
    sp.set_defaults(func=cmd_plan)

    sp = sub.add_parser("export", help="Pull a selection to an on-disk bundle.")
    add_src(sp)
    add_common_selection_args(sp)
    sp.add_argument("--out", required=True, help="Bundle directory to write.")
    sp.set_defaults(func=cmd_export)

    sp = sub.add_parser("import", help="Push a bundle to a target. Dry run unless --apply.")
    add_dst(sp)
    sp.add_argument("--in", dest="in_", required=True, help="Bundle directory to read.")
    sp.add_argument("--apply", action="store_true", help="Actually write. Without this, only prints what would happen.")
    sp.add_argument("--on-conflict", choices=("prompt", "skip", "overwrite"), default="prompt")
    add_secrets_args(sp)
    sp.set_defaults(func=cmd_import)

    sp = sub.add_parser("migrate", help="Straight instance-to-instance (plan+import chained). Dry run unless --apply.")
    add_src(sp)
    add_dst(sp)
    add_common_selection_args(sp)
    sp.add_argument("--apply", action="store_true", help="Actually write. Without this, only prints what would happen.")
    sp.add_argument("--on-conflict", choices=("prompt", "skip", "overwrite"), default="prompt")
    sp.add_argument("--allow-same", action="store_true", help="Allow source and destination to be the same url+endpoint.")
    add_secrets_args(sp)
    sp.set_defaults(func=cmd_migrate)

    sp = sub.add_parser("rollback", help="Undo a previous --apply run using its rollback snapshot.")
    add_dst(sp)
    sp.add_argument("--in", dest="in_", required=True, help="Rollback snapshot directory (printed by the run being undone).")
    sp.set_defaults(func=cmd_rollback)

    return p


def main():
    args = build_parser().parse_args()
    try:
        # Commands return a process exit code (None means success), so a run
        # that saved only some of its objects does not report success.
        sys.exit(args.func(args) or 0)
    except ApiError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
    except BundleError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("\nInterrupted.", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
