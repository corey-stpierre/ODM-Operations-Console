#!/usr/bin/env python3
"""Platform-neutral release validation for Quest ODM Operations Console 1.1.0-preview.6."""
from __future__ import annotations
import csv, json, re, subprocess, sys, xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path
from typing import Iterable
from pygments import lex
from pygments.lexers.shell import PowerShellLexer
from pygments.token import Token

ROOT=Path(__file__).resolve().parents[1]
EXPECTED_VERSION='1.1.0-preview.6'
XAML_NS='http://schemas.microsoft.com/winfx/2006/xaml'
REQUIRED_FILES=[
 'QuestODMConsole.ps1','QuestODMConsole.UI.ps1','VERSION.txt','README.md','RELEASE_NOTES.md','ROLLBACK.md','SUPPORT.md','NOTICE.md','CHANGELOG.md','FEATURE_MATRIX.md','AUDIT_REPORT.md','FILES_CHANGED.md','BUILD_VALIDATION.txt','V1_RELEASE_VALIDATION.json','SIGNING_STATUS.txt','MANIFEST.sha256',
 'Start-QuestODMConsole.cmd','Start-QuestODMConsole-WindowsPowerShell.cmd','Start-QuestODMConsole-PowerShell7.cmd',
 'Resources/QuestODMConsole.xaml','Resources/QuestSoftwareLogo.png','Resources/BRANDING.md','Config/QuestODMConsole.settings.json','Config/BuildInfo.json','Config/OdmApiCompatibility.json',
 'Engine/QuestODMConsole.Engine.psm1','Engine/Common.ps1','Engine/Governance.ps1','Engine/Context.ps1','Engine/Inventory.ps1','Engine/Membership.ps1','Engine/Accounts.ps1','Engine/Bulk.ps1','Engine/TaskFactory.ps1','Engine/LocalPreflight.ps1',
 'Tools/Invoke-CodeSigning.ps1','Tools/Test-CodeSigning.ps1','Tools/New-ReleaseManifest.ps1','Shared/LogMaintenance.ps1',
 'Tests/Run-StaticValidation.ps1','Tests/Run-V1BrandingTests.ps1','Tests/StaticValidation.py','Tests/RuntimeSourceAudit.py','Tests/Run-V1Acceptance.ps1','Tests/Run-V1GovernanceTests.ps1','Tests/Run-MockEngineTests.ps1','Tests/Run-WpfSmokeTest.ps1','Tests/Run-InstalledOdmApiPreflight.ps1','Tests/Run-ParserRegressionTests.ps1','Tests/Run-CollectionNormalizationTests.ps1','Tests/Run-WorkerBoundaryTests.ps1','Tests/Run-UiInitialStateTests.ps1','Tests/Run-OverviewPersistenceTests.ps1','Tests/Run-LogMaintenanceTests.ps1','Tests/Run-UiCallbackScopeTests.ps1','Tests/README.md',
 'Tests/Mocks/OdmApi/2.1.396/OdmApi.psd1','Tests/Mocks/OdmApi/2.1.396/OdmApi.psm1','Samples/README.md','Logs/.gitkeep',
 'MappingCollisionUtility/MappingCollisionUtility.ps1','MappingCollisionUtility/MappingCollisionUtility.UI.ps1','MappingCollisionUtility/Start-MappingCollisionUtility.cmd','MappingCollisionUtility/README.md',
 'MappingCollisionUtility/Engine/MappingCollisionEngine.psm1','MappingCollisionUtility/Collectors/Export-SourceIdentityInventory.ps1','MappingCollisionUtility/Collectors/Export-TargetIdentityInventory.ps1',
 'MappingCollisionUtility/Resources/MappingCollisionUtility.xaml','MappingCollisionUtility/Samples/SourceInventory.Sample.csv','MappingCollisionUtility/Samples/TargetInventory.Sample.csv','MappingCollisionUtility/Samples/README.md',
 'MappingCollisionUtility/Tests/Run-MappingCollisionTests.ps1','MappingCollisionUtility/Tests/Run-WpfSmokeTest.ps1','MappingCollisionUtility/Tests/StaticValidation.py','MappingCollisionUtility/Tests/README.md'
]
LEGACY=[
 'QuestODM-RemoveUsersFromTasks.ps1','QuestODM-Create-BatchedTasks-UsersFromCSV.ps1','QuestODM-CreateCollections-AndAddUsers.ps1','QuestODM-Create-TemplateTasks-FromCollectionCsv.ps1','QuestODM-Delete-AllTasks.ps1','QuestODM-DeleteTasks.ps1','QuestODM-DeleteTasks-Ready.ps1','QuestODM-Export-AllCollections.ps1','QuestODM-GetObjectInfo.ps1','QuestODM-GetTasks.ps1','QuestODM-GetUsers_Collections.ps1','QuestODM-GetUsers_Tasks.ps1','QuestODM-Preflight-Remove-MmpcEnrollmentFlag.ps1','QuestODM-Remove-CollectionsFromCsv.ps1','QuestODM-Remove-OdmUsersFromCollections.ps1','QuestODM-Remove-UsersFromBatchedTasks-FromCSV.ps1'
]
EXPECTED_SETTINGS={'Region','ReportDirectory','NotifyRecipients','LastOrganizationId','MailFrom','OneDriveFilterItems','ExistingTaskBehavior','MailSuffix','OneDriveSuffix','MeetingLinkSuffix','MailboxSwitchSuffix','MailPlacement','OneDrivePlacement','MeetingLinkPlacement','MailboxSwitchPlacement','SafeModeOnStartup','TaskDetailsAutoRefresh','TaskDetailsRefreshSeconds','SelectedProfileName','ReadinessCheckOnlineModuleVersion','Theme','LogRetentionDays'}
SAMPLE_HEADERS={
 'Users.csv':['SourceUPN'],'CollectionsAndUsers.csv':['CollectionName','SourceUPN'],'TaskRemovalPlan.csv':['TaskId','TaskName','ObjectId','SourceUPN'],'DeleteTasks.csv':['TaskName','TaskId'],'DeleteTasksAcrossProjects.csv':['TaskName','ProjectId','ProjectName','TaskId'],'RemoveCollections.csv':['CollectionName','CollectionId'],'TaskFactory.csv':['CollectionName','SourceUPN'],'ObjectLookup.csv':['SourceEmail'],'AccountDiscoveryByUPNTemplate.csv':['UserPrincipalName','Type'],'AccountDiscoveryByObjectIdTemplate.csv':['ObjectId','Type'],'AccountMappingByUPNTemplate.csv':['SourceUPN','TargetUPN','TargetDisplayName','TargetAlias','TargetPrimaryEmail','TargetFirstName','TargetLastName'],'AccountMappingByObjectIdTemplate.csv':['SourceObjectId','TargetObjectId'],'TaskReferences.csv':['TaskName','TaskId']
}
BULK_KEYS={'DiscoverAllAccounts','DiscoverAccountsFromCsv','MapAccountsFromCsv','CreateCollectionsAndAddUsers','RemoveUsersFromCollections','RemoveCollections','FindUserCollections','FindUserTasks','MatchObjectInfo','RemoveUsersFromTasksPlan','StartTasksFromCsv','StopTasksFromCsv','DeleteTasksFromCsv','DeleteTasksAcrossProjects','DeleteAllTasks','ExportTasks','ExportCollections'}

