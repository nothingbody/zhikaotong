"""Run the local API with the generated local environment."""
import os
from pathlib import Path
import sys


root=Path(__file__).resolve().parents[1]
environment=root/'.env.local'
if not environment.is_file():
    raise SystemExit('First run: python scripts/init_dev.py')
for line in environment.read_text(encoding='utf-8').splitlines():
    if not line.strip() or line.lstrip().startswith('#'):
        continue
    key,separator,value=line.partition('=')
    if separator and key.replace('_','').isalpha() and key.isupper():
        os.environ.setdefault(key,value)
os.chdir(root)
sys.path.insert(0,str(root))
import uvicorn
uvicorn.run('backend.app:app',host='127.0.0.1',port=8100)
