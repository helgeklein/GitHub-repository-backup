# GitHub Repository Backup

This script makes a local backup of every (public and private) GitHub repository you own.

Repositories that don't exist locally are cloned. Repositories that do exist are updated. Backups are stored as bare mirror repositories.

The result is a folder like this:

```text
/backup-root/
  repo-one.git/
  repo-two.git/
  repo-three.git/
```

Each `*.git` directory is a Git mirror created with `git clone --mirror`. That means it contains all branches, tags, and remote refs.

## How the backup script works

The script:

- authenticates to the GitHub API with a personal access token (PAT)
- verifies that the token belongs to the GitHub username you passed in
- requests all repositories owned by that user, including private repositories the token can access
- optionally excludes forked repositories
- clones missing repositories as mirrors
- updates repositories that already exist locally
- keeps each mirror's `origin` remote set to the public GitHub URL instead of storing the token in Git config

### What's not covered

- It does not create working copies you can edit directly.
  - To create a working copy, run `git clone` on a backup directory (see below).

- It does not delete local mirrors when a repository is deleted on GitHub.
- It does not include issues, pull requests, releases, or other non-Git GitHub data.

## Requirements

You need these commands installed:

- `bash`
- `curl`
- `jq`
- `git`
- `base64`

You also need a GitHub personal access token (PAT) with these properties:

- fine-grained
- access to all repositories
- permissions: read-only for contents and metadata

## Usage

### Backup

Set exactly one of these environment variables:

- `GITHUB_TOKEN`, or
- `GITHUB_TOKEN_FILE`

Then run:

```bash
github-backup.sh <GITHUB_USERNAME> <TARGET_DIR> [include_forks]
```

Arguments:

- `GITHUB_USERNAME`: the GitHub account that owns the token
   - If the username does not match the authenticated token owner, the script stops
- `TARGET_DIR`: directory where mirror repositories are stored
- `include_forks`: optional; defaults to `false`; accepted true values are `true`, `1`, `yes`, and `y`

### Working copy from backup

To use a backup and work on the code, create a working copy from the bare mirror repository in the backup directory:

```bash
git clone /path/to/backup-directory /path/to/new/working-directory
```

## Examples

Back up all owned repositories except forks, using a token from an environment variable:

```bash
GITHUB_TOKEN=YOUR_TOKEN ./github-backup.sh helgeklein /srv/github-backup
```

Back up all owned repositories including forks:

```bash
GITHUB_TOKEN=YOUR_TOKEN ./github-backup.sh helgeklein /srv/github-backup true
```

Use a token file instead of putting the token directly into the command line:

```bash
printf '%s\n' 'YOUR_TOKEN' > ~/.github-token
chmod 600 ~/.github-token
GITHUB_TOKEN_FILE=~/.github-token ./github-backup.sh helgeklein /srv/github-backup
```

Example output:

```text
Starting GitHub mirror sync for user 'helgeklein' into '/srv/github-backup' (include forks: false)...
Discovered 34 repositories owned by 'helgeklein' (forks false).
[CLONE] repo-one ...
  -> Cloned repo-one
[UPDATE] repo-two ...
  -> Updated repo-two
All repositories processed successfully.
```

If some repositories fail, the script continues with the others and exits with status code `5` at the end.

## Output layout

For a repository named `example-repo`, the script creates:

```text
<TARGET_DIR>/example-repo.git
```

This is a bare mirror repository. To inspect it, use Git commands directly, for example:

```bash
git -C ./example-repo.git show-ref
git -C ./example-repo.git log --all --oneline | head
```

## Exit codes

- `0`: all repositories were processed successfully
- `1`: invalid usage or missing token configuration
- `2`: required dependency is missing
- `3`: unexpected or unusable response from the GitHub API
- `4`: the supplied GitHub username does not match the token owner
- `5`: one or more repositories failed to clone or update

## Security notes

- Prefer `GITHUB_TOKEN_FILE` over putting the token directly in the shell command.
- The script does not store the token in Git remote URLs.
- Existing mirrors are kept with public `https://github.com/...` origin URLs.
