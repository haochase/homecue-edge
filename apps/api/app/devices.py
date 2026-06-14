from copy import deepcopy
from dataclasses import dataclass
from typing import Any


DEFAULT_DEVICES = {
    "light": {"label": "Living room light", "state": "off", "scene": "default"},
    "ac": {"label": "Air conditioner", "state": "off", "temperature": 24},
    "projector": {"label": "Projector", "state": "off", "mode": "standby"},
    "speaker": {"label": "Speaker", "state": "off", "playlist": "none"},
    "reminder": {"label": "Reminder", "state": "empty", "message": ""},
}

ALLOWED_ACTIONS = {
    "light": {"set_scene": {"warm", "bright", "night"}},
    "ac": {"set_temperature": range(18, 31)},
    "projector": {"set_mode": {"cinema", "standby"}},
    "speaker": {"play": {"soft ambient", "focus", "none"}},
    "reminder": {"set": "text"},
}


def is_action_allowed(device: str, command: str, value: object) -> bool:
    """Pure, read-only policy check shared by the device store and the planner tools."""
    commands = ALLOWED_ACTIONS.get(device)
    if not commands or command not in commands:
        return False

    allowed_values = commands[command]
    if allowed_values == "text":
        return isinstance(value, str) and 0 < len(value) <= 160

    if isinstance(allowed_values, range):
        return isinstance(value, int) and value in allowed_values

    return value in allowed_values


@dataclass
class ExecutionResult:
    device: str
    command: str
    accepted: bool
    reason: str
    value: Any

    def to_dict(self) -> dict:
        return {
            "device": self.device,
            "command": self.command,
            "accepted": self.accepted,
            "reason": self.reason,
            "value": self.value,
        }


class DeviceStore:
    def __init__(self) -> None:
        self._devices = deepcopy(DEFAULT_DEVICES)

    def all(self) -> dict:
        return self._devices

    def reset(self) -> dict:
        self._devices = deepcopy(DEFAULT_DEVICES)
        return self._devices

    def apply_action(self, action: dict) -> ExecutionResult:
        device = action["device"]
        command = action["command"]
        value = action["value"]

        if device not in self._devices:
            return ExecutionResult(device, command, False, "unknown device", value)

        if not self._is_allowed(device, command, value):
            return ExecutionResult(device, command, False, "action not allowed by edge policy", value)

        if device == "light" and command == "set_scene":
            self._devices[device]["state"] = "on"
            self._devices[device]["scene"] = value
        elif device == "ac" and command == "set_temperature":
            self._devices[device]["state"] = "on"
            self._devices[device]["temperature"] = value
        elif device == "projector" and command == "set_mode":
            self._devices[device]["state"] = "on"
            self._devices[device]["mode"] = value
        elif device == "speaker" and command == "play":
            self._devices[device]["state"] = "on"
            self._devices[device]["playlist"] = value
        elif device == "reminder" and command == "set":
            self._devices[device]["state"] = "scheduled"
            self._devices[device]["message"] = value

        return ExecutionResult(device, command, True, "executed locally", value)

    def _is_allowed(self, device: str, command: str, value: object) -> bool:
        return is_action_allowed(device, command, value)
