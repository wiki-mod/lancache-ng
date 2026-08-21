# CI-Automation/vex

This branch carries exactly one generated artifact: `vex.openvex.json`, an
[OpenVEX](https://openvex.dev) document listing this project's accepted/
deferred CVE dispositions (OSPS-VM-04.02).

**Do not hand-edit `vex.openvex.json` on this branch.** It is entirely and
deterministically regenerated from
[`.trivyignore.yaml`](https://github.com/wiki-mod/lancache-ng/blob/current_dev/.trivyignore.yaml)
on `current_dev` by
[`scripts/untracked/generate-vex.sh`](https://github.com/wiki-mod/lancache-ng/blob/current_dev/scripts/untracked/generate-vex.sh),
run automatically by
[`.github/workflows/vex-regenerate.yml`](https://github.com/wiki-mod/lancache-ng/blob/current_dev/.github/workflows/vex-regenerate.yml)
whenever `.trivyignore.yaml` or the generator itself changes on
`current_dev`. Any manual edit here is silently overwritten by the next
real regeneration.

To change the VEX content, edit `.trivyignore.yaml` on `current_dev`
instead -- this branch will catch up automatically.

Fetch the current document directly at:
`https://raw.githubusercontent.com/wiki-mod/lancache-ng/CI-Automation/vex/vex.openvex.json`

A release tag's own `vex.openvex.json` release asset is regenerated fresh
from that tag's own `.trivyignore.yaml` state at release time (see
`.github/workflows/build-push.yml`'s "Attach OpenVEX document to the
release" step) -- it is never copied from this branch's tip, since that
could race a release cut against this branch's own refresh.

Background: wiki-mod/lancache-ng issue 1095 (F-22).
