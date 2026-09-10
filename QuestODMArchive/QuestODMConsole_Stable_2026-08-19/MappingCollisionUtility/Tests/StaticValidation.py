#!/usr/bin/env python3
"""Platform-neutral validation for the Quest ODM Mapping Collision Utility."""
from __future__ import annotations

import csv
import re
import sys
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from pathlib import Path

from pygments import lex
from pygments.lexers.shell import PowerShellLexer
from pygments.token import Token

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = [
    'MappingCollisionUtility.ps1',
    'MappingCollisionUtility.UI.ps1',
    'Start-MappingCollisionUtility.cmd',
    'README.md',
    'Engine/MappingCollisionEngine.psm1',
    'Collectors/Export-SourceIdentityInventory.ps1',
    'Collectors/Export-TargetIdentityInventory.ps1',
    'Resources/MappingCollisionUtility.xaml',
    'Samples/SourceInventory.Sample.csv',
    'Samples/TargetInventory.Sample.csv',
    'Samples/README.md',
    'Tests/Run-MappingCollisionTests.ps1',
    'Tests/Run-WpfSmokeTest.ps1',
    'Tests/StaticValidation.py',
    'Tests/README.md',
]
REQUIRED_HEADERS = [
    'SchemaVersion','CollectorVersion','InventorySide','DirectoryType','EnvironmentName','TenantId','DomainName','CollectedAtUtc','ObjectType',
    'ObjectId','ObjectGuid','ObjectGuidBase64','ConsistencyGuid','ConsistencyGuidBase64','OnPremisesImmutableId','Sid','OnPremisesSecurityIdentifier',
    'DistinguishedName','DisplayName','UserPrincipalName','SamAccountName','Mail','MailNickname','PrimarySmtpAddress','ProxyAddresses','OtherMails',
    'SignInNames','TargetAddress','EmployeeId','AccountEnabled','UserType','IsGuest','CreatedDateTime'
]


def read(path: Path) -> str:
    return path.read_text(encoding='utf-8-sig')


def lexical_balance(path: Path) -> list[str]:
    errors: list[str] = []
    stacks = {'{': [], '(': [], '[': []}
    closing = {'}': '{', ')': '(', ']': '['}
    line = col = 1
    for token_type, value in lex(read(path), PowerShellLexer()):
        if token_type in Token.Error:
            errors.append(f'{path.relative_to(ROOT)}:{line}:{col}: lexer error {value!r}')
        ignored = token_type in Token.Comment or token_type in Token.String
        for char in value:
            if not ignored:
                if char in stacks:
                    stacks[char].append((line, col))
                elif char in closing:
                    opener = closing[char]
                    if stacks[opener]:
                        stacks[opener].pop()
                    else:
                        errors.append(f'{path.relative_to(ROOT)}:{line}:{col}: unmatched {char}')
            if char == '\n':
                line += 1
                col = 1
            else:
                col += 1
    for opener, positions in stacks.items():
        for line, col in positions:
            errors.append(f'{path.relative_to(ROOT)}:{line}:{col}: unmatched {opener}')
    return errors


def normalize_email(value: str) -> str:
    value = value.strip()
    if value.lower().startswith('smtp:'):
        value = value.split(':', 1)[1]
    return value.lower()


def normalize_alias(value: str) -> str:
    return value.strip().lower().split('\\')[-1]


def rows(path: Path) -> list[dict[str, str]]:
    with path.open(encoding='utf-8-sig', newline='') as handle:
        return list(csv.DictReader(handle))


def anchor_map(input_rows: list[dict[str, str]]) -> dict[tuple[str, str], set[str]]:
    result: dict[tuple[str, str], set[str]] = defaultdict(set)
    for row in input_rows:
        object_id = row['ObjectId'] or row['UserPrincipalName'] or row['DisplayName']
        for prop in ('UserPrincipalName','Mail','PrimarySmtpAddress','TargetAddress','OtherMails','SignInNames'):
            for value in re.split(r'[|;\r\n]+', row.get(prop, '')):
                normalized = normalize_email(value)
                if normalized:
                    result[('EmailAddress', normalized)].add(object_id)
        for proxy in re.split(r'[|;\r\n]+', row.get('ProxyAddresses', '')):
            proxy = proxy.strip()
            if not proxy:
                continue
            if proxy.lower().startswith('smtp:'):
                result[('EmailAddress', normalize_email(proxy))].add(object_id)
            elif proxy.lower().startswith('x500:'):
                result[('X500Address', proxy.split(':',1)[1].strip().lower())].add(object_id)
            elif proxy.lower().startswith('sip:'):
                result[('SipAddress', proxy.split(':',1)[1].strip().lower())].add(object_id)
        for prop in ('SamAccountName','MailNickname','EmployeeId'):
            normalized = normalize_alias(row.get(prop, ''))
            if normalized:
                result[('Alias' if prop != 'EmployeeId' else 'EmployeeId', normalized)].add(object_id)
        for prop in ('ObjectGuid','ConsistencyGuid'):
            normalized = row.get(prop, '').strip().lower()
            if normalized:
                result[(prop, normalized)].add(object_id)
        for prop in ('ObjectGuidBase64','ConsistencyGuidBase64','OnPremisesImmutableId'):
            normalized = row.get(prop, '').strip()
            if normalized:
                result[('ImmutableId', normalized)].add(object_id)
        for prop in ('Sid','OnPremisesSecurityIdentifier'):
            normalized = row.get(prop, '').strip().lower()
            if normalized:
                result[('SecurityId', normalized)].add(object_id)
    return result


