#!/usr/bin/env python3
"""Drive "ethd config" through its whiptail dialogs, as CI does on Ubuntu and macOS.

Its dependencies are locked in .github/test-tools. From the repo root:
uv run --locked --project .github/test-tools .github/test-ethd-config.py all-defaults
"""

import sys
from collections.abc import Callable

import pexpect

# Between prompts ethd only runs bash, but macOS CI runners are slow
TIMEOUT = 15
# ethd talks to Docker and Compose several times before the first whiptail screen
STARTUP_TIMEOUT = 120
# After the last prompt, __detect_v6 creates a Docker network and runs a container
FINISH_TIMEOUT = 120
# This prompt waits on speedtest-cli in __query_epbs_build_factor, which took 31.5s
# when measured. On macOS the speed test is skipped and "Grafana" arrives at once.
BUILD_FACTOR_TIMEOUT = 45

type Child = pexpect.spawn[str]


def accept_default(child: Child) -> None:
    child.send("\t\r")


def yes(child: Child) -> None:
    child.send("\r")


def no(child: Child) -> None:
    child.send("\t\r")


def address(child: Child) -> None:
    child.send("0xDccf8451070a86183eE70D330C4c43b686E9CF86\t\r")


def expect_or_fail(
    child: Child,
    pattern: str,
    action: Callable[[Child], None],
    timeout: int = TIMEOUT,
) -> None:
    index = child.expect_exact([pattern, pexpect.TIMEOUT, pexpect.EOF], timeout=timeout)
    if index == 1:
        print(f"Timeout waiting for: {pattern}")
        sys.exit(1)
    if index == 2:
        print(f"Unexpected EOF while waiting for: {pattern}")
        sys.exit(1)
    action(child)


# An optional prompt may not appear at all. Rather than wait out the whole timeout when it
# does not, also watch for the prompt that follows it. That match is put back into the
# buffer, so the caller's next expect_or_fail still sees it. The timeout is then only ever
# reached when something has genuinely hung.
def expect_optional(
    child: Child,
    pattern: str,
    action: Callable[[Child], None],
    next_pattern: str,
    timeout: int = TIMEOUT,
) -> None:
    index = child.expect_exact(
        [pattern, next_pattern, pexpect.TIMEOUT, pexpect.EOF], timeout=timeout
    )
    if index == 0:
        action(child)
    elif index == 1:
        child.buffer = next_pattern + child.buffer
    elif index == 3:
        print(f"Unexpected EOF while waiting for optional: {pattern}")
        sys.exit(1)


def expect_eof(child: Child, timeout: int) -> None:
    index = child.expect_exact([pexpect.EOF, pexpect.TIMEOUT], timeout=timeout)
    if index == 1:
        print("Timeout waiting for EOF")
        sys.exit(1)
    child.close()
    if child.signalstatus is not None:
        print(f"ethd was killed by signal {child.signalstatus}")
        sys.exit(1)
    if child.exitstatus != 0:
        print(f"ethd exited with status {child.exitstatus}")
        sys.exit(1)


def default_deployment(child: Child) -> None:
    expect_or_fail(child, "Select Network", accept_default, STARTUP_TIMEOUT)
    expect_or_fail(child, "Select deployment type", accept_default)
    expect_or_fail(child, "Select consensus client", accept_default)
    expect_optional(child, "Web3signer", yes, "Select execution client")
    expect_or_fail(child, "Select execution client", accept_default)
    expect_or_fail(child, "Select execution layer history", accept_default)


# Called without .env
def all_defaults(child: Child) -> None:
    default_deployment(child)

    expect_or_fail(child, "Configure CL checkpoint sync URL", accept_default)
    expect_or_fail(child, "MEV Boost", yes)
    expect_or_fail(child, "Relays list", accept_default)
    expect_or_fail(child, "ePBS Builders", yes)
    expect_or_fail(child, "Builder list", accept_default)
    expect_optional(child, "ePBS Build Factor", yes, "Grafana", BUILD_FACTOR_TIMEOUT)
    expect_or_fail(child, "Grafana", yes)
    expect_or_fail(child, "Configure rewards address", address)
    expect_or_fail(child, "Configure Graffiti", accept_default)
    expect_or_fail(child, "Default Graffiti", yes)

    expect_eof(child, FINISH_TIMEOUT)


# Called after all-defaults, existing .env
def no_epbs(child: Child) -> None:
    default_deployment(child)

    expect_or_fail(child, "Configure CL checkpoint sync URL", accept_default)
    expect_or_fail(child, "MEV Boost", no)
    expect_or_fail(child, "ePBS Builders", yes)
    expect_or_fail(child, "Builder list", accept_default)
    expect_or_fail(child, "Grafana", yes)
    expect_or_fail(child, "Configure rewards address", accept_default)
    expect_or_fail(child, "Configure Graffiti", accept_default)
    expect_or_fail(child, "Default Graffiti", yes)

    expect_eof(child, FINISH_TIMEOUT)


# Called after all-defaults, existing .env
def no_grafana(child: Child) -> None:
    default_deployment(child)

    expect_or_fail(child, "Configure CL checkpoint sync URL", accept_default)
    expect_or_fail(child, "MEV Boost", yes)
    expect_or_fail(child, "Relays list", accept_default)
    expect_or_fail(child, "ePBS Builders", yes)
    expect_or_fail(child, "Builder list", accept_default)
    expect_optional(child, "ePBS Build Factor", yes, "Grafana", BUILD_FACTOR_TIMEOUT)
    expect_or_fail(child, "Grafana", no)
    expect_or_fail(child, "Configure rewards address", accept_default)
    expect_or_fail(child, "Configure Graffiti", accept_default)
    expect_or_fail(child, "Default Graffiti", yes)

    expect_eof(child, FINISH_TIMEOUT)


ACTIONS: dict[str, Callable[[Child], None]] = {
    "all-defaults": all_defaults,
    "no-epbs": no_epbs,
    "no-grafana": no_grafana,
}


def main() -> None:
    if len(sys.argv) > 1:
        action = sys.argv[1]
        if action not in ACTIONS:
            print(f"Unknown action: {action}")
            sys.exit(1)
    else:
        print("No specific test specified, using all-defaults")
        action = "all-defaults"

    # Pin the pty size rather than relying on newt's fallback. The dialogs are echoed, which
    # is what "expect -d" showed.
    child = pexpect.spawn(
        "./ethd",
        ["config"],
        dimensions=(24, 80),
        encoding="utf-8",
        timeout=TIMEOUT,
    )
    child.logfile_read = sys.stdout
    ACTIONS[action](child)


if __name__ == "__main__":
    main()
