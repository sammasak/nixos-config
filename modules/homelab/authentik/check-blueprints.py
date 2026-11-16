"""Parse every blueprint in the directory Authentik is given the way its importer does, without a database: the YAML
through Authentik's own loader (its tags included), then the Blueprint dataclass, version 1, and each entry's model
resolved and allowed. The worker otherwise finds a broken one only when it applies it, after the deploy. Stricter than
the importer on purpose: an unknown key (`entires:`) fails here, where dacite would drop it and Authentik apply nothing."""
import os
import pathlib
import sys

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "authentik.root.settings")
os.environ.setdefault("AUTHENTIK_SECRET_KEY", "build-time-check")

import django

django.setup()

import yaml
from dacite import Config, from_dict

from authentik.blueprints.v1.common import Blueprint, BlueprintEntryDesiredState, BlueprintLoader, YAMLTag
from authentik.blueprints.v1.importer import is_model_allowed
from authentik.blueprints.v1.meta.registry import BaseMetaModel, registry


def problems(path):
    try:
        blueprint = from_dict(
            Blueprint, yaml.load(path.read_text(), BlueprintLoader), config=Config(cast=[BlueprintEntryDesiredState], strict=True)
        )
    except Exception as e:
        return [f"does not parse: {type(e).__name__}: {e}"]
    found = [] if blueprint.version == 1 else [f"version {blueprint.version}, not 1"]
    for i, entry in enumerate(blueprint.iter_entries()):
        if isinstance(entry.model, YAMLTag):
            continue
        try:
            model = registry.get_model(*entry.model.split(".", 1))
        except (LookupError, ValueError, TypeError) as e:
            found.append(f"entry {i}: model {entry.model!r}: {e}")
            continue
        if not is_model_allowed(model):
            found.append(f"entry {i}: model {entry.model} is not allowed in blueprints")
        elif not issubclass(model, BaseMetaModel) and not entry.identifiers:
            found.append(f"entry {i}: {entry.model} has no identifiers")
    return found


root = pathlib.Path(sys.argv[1])
files = sorted(root.rglob("*.yaml"))
failed = False
for f in files:
    for p in problems(f):
        failed = True
        print(f"{f.relative_to(root)}: {p}")
print(f"{len(files)} blueprints checked")
sys.exit(1 if failed or not files else 0)
