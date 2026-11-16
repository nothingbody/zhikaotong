"""Check tracked public files without printing any matching secret contents."""
from pathlib import Path
import re
import subprocess


root=Path(__file__).resolve().parents[1]
paths=subprocess.check_output(['git','ls-files','-z'],cwd=root).decode().split('\0')
issues=[]
for relative in filter(None,paths):
    p=root/relative
    parts=Path(relative).parts
    if any(x in parts for x in ('runtime','deliverables','word_assets','node_modules','.dart_tool','.gradle')):
        issues.append((relative,'private or generated directory'))
    if p.suffix.lower() in ('.pem','.key','.p12','.pfx','.jks','.keystore','.db','.sqlite','.docx','.doc','.pdf','.csv','.apk','.aab'):
        issues.append((relative,'private data or build artifact extension'))
    if p.name.startswith('.env') and p.name!='.env.example':
        issues.append((relative,'real environment file'))
    if p.suffix.lower() not in ('.ttf','.jar','.png','.jpg','.jpeg','.webp'):
        content=p.read_bytes()
        patterns=[rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
                  rb'gh[pousr]_[A-Za-z0-9]{30,}',rb'github_pat_[A-Za-z0-9_]{30,}',
                  rb'AKIA[0-9A-Z]{16}']
        if any(re.search(pattern,content) for pattern in patterns):
            issues.append((relative,'credential signature'))
if issues:
    for path,reason in issues:
        print(path+': '+reason)
    raise SystemExit(1)
print('Public tracked-file checks passed: '+str(len(list(filter(None,paths))))+' files')
