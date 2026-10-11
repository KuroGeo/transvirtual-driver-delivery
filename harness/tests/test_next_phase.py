import json
import hashlib
from pathlib import Path
import shutil
import runpy
import tempfile
import unittest
import subprocess

from harness import checks, next_phase


class PreparationContract(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.package = self.root / next_phase.PACKAGE
        shutil.copytree(checks.ROOT / next_phase.PACKAGE, self.package)
        self.inputs = {'prototype/next-phase/README.md','prototype/next-phase/next.js','docs/next-phase-solution-design.md'}
        for source in self.inputs:
            path = self.root/source
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('Fixture source')
        registry = self.read('feature-contracts.json')
        for feature in registry['features']:
            for key in ('prototype','technical_design','backend_architecture'):
                if key not in feature:
                    continue
                path = self.root/feature[key]
                path.parent.mkdir(parents=True,exist_ok=True)
                path.write_text('Fixture per-feature prototype or technical design')
        backlog = self.read('backlog.json')
        for skill in {name for task in backlog['tasks'] for name in task['skills']}:
            path = self.root/f'.agents/skills/{skill}/SKILL.md'
            path.parent.mkdir(parents=True,exist_ok=True)
            path.write_text('Fixture skill')
        # Normalize a repository that has already published back to draft.
        backlog['publication_status'] = 'draft'
        backlog['source_ref_pending'] = True
        backlog['github_parent'] = None
        for task in backlog['tasks']:
            task['github'] = None
        self.write('backlog.json',backlog)
        self.inputs.update(path.relative_to(self.root).as_posix() for path in checks.source_files(self.root))

    def read(self,name):
        return json.loads((self.package/name).read_text())

    def write(self,name,value):
        (self.package/name).write_text(json.dumps(value))

    def errors(self):
        return next_phase.validate(self.root,self.inputs)

    def mutate(self,name,action):
        value = self.read(name)
        action(value)
        self.write(name,value)

    def publish_fixture(self, reserved_number=False):
        registry = self.read('feature-contracts.json')
        value = self.read('backlog.json')
        repo = value['repository']
        value['publication_status'] = 'published'
        value['github_parent'] = {'number':9000,'issue_id':99000,'url':f'https://github.com/{repo}/issues/9000'}
        for index,task in enumerate(value['tasks']):
            number = 1000+index
            if reserved_number and task['id']=='NP14':
                number = 31
                task['external_dependencies'] = [31]
            task['github'] = {'number':number,'issue_id':50000+index,'url':f'https://github.com/{repo}/issues/{number}'}
        materials = {'prototype/next-phase/README.md','prototype/next-phase/next.js','docs/next-phase-solution-design.md'}
        for feature in registry['features']:
            materials.update(feature[key] for key in ('prototype','technical_design','backend_architecture') if key in feature)
        def git(*args):
            return subprocess.run(['git','-C',str(self.root),*args],capture_output=True,check=True).stdout.decode().strip()
        git('init','-q')
        git('add',*sorted(materials))
        git('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','Bind fixture materials')
        value.update(source_ref=git('rev-parse','HEAD'),source_ref_pending=False,source_manifest={source:hashlib.sha256((self.root/source).read_bytes()).hexdigest() for source in materials})
        self.write('backlog.json',value)
        runpy.run_path(str(self.package/'render_issues.py'))['render']()
        # Controlled remote read-back fixture, separate from the local renderer.
        value = self.read('backlog.json')
        value['github_parent']['body_sha256'] = value['epic_body_sha256']
        by_id = {task['id']:task for task in value['tasks']}
        for task in value['tasks']:
            task['github'].update(body_sha256=task['body_sha256'],parent_number=value['github_parent']['number'],blocked_by_numbers=[by_id[name]['github']['number'] for name in task['depends_on']]+task['external_dependencies'])
        self.write('backlog.json',value)

    def test_complete_preparation_is_valid_without_product_evidence(self):
        self.assertEqual(self.errors(),[])

    def test_user_architecture_decisions_cannot_drift(self):
        self.mutate('backlog.json',lambda value:value['architecture_decisions'].update(identity='mobile-only'))
        self.assertTrue(any('architecture decisions' in error for error in self.errors()))

    def test_renderer_does_not_manufacture_remote_receipts(self):
        value = self.read('backlog.json')
        value['github_parent']={'number':9000,'issue_id':99000,'url':f"https://github.com/{value['repository']}/issues/9000",'body_sha256':'historical-receipt'}
        self.write('backlog.json',value)
        runpy.run_path(str(self.package/'render_issues.py'))['render']()
        self.assertEqual(self.read('backlog.json')['github_parent']['body_sha256'],'historical-receipt')

    def test_published_cannot_use_old_source_ref(self):
        self.publish_fixture()
        (self.root/'docs/next-phase/backend-go.md').write_text('New architecture absent from committed source')
        self.assertTrue(any('stale/mismatched bytes' in error for error in self.errors()))

    def test_published_does_not_require_cancelled_management_review(self):
        self.publish_fixture()
        self.assertEqual(self.errors(),[])
        self.assertNotIn('management_prototype_status',self.read('feature-contracts.json')['features'][1])

    def test_routing_cannot_add_own_service(self):
        self.mutate('backlog.json',lambda value:next(t for t in value['tasks'] if t['id']=='NP05')['write_scope'].append('service/routes'))
        self.assertTrue(any('own routing/planning backend forbidden' in error for error in self.errors()))

    def test_go_backend_design_is_required_in_fingerprint(self):
        self.inputs.remove('docs/next-phase/backend-go.md')
        self.assertTrue(any('backend_architecture missing' in error for error in self.errors()))

    def test_management_cannot_return_to_login_only_scope(self):
        self.mutate('feature-contracts.json',lambda value:value['features'][1].update(management_ui=True))
        self.assertTrue(any('user/login-only scope' in error for error in self.errors()))

    def test_membership_module_is_not_hidden_backend_scope(self):
        self.mutate('backlog.json',lambda value:value['tasks'][2]['write_scope'].append('service/internal/membership'))
        self.assertTrue(any('B-end management write scope forbidden' in error for error in self.errors()))

    def test_agent_cannot_become_permanent_client_only(self):
        self.mutate('feature-contracts.json',lambda value:value['features'][2].update(target_executor='client'))
        self.assertTrue(any('executor migration contract' in error for error in self.errors()))

    def test_real_server_agent_is_not_this_iteration_task(self):
        self.mutate('backlog.json',lambda value:next(t for t in value['tasks'] if t['id']=='NP09')['write_scope'].append('service/internal/assistant'))
        self.assertTrue(any('real server Agent is deferred' in error for error in self.errors()))

    def test_missing_requirement_and_task_join_are_rejected(self):
        self.mutate('requirement-matrix.json',lambda value:value['requirements'].pop())
        self.assertTrue(any('coverage' in error for error in self.errors()))

    def test_dangling_dependency_is_rejected(self):
        self.mutate('backlog.json',lambda value:value['tasks'][3]['depends_on'].append('NP99'))
        self.assertTrue(any('missing dependency' in error for error in self.errors()))

    def test_cycle_is_rejected(self):
        self.mutate('backlog.json',lambda value:value['tasks'][0]['depends_on'].append('NP14'))
        self.assertTrue(any('cyclic' in error for error in self.errors()))

    def test_parallel_directory_contains_file_write_conflict(self):
        self.mutate('backlog.json',lambda value:value['tasks'][4]['write_scope'].append('app/lib/data/routes/provider.dart'))
        self.assertTrue(any('parallel write conflict' in error for error in self.errors()))

    def test_shared_lock_cannot_be_written_by_serial_consumer(self):
        self.mutate('backlog.json',lambda value:value['tasks'][4]['write_scope'].append('app/pubspec.lock'))
        self.assertTrue(any('shared domain' in error for error in self.errors()))

    def test_required_shared_owner_cannot_be_removed(self):
        self.mutate('backlog.json',lambda value:value['shared_file_owners'].pop('app/pubspec.lock'))
        self.assertTrue(any('required shared' in error for error in self.errors()))

    def test_contract_symlink_outside_candidate_is_rejected(self):
        outside = tempfile.TemporaryDirectory()
        self.addCleanup(outside.cleanup)
        path = self.package/'backlog.json'
        target = Path(outside.name)/'backlog.json'
        target.write_bytes(path.read_bytes())
        path.unlink()
        path.symlink_to(target)
        self.assertTrue(any('unsafe/missing contract' in error for error in self.errors()))

    def test_contract_missing_from_actual_fingerprint_is_rejected(self):
        self.inputs.remove(f'{next_phase.PACKAGE}/contracts.md')
        self.assertTrue(any('outside fingerprint' in error for error in self.errors()))

    def test_bool_schema_and_float_revision_are_not_integer_protocol(self):
        self.mutate('backlog.json',lambda value:value.update(schema_version=True))
        self.assertTrue(self.errors())

    def test_float_revision_is_rejected(self):
        self.mutate('requirement-matrix.json',lambda value:value.update(contract_revision=1.0))
        self.assertTrue(any('schema/revision' in error for error in self.errors()))

    def test_consistent_published_package_is_valid(self):
        self.publish_fixture()
        self.assertEqual(self.errors(),[])

    def test_reusing_existing_issue_or_self_blocking_is_rejected(self):
        self.publish_fixture(reserved_number=True)
        errors = self.errors()
        self.assertTrue(any('reuses previous/external' in error for error in errors))
        self.assertTrue(any('self-edge' in error for error in errors))

    def test_published_dependency_metadata_must_match_dag(self):
        self.publish_fixture()
        self.mutate('backlog.json',lambda value:value['tasks'][3]['github'].update(blocked_by_numbers=[]))
        self.assertTrue(any('publication mismatch' in error for error in self.errors()))

    def test_planned_check_cannot_carry_execution_evidence(self):
        self.mutate('requirement-matrix.json',lambda value:value['requirements'][0]['checks'][0]['evidence'].append('old-report.json'))
        self.assertTrue(any('cannot attest' in error for error in self.errors()))

    def test_browser_evidence_cannot_be_native(self):
        self.mutate('backlog.json',lambda value:value['tasks'][12]['verification'].update(evidence_kind='browser'))
        self.assertTrue(any('typed planned' in error for error in self.errors()))

    def test_prepare_work_cannot_claim_accepted(self):
        self.mutate('work.json',lambda value:value['tasks'][3].update(status='accepted',owner_agent_id='writer',evidence=['report']))
        self.assertTrue(any('cannot claim' in error for error in self.errors()))

    def test_future_command_cannot_claim_runnable_now(self):
        self.mutate('backlog.json',lambda value:value['tasks'][12]['commands'][1].update(availability='now'))
        self.assertTrue(any('cannot claim available now' in error for error in self.errors()))

    def test_sources_must_be_current_candidate_inputs(self):
        self.inputs.remove('prototype/next-phase/next.js')
        self.assertTrue(any('outside fingerprint' in error for error in self.errors()))

    def test_issue_feature_without_technical_design_is_rejected(self):
        (self.root/'docs/next-phase/routing.md').unlink()
        self.assertTrue(any('technical_design missing' in error for error in self.errors()))

    def test_issue_feature_without_prototype_is_rejected(self):
        (self.root/'prototype/next-phase/identity.html').unlink()
        self.assertTrue(any('prototype missing' in error for error in self.errors()))

    def test_issue_without_feature_mapping_is_rejected(self):
        self.mutate('backlog.json',lambda value:value['tasks'][5].pop('features'))
        self.assertTrue(any('feature source mapping' in error for error in self.errors()))

    def test_issue_cannot_omit_its_specific_technical_design_link(self):
        path = self.package/'issues/NP05.md'
        body = path.read_text().replace('/docs/next-phase/routing.md','/docs/only-general-design.md')
        path.write_text(body)
        self.mutate('backlog.json',lambda value:value['tasks'][5].update(body_sha256=hashlib.sha256(body.encode()).hexdigest()))
        self.assertTrue(any('technical_design link missing' in error for error in self.errors()))

    def test_local_issue_changed_after_hash_is_rejected(self):
        path = self.package/'issues/NP03.md'
        path.write_text(path.read_text()+'Unauthorized acceptance change')
        self.assertTrue(any('body hash mismatch' in error for error in self.errors()))

    def test_published_requires_real_bound_identities(self):
        self.publish_fixture()
        self.mutate('backlog.json',lambda value:value.update(github_parent=None))
        self.assertTrue(any('published identity missing' in error for error in self.errors()))

    def test_production_claim_is_rejected(self):
        self.mutate('backlog.json',lambda value:value.update(production_eligible=True))
        self.assertTrue(any('production' in error for error in self.errors()))

    def test_malformed_nested_type_fails_closed_without_crashing(self):
        self.mutate('backlog.json',lambda value:value['tasks'][0]['verification'].update(level={}))
        self.assertTrue(self.errors())

    def test_duplicate_json_key_is_rejected(self):
        path = self.package/'backlog.json'
        path.write_text('{"tasks": [], "tasks": []}')
        self.assertTrue(any('duplicate key' in error for error in self.errors()))

    def test_new_prototype_and_design_invalidate_candidate_but_screenshots_do_not(self):
        before = checks.fingerprint(self.root)
        image = self.root/'prototype/next-phase/evidence/review.png'
        image.parent.mkdir(parents=True,exist_ok=True)
        image.write_bytes(b'new screenshot')
        self.assertEqual(checks.fingerprint(self.root),before)
        for source in ('prototype/next-phase/next.js','docs/next-phase-solution-design.md'):
            before = checks.fingerprint(self.root)
            (self.root/source).write_text('Changed contract')
            self.assertNotEqual(checks.fingerprint(self.root),before)


if __name__ == '__main__':
    unittest.main()
