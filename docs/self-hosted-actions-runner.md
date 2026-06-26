# Self-hosted GitHub Actions runner

The repository workflows are configured to run the build, container checks and CodeQL jobs on self-hosted Linux runners with these labels:

- `self-hosted`
- `linux`
- `lancache`

Register at least one runner with the `lancache` label before enabling the workflows. The runner user must be able to run Docker builds and the few package-install commands used by the checks.

## Debian runner packages

On a Debian runner, install the baseline tools used by the workflows:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl git jq shellcheck sudo
```

Install Docker Engine and the Compose plugin from Docker's Debian repository, then add the GitHub Actions runner user to the `docker` group:

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker actions-runner
```

Replace `actions-runner` with the actual Linux user that runs the GitHub Actions service. Restart the runner service or log the user out and back in so the new group membership is applied.

## Runner labels

When configuring the runner, include the custom `lancache` label. For example:

```bash
./config.sh --url https://github.com/<owner>/<repo> --token <registration-token> --labels lancache
sudo ./svc.sh install
sudo ./svc.sh start
```

## Local Docker build cache

The build workflow uses a local Buildx cache under `/var/tmp/lancache-ng-buildx-cache` instead of GitHub's `type=gha` cache backend. This keeps Docker layer cache traffic on the self-hosted runner and avoids consuming GitHub Actions cache quota for image builds.

Create the cache directory once if your runner has restricted `sudo` rules:

```bash
sudo mkdir -p /var/tmp/lancache-ng-buildx-cache
sudo chown -R actions-runner:actions-runner /var/tmp/lancache-ng-buildx-cache
```

Replace `actions-runner:actions-runner` with the runner account and group. If passwordless `sudo` is available for the runner service, the workflow also creates and rotates this directory itself.

## CodeQL

The CodeQL workflow uses `github/codeql-action` on the same self-hosted runner labels. No separate CodeQL package needs to be installed on Debian; the action downloads and manages the CodeQL bundle during the workflow run.

The runner only needs outbound network access to GitHub to download actions, upload CodeQL results and fetch dependencies used by the repository checks.
