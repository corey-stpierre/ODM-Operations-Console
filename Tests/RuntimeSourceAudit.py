#!/usr/bin/env python3
"""Fast runtime-source audit used by the V1 build pipeline."""
from pathlib import Path
import re,sys,xml.etree.ElementTree as ET
ROOT=Path(__file__).resolve().parents[1]
RUNTIME=[ROOT/'QuestODMConsole.ps1',ROOT/'QuestODMConsole.UI.ps1']+sorted((ROOT/'Engine').glob('*.ps1'))+sorted((ROOT/'Engine').glob('*.psm1'))+sorted((ROOT/'Shared').glob('*.ps1'))
issues=[]
for p in RUNTIME:
 if not p.is_file(): issues.append('missing runtime file: '+str(p.relative_to(ROOT)))
text='\n'.join(p.read_text(encoding='utf-8-sig') for p in RUNTIME if p.exists())
# Exact parser regression: expandable variable immediately followed by terminal colon.
for p in RUNTIME:
 if not p.exists(): continue
 for ln,line in enumerate(p.read_text(encoding='utf-8-sig').splitlines(),1):
  if re.search(r'"[^"\n]*\$[A-Za-z_][A-Za-z0-9_]*:(?![A-Za-z0-9_?])',line): issues.append(f'{p.relative_to(ROOT)}:{ln}: ambiguous variable-plus-colon interpolation')
for pat,msg in ((r'New-Object\s+(?:-TypeName\s+)?System\.Collections\.Generic\.List','unsafe generic list construction'),(r'\(Get-SelectedGridItems[^\r\n]*\)\.Count','unsafe selection Count'),(r'Get-OdmProjectWorkload[^\r\n]*-ProjectId\b','unsupported workload ProjectId'),(r'Get-OdmTask\b[^\r\n]*-ProjectId\b','unsupported task ProjectId'),(r'Integrated\s*Windows|UseIntegratedWindowsAuthentication|IntegratedAuth','obsolete integrated Windows authentication')):
 if re.search(pat,text,re.I): issues.append(msg)
for marker in ('Get-QOdmCompatibilityAssessment','Invoke-QOdmReadinessCheck','Get-QOdmSafeModeState','New-QOdmSupportBundle','Write-QOdmOperationHistory','Get-QOdmTaskDetails','Invoke-QOdmLogMaintenance','CloneCurrentValue'):
 if marker not in text: issues.append('missing runtime marker: '+marker)
xaml=ROOT/'Resources/QuestODMConsole.xaml'
try:
 tree=ET.parse(xaml); names=[]
 for e in tree.iter():
  for k,v in e.attrib.items():
   if k.endswith('}Name') or k=='Name': names.append(v)
 if len(names)!=len(set(names)): issues.append('duplicate XAML names')
except Exception as e: issues.append('XAML parse failure: '+str(e)); names=[]
ui=(ROOT/'QuestODMConsole.UI.ps1').read_text(encoding='utf-8-sig')
refs=set(re.findall(r"Get-UiControl\s+(?:-Name\s+)?['\"]([^'\"]+)['\"]",ui,re.I))
missing=sorted(refs-set(names))
if missing: issues.append('missing XAML controls: '+', '.join(missing))
engine=(ROOT/'Engine/QuestODMConsole.Engine.psm1').read_text(encoding='utf-8-sig')
ops=set(re.findall(r"(?:Invoke-EngineAsync|Invoke-EngineSync)\s+-Operation\s+['\"]([^'\"]+)['\"]",ui,re.I))
for op in ops:
 if not re.search(rf"(?m)^\s*'{re.escape(op)}'\s*\{{",engine): issues.append('missing dispatcher route: '+op)
if re.search(r'\$script:Window\.Resources\s*\[\s*\$Name\s*\]\s*=',text): issues.append('unsafe ResourceDictionary theme indexer assignment')
if issues:
 print('RUNTIME SOURCE AUDIT: FAIL')
 for i in issues: print(' - '+i)
 sys.exit(1)
print(f'RUNTIME SOURCE AUDIT: PASS ({len(RUNTIME)} runtime files, {len(refs)} UI references, {len(names)} XAML controls, {len(ops)} UI operations)')
