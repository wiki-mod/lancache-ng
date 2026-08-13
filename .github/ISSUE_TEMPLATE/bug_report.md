---
name: Bug report
about: Something is not working as expected
labels: bug
---

**Describe the bug**
A clear description of what the bug is.

**Steps to reproduce**
1. ...

**Expected behavior**
What you expected to happen.

**Actual behavior**
What actually happened.

**Environment**
- Mode: [ ] standard [ ] ssl
- OS / Docker version (`cat /etc/os-release`, `docker --version`, `docker compose version`):
- Logs: run `sudo /opt/lancache-ng/setup.sh create-logs-for-issue` and attach the resulting archive (bundles all service logs, Compose status/config, host/Docker versions, and secret-redacted `.env` data in one step -- review it yourself before attaching, the command never uploads anything automatically):
