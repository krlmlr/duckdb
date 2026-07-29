#!/usr/bin/env python3
"""Maintain function documentation as YAML, emitting the functions.json files.

The YAML files (functions.yaml, one next to each functions.json) are the
source of truth; functions.json is a generated artifact consumed by
scripts/generate_functions.py and external tooling (duckdb-web, dd).

Subcommands:
  to-yaml   one-time bootstrap: convert functions.json -> functions.yaml
  to-json   emit functions.json from functions.yaml (normalized shape)
  check     verify functions.json semantically matches functions.yaml

Normalizations applied by to-yaml / to-json (documented, intentional):
  * `example` (string) becomes `examples` (list of strings)
  * canonical key order per entry and per variant
  * 4-space indent, trailing newline
Everything else round-trips unchanged; `check` fails on any other delta.
"""

import argparse
import json
import sys
from pathlib import Path

import yaml

ROOTS = ["src/function", "extension/core_functions"]

# Allowed keys (validation only; order is preserved from the source).
ENTRY_KEYS = [
    "name",
    "parameters",
    "description",
    "examples",
    "categories",
    "variants",
    "type",
    "struct",
    "aliases",
    "extra_functions",
]
VARIANT_KEYS = ["parameters", "description", "examples", "categories"]


class FlowDict(dict):
    """Mapping rendered in YAML flow style: {name: x, type: T}."""


class Dumper(yaml.SafeDumper):
    """Indent sequence items under their key (conventional YAML style)."""

    def increase_indent(self, flow=False, indentless=False):
        return super().increase_indent(flow, False)


def represent_flow_dict(dumper, data):
    return dumper.represent_mapping("tag:yaml.org,2002:map", data, flow_style=True)


Dumper.add_representer(FlowDict, represent_flow_dict)


def json_files(repo_root: Path):
    for root in ROOTS:
        yield from sorted((repo_root / root).rglob("functions.json"))


def normalize(entry: dict, keys: list[str]) -> dict:
    """Examples-as-list, preserving each entry's key order; drops nothing.

    Key order is deliberately not canonicalized: preserving it keeps the
    migration diff minimal and mergeable; ordering is a separate amendment.
    """
    unknown = set(entry) - set(keys) - {"example"}
    if unknown:
        raise ValueError(f"unknown keys {unknown} in entry {entry.get('name')}")
    out = {}
    for key, value in entry.items():
        if key == "example":
            out["examples"] = [value]
        elif key == "variants":
            out["variants"] = [normalize(v, VARIANT_KEYS) for v in value]
        else:
            out[key] = value
    return out


def to_yaml_value(entry):
    """Mark structured parameter mappings for flow-style rendering."""
    if isinstance(entry, dict):
        if set(entry) <= {"name", "type", "default"} and "name" in entry:
            return FlowDict({k: to_yaml_value(v) for k, v in entry.items()})
        return {k: to_yaml_value(v) for k, v in entry.items()}
    if isinstance(entry, list):
        return [to_yaml_value(v) for v in entry]
    return entry


def dump_yaml(entries: list[dict], path: Path):
    header = (
        "# Function documentation; source of truth for the sibling functions.json\n"
        "# (regenerate with: python3 scripts/functions_yaml.py to-json).\n"
    )
    body = yaml.dump(
        [to_yaml_value(e) for e in entries],
        Dumper=Dumper,
        sort_keys=False,
        allow_unicode=True,
        width=88,
        default_flow_style=False,
    )
    path.write_text(header + body)


def is_param(value) -> bool:
    return (
        isinstance(value, dict)
        and "name" in value
        and set(value) <= {"name", "type", "default"}
    )


def render_json(value, level: int) -> str:
    """Render in the repository's established functions.json style:
    scalar lists and parameter objects inline, one key per line otherwise."""
    indent, child = "    " * level, "    " * (level + 1)
    if is_param(value):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, dict):
        parts = [
            f"{child}{json.dumps(k, ensure_ascii=False)}: {render_json(v, level + 1)}"
            for k, v in value.items()
        ]
        return "{\n" + ",\n".join(parts) + f"\n{indent}}}"
    if isinstance(value, list):
        if all(not isinstance(v, (dict, list)) for v in value):
            return json.dumps(value, ensure_ascii=False)
        if len(value) == 1 and is_param(value[0]):
            return f"[{json.dumps(value[0], ensure_ascii=False)}]"
        parts = [f"{child}{render_json(v, level + 1)}" for v in value]
        return "[\n" + ",\n".join(parts) + f"\n{indent}]"
    return json.dumps(value, ensure_ascii=False)


def singular_example(entry: dict) -> dict:
    """Emit `example` for a single example, matching the prevailing style."""
    out = {}
    for key, value in entry.items():
        if key == "examples" and len(value) == 1:
            out["example"] = value[0]
        elif key == "variants":
            out["variants"] = [singular_example(v) for v in value]
        else:
            out[key] = value
    return out


def dump_json(entries: list[dict], path: Path):
    body = render_json([singular_example(e) for e in entries], 0)
    path.write_text(body + "\n")


def cmd_to_yaml(repo_root: Path) -> int:
    for jf in json_files(repo_root):
        entries = [normalize(e, ENTRY_KEYS) for e in json.loads(jf.read_text())]
        dump_yaml(entries, jf.with_suffix(".yaml"))
        print(f'wrote {jf.with_suffix(".yaml").relative_to(repo_root)}')
    return 0


def cmd_to_json(repo_root: Path) -> int:
    for jf in json_files(repo_root):
        yf = jf.with_suffix(".yaml")
        if not yf.exists():
            print(f"MISSING {yf.relative_to(repo_root)}", file=sys.stderr)
            return 1
        entries = [normalize(e, ENTRY_KEYS) for e in yaml.safe_load(yf.read_text())]
        dump_json(entries, jf)
        print(f"wrote {jf.relative_to(repo_root)}")
    return 0


def cmd_check(repo_root: Path) -> int:
    """Fail if any functions.json differs semantically from its functions.yaml."""
    status = 0
    for jf in json_files(repo_root):
        yf = jf.with_suffix(".yaml")
        if not yf.exists():
            print(f"MISSING {yf.relative_to(repo_root)}")
            status = 1
            continue
        from_json = [normalize(e, ENTRY_KEYS) for e in json.loads(jf.read_text())]
        from_yaml = [normalize(e, ENTRY_KEYS) for e in yaml.safe_load(yf.read_text())]
        if from_json != from_yaml:
            print(f"DIFFERS {jf.relative_to(repo_root)}")
            for i, (a, b) in enumerate(zip(from_json, from_yaml)):
                if a != b:
                    print(f'  entry {i}: {a.get("name")}')
            status = 1
    return status


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["to-yaml", "to-json", "check"])
    parser.add_argument("--repo", default=".", help="repository root")
    args = parser.parse_args()
    repo_root = Path(args.repo).resolve()
    sys.exit(
        {"to-yaml": cmd_to_yaml, "to-json": cmd_to_json, "check": cmd_check}[
            args.command
        ](repo_root)
    )


if __name__ == "__main__":
    main()
