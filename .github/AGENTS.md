# GitHub Directory Guidance

Repository-wide agent governance lives in [`../AGENTS.md`](../AGENTS.md).

Follow the root guidance for all `.github/**` changes too, especially workflow validation, runner-label review, secret/variable handling, and issue/PR linking rules.

## Build-tools Verification Contract

Workflows must also follow the **Build-tools verification contract** documented in the root [`AGENTS.md`](../AGENTS.md) under the "Required Validation" and "Coding Patterns" sections. In brief: all project verification (Rust checks, linting, build validation) must run inside the build-tools container at the immutable version selected by `scripts/select-build-tools-image.sh`. Host-local tools must be assumed missing or stale. Falling back from the build-tools container to host tools invalidates the verification attempt. Workflow jobs must use the container pattern: `docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:/work:ro" -w /work "${BUILD_TOOLS_IMAGE:?BUILD_TOOLS_IMAGE is required}" <command>`.
