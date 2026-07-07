# Bats Setup Tests

These fixtures cover small, stateful `setup.sh` migration helpers that are too
specific for plain `bash -n` and too cheap to require a full stack startup.

The tests load the real helper functions from `setup.sh` into an isolated Bats
process. They must not duplicate setup migration logic in test-only helper code.
