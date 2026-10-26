#!/usr/bin/env python3
"""Offline protocol compatibility check. Synthetic tokens; NEVER starts a model turn."""
import base64,json,os,selectors,subprocess,sys,tempfile,time
from pathlib import Path
cli=Path(sys.argv[1]).resolve(strict=True)
def b64(x): return base64.urlsafe_b64encode(json.dumps(x).encode()).decode().rstrip('=')
token=b64({'alg':'none'})+'.'+b64({'sub':'warmup-fixture','exp':4102444800,'https://api.openai.com/auth':{'chatgpt_account_id':'warmup-fixture','chatgpt_plan_type':'plus'}})+'.fixture'
with tempfile.TemporaryDirectory(prefix='still-warmup-protocol-') as d:
    d=str(Path(d).resolve());os.chmod(d,0o700)
    env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':d,'CODEX_HOME':d,'CODEX_SQLITE_HOME':d+'/state','TMPDIR':d,'XDG_CONFIG_HOME':d,'XDG_DATA_HOME':d,'XDG_CACHE_HOME':d,'LANG':'en_US.UTF-8'}
    args=[str(cli),'-c','cli_auth_credentials_store="ephemeral"','-c','analytics.enabled=false','-c','web_search="disabled"']
    for flag in ['shell_tool','unified_exec','shell_snapshot','apps','multi_agent','js_repl','sleep_tool','image_generation']:
        args+=['-c','features.'+flag+'=false']
    args+=['app-server']
    # OS-enforced network block, including model catalog fetches and telemetry.
    p=subprocess.Popen(['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)']+args,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,env=env,cwd=d)
    selector=selectors.DefaultSelector();selector.register(p.stdout,selectors.EVENT_READ);buffer=bytearray()
    def send(obj):
        assert obj.get('method') not in ['turn/start','account/rateLimits/read']
        p.stdin.write(json.dumps(obj).encode()+b'\n');p.stdin.flush()
    def response(n):
        deadline=time.monotonic()+30
        while time.monotonic()<deadline:
            while b'\n' in buffer:
                line,_,rest=buffer.partition(b'\n');buffer[:]=rest;obj=json.loads(line)
                if obj.get('id')==n:
                    if 'error' in obj: raise RuntimeError('Protocol response error (details suppressed)')
                    return obj['result']
            if selector.select(.1):
                data=os.read(p.stdout.fileno(),8192)
                if not data: raise RuntimeError('CLI ended')
                buffer.extend(data)
        raise RuntimeError('Protocol timeout')
    try:
        send({'id':1,'method':'initialize','params':{'clientInfo':{'name':'still_offline_warmup_fixture','version':'1.3.0'},'capabilities':{'experimentalApi':True}}});response(1)
        send({'method':'initialized'})
        send({'id':2,'method':'account/login/start','params':{'type':'chatgptAuthTokens','accessToken':token,'chatgptAccountId':'warmup-fixture','chatgptPlanType':'plus'}})
        assert response(2)['type']=='chatgptAuthTokens';print('PASS offline external access-token authentication')
        send({'id':5,'method':'thread/start','params':{'model':'gpt-6-luna','modelProvider':'openai','cwd':d,'approvalPolicy':'never','sandbox':'read-only','ephemeral':True,'baseInstructions':'Reply exactly ok. Do not use tools.','developerInstructions':'Reply exactly ok.','config':{'model_reasoning_effort':'low','web_search':'disabled','features.shell_tool':False,'features.apps':False,'features.multi_agent':False}}})
        r=response(5)
        assert r['thread']['ephemeral'] and r['cwd']==d and r['model']=='gpt-6-luna' and r['modelProvider']=='openai'
        assert r['sandbox']['type']=='readOnly' and r['approvalPolicy']=='never'
        assert not r.get('instructionSources')
        print('PASS ephemeral thread schema, isolated cwd, read-only sandbox and no inherited instruction files')
    finally:
        p.stdin.close();selector.close()
        try: p.wait(timeout=3)
        except subprocess.TimeoutExpired:
            p.terminate()
            try: p.wait(timeout=3)
            except subprocess.TimeoutExpired: p.kill();p.wait()
    assert not Path(d,'auth.json').exists()
    assert all(token.encode() not in f.read_bytes() for f in Path(d).rglob('*') if f.is_file())
    print('PASS no auth.json and no synthetic token persisted')
print('RESULT 3 offline compatibility checks passed; no quota query or model turn sent')
