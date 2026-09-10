# Security Policy

## Reporting

Report suspected vulnerabilities through Pellera's approved internal security or engineering escalation process. Do not place secrets, customer data, raw authentication artifacts, or unsanitized logs in a GitHub issue.

A useful report includes:

- affected console version and build ID
- reproducible steps using sanitized data
- expected and observed behavior
- relevant redacted log excerpts
- impact assessment

If a credential or token may have been exposed, revoke or rotate it immediately before continuing investigation.

## Sensitive data handling

The console, collectors, mapping inventories, and collision reports can process identity and migration metadata. Treat generated files as sensitive engagement data. Store and transfer them only through approved customer and Pellera systems.

## Supported builds

Security corrections are applied to the current maintained preview or stable branch. Older extracted packages should not be overlaid with individual files; deploy a clean, complete release package.
