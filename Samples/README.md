# Sample CSV Files

All identities and GUIDs are placeholders.

| File | Workflow |
|---|---|
| `AccountDiscoveryByUPNTemplate.csv` | Quest discovery by `UserPrincipalName,Type`. |
| `AccountDiscoveryByObjectIdTemplate.csv` | Quest discovery by `ObjectId,Type`. |
| `AccountMappingByUPNTemplate.csv` | Quest account mapping by `SourceUPN,TargetUPN`, with optional target fields. |
| `AccountMappingByObjectIdTemplate.csv` | Quest account mapping by `SourceObjectId,TargetObjectId`. |
| `TaskReferences.csv` | Start, stop, or delete tasks by exact ID or unambiguous exact name. |
| `Users.csv` | Generic user membership input. |
| `CollectionsAndUsers.csv` | Create collections/add users or remove users from collections. |
| `TaskRemovalPlan.csv` | Remove users from existing tasks. |
| `DeleteTasksAcrossProjects.csv` | Delete tasks while selecting project/workload context. |
| `RemoveCollections.csv` | Remove collections by ID or exact name. |
| `TaskFactory.csv` | Create direct or saved-template tasks per collection. |
| `ObjectLookup.csv` | Resolve source identities to ODM object information. |

Discovery `Type` must be `user` or `Microsoft 365 group`. Discovery and mapping filenames must contain ASCII characters only and must not exceed 15 MB. Use exactly one supported identifier schema per file.

Run write-capable workflows with **Execute changes** cleared first. Review the displayed rows and generated validation/report CSV before enabling execution.
