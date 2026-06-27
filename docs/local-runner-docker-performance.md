# Local runner Docker performance

This project already uses GitHub Actions Docker layer caching for image builds. The build workflow stores and restores BuildKit cache layers per service with `cache-from: type=gha,scope=<service>` and `cache-to: type=gha,scope=<service>,mode=max`. That means unchanged Dockerfile layers can be reused between workflow runs, which is most helpful for slow package installs and Rust dependency builds.

This document explains the practical performance options for a self-hosted runner.

## What changed in this PR

- Added `.dockerignore` files for every Docker build context under `services/`.
- These files keep local `target/` directories, editor files, logs, environment files and temporary data out of the Docker build context.
- Smaller build contexts reduce the amount of data sent to BuildKit before every build and make cache keys less likely to change because of local-only files.

## Docker layer caching

Docker layer caching reuses previous build steps when the Dockerfile instruction and the files used by that instruction have not changed.

The existing workflow already enables this through BuildKit's GitHub Actions cache backend. The biggest improvements come from keeping dependency installation steps before frequently changing application source files and keeping build contexts small.

Expected benefit:

- faster rebuilds after small source changes
- fewer repeated package downloads during image builds
- better reuse between pull request runs on the same repository

Limits:

- the first run is still cold and must download everything
- changes to package lists, lock files or copied source files can invalidate later layers
- cache size and eviction are controlled by the GitHub Actions cache backend

## Registry mirror

A Docker registry mirror helps when the runner repeatedly pulls the same public images from Docker Hub, such as Debian or Rust base images.

Example `/etc/docker/daemon.json` on the self-hosted runner:

```json
{
  "registry-mirrors": ["http://<lancache-or-mirror-host>:5000"]
}
```

After changing the daemon config, restart Docker:

```bash
sudo systemctl restart docker
```

Expected benefit:

- faster repeated pulls of the same public image layers
- less external internet traffic from the runner
- fewer slow Docker Hub downloads during cold builds

Limits:

- this helps image pulls, not application downloads inside running clients
- the mirror must be reachable and reliable from the runner
- private registries usually need separate authentication and should not be blindly mirrored

## Multi-stage builds

The Rust services already use multi-stage Dockerfiles where useful. For example, the DNS and UI images build Rust binaries in a `rust:slim` builder image and copy only the compiled binary into a smaller Debian runtime image.

Expected benefit:

- smaller runtime images
- fewer build tools in production images
- better separation between build dependencies and runtime dependencies

Limits:

- services that only install system packages and copy shell scripts do not gain much from multi-stage builds
- multi-stage builds improve image size and cleanliness more than raw network pull speed

## Parallelism and Docker daemon tuning on the local runner

The build job uses a matrix so services can build independently. On a self-hosted runner, too much parallelism can overload disk I/O, CPU or network.

For slow image pulls, tune Docker's pull and push concurrency together with the registry mirror in `/etc/docker/daemon.json`:

```json
{
  "registry-mirrors": ["http://<lancache-or-mirror-host>:5000"],
  "max-concurrent-downloads": 10,
  "max-concurrent-uploads": 5
}
```

After changing the daemon config, restart Docker:

```bash
sudo systemctl restart docker
```

For build steps that overload the runner, limit BuildKit worker parallelism in the Buildx builder configuration rather than in the Docker daemon file:

```toml
[worker.oci]
  max-parallelism = 4

[worker.containerd]
  max-parallelism = 4
```

Also consider limiting the GitHub Actions runner concurrency at the runner or workflow level if disk usage, CPU steal or network saturation is visible during builds.

## Simple German explanation

Diese Änderung macht die Docker-Builds nicht komplett neu, sondern räumt vor allem den Weg für schnellere Wiederholungen frei.

Die neuen `.dockerignore` Dateien sagen Docker: Bitte schicke keine lokalen Build-Ordner, Log-Dateien, Editor-Dateien oder geheimen `.env` Dateien in den Build. Dadurch muss Docker vor dem Bauen weniger Daten vorbereiten. Das kann besonders auf einem lokalen Runner Zeit sparen.

Der vorhandene Workflow nutzt bereits Docker Layer Cache. Das bedeutet: Wenn sich ein Schritt im Dockerfile nicht geändert hat, kann Docker alte Ergebnisse wiederverwenden. Der erste Lauf bleibt langsam, aber spätere Läufe können schneller werden.

Ein Registry Mirror ist zusätzlich sinnvoll, wenn dein Runner oft dieselben Basis-Images wie Debian oder Rust herunterladen muss. Dann werden diese Images lokal zwischengespeichert und müssen nicht jedes Mal langsam aus dem Internet kommen.

Multi-Stage Builds werden bei den Rust-Diensten bereits genutzt. Das hält die fertigen Images kleiner, weil nur das fertige Programm in das Laufzeit-Image kopiert wird und nicht die ganzen Build-Werkzeuge.

Wenn mehrere Builds gleichzeitig laufen und der Runner dadurch langsam wird, liegt das oft an zu viel Last auf CPU, Festplatte oder Netzwerk. Dann kann es helfen, weniger Builds gleichzeitig laufen zu lassen oder die BuildKit-Parallelität zu begrenzen. Bei langsamen Image-Downloads können ein Registry Mirror und mehr gleichzeitige Docker-Downloads helfen.
