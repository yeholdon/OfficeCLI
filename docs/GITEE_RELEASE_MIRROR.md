# Gitee release mirror

OfficeCLI release metadata, checksums, and non-Windows binaries are mirrored
from GitHub to:

<https://gitee.com/yeholdon/OfficeCLI/releases>

The GitHub workflow `.github/workflows/mirror-gitee-release.yml` runs whenever
a GitHub release is published. It also polls `iOfficeAI/OfficeCLI` hourly and
supports manually mirroring a specific tag. The polling path means the workflow
can run from a fork whose owner cannot manage secrets in the upstream project.

## Repository setup

Create a GitHub Actions repository secret named `GITEE_TOKEN`. Its value must be
a Gitee personal access token belonging to a user who can manage releases in
`yeholdon/OfficeCLI`. Grant the token the `projects` scope.

If you cannot manage settings in `iOfficeAI/OfficeCLI`, push this workflow to a
GitHub fork you control and create the secret in that fork. The workflow keeps
using `iOfficeAI/OfficeCLI` as the release source; it does not require Releases
to be copied into the fork.

No username or password is stored in GitHub. The workflow sends the token in an
HTTP authorization header, and the token is never placed in a download URL.

Before creating a release, the workflow fetches its exact tag from the upstream
GitHub repository and pushes that tag (and its required Git objects) to Gitee.
The fork and the Gitee default branch therefore do not need to be synchronized
manually before each release. An existing Gitee tag is accepted only when it
points to the same Git object as the upstream tag.

## Initial and manual synchronization

After adding `GITEE_TOKEN`, open **Actions → Mirror release to Gitee → Run
workflow**. Keep `latest` to mirror the current release, or enter a tag such as
`v1.0.146` to backfill a particular release.

The synchronization is idempotent: an existing Gitee release is reused and
attachments already present under the same name are skipped. GitHub assets are
verified against `SHA256SUMS` before they are uploaded. The checksum manifest is
published first, then at most two platform binaries are transferred in parallel.
A final job verifies every Gitee attachment and external mirror target.

Gitee's security scanner rejects the raw Windows executables. Those two files
remain on OfficeCLI's official download mirror, `https://d.officecli.ai`, which
the project's installers and self-updater already use as their primary source.
Each Gitee release description contains direct, versioned links to every asset
on that mirror. Gitee stores the checksum manifest plus the macOS and Linux
binaries; the workflow verifies that both Windows mirror URLs are available.

To validate GitHub asset download, checksum verification, and size checks
without contacting Gitee, run:

```bash
GITEE_DRY_RUN=true .github/scripts/sync-gitee-release.sh latest
```

Gitee's documented free-tier single-file limit is 50 MB. The script enforces
that limit before making changes. Set `GITEE_MAX_ASSET_BYTES` only if the target
Gitee plan has a different limit.

The published free-tier total attachment quota is 3 GB. A current OfficeCLI
release is roughly 270 MB, so the repository can retain only about ten complete
release mirrors before older Gitee attachments must be removed or storage must
be moved elsewhere. This workflow deliberately does not delete old releases.
