"""Generate a new local or production environment without shared credentials."""
import argparse
import os
from pathlib import Path
import secrets


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--production', action='store_true')
    parser.add_argument('--demo-questions', action='store_true')
    args = parser.parse_args()
    if args.production and args.demo_questions:
        parser.error('Demonstration questions are development-only')
    root = Path(__file__).resolve().parents[1]
    target = root / ('deploy/.env.server' if args.production else '.env.local')
    values = {
        'APP_ENV': 'production' if args.production else 'development',
        'DEV_SEED': 'false' if args.production else 'true',
        'DEV_SEED_QUESTIONS': str(args.demo_questions).lower(),
        'DB_PATH': '/data/zhikaotong.db' if args.production else 'runtime/zhikaotong.db',
    }
    for role in (['ADMIN'] if args.production else ['ADMIN','REVIEWER','TEACHER','STUDENT']):
        values['BOOTSTRAP_'+role+'_PASSWORD'] = secrets.token_urlsafe(24)+'9aA!'
    target.parent.mkdir(parents=True,exist_ok=True)
    try:
        fd = os.open(target, os.O_WRONLY|os.O_CREAT|os.O_EXCL, 0o600)
    except FileExistsError:
        raise SystemExit('Environment file exists; no credentials changed: '+str(target))
    with os.fdopen(fd,'w',encoding='utf-8') as handle:
        handle.write('\n'.join(k+'='+v for k,v in values.items())+'\n')
    (root/'runtime').mkdir(exist_ok=True)
    print('Created '+str(target)+'. Read passwords locally; do not commit this file.')


if __name__=='__main__':
    main()
