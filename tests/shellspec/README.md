# ShellSpec Setup Tests

ShellSpec fixtures cover host and command-simulation style checks for
`setup.sh`. They are intended for cases where the setup flow must be exercised
with controlled command behavior instead of changing the real host.

The fixtures must load real setup helpers from `setup.sh` and stub only external
host effects. They must not duplicate production setup logic as the test oracle.
