import json
from pathlib import Path
import shutil
import runpy
import tempfile
import unittest

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
        backlog = self.read('backlog.json')
        for skill in {name for task in backlog['tasks'] for name in task['skills']}:
            path = self.root/f'.agents/skills/{skill}/SKILL.md'
            path.parent.mkdir(parents=True,exist_ok=True)
            path.write_text('Fixture skill')
        # Normalize a repository that has already published back to draft.
        backlog['publication_status'] = 'draft'
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
        self.write('backlog.json',value)
        runpy.run_path(str(self.package/'render_issues.py'))['render']()

    def test_complete_preparation_is_valid_without_product_evidence(self):
        self.assertEqual(self.errors(),[])

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

    def test_local_issue_changed_after_hash_is_rejected(self):
        path = self.package/'issues/NP03.md'
        path.write_text(path.read_text()+'Unauthorized acceptance change')
        self.assertTrue(any('body hash mismatch' in error for error in self.errors()))

    def test_published_requires_real_bound_identities(self):
        self.mutate('backlog.json',lambda value:value.update(publication_status='published'))
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
