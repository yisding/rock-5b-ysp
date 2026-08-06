# Operation name

## Purpose and risk

State the outcome, affected systems, and whether the operation can install,
overwrite, reboot, expose credentials, or make recovery necessary.

## Prerequisites and authority

List required hardware, tools, free space, backups, network access, privileges,
and the safe way to verify each target before mutation.

## Input and artifact identity

Distinguish intended/default input from the actual source or binary exercised.
Link the owning script, manifest, standard package metadata, or source pin.

## Procedure

Give commands in execution order. Put destructive confirmation immediately
before the destructive command, not only in the introduction.

## Pass and fail signals

Name the expected output, exit status, counters, logs, or hardware behavior.
State conditions that require stopping rather than continuing.

## Cleanup and rollback

Explain temporary-state removal, package or configuration rollback, recovery
media, and how to prove the previous state is restored.

## Evidence to retain

Record date, exact identity, command/workload, signal, result, log or artifact
route, trust, and boundary. Keep build products outside the repository and give
a portable reconstruction path.

## Next decision owner

Link the status row, live plan, package owner, or project document that decides
what the result changes.
