"""Planner tools exposed to the agent loop.

The agent can call these read-only tools to gather context, inspect device
state, and pre-validate proposed actions against the edge policy. None of the
tools mutate real device state: actual execution stays a single guarded step in
``main.py`` after the routine is produced.
"""

from app.context import BASE_CONTEXT, build_privacy_summary
from app.devices import DEFAULT_DEVICES, is_action_allowed


# OpenAI-compatible tool/function schema advertised to the model.
TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "get_home_context",
            "description": (
                "Return the privacy-safe home context summary (room, time, weather, "
                "occupancy, mood, preference, schedule summary). Raw private data never leaves the edge."
            ),
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_device_states",
            "description": "Return the current smart-home device states the plan can act on.",
            "parameters": {"type": "object", "properties": {}, "required": []},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "propose_actions",
            "description": (
                "Pre-validate a list of candidate device actions against the edge safety policy "
                "WITHOUT changing any device. Returns accepted/reason per action so you can "
                "revise before producing the final routine."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "actions": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "device": {"type": "string"},
                                "command": {"type": "string"},
                                "value": {"type": ["string", "number", "boolean"]},
                            },
                            "required": ["device", "command", "value"],
                        },
                    }
                },
                "required": ["actions"],
            },
        },
    },
]


def validate_action(action: dict) -> dict:
    """Read-only policy check for a single action. Never mutates device state."""
    device = action.get("device")
    command = action.get("command")
    value = action.get("value")

    if device not in DEFAULT_DEVICES:
        accepted, reason = False, "unknown device"
    elif not is_action_allowed(device, command, value):
        accepted, reason = False, "action not allowed by edge policy"
    else:
        accepted, reason = True, "passes edge policy (not yet executed)"

    return {
        "device": device,
        "command": command,
        "value": value,
        "accepted": accepted,
        "reason": reason,
    }


def get_home_context() -> dict:
    return build_privacy_summary(BASE_CONTEXT)


def get_device_states() -> dict:
    # Read-only snapshot of the baseline home; planning happens before execution.
    return {key: dict(value) for key, value in DEFAULT_DEVICES.items()}


def propose_actions(actions: list | None = None) -> dict:
    actions = actions or []
    results = [validate_action(action) for action in actions]
    return {
        "results": results,
        "accepted_count": sum(1 for item in results if item["accepted"]),
        "rejected_count": sum(1 for item in results if not item["accepted"]),
        "note": "Validation only. No device state was changed.",
    }


def dispatch_tool(name: str, args: dict | None = None) -> dict:
    args = args or {}
    if name == "get_home_context":
        return get_home_context()
    if name == "get_device_states":
        return get_device_states()
    if name == "propose_actions":
        return propose_actions(args.get("actions"))
    return {"error": f"unknown tool: {name}"}
