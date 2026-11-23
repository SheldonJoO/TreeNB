import os, json, urllib.request, urllib.error, time, sys

cfg=json.loads(os.environ['CODEBUDDY_MCP_CONFIG']); g=cfg['mcpServers']['github']
URL=g['url']; H=dict(g.get('headers',{}))

def rpc(payload, sid=None, timeout=120):
    h=dict(H); h.update({'Content-Type':'application/json','Accept':'application/json, text/event-stream'})
    if sid: h['Mcp-Session-Id']=sid
    req=urllib.request.Request(URL,data=json.dumps(payload).encode(),headers=h)
    return urllib.request.urlopen(req,timeout=timeout).read().decode()

def session():
    for i in range(3):
        try:
            r=rpc({'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2024-11-05','capabilities':{},'clientInfo':{'name':'tnb','version':'1'}}})
            sid=next((l.split(':',1)[1].strip() for l in r.splitlines() if l.lower().startswith('mcp-session-id:')),None)
            rpc({'jsonrpc':'2.0','method':'notifications/initialized'},sid)
            return sid
        except Exception as e:
            print('retry init',i,e,file=sys.stderr); time.sleep(2)
    raise SystemExit('MCP init failed')

def call(name,args,sid):
    r=rpc({'jsonrpc':'2.0','id':99,'method':'tools/call','params':{'name':name,'arguments':args}},sid)
    for line in r.splitlines():
        if line.startswith('data:'):
            try: d=json.loads(line[5:]); break
            except: pass
    else: d=json.loads(r)
    res=d.get('result',{})
    if res.get('isError'): raise RuntimeError(res.get('content'))
    return '\n'.join(c.get('text','') for c in res.get('content',[]) if c.get('type')=='text')

if __name__=='__main__':
    sid=session()
    repo=sys.argv[1] if len(sys.argv)>1 else 'TreeNB'
    # 读取本地 git 追踪的所有文件
    import subprocess
    root='/Users/idoer/WorkBuddy/2026-11-23-11-28-53/TreeNB'
    paths=subprocess.check_output(['git','-C',root,'ls-files'],text=True).splitlines()
    files=[]
    for p in paths:
        with open(os.path.join(root,p),'rb') as f:
            content=f.read().decode('utf-8',errors='replace')
        files.append({'path':p,'content':content})
    print(f'Pushing {len(files)} files to SheldonJoO/{repo} ...')
    out=call('push_files',{
        'owner':'SheldonJoO','repo':repo,'branch':'main',
        'files':files,'message':'TreeNB: 单包无跳转骨架 + Spike 自检 (27 files)'
    },sid)
    print(out[:2000])
