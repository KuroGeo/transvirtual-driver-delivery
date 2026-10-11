"""Validate preparation structure; never attest next-phase product execution."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess

PACKAGE = 'harness/project/next-phase'
LEVELS = {'contract', 'harness', 'host', 'native', 'live', 'device-performance'}
NOW = {'python3 harness/run.py check', 'python3 harness/run.py quality'}
SHARED = {'app/pubspec.yaml':'NP10','app/pubspec.lock':'NP10','app/lib/main.dart':'NP10',
          'app/lib/app':'NP10','app/lib/ui/core':'NP10','app/android':'NP10','app/ios':'NP10',
          'app/lib/data/delivery':'NP03','app/lib/models/delivery.dart':'NP03','.github/workflows':'NP01',
          'service/go.mod':'NP15','service/go.sum':'NP15','service/cmd/api':'NP15',
          'service/internal/platform':'NP15','service/api':'NP15','service/migrations':'NP15'}
ARCHITECTURE = {'routing':'client-direct-third-party-no-own-routing-backend',
                'identity':'go-user-auth-no-b-end',
                'assistant':'client-executor-now-server-executor-later'}


def validate(root, candidate_inputs):
    root = Path(root).resolve()
    directory = root / PACKAGE
    if not directory.exists():
        return ['next-phase: task package missing'] if (root/'prototype/next-phase').exists() or (root/'docs/next-phase-solution-design.md').exists() else []
    errors = []
    def fail(message):
        errors.append(f'next-phase: {message}')
    def pairs(items):
        result = {}
        for key,value in items:
            if key in result:
                raise ValueError(f'duplicate key {key}')
            result[key] = value
        return result
    def invalid(value):
        raise ValueError(f'nonfinite {value}')
    def read_json(name):
        try:
            path = safe_file(name, fingerprint=name!='work.json')
            return json.loads(path.read_text(), object_pairs_hook=pairs, parse_constant=invalid) if path else {}
        except (OSError,ValueError,UnicodeError) as error:
            fail(f'{name}: {error}')
            return {}
    def strings(value, nonempty=True):
        return isinstance(value,list) and (bool(value) or not nonempty) and all(isinstance(item,str) and item.strip() for item in value) and len(value)==len(set(value))
    def canonical(value):
        if not isinstance(value,str) or not value or '\\' in value or '\0' in value:
            return False
        path = PurePosixPath(value)
        try:
            return not path.is_absolute() and '..' not in path.parts and path.as_posix()==value and (root/value).resolve()==root/value and (root/value).resolve().is_relative_to(root)
        except (OSError,ValueError,RuntimeError):
            return False
    def overlaps(a,b):
        left,right = PurePosixPath(a).parts,PurePosixPath(b).parts
        return left[:len(right)]==right or right[:len(left)]==left
    def safe_file(name, fingerprint=True):
        relative = f'{PACKAGE}/{name}'
        path = root/relative
        if not canonical(relative) or not path.is_file() or (fingerprint and relative not in candidate_inputs):
            fail(f'{name}: unsafe/missing contract file or outside fingerprint')
            return None
        return path
    backlog,matrix,work = [read_json(name) for name in ('backlog.json','requirement-matrix.json','work.json')]
    if not all(isinstance(value,dict) for value in (backlog,matrix,work)):
        return errors+['next-phase: malformed package']
    revision = backlog.get('contract_revision')
    if type(backlog.get('schema_version')) is not int or backlog['schema_version']!=1 or backlog.get('package')!='NEXT-PHASE' or backlog.get('mode')!='prepare' or type(revision) is not int or revision<=0:
        fail('expected NEXT-PHASE prepare schema/revision; execute requires NP01 protocol')
    if backlog.get('production_eligible') is not False or backlog.get('enforcement_deployed') is not False:
        fail('prepare cannot grant production/enforcement eligibility')
    if backlog.get('repository')!='KuroGeo/transvirtual-driver-delivery':
        fail('unexpected repository')
    publication = backlog.get('publication_status')
    if publication not in ('draft','published'):
        fail('invalid publication status')
    try:
        mission = safe_file('mission.md')
        required = set(re.findall(r'\| (NP-R\d{2}) \|',mission.read_text())) if mission else set()
    except (OSError,UnicodeError) as error:
        fail(f'mission: {error}')
        required = set()
    if not required:
        fail('mission requirements missing')
    safe_file('contracts.md')
    registry = read_json('feature-contracts.json')
    features = {}
    if not isinstance(registry,dict) or type(registry.get('schema_version')) is not int or registry.get('schema_version')!=1 or not isinstance(registry.get('features'),list):
        fail('feature registry schema missing')
    else:
        if registry.get('architecture_decisions')!=ARCHITECTURE or backlog.get('architecture_decisions')!=ARCHITECTURE:
            fail('user architecture decisions missing/changed or inconsistent')
        for feature in registry['features']:
            if not isinstance(feature,dict) or not isinstance(feature.get('id'),str) or feature['id'] in features or feature.get('status')!='prepared':
                fail('invalid/duplicate/unprepared feature')
                continue
            features[feature['id']] = feature
            for key,suffix in (('prototype','.html'),('technical_design','.md')):
                value = feature.get(key)
                if not canonical(value) or not value.endswith(suffix) or value not in candidate_inputs or not (root/value).is_file():
                    fail(f"{feature['id']}: {key} missing/unsafe or outside fingerprint")
        if set(features)!={'F1','F2','F3'}:
            fail('every user requirement must have a prototype and technical design')
        routing,identity,assistant = [features.get(name,{}) for name in ('F1','F2','F3')]
        if routing.get('integration_policy')!=ARCHITECTURE['routing']:
            fail('F1: client third-party routing must not require own backend')
        if identity.get('backend_language')!='Go' or identity.get('product_scope')!='user-login-only' or identity.get('management_ui') is not False or any(key in identity for key in ('management_prototype','management_approval','management_prototype_status')):
            fail('F2: Go user/login-only scope must exclude B-end management and approval gate')
        if (root/'prototype/next-phase/identity-admin.html').exists():
            fail('F2: cancelled B-end management prototype must not return')
        for key,suffix in (('backend_architecture','.md'),):
            value = identity.get(key)
            if not canonical(value) or not value.endswith(suffix) or value not in candidate_inputs or not (root/value).is_file():
                fail(f'F2: {key} missing/unsafe or outside fingerprint')
        if assistant.get('initial_executor')!='client' or assistant.get('target_executor')!='server' or assistant.get('protocol')!='AssistantExecutor-v1':
            fail('F3: client-to-server executor migration contract missing')
    # Bind issue materials to real committed bytes, rather than checking URL spelling alone.
    materials = {'prototype/next-phase/README.md','prototype/next-phase/next.js','docs/next-phase-solution-design.md'}
    for feature in features.values():
        materials.update(feature[key] for key in ('prototype','technical_design','backend_architecture') if isinstance(feature.get(key),str))
    pending = backlog.get('source_ref_pending')
    if type(pending) is not bool or (publication=='published' and pending):
        fail('source binding pending/unknown cannot attest published materials')
    if pending is False:
        ref,manifest = backlog.get('source_ref'),backlog.get('source_manifest')
        if not isinstance(ref,str) or not re.fullmatch(r'[a-f0-9]{40}',ref) or not isinstance(manifest,dict) or set(manifest)!=materials:
            fail('committed source ref/manifest missing')
        else:
            for source in sorted(materials):
                try:
                    if not canonical(source) or source not in candidate_inputs:
                        fail(f'{source}: source binding unsafe/outside fingerprint')
                        continue
                    current = (root/source).read_bytes()
                    bound = subprocess.run(['git','-C',str(root),'show',f'{ref}:{source}'],capture_output=True,timeout=5,check=True).stdout
                    if bound!=current or manifest[source]!=hashlib.sha256(current).hexdigest():
                        fail(f'{source}: issue source ref contains stale/mismatched bytes')
                except (OSError,subprocess.SubprocessError) as error:
                    fail(f'{source}: committed issue source unavailable ({type(error).__name__})')
    tasks = backlog.get('tasks')
    if not isinstance(tasks,list) or not tasks:
        return errors+['next-phase: tasks missing']
    by_id = {}
    for task in tasks:
        if not isinstance(task,dict) or not isinstance(task.get('id'),str) or not re.fullmatch(r'NP\d{2}',task['id']) or task['id'] in by_id:
            fail('invalid/duplicate task ID')
            continue
        name = task['id']
        by_id[name] = task
        if name=='NP16':
            fail('cancelled B-end management task NP16 must not return')
        if not strings(task.get('features')) or set(task['features'])-set(features):
            fail(f'{name}: feature source mapping missing/unknown')
        if not strings(task.get('requirements')) or set(task['requirements'])-required:
            fail(f'{name}: invalid/unknown requirements')
        if not strings(task.get('depends_on'),False):
            fail(f'{name}: invalid dependencies')
        if not strings(task.get('write_scope')) or any(not canonical(scope) for scope in task['write_scope']):
            fail(f'{name}: invalid write scope')
        elif any(scope.startswith(('service/internal/workspace','service/internal/membership','service/internal/audit','admin/')) for scope in task['write_scope']):
            fail(f'{name}: B-end management write scope forbidden')
        elif name in ('NP05','NP07') and any(scope.startswith('service/') for scope in task['write_scope']):
            fail(f'{name}: own routing/planning backend forbidden this iteration')
        elif name=='NP09' and any(scope.startswith(('service/assistant','service/internal/assistant')) for scope in task['write_scope']):
            fail('NP09: real server Agent is deferred; only modelproxy allowed this iteration')
        if not strings(task.get('acceptance')) or not strings(task.get('outputs')) or any(not isinstance(task.get(key),str) or not task[key].strip() for key in ('role','recovery','handoff')):
            fail(f'{name}: owner/acceptance/output/recovery/handoff missing')
        if task.get('status')!='planned':
            fail(f'{name}: prepare task must remain planned')
        skills = task.get('skills')
        if not strings(skills) or any(not re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*',skill) or not (root/f'.agents/skills/{skill}/SKILL.md').is_file() for skill in skills):
            fail(f'{name}: unknown/missing skill')
        check = task.get('verification')
        if not isinstance(check,dict) or not isinstance(check.get('level'),str) or check['level'] not in LEVELS or check.get('evidence_kind')!=check.get('level') or check.get('status')!='planned' or check.get('evidence')!=[]:
            fail(f'{name}: verification must be typed planned with no evidence')
        commands = task.get('commands')
        if not isinstance(commands,list) or not commands:
            fail(f'{name}: commands missing')
        else:
            for item in commands:
                if not isinstance(item,dict) or item.get('availability') not in ('now','planned','blocked') or not isinstance(item.get('command'),str) or not item.get('purpose'):
                    fail(f'{name}: malformed command')
                elif item['availability']=='now' and item['command'] not in NOW:
                    fail(f'{name}: unverified command cannot claim available now')
        external = task.get('external_dependencies')
        if not isinstance(external,list) or any(type(number) is not int or number not in (31,32,33) for number in external) or len(external)!=len(set(external)):
            fail(f'{name}: unknown external dependency')
    if errors:
        return errors  # malformed containers cannot reach DAG/index operations
    ancestors = {}
    def visit(name,chain):
        if name in chain:
            fail(f'cyclic DAG: {" -> ".join(chain+[name])}')
            return set()
        if name in ancestors:
            return ancestors[name]
        result = set()
        for dependency in by_id[name]['depends_on']:
            if dependency not in by_id:
                fail(f'{name}: missing dependency {dependency}')
                continue
            result.add(dependency)
            result.update(visit(dependency,chain+[name]))
        ancestors[name] = result
        return result
    for name in by_id:
        visit(name,[])
    for name,task in by_id.items():
        for other,other_task in by_id.items():
            if name<other and name not in ancestors.get(other,set()) and other not in ancestors.get(name,set()) and any(overlaps(a,b) for a in task['write_scope'] for b in other_task['write_scope']):
                fail(f'parallel write conflict: {name}/{other}')
    owners = backlog.get('shared_file_owners')
    if not isinstance(owners,dict) or not owners:
        fail('shared_file_owners missing')
    else:
        if any(owners.get(path)!=owner for path,owner in SHARED.items()):
            fail('required shared domains/owners missing or changed')
        for path,owner in owners.items():
            if not canonical(path) or not isinstance(owner,str) or owner not in by_id or not any(PurePosixPath(path).is_relative_to(PurePosixPath(scope)) for scope in by_id[owner]['write_scope']):
                fail(f'unknown shared owner/path {path}: {owner}')
                continue
            for name,task in by_id.items():
                if name!=owner and any(overlaps(path,scope) for scope in task['write_scope']):
                    fail(f'{path}: {name} writes another owner shared domain')
    if type(matrix.get('schema_version')) is not int or matrix['schema_version']!=1 or type(matrix.get('contract_revision')) is not int or matrix['contract_revision']!=revision:
        fail('matrix schema/revision mismatch')
    rows = matrix.get('requirements')
    seen = set()
    if not isinstance(rows,list):
        fail('matrix rows missing')
        rows = []
    for row in rows:
        if not isinstance(row,dict) or not isinstance(row.get('id'),str) or row['id'] in seen or row['id'] not in required:
            fail('malformed/duplicate/unknown requirement row')
            continue
        rid = row['id']
        seen.add(rid)
        expected = {name for name,task in by_id.items() if rid in task['requirements']}
        if not expected or not strings(row.get('tasks')) or set(row['tasks'])!=expected:
            fail(f'{rid}: task joins/coverage mismatch')
        if not strings(row.get('sources')) or any(not canonical(source) or source not in candidate_inputs or not (root/source).is_file() for source in row['sources']):
            fail(f'{rid}: source missing or outside fingerprint')
        if not strings(row.get('gaps')):
            fail(f'{rid}: preparation gaps missing')
        checks = row.get('checks')
        mapped,ids = set(),set()
        if not isinstance(checks,list):
            fail(f'{rid}: checks missing')
            checks = []
        for check in checks:
            if not isinstance(check,dict) or not isinstance(check.get('id'),str) or check['id'] in ids or not isinstance(check.get('task'),str) or check['task'] not in expected:
                fail(f'{rid}: invalid/duplicate check or task join')
                continue
            ids.add(check['id'])
            mapped.add(check['task'])
            level = by_id[check['task']]['verification']['level']
            if check.get('level')!=level or check.get('evidence_kind')!=level or check.get('status')!='planned' or check.get('evidence')!=[]:
                fail(f'{rid}: prepare check cannot attest product/native/live evidence')
        if mapped!=expected:
            fail(f'{rid}: checks must cover mapped tasks')
    if seen!=required:
        fail('mission/matrix requirement coverage mismatch')
    if type(work.get('schema_version')) is not int or work['schema_version']!=1 or work.get('mode')!='prepare' or type(work.get('contract_revision')) is not int or work['contract_revision']!=revision or work.get('product_execution_authorized') is not False:
        fail('work authorization/schema mismatch')
    entries = work.get('tasks')
    if not isinstance(entries,list) or any(not isinstance(entry,dict) or not isinstance(entry.get('id'),str) for entry in entries) or len(entries)!=len(by_id) or {entry['id'] for entry in entries}!=set(by_id):
        fail('work task coverage mismatch')
    else:
        for entry in entries:
            if entry.get('status')!='planned' or any(entry.get(key) is not None for key in ('owner_agent_id','candidate','result_path')) or entry.get('evidence')!=[]:
                fail('prepare work cannot claim product execution/acceptance')
    identities = {key:set() for key in ('number','issue_id','url')}
    def body_identity(name,record,marker,body_hash):
        try:
            path = safe_file(f'issues/{name}.md')
            if path is None:
                return
            body = path.read_bytes()
            digest = hashlib.sha256(body).hexdigest()
            if marker not in body.decode() or body_hash!=digest:
                fail(f'{name}: local marker/body hash mismatch')
            required_features = by_id[name]['features'] if name in by_id else list(features)
            for feature_id in required_features:
                source_keys = ('prototype','technical_design','backend_architecture') if feature_id=='F2' else ('prototype','technical_design')
                for key in source_keys:
                    expected = f"https://github.com/{backlog['repository']}/blob/{backlog.get('source_ref')}/{features[feature_id][key]}"
                    if expected not in body.decode():
                        fail(f'{name}: corresponding feature {key} link missing')
        except (OSError,UnicodeError) as error:
            fail(f'{name}: issue body missing: {error}')
            return
        if publication!='published' and record is None:
            return
        if not isinstance(record,dict):
            fail(f'{name}: published identity missing')
            return
        if any(type(record.get(key)) is not int or record[key]<=0 for key in ('number','issue_id')) or record.get('url')!=f"https://github.com/{backlog['repository']}/issues/{record.get('number')}" or (publication=='published' and record.get('body_sha256')!=digest):
            fail(f'{name}: publication identity/hash mismatch')
        for key in identities:
            identity = record.get(key)
            if not isinstance(identity,(str,int)) or identity in identities[key]:
                fail(f'{name}: duplicate/invalid {key}')
            else:
                identities[key].add(identity)
    parent = backlog.get('github_parent')
    body_identity('EPIC',parent,f'<!-- ocean-delivery-next-epic:NEXT-PHASE; contract:{revision} -->',backlog.get('epic_body_sha256'))
    for name,task in by_id.items():
        body_identity(name,task.get('github'),f'<!-- ocean-delivery-next-task:{name}; contract:{revision} -->',task.get('body_sha256'))
    if errors:
        return errors
    if publication=='published':
        reserved = {'number':{31,32,33},'issue_id':set(),'url':set()}
        old_path = root/'harness/project/backlog.json'
        if old_path.is_file():
            try:
                old = json.loads(old_path.read_text(), object_pairs_hook=pairs)
                records = [old.get('github_parent',{})]+[task.get('github',{}) for task in old.get('tasks',[])]
                for record in records:
                    for key in reserved:
                        if isinstance(record.get(key),(int,str)):
                            reserved[key].add(record[key])
            except (OSError,ValueError,AttributeError,TypeError) as error:
                fail(f'cannot validate previous package identities: {error}')
        for key in identities:
            if identities[key] & reserved[key]:
                fail(f'new issue reuses previous/external {key}')
        for name,task in by_id.items():
            github = task.get('github') or {}
            expected = [(by_id[dep].get('github') or {}).get('number') for dep in task['depends_on']]+task['external_dependencies']
            if not isinstance(parent,dict) or github.get('parent_number')!=parent.get('number') or github.get('blocked_by_numbers')!=expected:
                fail(f'{name}: parent/dependency publication mismatch')
            elif github.get('number') in expected:
                fail(f'{name}: published dependency self-edge')
            else:
                text = (directory/f'issues/{name}.md').read_text() if (directory/f'issues/{name}.md').is_file() else ''
                if not isinstance(parent.get('url'),str) or parent['url'] not in text:
                    fail(f'{name}: parent link missing')
    return errors
