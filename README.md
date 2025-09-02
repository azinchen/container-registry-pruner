# Container Registry Pruner

A powerful bash script to automatically clean up old container images from GitHub Container Registry (GHCR) and Docker Hub, helping you manage storage costs and keep your registries organized.

## Features

- **Multi-Registry Support**: Works with both GitHub Container Registry (GHCR) and Docker Hub
- **Smart Tag Protection**: Automatically protects important tags like `latest` and highest version releases
- **Flexible Retention Policies**: Different age limits for release vs development tags
- **Version-Aware**: Intelligently recognizes semantic version tags (e.g., `v1.2.3`, `1.2.3-beta`)
- **Dry Run Mode**: Safe preview mode (default) to see what would be deleted before execution
- **Untagged Cleanup**: Option to clean up untagged versions in GHCR
- **Customizable Protection**: Protect specific tags and control retention counts
- **Detailed Reporting**: Clear output showing what will be kept vs deleted

## Requirements

- `bash` (with GNU date support)
- `curl`
- `jq`

On macOS, install GNU coreutils: `brew install coreutils`

## Quick Start

### GHCR Only
```bash
./registry-prune.sh \
  --ghcr-owner-type users \
  --ghcr-owner myusername \
  --ghcr-token ghp_xxxxxxxxxxxx \
  --ghcr-package mypackage \
  --max-release-days 90 \
  --max-dev-days 30
```

### Docker Hub Only
```bash
./registry-prune.sh \
  --docker-user myusername \
  --docker-pass mypassword \
  --docker-namespace myusername \
  --docker-repo myrepo \
  --max-release-days 90 \
  --max-dev-days 30
```

### Both Registries
```bash
./registry-prune.sh \
  --ghcr-owner-type users \
  --ghcr-owner myusername \
  --ghcr-token ghp_xxxxxxxxxxxx \
  --ghcr-package mypackage \
  --docker-user myusername \
  --docker-pass mypassword \
  --docker-namespace myusername \
  --docker-repo myrepo \
  --max-release-days 90 \
  --max-dev-days 30 \
  --execute --yes
```

## Options

### Registry Configuration

#### GitHub Container Registry (GHCR)
- `--ghcr-owner-type users|orgs` - Owner type (users or organizations)
- `--ghcr-owner OWNER` - GitHub username or organization name
- `--ghcr-token TOKEN` - GitHub Personal Access Token with package permissions
- `--ghcr-package PACKAGE` - Package name in GHCR

#### Docker Hub
- `--docker-user USER` - Docker Hub username
- `--docker-pass PASS` - Docker Hub password or access token
- `--docker-namespace NS` - Docker Hub namespace (usually same as username)
- `--docker-repo REPO` - Docker Hub repository name

### Retention Policies
- `--max-release-days N` - Maximum age in days for release tags (required)
- `--max-dev-days M` - Maximum age in days for development tags (required)
- `--keep-release-count N` - Keep N newest release tags regardless of age
- `--keep-dev-count M` - Keep M newest dev tags regardless of age

### Tag Protection
- `--protect TAG` - Protect specific tags from deletion (can be used multiple times)
- `--protect-latest-per [minor|patch]` - Protect latest tag per minor/patch version
  - `minor`: For each `A.B`, protect highest `A.B.C` version
  - `patch`: For each `A.B.C`, protect highest `A.B.C.D` version

### Untagged Images (GHCR Only)
- `--include-untagged` - Include untagged versions in cleanup
- `--max-untagged-days K` - Maximum age for untagged versions

### Execution Control
- `--execute` - Actually perform deletions (default is dry-run mode)
- `--yes` - Skip confirmation prompts
- `--delete-limit N` - Limit number of deletions per run

### Output Options
- `--output-dir DIR` - Save operation details to files in this directory
- `--quiet` - Suppress informational output
- `--verbose` - Show debug information

## Tag Classification

