#!/usr/bin/env python3
"""Read-only Actions monitor with durable status, full log and diagnostics capture."""
import argparse
from datetime import datetime,timezone
import json
from pathlib import Path
import subprocess
import time

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('run')
    parser.add_argument('--repo',default='Taipeione/iStoreOS-R76S-Custom')
    parser.add_argument('--reports',type=Path,required=True)
    args=parser.parse_args()
    args.reports.mkdir(parents=True,exist_ok=True)
    prefix=['gh','run','view',args.run,'--repo',args.repo]
    with (args.reports/'monitor.log').open('a') as output:
        while True:
            try:
                result=subprocess.run(prefix+['--json','status,conclusion,jobs,headSha,url'],capture_output=True,text=True,timeout=90)
                if result.returncode:raise RuntimeError(result.stderr.strip())
                state=json.loads(result.stdout)
            except (subprocess.TimeoutExpired,RuntimeError,json.JSONDecodeError) as error:
                line='MONITOR_RETRY '+str(error)
                print(line,flush=True);output.write(line+'\n');output.flush();time.sleep(30);continue
            (args.reports/'run.json').write_text(json.dumps(state,indent=2)+'\n')
            current=[s['name'] for j in state.get('jobs',[]) for s in j.get('steps',[]) if s['status']=='in_progress']
            line=f"{datetime.now(timezone.utc).isoformat()} {state['status']} {state['conclusion']} {' | '.join(current)}"
            print(line,flush=True);output.write(line+'\n');output.flush()
            if state['status']=='completed':
                for flag,name in [('--log','actions-full.log'),('--log-failed','actions-failed.log')]:
                    with (args.reports/name).open('w') as log:
                        result=subprocess.run(prefix+[flag],stdout=log,stderr=subprocess.PIPE,text=True,timeout=180)
                    if result.returncode:output.write('LOG_CAPTURE_ERROR '+result.stderr+'\n')
                subprocess.run(['gh','run','download',args.run,'--repo',args.repo,'--pattern','*diagnostics*','--dir',str(args.reports/'diagnostics')],capture_output=True,text=True,timeout=180)
                return 0 if state['conclusion']=='success' else 1
            time.sleep(45)

if __name__=='__main__':raise SystemExit(main())
