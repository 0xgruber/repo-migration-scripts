# Security Workflow for GitHub Repositories

This repository includes a standard security workflow that should be deployed to all repositories.

## Features

The security workflow provides:

1. **Secret Scanning with Gitleaks**
   - Scans entire git history for leaked credentials
   - Detects 1000+ secret patterns (API keys, tokens, passwords, etc.)
   - Runs on every push and pull request

2. **Shell Script Linting with ShellCheck**
   - Automatically detects shell scripts
   - Enforces security best practices
   - Catches common scripting errors

3. **Dependency Review**
   - Scans dependencies in pull requests
   - Alerts on vulnerable packages
   - Fails PRs with moderate+ severity vulnerabilities

4. **Scheduled Scans**
   - Weekly security scans every Monday at 00:00 UTC
   - Ensures ongoing protection even without commits

## Deployment

### For All Existing Repositories

Run the deployment script from this directory:

```bash
./07-deploy-security-workflow.sh
```

This will:
- Process all repositories listed in `repos.ini`
- Clone repos locally if needed
- Add the security workflow to each repository
- Commit and push changes (with your approval)

**Dry-run mode:**
```bash
./07-deploy-security-workflow.sh --dry-run
```

### For a Single Repository

Manually copy the template:

```bash
# From repo-migration-scripts directory
cp templates/security-workflow.yml /path/to/your-repo/.github/workflows/security.yml
cd /path/to/your-repo
git add .github/workflows/security.yml
git commit -m "Add GitHub Actions security workflow"
git push
```

### For New Repositories

When creating a new repository:

1. Create `.github/workflows/` directory
2. Copy `templates/security-workflow.yml` to `.github/workflows/security.yml`
3. Commit and push

**Or use the deployment script** to add the workflow to repos.ini first, then run:
```bash
./07-deploy-security-workflow.sh
```

## Template Location

The security workflow template is stored at:
```
repo-migration-scripts/templates/security-workflow.yml
```

## Customization

The template supports both `main` and `master` branches automatically.

To customize for a specific repository:
1. Copy the template to the repository
2. Edit `.github/workflows/security.yml` as needed
3. Commit changes

## Monitoring

View workflow runs at:
```
https://github.com/<username>/<repo>/actions
```

GitHub will notify you via email if security issues are detected.

## What Gets Detected

### Secrets (Gitleaks)
- AWS, Azure, GCP credentials
- GitHub, GitLab, Bitbucket tokens
- Database connection strings
- Private SSH/PGP keys
- API keys from popular services
- Generic passwords and secrets

### Shell Issues (ShellCheck)
- Command injection vulnerabilities
- Quote/escaping issues
- Unsafe variable expansions
- Deprecated syntax
- Portability problems

### Dependencies (Dependency Review)
- Known CVEs in dependencies
- Malicious packages
- License compliance issues
- Outdated dependencies with fixes

## Updating the Workflow

When the template is updated, re-run the deployment script:

```bash
./07-deploy-security-workflow.sh
```

The script will detect existing workflows and offer to update them.

## Best Practices

1. **Never disable secret scanning** - Even for private repos
2. **Fix issues promptly** - Don't ignore workflow failures
3. **Review weekly scan results** - Check Monday morning notifications
4. **Rotate secrets if leaked** - Removing from git is not enough
5. **Use .gitleaksignore sparingly** - Only for false positives

## Troubleshooting

### Gitleaks False Positives

Create `.gitleaksignore` in the repository root:
```
# Ignore specific file
path/to/false-positive.txt

# Ignore by commit
commit:abc123def456...
```

### ShellCheck Exceptions

Add inline comments in shell scripts:
```bash
# shellcheck disable=SC2086
variable_without_quotes
```

### Dependency Review Failures

Update vulnerable dependencies or add exceptions in `.github/dependabot.yml`

## Support

For issues with the security workflow:
1. Check GitHub Actions logs for details
2. Review the workflow file for syntax errors
3. Ensure GitHub Actions is enabled for the repository
4. Contact repository admin for permission issues