The script automatically classifies tags into two types:

### Release Tags
Tags matching semantic version patterns:
- `1.2.3`, `v1.2.3`
- `1.2.3.4`, `v1.2.3.4`
- `1.2.3-beta`, `v1.2.3-rc1`

### Development Tags
All other tags not matching release patterns:
- `main`, `master`, `develop`
- `feature-branch`, `pr-123`
- Custom tags

## Protection Rules

The script automatically protects:

1. **Always Protected**: `latest` tag and any tags specified with `--protect`
2. **Highest Release**: The highest semantic version tag overall
3. **Latest Per Version** (optional): Latest patch/minor per version family
4. **Force Keep Counts**: Newest N releases/dev tags via `--keep-release-count`/`--keep-dev-count`

## Examples

### Basic Cleanup (Dry Run)
```bash
./registry-prune.sh \
  --ghcr-owner-type users \
  --ghcr-owner johndoe \
  --ghcr-token ghp_xxxxxxxxxxxx \
  --ghcr-package myapp \
  --max-release-days 180 \
  --max-dev-days 30
```

### Aggressive Cleanup with Protection
```bash
./registry-prune.sh \
  --docker-user johndoe \
  --docker-pass mypassword \
  --docker-namespace johndoe \
  --docker-repo myapp \
  --max-release-days 60 \
  --max-dev-days 14 \
  --protect stable \
  --protect v1.0.0 \
  --keep-release-count 5 \
  --execute --yes
```

### Clean Untagged Images in GHCR
```bash
./registry-prune.sh \
  --ghcr-owner-type orgs \
  --ghcr-owner myorg \
  --ghcr-token ghp_xxxxxxxxxxxx \
  --ghcr-package myapp \
  --max-release-days 90 \
  --max-dev-days 30 \
  --include-untagged \
  --max-untagged-days 7 \
  --execute
```

### Protect Latest Per Minor Version
```bash
./registry-prune.sh \
  --ghcr-owner-type users \
  --ghcr-owner johndoe \
  --ghcr-token ghp_xxxxxxxxxxxx \
  --ghcr-package myapp \
  --max-release-days 365 \
  --max-dev-days 30 \
  --protect-latest-per minor \
  --execute
```

## Authentication

### GHCR Token
Create a GitHub Personal Access Token with these permissions:
- `read:packages`
- `delete:packages`

### Docker Hub
You can use either:
- Your Docker Hub password
- A Docker Hub Access Token (recommended)

## Safety Features

- **Dry Run by Default**: The script runs in preview mode unless `--execute` is specified
- **Confirmation Prompt**: Interactive confirmation before deletions (unless `--yes` is used)
- **Rate Limiting**: Built-in retry logic for API rate limits
- **Error Handling**: Robust error handling with detailed logging
- **Delete Limits**: Optional `--delete-limit` to cap deletions per run

## Output Example

```
Protected tags: latest stable
Mode: DRY RUN
Enabled: GHCR=1, DockerHub=0

GHCR tags for johndoe/myapp:
ACTION   TYPE       AGE   TAG
----------------------------------------------------------
KEEP     protected    0d   latest
KEEP     protected   30d   stable
KEEP     release     45d   v2.1.0
KEEP     release     60d   v2.0.1
DRY-RUN  release     95d   v1.5.0
DRY-RUN  dev        120d   feature-old
DRY-RUN  dev         40d   pr-123

GHCR summary: keep=4 delete=3 (dry run)
```

## Automation

This script is perfect for CI/CD pipelines and cron jobs:

```bash
# Weekly cleanup cron job
0 2 * * 0 /path/to/registry-prune.sh --config-from-env --execute --yes
```

Set environment variables for credentials:
```bash
export GHCR_OWNER="myusername"
export GHCR_TOKEN="ghp_xxxxxxxxxxxx"
# ... other vars
```

## License

This project is available under the MIT License. See the script header for details.

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.
