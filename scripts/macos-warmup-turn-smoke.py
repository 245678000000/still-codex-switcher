#!/usr/bin/env python3
import base64,json,os,selectors,subprocess,sys,tempfile,time
from pathlib import Path
cli=str(Path(sys.argv[1]).resolve(strict=True)) if len(sys.argv)>1 else '/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex'
def b64(x):return base64.urlsafe_b64encode(json.dumps(x).encode()).decode().rstrip('=')
token=b64({'alg':'none'})+'.'+b64({'sub':'synthetic-fixture','exp':4102444800,'https://api.openai.com/auth':{'chatgpt_account_id':'synthetic-fixture','chatgpt_plan_type':'plus'}})+'.fixture'
with tempfile.TemporaryDirectory(prefix='still-offline-turn-') as d:
 d=str(Path(d).resolve());os.chmod(d,0o700);os.mkdir(d+'/tmp',0o700)
 env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':d,'CODEX_HOME':d,'CODEX_SQLITE_HOME':d+'/state','TMPDIR':d+'/tmp','XDG_CONFIG_HOME':d,'XDG_DATA_HOME':d,'XDG_CACHE_HOME':d,'LANG':'en_US.UTF-8'}
 flags=['shell_tool','unified_exec','shell_snapshot','apps','multi_agent','js_repl','sleep_tool','image_generation']
 args=['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)',cli,'-c','cli_auth_credentials_store="ephemeral"','-c','analytics.enabled=false','-c','web_search="disabled"']
 for f in flags:args+=['-c','features.'+f+'=false']
 p=subprocess.Popen(args+['app-server'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,cwd=d,env=env)
 sel=selectors.DefaultSelector();sel.register(p.stdout,selectors.EVENT_READ);buf=bytearray()
 def send(x):p.stdin.write(json.dumps(x).encode()+b'\n');p.stdin.flush()
 def response(i):
  end=time.monotonic()+30
  while time.monotonic()<end:
   while b'\n' in buf:
    line,_,rest=buf.partition(b'\n');buf[:]=rest;v=json.loads(line)
    if v.get('id')==i:
     if 'error' in v:print('OFFLINE ERROR',i,json.dumps(v['error'],ensure_ascii=False));return None
     return v['result']
    if v.get('method')=='turn/completed': print('OFFLINE completion status:',v.get('params',{}).get('turn',{}).get('status'))
   if sel.select(.1):
    chunk=os.read(p.stdout.fileno(),8192)
    if not chunk:raise RuntimeError('CLI closed')
    buf.extend(chunk)
  raise TimeoutError('no response')
 try:
  send({'id':1,'method':'initialize','params':{'clientInfo':{'name':'still_diagnostic_fixture','version':'1.0'},'capabilities':{'experimentalApi':True}}}); assert response(1) is not None
  send({'method':'initialized'});send({'id':2,'method':'account/login/start','params':{'type':'chatgptAuthTokens','accessToken':token,'chatgptAccountId':'synthetic-fixture','chatgptPlanType':'plus'}});assert response(2)['type']=='chatgptAuthTokens'
  send({'id':5,'method':'thread/start','params':{'model':'gpt-6-luna','modelProvider':'openai','cwd':d,'approvalPolicy':'never','sandbox':'read-only','ephemeral':True,'baseInstructions':'Reply exactly ok. Do not use tools or access files, commands, websites, or other accounts.','developerInstructions':'This is a single minimal reply. Reply exactly ok.','config':{'model_reasoning_effort':'low','web_search':'disabled','features.shell_tool':False,'features.apps':False,'features.multi_agent':False}}})
  r=response(5);assert r and r['thread']['ephemeral'];tid=r['thread']['id'];print('OFFLINE synthetic ephemeral thread created')
  send({'id':6,'method':'turn/start','params':{'threadId':tid,'input':[{'type':'text','text':'回复ok'}],'model':'gpt-6-luna','effort':'low','approvalPolicy':'never','sandboxPolicy':{'type':'readOnly','networkAccess':False}}})
  r=response(6)
  assert r and r.get('turn',{}).get('status') in ('inProgress','completed'), 'offline synthetic turn request rejected'
  print('PASS offline synthetic turn accepted:',r['turn']['status'])
 finally:
  p.stdin.close();sel.close()
  try:p.wait(timeout=3)
  except subprocess.TimeoutExpired:p.terminate();p.wait(timeout=3)
print('RESULT offline synthetic turn check passed; no real account and OS denies all network.')
