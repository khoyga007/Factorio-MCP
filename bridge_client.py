"""Adapt the shared Factorio CLI executor to MCP tool results."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

from mcp.types import CallToolResult, TextContent

from factorio_ai import DEFAULT_HOST, DEFAULT_PORT, execute


def invoke(command: str, **values) -> CallToolResult:
    """Use the same command implementation as the diagnostic CLI."""
    try:
        if "file" in values:
            path = Path(values["file"])
            if not path.is_absolute():
                raise ValueError("blueprint file must be an absolute path")
            values["file"] = path
        args = argparse.Namespace(
            command=command,
            host=os.environ.get("FACTORIO_HOST", DEFAULT_HOST),
            port=int(os.environ.get("FACTORIO_PORT", DEFAULT_PORT)),
            **values,
        )
        reply = execute(args)
    except (OSError, ValueError) as exc:
        reply = {"ok": False, "error": str(exc)}
    return CallToolResult(
        isError=not reply.get("ok", False),
        content=[TextContent(type="text", text=json.dumps(reply, ensure_ascii=False, separators=(",", ":")))],
    )
