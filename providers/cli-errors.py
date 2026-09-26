#!/usr/bin/env python3
"""Extract CLI diagnostics, never free-form model stdout or tool results."""
import json
import re
import sys

for index, path in enumerate(sys.argv[1:]):
    in_error_block = False
    with open(path, encoding="utf-8", errors="replace") as stream:
        for line in stream:
            try:
                record = json.loads(line)
            except ValueError:
                # Plain text is diagnostic only on stderr. Require a CLI error
                # prefix so transcript prose and test summaries are ignored.
                starts_error = re.match(
                    r"\s*(?:error\b|internal error\b|api error\b|http\b|status\b|"
                    r"not (?:logged in|authenticated)\b|please run /login\b|"
                    r"you.ve (?:hit|reached)\b|usage balance exhausted\b|"
                    r"rate limit\b|your usage balance\b|you have no remaining credits\b|"
                    r"payment required\b|402\b|quota will reset\b|usage limit\b)",
                    line, re.I,
                )
                if index == 1:
                    continuation = in_error_block and (line[:1].isspace() or line.strip() == "}")
                    in_error_block = bool(starts_error or continuation)
                    if in_error_block:
                        print(line, end="")
                continue
            if not isinstance(record, dict):
                continue
            if (record.get("type") == "result" and record.get("is_error") is True
                    or record.get("is_api_error_message") is True
                    or record.get("type") in ("error", "turn.failed")):
                print(line, end="")
