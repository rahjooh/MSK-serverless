#!/usr/bin/env python3
"""Load Terraform workflow configuration from TERRAFORM_TFVARS."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


class TfvarsParseError(Exception):
    """Raised when the tfvars payload cannot be parsed."""


@dataclass
class ParseState:
    text: str
    index: int = 0

    @property
    def length(self) -> int:
        return len(self.text)

    def remaining(self) -> str:
        return self.text[self.index :]


class TfvarsParser:
    """Very small HCL parser that understands tfvars assignments."""

    def __init__(self, text: str) -> None:
        self.state = ParseState(text)

    # Public API ---------------------------------------------------------
    def parse_assignments(self) -> dict[str, Any]:
        values: dict[str, Any] = {}
        while True:
            self._skip_ignored()
            if self._eof():
                break
            key = self._parse_key()
            self._skip_ignored()
            self._expect_assignment()
            value = self._parse_value()
            values[key] = value
            self._skip_ignored()
        return values

    def parse_value(self) -> Any:
        self._skip_ignored()
        value = self._parse_value()
        self._skip_ignored()
        if not self._eof():
            raise TfvarsParseError("Unexpected trailing characters while parsing value")
        return value

    # Internal helpers ---------------------------------------------------
    def _eof(self) -> bool:
        return self.state.index >= self.state.length

    def _peek(self) -> str:
        if self._eof():
            return ""
        return self.state.text[self.state.index]

    def _advance(self, count: int = 1) -> None:
        self.state.index += count

    def _match(self, value: str) -> bool:
        if self.state.text.startswith(value, self.state.index):
            self.state.index += len(value)
            return True
        return False

    def _skip_ignored(self) -> None:
        while not self._eof():
            ch = self._peek()
            if ch in " \t\r\n":
                self._advance()
                continue
            if self._match("//"):
                self._skip_until_newline()
                continue
            if ch == "#":
                self._skip_until_newline()
                continue
            if self._match("/*"):
                self._skip_block_comment()
                continue
            break

    def _skip_until_newline(self) -> None:
        while not self._eof() and self._peek() != "\n":
            self._advance()
        if not self._eof():
            self._advance()

    def _skip_block_comment(self) -> None:
        depth = 1
        while not self._eof() and depth > 0:
            if self._match("/*"):
                depth += 1
                continue
            if self._match("*/"):
                depth -= 1
                continue
            self._advance()
        if depth != 0:
            raise TfvarsParseError("Unterminated block comment")

    def _parse_key(self) -> str:
        self._skip_ignored()
        ch = self._peek()
        if ch == '"':
            return self._parse_string()
        if ch and (ch.isalpha() or ch in {"_"}):
            return self._parse_identifier()
        raise TfvarsParseError("Invalid key in tfvars assignment")

    def _parse_identifier(self) -> str:
        start = self.state.index
        while not self._eof():
            ch = self._peek()
            if ch.isalnum() or ch in {"_", "-"}:
                self._advance()
                continue
            break
        if start == self.state.index:
            raise TfvarsParseError("Expected identifier")
        return self.state.text[start : self.state.index]

    def _expect_assignment(self) -> None:
        self._skip_ignored()
        if self._match("="):
            return
        raise TfvarsParseError("Expected '=' after key in tfvars assignment")

    def _parse_value(self) -> Any:
        self._skip_ignored()
        if self._eof():
            raise TfvarsParseError("Unexpected end of input while parsing value")
        ch = self._peek()
        if ch == '"':
            return self._parse_string()
        if ch == '{':
            return self._parse_object()
        if ch == '[':
            return self._parse_array()
        if ch in "-0123456789":
            return self._parse_number()
        if ch == '<' and self.state.text.startswith("<<", self.state.index):
            return self._parse_heredoc()
        for literal, value in {"true": True, "false": False, "null": None}.items():
            if self.state.text.startswith(literal, self.state.index):
                end = self.state.index + len(literal)
                next_ch = self.state.text[end : end + 1]
                if not next_ch or next_ch[0] in " \t\r\n,]}#/":
                    self.state.index = end
                    return value
        raise TfvarsParseError("Unsupported expression in tfvars value")

    def _parse_string(self) -> str:
        if not self._match('"'):
            raise TfvarsParseError("Expected '\"' to start string")
        result: list[str] = []
        while not self._eof():
            ch = self._peek()
            self._advance()
            if ch == '"':
                return "".join(result)
            if ch == "\\":
                if self._eof():
                    raise TfvarsParseError("Incomplete escape sequence in string")
                esc = self._peek()
                self._advance()
                if esc == '"':
                    result.append('"')
                elif esc == "\\":
                    result.append("\\")
                elif esc == "/":
                    result.append("/")
                elif esc == "b":
                    result.append("\b")
                elif esc == "f":
                    result.append("\f")
                elif esc == "n":
                    result.append("\n")
                elif esc == "r":
                    result.append("\r")
                elif esc == "t":
                    result.append("\t")
                elif esc == "u":
                    code = self.state.text[self.state.index : self.state.index + 4]
                    if len(code) != 4 or not all(c in "0123456789abcdefABCDEF" for c in code):
                        raise TfvarsParseError("Invalid unicode escape in string")
                    self._advance(4)
                    result.append(chr(int(code, 16)))
                else:
                    raise TfvarsParseError(f"Unsupported escape sequence \\{esc}")
            else:
                result.append(ch)
        raise TfvarsParseError("Unterminated string literal")

    def _parse_number(self) -> Any:
        start = self.state.index
        if self._peek() == '-':
            self._advance()
        digits_seen = False
        while not self._eof() and self._peek().isdigit():
            digits_seen = True
            self._advance()
        if not digits_seen:
            raise TfvarsParseError("Invalid number literal")
        if not self._eof() and self._peek() == '.':
            self._advance()
            if self._eof() or not self._peek().isdigit():
                raise TfvarsParseError("Invalid number literal")
            while not self._eof() and self._peek().isdigit():
                self._advance()
        if not self._eof() and self._peek() in {'e', 'E'}:
            self._advance()
            if not self._eof() and self._peek() in {'+', '-'}:
                self._advance()
            if self._eof() or not self._peek().isdigit():
                raise TfvarsParseError("Invalid exponent in number literal")
            while not self._eof() and self._peek().isdigit():
                self._advance()
        raw = self.state.text[start : self.state.index]
        if any(c in raw for c in '.eE'):
            return float(raw)
        return int(raw)

    def _parse_array(self) -> list[Any]:
        if not self._match('['):
            raise TfvarsParseError("Expected '[' to start array")
        values: list[Any] = []
        while True:
            self._skip_ignored()
            if self._match(']'):
                return values
            values.append(self._parse_value())
            self._skip_ignored()
            if self._match(','):
                continue
            if self._match(']'):
                return values
            raise TfvarsParseError("Expected ',' or ']' in array literal")

    def _parse_object(self) -> dict[str, Any]:
        if not self._match('{'):
            raise TfvarsParseError("Expected '{' to start object")
        result: dict[str, Any] = {}
        while True:
            self._skip_ignored()
            if self._match('}'):
                return result
            key = self._parse_key()
            self._skip_ignored()
            if self._match('=') or self._match(':'):
                pass
            else:
                raise TfvarsParseError("Expected '=' or ':' inside object literal")
            value = self._parse_value()
            result[key] = value
            self._skip_ignored()
            if self._match(','):
                continue
            if self._match('}'):
                return result
            # Allow newline-separated entries without trailing commas.

    def _parse_heredoc(self) -> str:
        indent = False
        if self._match("<<-"):
            indent = True
        elif self._match("<<"):
            indent = False
        else:
            raise TfvarsParseError("Expected heredoc introducer")
        label = self._parse_identifier()
        # Skip to the end of the current line
        while not self._eof() and self._peek() != '\n':
            self._advance()
        if not self._eof():
            self._advance()
        lines: list[str] = []
        while not self._eof():
            line_start = self.state.index
            while not self._eof() and self._peek() != '\n':
                self._advance()
            line = self.state.text[line_start : self.state.index]
            check = line
            if indent:
                check = line.lstrip('\t ')
            if check == label:
                if not self._eof():
                    self._advance()
                break
            lines.append(line)
            if not self._eof():
                self._advance()
        else:
            raise TfvarsParseError("Unterminated heredoc")
        return "\n".join(lines)


def _error(message: str) -> None:
    print(f"::error::{message}", file=sys.stderr)


def _load_secret() -> str:
    raw = os.environ.get("TERRAFORM_TFVARS") or os.environ.get("TERRAFORM_TFVARS_JSON")
    if not raw:
        _error("TERRAFORM_TFVARS secret is empty. Provide a Terraform tfvars payload.")
        raise SystemExit(1)
    return raw


def _parse_tfvars(raw: str) -> dict[str, Any]:
    parser = TfvarsParser(raw)
    try:
        return parser.parse_assignments()
    except TfvarsParseError as exc:
        _error(f"Failed to parse TERRAFORM_TFVARS as tfvars: {exc}")
        raise SystemExit(1)


def _parse_metadata(raw: str) -> dict[str, Any]:
    metadata: dict[str, Any] = {}
    for line in raw.splitlines():
        stripped = line.strip()
        body = None
        if stripped.startswith("#"):
            body = stripped[1:].strip()
        elif stripped.startswith("//"):
            body = stripped[2:].strip()
        if not body or not body.startswith("workflow."):
            continue
        if "=" not in body:
            _error(f"Invalid workflow directive (missing '='): {line.strip()}")
            raise SystemExit(1)
        key_path, value_raw = body[len("workflow.") :].split("=", 1)
        key_path = key_path.strip()
        value_raw = value_raw.strip()
        try:
            value = TfvarsParser(value_raw).parse_value()
        except TfvarsParseError as exc:
            _error(f"Unable to parse workflow directive '{line.strip()}': {exc}")
            raise SystemExit(1)
        _metadata_set(metadata, key_path.split('.'), value)
    return metadata


def _metadata_set(metadata: dict[str, Any], parts: list[str], value: Any) -> None:
    cursor: dict[str, Any] = metadata
    for part in parts[:-1]:
        existing = cursor.get(part)
        if existing is None:
            next_level: dict[str, Any] = {}
            cursor[part] = next_level
            cursor = next_level
            continue
        if not isinstance(existing, dict):
            _error(f"Workflow directive path conflict at '{part}'")
            raise SystemExit(1)
        cursor = existing
    cursor[parts[-1]] = value


def _ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def _append_env(lines: list[str]) -> None:
    github_env = os.environ.get("GITHUB_ENV")
    if not github_env:
        _error("GITHUB_ENV is not available; cannot set environment variables.")
        raise SystemExit(1)
    with open(github_env, "a", encoding="utf-8") as handle:
        for chunk in lines:
            handle.write(chunk)
            if not chunk.endswith("\n"):
                handle.write("\n")


def _format_with_terraform(path: Path) -> None:
    """Run ``terraform fmt`` on ``path`` when the CLI is available."""

    terraform = shutil.which("terraform")
    if not terraform:
        return
    try:
        subprocess.run(
            [terraform, "fmt", str(path)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        details = ""
        if isinstance(exc, subprocess.CalledProcessError):
            details = exc.stderr.decode("utf-8", "ignore").strip()
        message = f"Failed to format {path} with terraform fmt."
        if details:
            message = f"{message} Details: {details}"
        print(f"::warning::{message}", file=sys.stderr)


def _serialize_for_env(value: Any) -> str:
    if isinstance(value, str):
        return value
    return json.dumps(value, separators=(",", ":"))


def _needs_quotes(text: str) -> bool:
    if not text:
        return True
    if not text[0].isalpha() and text[0] != "_":
        return True
    for ch in text:
        if not (ch.isalnum() or ch == "_"):
            return True
    return False


def _format_key(text: str) -> str:
    return json.dumps(text) if _needs_quotes(text) else text


def _format_scalar(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return "null"
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return repr(value)
    if isinstance(value, str):
        return json.dumps(value)
    raise TypeError(f"Unsupported scalar type: {type(value)!r}")


def _indent(level: int) -> str:
    return "  " * level


def _format_list(value: list[Any], level: int) -> str:
    if not value:
        return "[]"
    lines: list[str] = ["["]
    last_index = len(value) - 1
    for index, item in enumerate(value):
        rendered = _format_value(item, level + 1).splitlines()
        indent = _indent(level + 1)
        suffix = "," if index != last_index else ""
        if len(rendered) == 1:
            lines.append(f"{indent}{rendered[0]}{suffix}")
            continue
        lines.append(f"{indent}{rendered[0]}")
        for inner in rendered[1:-1]:
            lines.append(inner)
        lines.append(f"{rendered[-1]}{suffix}")
    lines.append(f"{_indent(level)}]")
    return "\n".join(lines)


def _format_object(value: dict[str, Any], level: int) -> str:
    if not value:
        return "{}"
    lines: list[str] = ["{"]
    keys = list(value.keys())
    formatted_keys = [_format_key(str(key)) for key in keys]
    padding = 0
    if formatted_keys:
        padding = max(len(key) for key in formatted_keys)
    for original_key, formatted_key in zip(keys, formatted_keys):
        rendered = _format_value(value[original_key], level + 1).splitlines()
        indent = _indent(level + 1)
        pad = " " * (padding - len(formatted_key))
        prefix = f"{indent}{formatted_key}{pad} = "
        if len(rendered) == 1:
            lines.append(f"{prefix}{rendered[0]}")
            continue
        lines.append(f"{prefix}{rendered[0]}")
        for inner in rendered[1:]:
            lines.append(inner)
    lines.append(f"{_indent(level)}}}")
    return "\n".join(lines)


def _format_value(value: Any, level: int = 0) -> str:
    if isinstance(value, dict):
        return _format_object(value, level)
    if isinstance(value, list):
        return _format_list(value, level)
    return _format_scalar(value)


def _dump_tfvars(tfvars: dict[str, Any]) -> str:
    lines: list[str] = []
    for key, value in tfvars.items():
        rendered = _format_value(value, 0).splitlines()
        if not rendered:
            continue
        lines.append(f"{key} = {rendered[0]}")
        for inner in rendered[1:]:
            lines.append(inner)
    return "\n".join(lines) + "\n"


def main() -> None:
    raw = _load_secret()
    tfvars = _parse_tfvars(raw)
    # Keep the original assume_role_arn for GH credential configuration,
    # but scrub it from the generated tfvars file to prevent provider-level
    # re-assume during CI runs where the workflow already assumes the role.
    original_assume_role = tfvars.get("assume_role_arn")
    if (
        isinstance(original_assume_role, str)
        and original_assume_role
        and os.environ.get("GITHUB_ACTIONS") == "true"
    ):
        # Ensure subsequent Terraform CLI calls using -var-file do NOT pass a
        # non-empty assume_role_arn to the provider.
        tfvars["assume_role_arn"] = ""
    metadata = _parse_metadata(raw)

    tf_vars_file = Path(os.environ.get("TF_VARS_FILE", "ci.auto.tfvars"))
    backend_file = Path(os.environ.get("TF_BACKEND_FILE", "backend.auto.tfbackend"))

    _ensure_parent(tf_vars_file)
    formatted_tfvars = _dump_tfvars(tfvars)
    tf_vars_file.write_text(formatted_tfvars, encoding="utf-8")
    _format_with_terraform(tf_vars_file)

    env_lines: list[str] = []

    for key, value in tfvars.items():
        env_key = f"TF_VAR_{key}"
        serialized = _serialize_for_env(value)
        if isinstance(value, str):
            env_lines.append(f"{env_key}={serialized}")
        else:
            env_lines.append(f"{env_key}<<EOF\n{serialized}\nEOF")

    region = tfvars.get("region")
    if isinstance(region, str) and region:
        env_lines.append(f"AWS_REGION={region}")
        env_lines.append(f"AWS_REGION_EFFECTIVE={region}")

    # Use the original (pre-scrubbed) value to drive GH credential assumption.
    if isinstance(original_assume_role, str) and original_assume_role:
        env_lines.append(f"ASSUME_ROLE_ARN={original_assume_role}")
        env_lines.append(f"AWS_ASSUME_ROLE_ARN={original_assume_role}")
    # else:
    #     env_lines.append("ASSUME_ROLE_ARN=")
    #     env_lines.append("AWS_ASSUME_ROLE_ARN=")

    backend_cfg = metadata.get("backend")
    backend_lines: list[str] = []

    def _string_from_tfvars(name: str) -> str | None:
        value = tfvars.get(name)
        if isinstance(value, str) and value:
            return value
        return None

    backend_bucket: str | None = None
    backend_key: str | None = None
    backend_region: str | None = None
    if isinstance(backend_cfg, dict):
        for key, value in backend_cfg.items():
            if value is None:
                continue
            if isinstance(value, str):
                backend_lines.append(f"{key} = {json.dumps(value)}")
            elif isinstance(value, bool):
                backend_lines.append(f"{key} = {'true' if value else 'false'}")
            elif isinstance(value, (int, float)):
                backend_lines.append(f"{key} = {value}")
            else:
                backend_lines.append(f"{key} = {json.dumps(value)}")

            lowered = key.lower()
            if lowered == "bucket" and isinstance(value, str) and value:
                backend_bucket = value
            elif lowered == "key" and isinstance(value, str) and value:
                backend_key = value
            elif lowered == "region" and isinstance(value, str) and value:
                backend_region = value
        if backend_lines:
            _ensure_parent(backend_file)
            backend_file.write_text("\n".join(backend_lines) + "\n", encoding="utf-8")
            env_lines.append(f"TF_BACKEND_FILE={backend_file}")

    backend_bucket = (
        backend_bucket
        or _string_from_tfvars("TF_BACKEND_BUCKET")
        or _string_from_tfvars("S3_BUCKET")
        or os.environ.get("TF_BACKEND_BUCKET")
        or os.environ.get("S3_BUCKET")
    )
    backend_key = (
        backend_key
        or _string_from_tfvars("TF_BACKEND_KEY")
        or os.environ.get("TF_BACKEND_KEY")
    )
    backend_region = (
        backend_region
        or _string_from_tfvars("TF_BACKEND_REGION")
        or os.environ.get("TF_BACKEND_REGION")
        or os.environ.get("AWS_REGION")
    )

    if backend_bucket:
        env_lines.append(f"TF_BACKEND_BUCKET={backend_bucket}")
        env_lines.append(f"S3_BUCKET={backend_bucket}")
    if backend_key:
        env_lines.append(f"TF_BACKEND_KEY={backend_key}")
    if backend_region:
        env_lines.append(f"TF_BACKEND_REGION={backend_region}")

    summary_cfg = metadata.get("summary")
    if isinstance(summary_cfg, dict):
        bucket = summary_cfg.get("bucket")
        key = summary_cfg.get("key")
        if isinstance(bucket, str) and bucket:
            env_lines.append(f"INFRA_SUMMARY_BUCKET={bucket}")
        if isinstance(key, str) and key:
            env_lines.append(f"INFRA_SUMMARY_KEY={key}")

    use_existing = metadata.get("use_existing")
    if isinstance(use_existing, bool):
        env_lines.append(f"USE_EXISTING={'true' if use_existing else 'false'}")

    env_lines.append(f"TF_VARS_FILE={tf_vars_file}")

    _append_env(env_lines)


if __name__ == "__main__":
    main()
