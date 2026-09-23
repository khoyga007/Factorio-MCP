"""Check the three declarations of bridge actions.

``actions.json`` declares each action's name, client command, and arguments.
This module checks that declaration against the two other places that
declare the same list: the ``HANDLERS`` table in ``control.lua`` and the
argparse subcommands + ``command_body`` action mapping in ``factorio_ai.py``.

``check()`` returns a list of mismatch descriptions; an empty list means the
three sources agree.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
LUA = HERE / "factorio-ai-bridge_0.1.0" / "control.lua"
CLIENT = HERE / "factorio_ai.py"
ACTIONS = HERE / "actions.json"


def load_actions() -> dict[str, Any]:
    return json.loads(ACTIONS.read_text(encoding="utf-8"))["actions"]


def handlers_in_lua() -> set[str]:
    # HANDLERS = { audit = handle_audit, ... } — one action per line.
    text = LUA.read_text(encoding="utf-8")
    return set(re.findall(r"^\s{2}(\w+) = handle_\w+,?$", text, flags=re.M))


def client_commands() -> set[str]:
    text = CLIENT.read_text(encoding="utf-8")
    return set(re.findall(r'commands\.add_parser\(\s*"([^"]+)"', text))


def client_actions() -> set[str]:
    text = CLIENT.read_text(encoding="utf-8")
    # Every request body in command_body sets "action": "<name>".
    return set(re.findall(r'"action":\s*"(\w+)"', text))


def check() -> list[str]:
    actions = load_actions()
    declared = set(actions)
    problems: list[str] = []

    handlers = handlers_in_lua()
    if declared != handlers:
        problems.append(
            "HANDLERS mismatch: only-lua={} only-json={}".format(
                sorted(handlers - declared), sorted(declared - handlers)
            )
        )

    c_actions = client_actions()
    if declared != c_actions:
        problems.append(
            "client action mismatch: only-client={} only-json={}".format(
                sorted(c_actions - declared), sorted(declared - c_actions)
            )
        )

    declared_clients = {a.get("client", name) for name, a in actions.items()}
    if declared_clients != client_commands():
        problems.append(
            "client command mismatch: only-parser={} only-json={}".format(
                sorted(client_commands() - declared_clients),
                sorted(declared_clients - client_commands()),
            )
        )

    return problems


if __name__ == "__main__":
    problems = check()
    if problems:
        for p in problems:
            print("MISMATCH:", p)
        raise SystemExit(1)
    print(f"OK: {len(load_actions())} actions agree across actions.json, control.lua, factorio_ai.py")
