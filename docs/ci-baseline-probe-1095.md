# CI Baseline Probe (Issue #1095)

This file exists only to open a trivial, docs-only PR against `current_dev`
and observe whether required CI checks pass on a change that touches
nothing but this one new documentation file.

Purpose: empirically settle whether the low success rates shown on the
repository's own Actions performance dashboard reflect real, persistent
bugs, or benign cancelled/superseded noise from concurrency groups on an
active branch.

This file and its PR are meant to be closed/deleted once the probe has
run; it is not meant to remain in the tree.
