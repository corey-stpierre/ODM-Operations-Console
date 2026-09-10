# Repository Preparation Record

Prepared: 2026-08-25

## Structural decision

The existing application layout was retained at repository root. Moving it into a new `src` directory would have invalidated root-relative assumptions in launchers, tests, governance checks, and release tooling.

## Added repository controls

- expanded `.gitignore`
- `.gitattributes`
- GitHub validation workflow
- pull-request and issue templates
- contribution and security guidance
- repository setup, architecture, and release-process documentation

## Sanitization applied

The following repository-only corrections were applied without changing production console logic:

- removed two personal email addresses used as default notification recipients in a legacy standalone script
- replaced an engagement-specific Quest organization identifier in legacy usage examples with a sample GUID
- replaced engagement-specific project, workload, and task identifiers in legacy examples with explicit placeholders
- replaced engagement-specific example project/file labels with neutral examples

## Reproducibility controls

Tracked text files use deterministic line endings through `.gitattributes`. The prepared working tree and a clean clone created with Git automatic line-ending conversion enabled produced the same 117-entry internal manifest. The clean clone also remained free of uncommitted checkout changes.

The GitHub-prepared tree contains 118 tracked files, including the internal manifest.

## Validation result

The source archive's original internal SHA-256 manifest passed before preparation. After preparation, the repository manifest was regenerated and the available platform-neutral static validation, runtime source audit, and Mapping Collision Utility static validation passed in both the prepared tree and a clean clone.

Native WPF, live Quest, installed `OdmApi`, Active Directory, Entra, and Authenticode validation require a Windows release-test environment.
