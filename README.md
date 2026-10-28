# Quest ODM Operations Console — 1.1.0-rc.2

RC1 expands the existing Microsoft 365 migration console and repairs issues found during the audit. It includes Accounts, mailbox/OneDrive workflows, Teams/groups/chats, SharePoint, Power BI, Power Platform, public folders, Desktop Update Agent and Hybrid Exchange. RC2 adds Active Directory and device migration through a separate organization-scoped workspace. Hybrid SharePoint remains outside this release's scope.

**This is an unsigned candidate for pilot acceptance. Live Quest testing has not run. Full native web-console parity is not claimed.** See `RC_STATUS.html`, `V1_RELEASE_VALIDATION.json` and `docs/QUEST_PARITY.csv` for the exact coverage and remaining work.

## Start

1. Extract the entire package into a new folder. Keep your existing release available for rollback.
2. Use `Start-QuestODMConsole-WindowsPowerShell.cmd` or `Start-QuestODMConsole-PowerShell7.cmd` on Windows x64. The launchers use STA. Follow your organization's unsigned-script policy; no machine execution policy is changed by this release.
3. Inspect Diagnostics, connect, and select the organization. For M365 select a project/workload and run readiness. For AD open the Active Directory workspace and review the AD prerequisites in Guides; AD readiness checks host/storage and command availability while leaving tenant prerequisites explicitly unverified.
4. Open **Guides** for workflows, CSV schemas, sample files, scope rules and recovery instructions. `OPERATOR_GUIDE.html` provides the same guide outside the application.
5. Pilot a small held task and inspect its settings and members in Quest before starting it.

## Added in RC2: Active Directory and devices

- 27 bounded inventory/monitoring views and 20 action forms, checked against OdmApi 2.1.401 metadata. Includes directory workflows/runs/logs, device discovery/ReACL/cutover, credential caching, offline domain join, Entra ID cutover, file-share processing, shared-profile updates and self-service migration.
- Organization-only selection supports AD-only organizations. AD and M365 selections are isolated; context switches reset Safe Mode and previews.
- Exact-ID or guarded CSV targets, re-resolved references, future-date validation, redacted agent/service/auth keys, one-use previews and a journal before each submission. Partial/uncertain failure stops the rest of the batch; there is no automatic retry.
- AD actions may start immediately. A scheduled earliest-start field is not a hold. Shared profile changes can affect devices outside the selected list. Submitted results require live readback and job/workflow monitoring.
- Three AD guide chapters, example CSVs and a connected pilot worksheet. Existing environment/workflow/profile setup, agent deployment, new profile creation and unsupported settings use the Quest web-console handoff.
- AD tests use real installed command metadata and a real device SDK model, with the service boundary replaced by fixtures. They do not invoke compiled vendor mutation cmdlets or certify their backend behavior.

## Added in RC1

- **Operations Center:** 174 catalog entries: 109 creation commands and 65 update commands. 104 creation routes are enabled with OdmApi 2.1.401; five routes remain clearly marked web handoffs: address rewriting can execute immediately and replace fixed-ID tasks, and four SharePoint constructors lack an explicit scheduling parameter (single site/web/list mapping and object removal). Older modules show unavailable operations with a reason.
- Fields use the loaded module's choices and parameter descriptions. Optional creation fields use vendor defaults; optional update fields preserve current settings. No arbitrary PowerShell expression execution is offered.
- New tasks remain held. Existing tasks can be updated or scheduled with an explicit future ISO timestamp, or returned to hold. Task updates require the exact ID and task type; active tasks are blocked. Read back the resulting settings before relying on the update.
- Typed inventories and exact object-ID lookup for Power Platform, Power BI, public folders and existing workloads.
- Collection rename, task-to-template save, template import/export, current event acknowledgement and report metadata inventory. Each action has a preview; service changes require the write gates.
- Preview expiry, one-use tokens, context/file/template/task-state binding, file hashes, redacted reports and no automatic retry after uncertain writes.
- In-app guides, operator HTML manual, native mapping examples, pilot checklist and a route-by-route coverage table.
- Original CSV batching, Task Factory, memberships, task lifecycle, diagnostics, themes, profiles, logs and Mapping Collision Utility remain available.

## Corrections from the audit

Empty organization results and readiness lists now normalize correctly. Task stop forwards its delay option. Task reporting uses the selected workload, and account Task Factory enforces the Accounts workload. CSV parsing rejects duplicate/blank headers and wrong field counts while preserving quoted commas and multiline values. Credential sanitization handles short JWT headers and JSON embedded in templates. Reports get unique filenames. CSV action footers remain usable at minimum window size; new fields and dropdowns use readable theme colors. Context changes clear the new forms and previews.

Several original test failures were test-harness issues: function import scope, stale state fixtures, invalid assumptions about WPF freezing, and an inaccessible temporary-file location. Tests now exercise the production functions and real WPF layout. These repairs are documented separately from production fixes in `AUDIT_REPORT.md`.

## Remaining Quest web-console work

Organization/project administration, tenant onboarding and consent, roles/subscriptions/licenses, workload setup, address rewriting, full report-file downloads, vendor-only dashboards and wizard settings not exposed by the inspected public module remain web-console actions. The Guides button opens Quest; it does not share authentication or perform those actions. Native API coverage is not equivalent to every web feature. The inspected module is 2.1.401; this does not assert it is the newest published module.

## Validation

Run the documented offline suites before release. `Tests/Run-RcAcceptance.ps1` starts isolated native-module tests so their network fixtures cannot contaminate the ordinary acceptance suite. Pass the installed module manifest explicitly when validating 2.1.401:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Tests\Run-RcAcceptance.ps1 -ModuleManifest 'C:\path\to\OdmApi\2.1.401\OdmApi.psd1'
pwsh.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Tests\Run-RcAcceptance.ps1 -ModuleManifest 'C:\path\to\OdmApi\2.1.401\OdmApi.psd1'
python .\Tests\StaticValidation.py
python .\Tests\RuntimeSourceAudit.py
python .\MappingCollisionUtility\Tests\StaticValidation.py
```

No tests should be interpreted as a guarantee of defect-free behavior. Connected pilot results, approval of remaining gaps, code signing and a fresh signed-package manifest are the remaining production release gates. Use `Samples/PilotAcceptance.csv` to record results. See `ROLLBACK.md`, `SUPPORT.md`, `NOTICE.md`, `WORKLOAD_GUIDE.txt` and the historical notes under `docs/preview7-history` as needed.
