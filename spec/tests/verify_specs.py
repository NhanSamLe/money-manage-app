"""Static spec validation only; not a backend, DB or Android test. Requires pyyaml,jsonschema."""
from pathlib import Path
import json
import yaml
from jsonschema import Draft202012Validator, FormatChecker
root=Path(__file__).resolve().parents[1]
def load(p): return json.loads((root/p).read_text())
files=list(root.rglob('*.json'))
for f in files: json.loads(f.read_text())
for name in ['commands','ai-action','normalized-event']:
    Draft202012Validator.check_schema(load(f'contracts/{name}.schema.json'))
api=yaml.safe_load((root/'contracts/openapi.yaml').read_text()); assert api['openapi']=='3.1.0'
seen=set()
for path,methods in api['paths'].items():
    for method,op in methods.items():
        assert op['operationId'] not in seen; seen.add(op['operationId'])
        assert op['responses']
        for p in op.get('parameters',[]):
            if p['in']=='path': assert '{'+p['name']+'}' in path and p['required']
def walk(o):
    if isinstance(o,dict):
        if '$ref' in o and o['$ref'].startswith('#/'):
            n=api
            for k in o['$ref'][2:].split('/'): n=n[k]
        for v in o.values(): walk(v)
    elif isinstance(o,list):
        for v in o: walk(v)
walk(api)
commands=load('contracts/commands.schema.json')['$defs']
for key,value in commands.items(): assert api['components']['schemas']['Command'+key]==value
fixtures=load('tests/fixtures.json')
for f in fixtures['schema_cases']:
    valid=Draft202012Validator(load('contracts/'+f['schema']),format_checker=FormatChecker()).is_valid(f['value'])
    assert valid==f['valid'],f['id']
for f in fixtures['ledger_scenarios']:
    acc={k:0 for k in f['accounts']}; journals={}
    for j in f['journals']:
        lines={k:int(v) for k,v in j['lines'].items()}; assert len(lines)>=2 and all(lines.values()) and sum(lines.values())==0, (f['id'],j['id'])
        if 'reversal_of' in j: assert lines=={k:-v for k,v in journals[j['reversal_of']].items()}
        journals[j['id']]=lines
        for k,v in lines.items():acc[k]+=v
    income=-sum(v for k,v in acc.items() if f['accounts'][k]=='INCOME'); expense=sum(v for k,v in acc.items() if f['accounts'][k]=='EXPENSE'); net=sum(v for k,v in acc.items() if f['accounts'][k] in ['ASSET','LIABILITY'])
    expected=f['expected']; assert str(income)==expected['income'] and str(expense)==expected['expense'] and str(income-expense)==expected['net_savings'] and str(net)==expected['net_worth'], f['id']
    for k,v in expected['balances'].items(): assert str(acc[k]*(-1 if f['accounts'][k]=='LIABILITY' else 1))==v, (f['id'],k)
for f in fixtures['cost_scenarios']:
    allowed=sum(int(f[k]) for k in ['spent','reserved','requested'])<=int(f['cap_micro_usd']); assert allowed==(f['expected']=='ALLOWED')
providers=load('config/providers.json'); assert not providers['default_live_enabled']; assert providers['zero_cost_required']
print(f'PASS static: {len(files)} JSON files, 3 JSON Schemas, {len(commands)} command schema parity checks, {len(api["paths"])} OpenAPI paths, {len(seen)} unique operations, local refs, {len(fixtures["schema_cases"])} schema examples, {len(fixtures["ledger_scenarios"])} ledger golden scenarios, {len(fixtures["cost_scenarios"])} cost scenarios.')
print('NOT RUN: full OpenAPI validator, SQL migration/database/RLS/concurrency, actual app, device, provider, email, AI benchmark, deployment.')
