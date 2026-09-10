# GitHub Repository Setup

The application-root layout in this repository is intentional. Existing launchers, static validation, release manifests, and tests resolve files relative to the repository root. Do not move the application into a new `src` folder during the initial import.

## 1. Place the repository in a permanent working directory

Example:

```powershell
$RepoRoot = 'F:\GitHub\ODM-Operations-Console'
Set-Location $RepoRoot
```

Keep the immutable stable archive outside this directory.

## 2. Review the prepared source

```powershell
Get-ChildItem -LiteralPath . -Recurse -File
rg -n -i 'client[_ -]?secret|access[_ -]?token|refresh[_ -]?token|authorization\s*[:=]|password\s*[:=]' .
```

Review all staged content again before the first commit.

## 3. Initialize Git

```powershell
git init -b main
git config user.name 'Corey St. Pierre'
git config user.email '<your GitHub-associated email>'

git add .
git status
git diff --cached --stat
git diff --cached
```

Commit only after the staged diff is clean:

```powershell
git commit -m 'chore: import stable console source baseline'
```

## 4. Create the private repository

Using GitHub CLI:

```powershell
gh auth login

gh repo create <PELLERA_GITHUB_ORG>/odm-operations-console `
    --private `
    --source . `
    --remote origin `
    --push `
    --description 'Pellera operations console for governed Quest On Demand Migration workflows.'
```

## 5. Tag the imported build

Confirm the version first:

```powershell
$Version = (Get-Content .\VERSION.txt -Raw).Trim()
git tag -a "v$Version" -m "Imported console baseline $Version"
git push origin "v$Version"
```

Because the current version is a preview, mark its GitHub Release as a prerelease.

## 6. Protect `main`

Configure a repository ruleset that:

- requires pull requests
- prevents force pushes
- prevents branch deletion
- requires the validation workflow
- requires resolved review conversations

A separate approving reviewer can be added when another maintainer is assigned.
