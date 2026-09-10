# Mapping Collision Utility tests

- `Run-MappingCollisionTests.ps1` executes the analysis engine against the packaged known-collision inventories and verifies expected categories, candidate dispositions, reports, manifest hashes, and input immutability.
- `Run-WpfSmokeTest.ps1` loads the production XAML under 64-bit STA Windows PowerShell, validates required controls and initial state, confirms theme brushes are unfrozen, executes both palettes, forces the frozen-brush fallback path, and performs a layout pass.
- `StaticValidation.py` provides cross-platform package, schema, XAML-resource, controller-reference, theme/log-maintenance marker, lexical, and sample-scenario checks.