def main() -> int:
    failures: list[str] = []
    checks: list[str] = []
    for relative in REQUIRED:
        if not (ROOT / relative).is_file():
            failures.append(f'Missing required file: {relative}')
    checks.append(f'Required files: {len(REQUIRED)}')

    xaml_path = ROOT / 'Resources/MappingCollisionUtility.xaml'
    names: list[str] = []
    resources: set[str] = set()
    try:
        tree = ET.parse(xaml_path)
        for element in tree.iter():
            for key, value in element.attrib.items():
                if key.endswith('}Name') or key == 'Name':
                    names.append(value)
                if key.endswith('}Key') or key == 'Key':
                    resources.add(value)
        duplicates = sorted(name for name, count in Counter(names).items() if count > 1)
        if duplicates:
            failures.append('Duplicate XAML names: ' + ', '.join(duplicates))
    except Exception as exc:
        failures.append(f'Utility XAML parse failure: {exc}')
    xaml = read(xaml_path) if xaml_path.is_file() else ''
    for resource_kind, reference in re.findall(r'\{(StaticResource|DynamicResource)\s+([^}]+)\}', xaml):
        if reference not in resources:
            failures.append(f'Unresolved utility {resource_kind}: {reference}')
    required_controls = {
        'MappingCollisionWindow','QuestLogoImage','ExportBothCollectorsButton','SaveSourceCollectorButton','SaveTargetCollectorButton',
        'SourceCsvPathBox','TargetCsvPathBox','OutputDirectoryBox','AnalyzeButton','ResultsTabControl','CollisionsGrid',
        'MappingCandidatesGrid','AmbiguousMappingsGrid','InventoryQualityGrid','UnmatchedSourceGrid','RunLogBox','BusyProgressBar','DarkModeCheckBox',
        'UtilityLogRetentionStatusText','UtilityLogRetentionDaysCombo','OpenUtilityLogsButton','CleanUtilityLogsButton','ClearUtilityStoredLogsButton','ClearRunLogViewButton'
    }
    missing_controls = sorted(required_controls - set(names))
    if missing_controls:
        failures.append('Missing utility controls: ' + ', '.join(missing_controls))
    checks.append(f'XAML controls: {len(names)}')
    required_theme_resources = {
        'PrimaryBrush','PrimaryDarkBrush','MetricValueBrush','AccentBrush','AccentLightBrush','AccentTextBrush','OnPrimaryBrush',
        'SurfaceBrush','InputSurfaceBrush','BackgroundBrush','BorderBrush','TextBrush','HeadingBrush','MutedBrush','GridLineBrush',
        'GridAlternateBrush','GridHeaderBrush','GridHeaderTextBrush','SelectionBrush','SelectionTextBrush','DangerBrush','WarningBrush',
        'WarningLightBrush','WarningBorderBrush','WarningTextBrush','SuccessBrush'
    }
    missing_theme_resources = sorted(required_theme_resources - resources)
    if missing_theme_resources:
        failures.append('Missing utility theme resources: ' + ', '.join(missing_theme_resources))
    if 'tree' in locals():
        presentation_ns = 'http://schemas.microsoft.com/winfx/2006/xaml/presentation'
        xaml_ns = 'http://schemas.microsoft.com/winfx/2006/xaml'
        options_ns = 'http://schemas.microsoft.com/winfx/2006/xaml/presentation/options'
        brush_elements = {element.attrib.get('{'+xaml_ns+'}Key'): element for element in tree.iter() if element.tag == '{'+presentation_ns+'}SolidColorBrush' and element.attrib.get('{'+xaml_ns+'}Key')}
        for resource_name in sorted(required_theme_resources):
            brush = brush_elements.get(resource_name)
            if brush is not None and brush.attrib.get('{'+options_ns+'}Freeze') != 'False':
                failures.append(f'Utility theme brush is not explicitly unfrozen: {resource_name}')
    for marker, label in (
        ('Background="{DynamicResource BackgroundBrush}" Foreground="{DynamicResource TextBrush}"', 'Utility window does not use dynamic theme brushes'),
        ('<Setter Property="TextElement.Foreground" Value="{DynamicResource TextBrush}" />', 'Utility cards do not use the theme foreground'),
        ('x:Name="DarkModeCheckBox"', 'Utility dark mode toggle is missing'),
        ('x:Name="UtilityLogRetentionDaysCombo"', 'Utility log-retention selector is missing'),
        ('x:Name="ClearUtilityStoredLogsButton"', 'Utility stored-log clear action is missing'),
    ):
        if marker not in xaml:
            failures.append(label)

    ui = read(ROOT / 'MappingCollisionUtility.UI.ps1') if (ROOT / 'MappingCollisionUtility.UI.ps1').is_file() else ''
    ui_refs = set(re.findall(r"Get-McuUiControl\s+(?:-Name\s+)?['\"]([^'\"]+)['\"]", ui, re.I))
    missing_refs = sorted(ui_refs - set(names))
    if missing_refs:
        failures.append('Utility UI references absent from XAML: ' + ', '.join(missing_refs))
    checks.append(f'UI control references: {len(ui_refs)}')
    for marker in (
        'function Get-McuThemePalette','function Set-McuThemeBrush','function Set-McuTheme','function Get-McuSavedTheme','function Save-McuUiSettings',
        "$script:SettingsPath = Join-Path $script:ConfigPath 'MappingCollisionUtility.settings.json'",
        r"$script:ParentConsoleSettingsPath = Join-Path (Split-Path -Parent $script:DataRoot) 'Config\QuestODMConsole.settings.json'",
        "Get-McuUiControl 'DarkModeCheckBox'","Set-McuTheme -Theme 'Dark'","Set-McuTheme -Theme 'Light'",
        'CloneCurrentValue','[System.Collections.IDictionary]$script:Window.Resources',
        r'Shared\LogMaintenance.ps1','function Get-McuLogRetentionDays','function Set-McuLogMaintenanceStatus','function Invoke-McuLogMaintenanceFromUi',
        'Invoke-QOdmLogMaintenance -Application MappingCollisionUtility',"Get-McuUiControl 'CleanUtilityLogsButton'","Get-McuUiControl 'ClearUtilityStoredLogsButton'",
    ):
        if marker not in ui:
            failures.append(f'Utility theme marker missing: {marker}')

    if re.search(r'\$script:Window\.Resources\s*\[\s*\$Name\s*\]\s*=', ui):
        failures.append('Unsafe direct ResourceDictionary indexer assignment remains in the utility theme setter')

    engine = read(ROOT / 'Engine/MappingCollisionEngine.psm1') if (ROOT / 'Engine/MappingCollisionEngine.psm1').is_file() else ''
    if engine.count('[AllowEmptyCollection()][object[]]$Rows') < 2:
        failures.append('Mapping report row parameters do not permit legitimate empty collections')
    smtp_trim_pattern = "if ($text -match '^(?i)smtp:') { $text = $text.Substring($text.IndexOf(':') + 1).Trim() }"
    if engine.count(smtp_trim_pattern) < 2:
        failures.append('SMTP normalization and validation do not both trim whitespace after the prefix')
    for marker in ('function Invoke-MappingCollisionAnalysis','CollisionDetails.csv','MappingCandidates.csv','AmbiguousMappings.csv','InventoryQualityIssues.csv','UnmatchedSourceObjects.csv','RunManifest.json','MappingCollisionSummary.html','ReportFiles=$reportFiles','$anchorCapableFields',
                   "if ($spec.Kind -eq 'Email' -and -not (Test-McuEmailLike -Value $rawValue)) { continue }"):
        if marker not in engine:
            failures.append(f'Engine marker missing: {marker}')
    bootstrap = read(ROOT / 'MappingCollisionUtility.ps1') if (ROOT / 'MappingCollisionUtility.ps1').is_file() else ''
    for marker in ('Test-McuBootstrapSyntax','Test-McuBootstrapXaml','-STA','MappingCollisionUtility.UI.ps1'):
        if marker not in bootstrap:
            failures.append(f'Bootstrap marker missing: {marker}')

    source_collector = read(ROOT / 'Collectors/Export-SourceIdentityInventory.ps1')
    target_collector = read(ROOT / 'Collectors/Export-TargetIdentityInventory.ps1')
    if "$inventorySide = 'Source'" not in source_collector:
        failures.append('Source collector is not labeled Source.')
    if "$inventorySide = 'Target'" not in target_collector:
        failures.append('Target collector is not labeled Target.')
    for collector_name, collector in (('Source', source_collector), ('Target', target_collector)):
        for marker in ('Get-ADUser','Connect-MgGraph','Invoke-MgGraphRequest','Directory.Read.All','proxyAddresses','mS-DS-ConsistencyGuid','onPremisesImmutableId','Export-Csv','CsvSha256'):
            if marker not in collector:
                failures.append(f'{collector_name} collector marker missing: {marker}')
    normalized_source = source_collector.replace("$inventorySide = 'Source'", "$inventorySide = '<SIDE>'")
    normalized_target = target_collector.replace("$inventorySide = 'Target'", "$inventorySide = '<SIDE>'")
    if normalized_source != normalized_target:
        failures.append('Source and target collectors differ by more than the inventory-side label.')

    ps_paths = sorted(ROOT.rglob('*.ps1')) + sorted(ROOT.rglob('*.psm1'))
    cardinality_pattern = re.compile(r'(?im)^\s*return\s+,\s*(?:\$[^\r\n]*\.ToArray\(\)|@\()')
    for path in ps_paths:
        if not path.read_bytes().startswith(b'\xef\xbb\xbf'):
            failures.append(f'PowerShell file lacks UTF-8 BOM: {path.relative_to(ROOT)}')
        text = read(path)
        if cardinality_pattern.search(text):
            failures.append(f'Unary-comma collection return can create nested arrays: {path.relative_to(ROOT)}')
        failures.extend(lexical_balance(path))
    checks.append(f'PowerShell lexical files: {len(ps_paths)}')
    checks.append('Collection-return cardinality regression guard: PASS')

    source_path = ROOT / 'Samples/SourceInventory.Sample.csv'
    target_path = ROOT / 'Samples/TargetInventory.Sample.csv'
    source_rows = rows(source_path)
    target_rows = rows(target_path)
    for side, input_rows in (('Source', source_rows), ('Target', target_rows)):
        if len(input_rows) != 8:
            failures.append(f'{side} sample does not contain eight rows.')
        if input_rows and list(input_rows[0]) != REQUIRED_HEADERS:
            failures.append(f'{side} sample headers do not match collector schema.')
        if any(row['InventorySide'] != side for row in input_rows):
            failures.append(f'{side} sample contains an incorrect InventorySide label.')
    source_anchors = anchor_map(source_rows)
    target_anchors = anchor_map(target_rows)
    if not any(len(objects) > 1 for objects in source_anchors.values()):
        failures.append('Source sample contains no internal duplicate anchor.')
    if not any(len(objects) > 1 for objects in target_anchors.values()):
        failures.append('Target sample contains no internal duplicate anchor.')
    candidate_targets: dict[str, set[str]] = defaultdict(set)
    target_claims: dict[str, set[str]] = defaultdict(set)
    for key, source_ids in source_anchors.items():
        for source_id in source_ids:
            for target_id in target_anchors.get(key, set()):
                candidate_targets[source_id].add(target_id)
                target_claims[target_id].add(source_id)
    if not any(len(targets) > 1 for targets in candidate_targets.values()):
        failures.append('Sample data contains no one-source-to-multiple-target scenario.')
    if not any(len(sources) > 1 for sources in target_claims.values()):
        failures.append('Sample data contains no multiple-source-to-one-target scenario.')
    dave_source = next((row for row in source_rows if row['UserPrincipalName'] == 'dave@source.example'), None)
    if not dave_source or len(candidate_targets.get(dave_source['ObjectId'], set())) != 2:
        failures.append('Known Dave split-anchor scenario does not resolve to exactly two targets.')
    carol_source = next((row for row in source_rows if row['UserPrincipalName'] == 'carol@source.example'), None)
    carol_target = next((row for row in target_rows if row['UserPrincipalName'] == 'carol@target.example'), None)
    if not carol_source or not carol_target or carol_source['ConsistencyGuidBase64'] != carol_target['OnPremisesImmutableId']:
        failures.append('Known immutable-ID sample scenario is missing.')
    checks.append(f'Sample rows: {len(source_rows)}/{len(target_rows)}')

    if failures:
        print('MAPPING COLLISION STATIC VALIDATION: FAIL')
        for failure in failures:
            print(' - ' + failure)
        return 1
    print('MAPPING COLLISION STATIC VALIDATION: PASS')
    for check in checks:
        print(' - ' + check)
    return 0


if __name__ == '__main__':
    sys.exit(main())
