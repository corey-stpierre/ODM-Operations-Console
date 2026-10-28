# RC1 audit record

Scope: review of the existing preview.7 implementation, required acceptance tests, vendor command metadata/source inspection, offline command behavior and new WPF flows. This is not a formal security certification or proof that no defects remain.

## Production corrections

| Finding | Correction and evidence |
| --- | --- |
| Empty organization result broke strict-mode count handling | Normalize zero/one/many results; existing mock regression |
| Empty readiness list rejected by parameter binding | Allow empty collection; governance regression |
| Stop delay argument did not reach stop helper | Validated DelaySeconds forwarding; lifecycle mocks |
| Report scope used parent project | Query selected workload; governance tests |
| Account Task Factory could be invoked in another workload | Explicit account workload gate |
| CSV parser accepted duplicate headers or uneven rows | Strict CSV parser; malformed and quoted multiline cases |
| Short JWT header escaped sanitization | Corrected expression; governance redaction regression |
| Template Values contains nested JSON credentials | Parse/sanitize embedded JSON in reports; native management regression |
| Manifest/signing report paths used a two-character backslash where TrimStart needs a character | Corrected path formatting and deferred default-root resolution until script initialization; manifest generation and read-only signature checks executed on PS5.1 |
| Reports generated in same millisecond could collide | Random suffix in report filenames |
| New setter calls passed common parameters as task properties | Scoped error preference; native Quest setter exercised offline |
| Native task classes fail PS5 raw JSON serialization | Canonical plain snapshots for preview fingerprints |
| Workload switch left new form state visible | Shared reset of fields, IDs, inventories, tokens and secrets; WPF regression |
| Footer controls clipped and new form colors inherited selected-tab white | Minimum layout correction, explicit theme foreground, dropdown/password styles; offscreen WPF render checks |

## Test-harness repairs

UI initial-state and overview tests formerly defined functions in a helper's disappearing scope and used incomplete state fixtures. They now load the production functions and initial state. WPF can legitimately freeze style brushes; tests exercise the production replacement fallback and both themes instead of asserting all brushes stay unfrozen. Layout assertions use an actual offscreen window. Mock expectations now match the schema/validation report contract. JSON redaction assertions parse JSON rather than depending on host-specific escaping.

The log-retention failure was reproduced as a temporary-directory access constraint. The test now reports the underlying maintenance failure, and validation runs use an accessible dedicated temporary directory. No unrelated log-retention behavior was changed to make the assertion pass.

## New workflow limits

Commands are allowlisted and checked against the loaded module. Preview and validation never call mutation commands. Creation is held; address rewriting is blocked because its vendor implementation can run immediately. Four SharePoint constructors are also blocked because they read an ambient schedule variable without exposing a scheduling parameter; supported file-based mapping routes and the web console remain available. Updates preserve omitted fields, block active tasks and show readback with UPDATED_REVIEW_REQUIRED. Exact final-property equivalence is not automatically proved for every setter, because vendor parameter/property mappings differ. Partial/ambiguous responses remain REVIEW_REQUIRED with known IDs and no retry. Template import validates the whole file before submission but the service import itself is not transactional.

Offline tests run real exported vendor commands with only backend calls replaced. They establish local behavior for representative constructors, task updates/scheduling, collection rename, template save/export/import and event acknowledgement. Metadata checks cover the full catalog. They do not prove tenant permissions, service pagination, eventual consistency, vendor defaults across all commands, throttling behavior, every CSV schema, or migration outcomes. Those require the connected pilot checklist.


## RC2 — Active Directory extension

AD runs in a separate organization-scoped context. Added 27 bounded read views and 20 reviewed actions from the installed 2.1.401 module metadata. All mutations require exact targets, matching CSV organization/kind/environment guards where supplied, reference resolution, a recent one-use preview, Safe Mode disabled, local acknowledgement and typed confirmation. AD actions may execute immediately; shared profiles and self-service notifications are explicitly identified in guidance. Reports hide AD agent/service/authentication keys and global-variable values, and flatten SDK snapshots to avoid navigation cycles. Submission journals persist before each target; uncertain failures stop the batch. AD setup and unexported operations remain web handoffs. No live acceptance was attempted, per the user's deferral.
