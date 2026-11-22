#!/usr/bin/env python3
"""Reject incomplete or unsuccessful Flutter runs even when Flutter exits zero."""
import json
import sys


def validate(path):
    started, finished, outcomes = set(), set(), []
    passed = 0
    with open(path, encoding="utf-8") as report:
        for line in report:
            event = json.loads(line)
            kind = event.get("type")
            if kind == "testStart":
                started.add(event["test"]["id"])
            elif kind == "testDone":
                finished.add(event["testID"])
                if event.get("result") != "success":
                    raise ValueError("a test failed or did not complete")
                if not event.get("hidden") and not event.get("skipped"):
                    passed += 1
            elif kind == "error":
                raise ValueError("the test runner reported an error")
            elif kind == "done":
                outcomes.append(event.get("success"))
    if outcomes != [True] or started != finished or not passed:
        raise ValueError("missing successful completion or unfinished tests")
    print(f"Verified complete Flutter report: {passed} tests passed")


if __name__ == "__main__":
    try:
        validate(sys.argv[1])
    except (OSError, ValueError, KeyError, IndexError) as error:
        sys.exit(f"Flutter test report rejected: {error}")
