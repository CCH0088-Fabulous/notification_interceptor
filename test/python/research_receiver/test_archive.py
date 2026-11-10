from copy import deepcopy
import csv
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
import uuid
import zipfile

from tool.research_receiver.archive import read_archive, validate_archive
from tool.research_receiver.storage import Store, Rejected
from tool.research_receiver.validation import ValidationError
from tool.research_receiver.web import admin_app, upload_app

ROOT=Path(__file__).resolve().parents[3]


def fixture():
    batch=json.loads((ROOT/'test/fixtures/research_upload_v1.json').read_text())
    batch['kind']='notification_research_export'
    batch['exportId']=batch.pop('batchId')
    batch['consent']['version']=2
    batch.update(period={'startedAt':batch['consent']['acceptedAt'],'endedAt':0},
        retention={'eventDays':14,'hourDays':30,'eventLimit':50000,'hourLimit':4096,'databaseMaxBytes':64*1024*1024},
        captureFailuresSinceProcessStart=0,events=[{'eventId':hashlib.sha256(b'event').hexdigest(),
            'at':batch['createdAt'],'bucketStart':batch['hours'][0]['bucketStart'],'utcOffsetMinutes':0,
            'cohort':'demo','metrics':{'action_page_settings':1}}])
    return batch


def zipped(value, name='research.json'):
    out=io.BytesIO()
    with zipfile.ZipFile(out,'w',compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(name,json.dumps(value))
    return out.getvalue()


class ArchiveTests(unittest.TestCase):
    def test_ongoing_diagnostic_import_does_not_inflate_notification_totals(self):
        value=fixture()
        value['hours'][0]['metrics']['ongoing_excluded']=80
        value['events'][0]['metrics']={'ongoing_excluded':80}
        accepted=read_archive(zipped(value))
        self.assertEqual(accepted['hours'][0]['metrics']['ongoing_excluded'],80)
        self.store.import_archive(accepted)
        self.store.import_archive(accepted)
        totals=self.store.report(0,4102444800000,'demo')['sums']
        self.assertEqual(totals['processed'],2)
        self.assertEqual(totals['intercept_matched'],1)
        self.assertEqual(len(list(self.store.event_rows(self.pid))),1)

    def setUp(self):
        root=ROOT/'build/receiver-verification';root.mkdir(parents=True,exist_ok=True)
        self.temp=tempfile.TemporaryDirectory(dir=root)
        assert Path(self.temp.name).resolve().parent==root.resolve()
        self.addCleanup(self.temp.cleanup)
        self.path=Path(self.temp.name)/'receiver.sqlite3'
        self.store=Store(self.path)
        self.value=fixture()
        self.pid=self.value['participantId']

    def test_archive_has_all_hours_over_network_batch_size(self):
        base=self.value['hours'][0]
        self.value['hours']=[{**deepcopy(base),'bucketStart':base['bucketStart']-i*3600000} for i in range(120)]
        read=read_archive(zipped(self.value));self.assertEqual(len(read['hours']),120)
        self.store.import_archive(read)
        self.assertEqual(self.store.report(0,4102444800000,'demo')['sums']['processed'],240)

    def test_repeat_and_new_snapshot_dedup_hour_and_events(self):
        self.store.import_archive(read_archive(zipped(self.value)))
        self.store.import_archive(self.value)
        newer=deepcopy(self.value);newer['exportId']=str(uuid.uuid4())
        newer['hours'][0]['revision']+=1
        newer['hours'][0]['metrics'].update(processed=5,allow=4)
        self.store.import_archive(validate_archive(newer))
        self.assertEqual(self.store.report(0,4102444800000,'demo')['sums']['processed'],5)
        self.assertEqual(self.store.offline_status()['used'],1)
        self.assertEqual(len(list(self.store.event_rows(self.pid))),1)
        self.assertEqual(Store(self.path).offline_status()['used'],1)

    def test_changed_export_id_content_and_event_conflict_roll_back(self):
        self.store.import_archive(self.value)
        changed=deepcopy(self.value);changed['events'][0]['metrics']['action_page_settings']=2
        with self.assertRaises(Rejected):self.store.import_archive(changed)
        changed['exportId']=str(uuid.uuid4());changed['hours'][0]['revision']+=1
        changed['hours'][0]['metrics'].update(processed=9,allow=8)
        with self.assertRaises(Rejected):self.store.import_archive(changed)
        self.assertEqual(self.store.report(0,4102444800000,'demo')['sums']['processed'],2)

    def test_older_snapshot_does_not_overwrite_newer(self):
        self.store.import_archive(self.value)
        old=deepcopy(self.value);old['exportId']=str(uuid.uuid4());old['hours'][0]['revision']-=1
        old['hours'][0]['metrics'].update(processed=1,allow=0)
        self.store.import_archive(old)
        self.assertEqual(self.store.report(0,4102444800000,'demo')['sums']['processed'],2)

    def test_ten_offline_ids_and_deleted_id_refused(self):
        for _ in range(10):
            value=fixture();value['participantId']=str(uuid.uuid4());value['exportId']=str(uuid.uuid4())
            self.store.import_archive(value)
        with self.assertRaises(Rejected):self.store.import_archive(self.value)
        first=self.store.offline_status()['devices'][0]['participant_id']
        self.store.delete_participant(first)
        self.store.import_archive(self.value)
        self.assertEqual(self.store.offline_status()['used'],10)
        old=fixture();old['participantId']=first;old['exportId']=str(uuid.uuid4())
        with self.assertRaises(Rejected):self.store.import_archive(old)
        self.store.delete_participant(self.pid)
        self.assertEqual(list(self.store.event_rows(self.pid)),[])

    def test_scope_revocation_and_stale_file_cannot_restore(self):
        self.store.import_archive(self.value)
        newer=deepcopy(self.value);newer['exportId']=str(uuid.uuid4())
        newer['consent'].update(ruleStructures=False,configurationRevision=5);newer['ruleSnapshot']=None
        self.store.import_archive(newer)
        old=deepcopy(self.value);old['exportId']=str(uuid.uuid4());self.store.import_archive(old)
        self.assertIsNone(self.store.participant(self.pid)['profile'])

    def test_rejects_free_text_events_bad_period_and_bad_retention(self):
        mutations=[lambda x:x['events'][0].update(body='PRIVATE'),
                   lambda x:x['events'][0]['metrics'].update(keyword='PRIVATE'),
                   lambda x:x['period'].update(endedAt=x['createdAt']+1),
                   lambda x:x['retention'].update(eventDays=90),
                   lambda x:x['events'].append(deepcopy(x['events'][0]))]
        for mutate in mutations:
            value=fixture();mutate(value)
            with self.assertRaises(ValidationError):read_archive(zipped(value))

    def test_zip_paths_unknown_entries_and_corruption_rejected(self):
        for name in ('../research.json','folder/research.json','secret.txt'):
            with self.assertRaises(ValidationError):read_archive(zipped(self.value,name))
        raw=io.BytesIO()
        with zipfile.ZipFile(raw,'w') as archive:
            archive.writestr('research.json','{}');archive.writestr('other.txt','x')
        for content in (raw.getvalue(),b'not zip',zipped(self.value)[:50]):
            with self.assertRaises(ValidationError):read_archive(content)

    def test_admin_import_csv_rename_and_port_isolation(self):
        client=admin_app(self.store,{'admin_key':'a'*50,'session_secret':'s'*64,'upload_port':8765}).test_client()
        with client.session_transaction() as state:state.update(authenticated=True,csrf='test')
        self.assertEqual(client.post('/imports',data={'archives':(io.BytesIO(zipped(self.value)),'test.zip')}).status_code,403)
        response=client.post('/imports',data={'csrf':'test','archives':(io.BytesIO(zipped(self.value)),'test.zip')})
        self.assertEqual(response.status_code,200)
        self.assertIn('已导入',response.text)
        self.assertEqual(self.store.offline_status()['used'],1)
        response=client.get(f'/participants/{self.pid}/events.csv')
        rows=list(csv.DictReader(io.StringIO(response.data.decode('utf-8-sig'))))
        self.assertEqual(rows[0]['action_page_settings'],'1')
        self.assertEqual(client.post(f'/offline/{self.pid}/rename',data={'csrf':'test','label':'设备 A'}).status_code,302)
        self.assertIn('设备 A',client.get('/imports').text)
        self.assertEqual(upload_app(self.store,'i').test_client().get('/imports').status_code,404)

    def test_bad_archive_never_creates_install(self):
        with self.assertRaises(ValidationError):read_archive(zipped({'kind':'secret','body':'PRIVATE'}))
        self.assertEqual(self.store.offline_status()['used'],0)

    def test_old_disclosure_keeps_original_seven_day_detail_policy(self):
        self.value['consent']['version']=1
        self.value['retention']['eventDays']=7
        self.assertEqual(read_archive(zipped(self.value))['retention']['eventDays'],7)
