# Contributing

This repository is intended for controlled Pellera development of the Quest ODM Operations Console and Mapping Collision Utility.

## Branches

Create work from `main` using one of these patterns:

- `feature/<description>`
- `fix/<description>`
- `refactor/<description>`
- `release/<version>`

Submit changes through a pull request. Do not force-push or commit directly to a protected `main` branch.

## Required checks

Before opening a pull request, run the platform-neutral validations:

```powershell
python .\Tests\StaticValidation.py
python .\Tests\RuntimeSourceAudit.py
python .\MappingCollisionUtility\Tests\StaticValidation.py
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Run-StaticValidation.ps1 -SkipWpfSmokeTest -SkipGovernanceTests
```

On a Windows test workstation, also run the release acceptance suite documented in `README.md` and `docs/RELEASE_PROCESS.md`.

## Repository safety

Never commit:

- Quest access or refresh tokens
- OAuth authorization headers
- passwords, client secrets, or certificate private keys
- customer inventory exports or collision reports
- operational CSV files containing real identities
- unsanitized logs or support bundles
- customer tenant, organization, project, task, or workload identifiers unless explicitly approved

Use `.example`, `.test`, or Contoso-style values in samples. Review `git diff --cached` before every commit.

## Change discipline

Keep functional changes separate from formatting or file-layout changes. Preserve the application-root layout unless all launchers, tests, packaging tools, and relative paths are updated and validated together.