def read(p:Path)->str:return p.read_text(encoding='utf-8-sig')
def ps_files()->Iterable[Path]:
 for ext in ('*.ps1','*.psm1','*.psd1'):
  for p in sorted(ROOT.rglob(ext)):
   if 'LegacyScripts' not in p.parts: yield p

def balance(p:Path):
 errs=[]; stacks={'{':[],'(':[],'[':[]}; close={'}':'{',')':'(',']':'['}; line=col=1
 for tt,val in lex(read(p),PowerShellLexer()):
  if tt in Token.Error: errs.append(f'{p.relative_to(ROOT)}:{line}:{col}: lexer error {val!r}')
  ignored=tt in Token.Comment or tt in Token.String
  for ch in val:
   if not ignored:
    if ch in stacks: stacks[ch].append((line,col))
    elif ch in close:
     op=close[ch]
     if stacks[op]: stacks[op].pop()
     else: errs.append(f'{p.relative_to(ROOT)}:{line}:{col}: unmatched {ch}')
   if ch=='\n': line+=1; col=1
   else: col+=1
 for op,positions in stacks.items():
  for ln,cl in positions: errs.append(f'{p.relative_to(ROOT)}:{ln}:{cl}: unmatched {op}')
 return errs

def main():
 fail=[]; checks=[]
 for rel in REQUIRED_FILES:
  if not (ROOT/rel).is_file(): fail.append('Missing required file: '+rel)
 checks.append(f'Required files: {len(REQUIRED_FILES)}')
 for name in LEGACY:
  if not (ROOT/'LegacyScripts'/name).is_file(): fail.append('Missing legacy script: '+name)
 checks.append(f'Legacy scripts: {len(LEGACY)}')
 if (ROOT/'VERSION.txt').is_file() and read(ROOT/'VERSION.txt').strip()!=EXPECTED_VERSION: fail.append(f'VERSION.txt is not {EXPECTED_VERSION}')
 for rel in ('Config/BuildInfo.json','Config/OdmApiCompatibility.json','Config/QuestODMConsole.settings.json','V1_RELEASE_VALIDATION.json'):
  try: json.loads(read(ROOT/rel))
  except Exception as e: fail.append(f'Invalid JSON {rel}: {e}')
 try:
  settings=json.loads(read(ROOT/'Config/QuestODMConsole.settings.json'))
  keys=set(settings)
  if keys!=EXPECTED_SETTINGS:
   if EXPECTED_SETTINGS-keys: fail.append('Missing settings: '+', '.join(sorted(EXPECTED_SETTINGS-keys)))
   if keys-EXPECTED_SETTINGS: fail.append('Unexpected settings: '+', '.join(sorted(keys-EXPECTED_SETTINGS)))
  if settings.get('LogRetentionDays') not in (7,14,30,60,90,180): fail.append('Default LogRetentionDays is not an allowed retention value')
 except Exception: pass
 try:
  policy=json.loads(read(ROOT/'Config/OdmApiCompatibility.json'))
  if policy.get('ConsoleVersion')!=EXPECTED_VERSION: fail.append('Compatibility policy console version mismatch')
  if policy.get('MinimumOdmApiVersion')!='2.1.396': fail.append('Compatibility minimum version mismatch')
  if '2.1.396' not in policy.get('ValidatedOdmApiVersions',[]): fail.append('Validated OdmApi 2.1.396 missing')
  for group in ('Core','Membership','TaskLifecycle','AccountDiscovery','TaskFactory','Readiness','TaskMonitoring','Reporting'):
   if not policy.get('RequiredCommands',{}).get(group): fail.append('Compatibility command group missing: '+group)
 except Exception: pass

 names=[]; resources=set()
 try:
  tree=ET.parse(ROOT/'Resources/QuestODMConsole.xaml')
  for el in tree.iter():
   for k,v in el.attrib.items():
    if k.endswith('}Name') or k=='Name': names.append(v)
    if k.endswith('}Key') or k=='Key': resources.add(v)
  dup=[n for n,c in Counter(names).items() if c>1]
  if dup: fail.append('Duplicate XAML controls: '+', '.join(sorted(dup)))
 except Exception as e: fail.append('XAML parse failure: '+str(e)); tree=None
 xaml=read(ROOT/'Resources/QuestODMConsole.xaml') if (ROOT/'Resources/QuestODMConsole.xaml').exists() else ''
 for resource_kind,ref in re.findall(r'\{(StaticResource|DynamicResource)\s+([^}]+)\}',xaml):
  if ref not in resources: fail.append(f'Unresolved {resource_kind}: '+ref)
 for control in ('SafeModeStatusText','ToggleSafeModeButton','TaskDetailsTextBox','TaskEventsGrid','RunReadinessButton','ReadinessGrid','CreateSupportBundleButton','AboutTextBox','OperationHistoryGrid','ProfileCombo','QuestLogoImage','LaunchMappingCollisionUtilityButton','OpenMappingCollisionUtilityFolderButton','MappingCollisionUtilityStatusText','TaskCsvActionCard','TaskCsvActionFooter','TaskCsvInputScrollViewer','CollectionCsvActionCard','CollectionCsvActionFooter','CollectionCsvInputScrollViewer','AddCsvUsersToTaskButton','RemoveCsvUsersFromTaskButton','AddCsvUsersToCollectionButton','RemoveCsvUsersFromCollectionButton','DarkModeCheckBox','LogRetentionDaysCombo','CleanOldLogsButton','ClearStoredLogsButton','LogRetentionStatusText'):
  if control not in names: fail.append('Missing V1 XAML control: '+control)
 checks.append(f'XAML controls: {len(names)}')
 required_theme_resources={'PrimaryBrush','PrimaryDarkBrush','MetricValueBrush','AccentBrush','AccentLightBrush','AccentTextBrush','OnPrimaryBrush','SurfaceBrush','InputSurfaceBrush','BackgroundBrush','SubtleSurfaceBrush','StatusSurfaceBrush','BorderBrush','TextBrush','HeadingBrush','MutedBrush','GridLineBrush','GridAlternateBrush','GridHeaderBrush','GridHeaderTextBrush','SelectionBrush','SelectionTextBrush','DangerBrush','DangerLightBrush','DangerBorderBrush','DangerTextBrush','SuccessBrush','SuccessLightBrush','WarningBrush','WarningLightBrush','WarningBorderBrush','WarningTextBrush','NeutralDotBrush'}
 missing_theme_resources=sorted(required_theme_resources-resources)
 if missing_theme_resources: fail.append('Missing theme resources: '+', '.join(missing_theme_resources))
 if tree is not None:
  presentation_ns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'
  options_ns='http://schemas.microsoft.com/winfx/2006/xaml/presentation/options'
  brush_elements={el.attrib.get('{'+XAML_NS+'}Key'):el for el in tree.iter() if el.tag=='{'+presentation_ns+'}SolidColorBrush' and el.attrib.get('{'+XAML_NS+'}Key')}
  for resource_name in sorted(required_theme_resources):
   brush=brush_elements.get(resource_name)
   if brush is None: continue
   if brush.attrib.get('{'+options_ns+'}Freeze')!='False':
    fail.append(f'Theme brush is not explicitly unfrozen: {resource_name}')
 for marker,label in (
  ('Background="{DynamicResource BackgroundBrush}" Foreground="{DynamicResource TextBrush}"','Window does not use dynamic theme brushes'),
  ('<Setter Property="TextElement.Foreground" Value="{DynamicResource TextBrush}" />','Card text does not override selected-tab foreground inheritance'),
  ('Text="Mapping collision utility" FontSize="15" FontWeight="SemiBold" Foreground="{DynamicResource TextBrush}"','Mapping Collision Utility card title does not use the readable theme foreground'),
  ('x:Name="DarkModeCheckBox"','Dark mode toggle is missing'),
  ('x:Name="LogRetentionDaysCombo"','Log-retention selector is missing'),
  ('x:Name="ClearStoredLogsButton"','Stored-log clear action is missing'),
 ):
  if marker not in xaml: fail.append(label)
 # CSV membership actions must remain visible at constrained window heights. The
 # input fields may scroll, but the execute checkbox and Add/Remove buttons are
 # pinned in a bottom-docked footer.
 if tree is not None:
  name_attr='{'+XAML_NS+'}Name'
  named={el.attrib.get(name_attr):el for el in tree.iter() if el.attrib.get(name_attr)}
  for prefix,expected in (
   ('Task',('TaskCsvExecuteCheckBox','AddCsvUsersToTaskButton','RemoveCsvUsersFromTaskButton')),
   ('Collection',('CollectionCsvExecuteCheckBox','AddCsvUsersToCollectionButton','RemoveCsvUsersFromCollectionButton')),
  ):
   card=named.get(prefix+'CsvActionCard'); footer=named.get(prefix+'CsvActionFooter'); scroller=named.get(prefix+'CsvInputScrollViewer')
   if card is None or footer is None or scroller is None:
    fail.append(prefix+' CSV membership action layout container is missing')
    continue
   if footer.attrib.get('DockPanel.Dock')!='Bottom': fail.append(prefix+' CSV membership action footer is not bottom-docked')
   footer_names={el.attrib.get(name_attr) for el in footer.iter() if el.attrib.get(name_attr)}
   for control in expected:
    if control not in footer_names: fail.append(f'{control} is not inside the pinned {prefix.lower()} CSV action footer')
   if scroller.attrib.get('VerticalScrollBarVisibility')!='Auto': fail.append(prefix+' CSV input area is not vertically scrollable')
   card_names={el.attrib.get(name_attr) for el in card.iter() if el.attrib.get(name_attr)}
   if prefix+'CsvActionFooter' not in card_names or prefix+'CsvInputScrollViewer' not in card_names:
    fail.append(prefix+' CSV action card does not contain both the pinned footer and scrollable inputs')
 # Branding and accepted V1.0.0 tab-layout regression.
 if 'QuestLogoImage' not in names: fail.append('Quest logo control missing from XAML')
 if 'Text="Q" Foreground="White" FontSize="30"' in xaml: fail.append('Legacy Q header tile remains')
 if 'Padding" Value="15,8"' not in xaml or 'Margin" Value="0,0,6,0"' not in xaml or 'CornerRadius="16"' not in xaml:
  fail.append('Global TabItem style no longer matches the accepted V1.0.0 layout')
 tab_match=re.search(r'<Style TargetType="TabItem">(.*?)</Style>',xaml,re.S)
 if not tab_match: fail.append('Global TabItem style missing')
 elif 'MinHeight' in tab_match.group(1) or 'CornerRadius="19"' in tab_match.group(1): fail.append('Rejected pill-tab geometry is present')
 logo=ROOT/'Resources/QuestSoftwareLogo.png'
 if logo.is_file():
  data=logo.read_bytes()
  if not data.startswith(b'\x89PNG\r\n\x1a\n'): fail.append('QuestSoftwareLogo.png has an invalid PNG signature')

 ui=read(ROOT/'QuestODMConsole.UI.ps1'); engine=read(ROOT/'Engine/QuestODMConsole.Engine.psm1'); governance=read(ROOT/'Engine/Governance.ps1')
 refs=set(re.findall(r"Get-UiControl\s+(?:-Name\s+)?['\"]([^'\"]+)['\"]",ui,re.I))
 missing=sorted(refs-set(names))
 if missing: fail.append('UI controls absent from XAML: '+', '.join(missing))
 uiops=set(re.findall(r"(?:Invoke-EngineAsync|Invoke-EngineSync)\s+-Operation\s+['\"]([^'\"]+)['\"]",ui,re.I))
 for op in sorted(uiops):
  if not re.search(rf"(?m)^\s*'{re.escape(op)}'\s*\{{",engine): fail.append('UI operation missing dispatcher route: '+op)
 checks.append(f'UI controls/operations: {len(refs)}/{len(uiops)}')
 for marker in ('Test-MappingCollisionUtilityAvailable','Start-MappingCollisionUtility','MappingCollisionUtilityBootstrapPath','-STA'):
  if marker not in ui: fail.append('Mapping Collision Utility launcher marker missing: '+marker)
 theme_markers=(
  'function Get-UiThemePalette','function Set-UiThemeBrush','function Set-UiTheme',
  "Get-SettingValue -Name 'Theme' -Default 'Light'",'Theme                     = [string]$script:State.Theme',
  "Get-UiControl 'DarkModeCheckBox'","Set-UiTheme -Theme 'Dark'","Set-UiTheme -Theme 'Light'",
  'CloneCurrentValue','[System.Collections.IDictionary]$script:Window.Resources',
 )
 for marker in theme_markers:
  if marker not in ui: fail.append('Main-console theme marker missing: '+marker)
 if re.search(r'\$script:Window\.Resources\s*\[\s*\$Name\s*\]\s*=',ui):
  fail.append('Unsafe direct ResourceDictionary indexer assignment remains in the theme setter')
 if '.GetNewClosure()' in ui:
  fail.append('Production UI callbacks still use GetNewClosure and can lose script-scope helper resolution')
 for marker in (
  '$script:State.BulkUiContext = [pscustomobject]@{',
  'Get-BulkResultRows -Data $data',
  '-OnSuccess $successCallback -OnFailure $failureCallback',
  '$script:State.ProfileLoadContext',
  '$script:State.OdmApiModuleActionContext',
  '$button.Tag = [pscustomobject]@{ Action = $action; ErrorText = $Text; Dialog = $dialog }',
  'The underlying operation was not rolled back. Verify the generated report and Quest state before retrying an executed write.',
 ):
  if marker not in ui: fail.append('UI callback-scope marker missing: '+marker)
 log_markers=(
  r'Shared\LogMaintenance.ps1','function Get-UiLogRetentionDays','function Set-UiLogMaintenanceStatus','function Invoke-UiLogMaintenanceFromUi',
  'Invoke-QOdmLogMaintenance -Application MainConsole',"Get-UiControl 'CleanOldLogsButton'","Get-UiControl 'ClearStoredLogsButton'",
  "Get-SettingValue -Name 'LogRetentionDays' -Default 30",'LogRetentionDays           = Get-UiLogRetentionDays',
 )
 for marker in log_markers:
  if marker not in ui: fail.append('Main-console log-maintenance marker missing: '+marker)
 helper=read(ROOT/'Shared/LogMaintenance.ps1') if (ROOT/'Shared/LogMaintenance.ps1').is_file() else ''
 for marker in ('function Invoke-QOdmLogMaintenance','ClearHistorical','OperationHistory.jsonl','QuestODMConsole-bootstrap.log','CurrentSessionLogPath'):
  if marker not in helper: fail.append('Shared log-maintenance helper marker missing: '+marker)
 csv_membership_markers=(
  "function Complete-UiCsvMembershipAction",
  "Complete-UiCsvMembershipAction -EntityType Task -GridName 'TaskMembersGrid'",
  "Complete-UiCsvMembershipAction -EntityType Collection -GridName 'CollectionMembersGrid'",
  "& $taskCsvAction 'AddUsersToEntityFromCsv' 'Add'",
  "& $taskCsvAction 'RemoveUsersFromEntityFromCsv' 'Remove'",
  "& $collectionCsvAction 'AddUsersToEntityFromCsv' 'Add'",
  "& $collectionCsvAction 'RemoveUsersFromEntityFromCsv' 'Remove'",
  "No API changes were submitted",
  "CommandSucceededCount",
  "VerifiedCount",
 )
 for marker in csv_membership_markers:
  if marker not in ui: fail.append('CSV membership action marker missing: '+marker)
 utility_validator=ROOT/'MappingCollisionUtility/Tests/StaticValidation.py'
 if utility_validator.is_file():
  utility_result=subprocess.run([sys.executable,str(utility_validator)],cwd=str(ROOT),capture_output=True,text=True)
  if utility_result.returncode!=0:
   fail.append('Mapping Collision Utility static validation failed: '+(utility_result.stdout+utility_result.stderr).strip().replace('\n',' | '))
  else:
   checks.append('Mapping Collision Utility static validation: PASS')
 for key in BULK_KEYS:
  if f"Key='{key}'" not in engine and f'Key="{key}"' not in engine: fail.append('Bulk operation missing: '+key)

 runtime_files=[ROOT/'QuestODMConsole.ps1',ROOT/'QuestODMConsole.UI.ps1']+sorted((ROOT/'Engine').glob('*.ps1'))+sorted((ROOT/'Engine').glob('*.psm1'))+sorted((ROOT/'Shared').glob('*.ps1'))+sorted((ROOT/'Tools').glob('*.ps1'))
 combined='\n'.join(read(p) for p in runtime_files)
 markers={
  'Safe Mode confirmation':'ENABLE CHANGES','Compatibility policy':'Get-QOdmCompatibilityAssessment','Readiness':'Invoke-QOdmReadinessCheck','Operation history':'OperationHistory.jsonl','Support bundle':'New-QOdmSupportBundle','Task details':'Get-QOdmTaskDetails','Task error export':'New-QOdmTaskErrorLogExport','Profiles':'QuestODMConsole.profiles.json','About':'Get-QOdmBuildInfo','Signing':'Set-AuthenticodeSignature'
 }
 for label,marker in markers.items():
  if marker not in combined and marker not in xaml: fail.append(label+' marker missing: '+marker)
 if re.search(r'Integrated\s*Windows|UseIntegratedWindowsAuthentication|IntegratedAuth',combined+xaml,re.I): fail.append('Obsolete Integrated Windows authentication reference')
 for pat,msg in ((r'New-Object\s+(?:-TypeName\s+)?System\.Collections\.Generic\.List','Generic List must use CLR constructor'),(r'\(Get-SelectedGridItems[^\r\n]*\)\.Count','Unsafe selected-grid .Count'),(r'Get-OdmProjectWorkload[^\r\n]*-ProjectId\b','Unsupported workload ProjectId'),(r'Get-OdmTask\b[^\r\n]*-ProjectId\b','Unsupported task ProjectId')):
  if re.search(pat,combined,re.I): fail.append(msg)
 for p in ps_files(): fail.extend(balance(p))
 checks.append(f'PowerShell lexical files: {len(list(ps_files()))}')
 for p in ps_files():
  if p.read_bytes()[:3]!=b'\xef\xbb\xbf': fail.append('UTF-8 BOM missing: '+str(p.relative_to(ROOT)))
 for name,expected in SAMPLE_HEADERS.items():
  p=ROOT/'Samples'/name
  if not p.is_file(): fail.append('Missing sample: '+name); continue
  with p.open('r',encoding='utf-8-sig',newline='') as f:
   actual=next(csv.reader(f),[])
  if actual!=expected: fail.append(f'Sample header mismatch {name}: {actual}')
 checks.append(f'Samples: {len(SAMPLE_HEADERS)}')

 # local markdown links
 for p in ROOT.rglob('*.md'):
  text=read(p)
  for target in re.findall(r'\[[^\]]+\]\(([^)]+)\)',text):
   target=target.strip().split('#',1)[0]
   if not target or re.match(r'^(?:https?://|mailto:|#|sandbox:)',target,re.I): continue
   target=target.replace('\\','/')
   if not (p.parent/target).resolve().exists(): fail.append(f'Broken markdown link {p.relative_to(ROOT)} -> {target}')

 if '0.9.0-rc.7' in read(ROOT/'QuestODMConsole.ps1') or '0.9.0-rc.7' in ui: fail.append('Stale RC7 runtime version reference')
 if 'Run-RC7Acceptance.ps1' in read(ROOT/'README.md'): fail.append('README references obsolete RC7 acceptance')
 if (ROOT/'Tests/Run-RC7Acceptance.ps1').exists(): fail.append('Obsolete RC7 acceptance runner remains')
 if (ROOT/'RC7_RELEASE_VALIDATION.json').exists(): fail.append('Obsolete RC7 release validation remains')

 if fail:
  print('STATIC VALIDATION: FAIL')
  for x in fail: print(' - '+x)
  print('Checks attempted:')
  for x in checks: print(' - '+x)
  return 1
 print('STATIC VALIDATION: PASS')
 for x in checks: print(' - '+x)
 return 0
if __name__=='__main__': sys.exit(main())
