import Darwin
import SystemConfiguration
import XCTest
import AppKit
import AVFoundation
import CryptoKit

enum NativeUITestEnvironment {
    private struct IsolationError: LocalizedError {
        let reason: String
        var errorDescription: String? {
            "Native UI tests require a macOS VM with this user's active Aqua console. \(reason) Run the tests inside the isolated VM after logging in to its desktop."
        }
    }

    static func requireIsolatedAquaSession() throws {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            throw IsolationError(reason: "Cannot verify the hardware model.")
        }
        var model = [CChar](repeating: 0, count: size)
        let result = model.withUnsafeMutableBufferPointer { buffer in
            sysctlbyname("hw.model", buffer.baseAddress, &size, nil, 0)
        }
        guard result == 0, String(cString: model).hasPrefix("VirtualMac") else {
            throw IsolationError(reason: "The hardware model is not VirtualMac.")
        }

        var consoleUID: uid_t = 0
        guard let consoleUser = SCDynamicStoreCopyConsoleUser(nil, &consoleUID, nil),
              (consoleUser as String) != "loginwindow",
              getuid() != 0, consoleUID == getuid() else {
            throw IsolationError(reason: "The active console does not belong to the test user.")
        }

        let session = Process()
        let output = Pipe()
        session.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        session.arguments = ["managername"]
        session.standardOutput = output
        session.standardError = FileHandle.nullDevice
        do {
            try session.run()
        } catch {
            throw IsolationError(reason: "Cannot verify the Aqua session.")
        }
        session.waitUntilExit()
        let manager = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard session.terminationStatus == 0, manager == "Aqua" else {
            throw IsolationError(reason: "The test process is not in an Aqua session.")
        }
    }
}

/// Native presentation checks use an isolated home and a deterministic CLI.
/// No model operation or external discovery is executed by these fixtures.
final class WorkbenchReviewUITests: XCTestCase {
    private var app: XCUIApplication!
    private var root: URL!

    override func setUpWithError() throws {
        try NativeUITestEnvironment.requireIsolatedAquaSession()
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "Disposable VM screen-capture consent") { dialog in
            let text = dialog.staticTexts.allElementsBoundByIndex
                .map { $0.label + " " + (($0.value as? String) ?? "") }.joined(separator: " ")
            guard text.contains("tart-guest-agent"), text.contains("private window picker") else { return false }
            let allow = dialog.buttons["Allow"].firstMatch
            guard allow.exists else { return false }
            allow.click()
            return true
        }
        root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
            .appendingPathComponent("workbench-review-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let script = root.appendingPathComponent("agent/scripts/mlx-agent")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("models"), withIntermediateDirectories: true)
        let python = """
        import hashlib, json, math, os, pathlib, shutil, struct, sys, time, uuid, wave, zlib
        root = pathlib.Path(__file__).resolve().parents[2]
        args = sys.argv[1:]
        with (root / 'calls.jsonl').open('a') as f:
            f.write(json.dumps(args) + '\\n')
        if args and args[0] == 'task':
            task_root = pathlib.Path(args[args.index('--state-dir') + 1]) if '--state-dir' in args else root / 'Library/Application Support/mlx-agent/tasks'
            records_path = task_root / 'fixture-tasks.json'
            records = json.loads(records_path.read_text()) if records_path.exists() else []
            def reference(path):
                content = path.read_bytes()
                return dict(path=str(path), sha256=hashlib.sha256(content).hexdigest(), bytes=len(content))
            def png(width=4, height=3):
                def chunk(kind, data):
                    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
                pixels = b''.join(bytes((0,)) + bytes((220, 70, 40, 255)) * width for _ in range(height))
                return bytes((137, 80, 78, 71, 13, 10, 26, 10)) + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b'')
            def artifact(identifier, name, value):
                folder = task_root / 'artifacts' / identifier
                folder.mkdir(parents=True, exist_ok=True, mode=0o700)
                path = folder / name
                path.write_text(json.dumps(value, ensure_ascii=False, sort_keys=True))
                path.chmod(0o600)
                return reference(path)
            def finish(record):
                folder = task_root / 'artifacts' / record['id']
                request = json.loads(pathlib.Path(record['request']['path']).read_text())
                if record['kind'] == 'classification':
                    result = dict(schema='decide/1', model=record['model_path'], backend='mlx-embeddings', seconds=0.1,
                        answers={name:dict(type='choice', choice='billing', probabilities=dict(billing=0.9, technical=0.1))
                                 for name in request['parameters']['questions']})
                elif record['kind'] == 'transcribe':
                    result = dict(schema='transcribe/1', model=record['model_path'], backend='mlx-audio',
                        text='Fixture transcript retained from the accepted audio.', input_artifact=record['input_artifact'])
                elif record['kind'] == 'image_understanding':
                    result = dict(schema='describe/1', model=record['model_path'], backend='mlx-vlm',
                        text='The image shows a red object against a light background.', input_artifact=record['input_artifact'])
                elif record['kind'] == 'video_understanding':
                    result = dict(schema='describe/1', model=record['model_path'], backend='mlx-vlm',
                        text='The red square moves from left to right.', input_artifact=record['input_artifact'])
                elif record['kind'] == 'image_generation':
                    path = folder / 'output.png'
                    path.write_bytes(png())
                    path.chmod(0o600)
                    result = dict(schema='generate/1', model=record['model_path'], backend='mflux',
                        output_artifact=reference(path), width=4, height=3, steps=20, seed=42, seconds=0.1)
                elif record['kind'] == 'video_generation':
                    path = folder / 'output.mp4'
                    shutil.copyfile(root / 'fixture-video.mp4', path)
                    path.chmod(0o600)
                    result = dict(schema='video/1', model=record['model_path'], backend='mlx-video',
                        output_artifact=reference(path), width=256, height=256, frames=30, fps=10, seconds=3.0)
                else:
                    path = folder / 'output.wav'
                    with wave.open(str(path), 'wb') as output:
                        output.setnchannels(1); output.setsampwidth(2); output.setframerate(16000)
                        output.writeframes(b''.join(struct.pack('<h', int(2000 * math.sin(2 * math.pi * 220 * i / 16000))) for i in range(240000)))
                    path.chmod(0o600)
                    result = dict(schema='speak/1' if record['kind'] == 'speak' else 'music/1', model=record['model_path'], backend='mlx-audio', path=str(path),
                        output_artifact=reference(path), audio_seconds=15, sample_rate=16000, seconds=0.1,
                        duration=15, steps=30, seed=42)
                record.update(state='succeeded', completed_at='2026-01-01T00:00:01Z', result=artifact(record['id'], 'result.json', result))
            action = args[1]
            if action == 'capabilities':
                data = dict(schema='task-capabilities/1', request_schema='task-request/1', run_schema='task-run/1', tasks=[
                    dict(kind=kind, result_schema=result, cancellation=True, requires_local_model=True, model_verification=True)
                    for kind, result in [('classification', 'decide/1'), ('music_generation', 'music/1')]])
                data['tasks'].extend([
                    dict(kind='transcribe', result_schema='transcribe/1', cancellation=True, requires_local_model=True,
                         model_verification=True, request_schema='task-request/2', run_schema='task-run/2'),
                    dict(kind='speak', result_schema='speak/1', cancellation=True, requires_local_model=True,
                         model_verification=True, request_schema='task-request/2', run_schema='task-run/2')])
                data['tasks'].extend([
                    dict(kind='image_generation', result_schema='generate/1', cancellation=True, requires_local_model=True,
                         model_verification=True, request_schema='task-request/2', run_schema='task-run/2'),
                    dict(kind='image_understanding', result_schema='describe/1', cancellation=True, requires_local_model=True,
                         model_verification=True, request_schema='task-request/2', run_schema='task-run/2')])
                data['tasks'].extend([
                    dict(kind='video_generation', result_schema='video/1', cancellation=True, requires_local_model=True,
                         model_verification=True, request_schema='task-request/2', run_schema='task-run/2'),
                    dict(kind='video_understanding', result_schema='describe/1', cancellation=True, requires_local_model=True,
                         model_verification=True, request_schema='task-request/2', run_schema='task-run/2')])
                if (root / 'legacy-image-tasks').exists():
                    data['tasks'] = [task for task in data['tasks'] if task['kind'] != 'image_generation']
            elif action == 'start':
                request = json.loads(pathlib.Path(args[args.index('--request') + 1]).read_text())
                identifier = str(uuid.UUID(int=len(records) + 1))
                input_artifact = None
                if request['kind'] in ('transcribe', 'image_understanding', 'video_understanding'):
                    source_key, filename = ('audio_path', 'input.wav') if request['kind'] == 'transcribe' else (('image_path', 'input.png') if request['kind'] == 'image_understanding' else ('video_path', 'input.mp4'))
                    source = pathlib.Path(request['parameters'][source_key])
                    destination = task_root / 'artifacts' / identifier / filename
                    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                    shutil.copyfile(source, destination)
                    destination.chmod(0o600)
                    input_artifact = reference(destination)
                record = dict(schema='task-run/2' if request['kind'] in ('transcribe', 'speak', 'image_generation', 'image_understanding', 'video_generation', 'video_understanding') else 'task-run/1', id=identifier, kind=request['kind'], state='running', model_path=request['model_path'],
                    created_at='2026-01-01T00:00:00Z', started_at='2026-01-01T00:00:00Z', completed_at=None,
                    cancel_requested=False, execution_unresolved=False, supervisor=dict(pid=101), execution=dict(pid=102),
                    request=artifact(identifier, 'request.json', request), result=None, error=None,
                    identity=dict(backend='mlx-embeddings' if request['kind'] == 'classification' else 'mlx-audio',
                        backend_version='1.0', engine_version='0.7.0', python_version='3.12', model_fingerprint='a' * 64),
                    input_artifact=input_artifact)
                if request['kind'] in ('classification', 'transcribe', 'speak', 'image_generation', 'image_understanding', 'video_generation', 'video_understanding'): finish(record)
                records.insert(0, record)
                data = dict(task=record)
            elif action == 'list':
                limit = int(args[args.index('--limit') + 1]) if '--limit' in args else 20
                data = dict(tasks=records[:limit], has_more=len(records) > limit)
            else:
                identifier = args[args.index('--id') + 1]
                record = next(item for item in records if item['id'] == identifier)
                if action == 'cancel' and record['state'] == 'running':
                    record.update(state='cancelled', cancel_requested=True, completed_at='2026-01-01T00:00:01Z')
                elif action == 'status' and record['state'] == 'running' and (root / 'finish-music-task').exists():
                    finish(record)
                if action == 'verify-model':
                    assert pathlib.Path(record['model_path']).is_dir()
                    data = dict(id=record['id'], model_path=record['model_path'],
                                model_fingerprint=record['identity']['model_fingerprint'], matches=True)
                elif action == 'result':
                    assert record['state'] == 'succeeded'
                    data = dict(task=record, artifact=record['result'], inline=True,
                                result=json.loads(pathlib.Path(record['result']['path']).read_text()))
                else:
                    data = dict(task=record)
            if action in ('start', 'status', 'cancel'):
                records_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                records_path.write_text(json.dumps(records)); records_path.chmod(0o600)
        elif args[:2] == ['convert', 'scan']:
            if (root / 'fail-scan').exists():
                print('Fixture scan failed: choose a readable model root.', file=sys.stderr)
                sys.exit(2)
            data = {'models': [], 'outputs': [], 'pending': [], 'duplicates': [],
                    'totals': {'gguf': 0, 'pending': 0, 'converted': 0, 'unreadable': 0, 'bytes': 0, 'reclaimable_bytes': 0}}
            if (root / 'scan-result.json').exists():
                data = json.loads((root / 'scan-result.json').read_text())
        elif args[:2] == ['backend', 'list']:
            time.sleep(0.2)
            if (root / 'fail-backends').exists():
                print('Fixture backend status unavailable.', file=sys.stderr)
                sys.exit(2)
            entries = json.loads((root / 'backends.json').read_text()) if (root / 'backends.json').exists() else []
            data = {'schema':'backends/1', 'root':'/fixture/backends', 'backends':entries}
        elif args[:2] == ['backend', 'install'] and (root / 'allow-runtime-repair').exists():
            backend = args[2]
            if '--confirm' not in args:
                data = {'status':'preview', 'plan':{'id':backend, 'version':'1.0', 'target':'/fixture/backends/' + backend,
                        'package':backend, 'network':['pypi.org'], 'preview_hash':'runtime-repair-plan'}}
            else:
                assert args[args.index('--preview-hash') + 1] == 'runtime-repair-plan'
                entries = json.loads((root / 'backends.json').read_text())
                log_path = root / 'backend-install.log'
                if (root / 'fail-runtime-repair').exists():
                    log_path.write_text('Fixture dependency resolution failed. Review the pinned package requirements.\\n')
                    for entry in entries:
                        if entry['id'] == backend:
                            entry.update(state='failed', log_path=str(log_path), started_at='2026-01-01T00:00:00Z')
                else:
                    log_path.write_text('Fixture backend installed.\\n')
                    for entry in entries:
                        if entry['id'] == backend:
                            entry.update(state='installed', log_path=str(log_path), started_at='2026-01-01T00:01:00Z')
                    scan = json.loads((root / 'scan-result.json').read_text())
                    for output in scan['outputs']:
                        if output.get('backend', {}).get('id') == backend: output['backend']['installed'] = True
                    (root / 'scan-result.json').write_text(json.dumps(scan))
                (root / 'backends.json').write_text(json.dumps(entries))
                data = {'status':'started'}
        elif args and args[0] == 'doctor':
            time.sleep(0.5)
            if (root / 'fail-doctor').exists():
                print('Fixture doctor failed: inventory unavailable.', file=sys.stderr)
                sys.exit(2)
            data = {'findings': [], 'prune_count': 0}
        elif args and args[0] == 'discover':
            deadline = time.monotonic() + 30
            while (root / 'hold-discover').exists():
                if time.monotonic() > deadline:
                    print('Discovery fixture was not released.', file=sys.stderr)
                    sys.exit(2)
                time.sleep(0.05)
            time.sleep(0.5)
            if (root / 'fail-discover').exists():
                print('Fixture discovery failed: catalog unavailable.', file=sys.stderr)
                sys.exit(2)
            candidates = root / 'discover-candidates.json'
            data = {'candidates': json.loads(candidates.read_text()) if candidates.exists() else []}
        elif args[:2] == ['serve', 'status'] and (root / 'servers.json').exists():
            deadline = time.monotonic() + 20
            while (root / 'slow-server-status').exists():
                if time.monotonic() > deadline:
                    print('Server status fixture was not released.', file=sys.stderr)
                    sys.exit(2)
                time.sleep(0.05)
            time.sleep(0.3)
            if (root / 'fail-server-status').exists():
                print('Fixture server status failed.', file=sys.stderr)
                sys.exit(2)
            data = {'servers': json.loads((root / 'servers.json').read_text())}
        elif args[:2] == ['lora', 'status']:
            deadline = time.monotonic() + 20
            while (root / 'slow-training-status').exists():
                if time.monotonic() > deadline:
                    print('Training status fixture was not released.', file=sys.stderr)
                    sys.exit(2)
                time.sleep(0.05)
            if (root / 'fail-training-status').exists():
                print('Fixture training jobs unavailable: receipt directory is unreadable.', file=sys.stderr)
                sys.exit(2)
            data = {'jobs': json.loads((root / 'training-jobs.json').read_text()) if (root / 'training-jobs.json').exists() else []}
        elif args[:2] == ['lab', 'queue']:
            request = json.loads(pathlib.Path(args[args.index('--request') + 1]).read_text())
            assert request['operation'] == 'snapshot', 'This fixture only reads the conversion queue'
            data = {'conversion_queue':{'schema_version':'1.1', 'items':[]},
                    'queue_path':str(root / 'convert-queue.json')}
        elif args and args[0] == 'lab' and 'workspace' in args:
            request = json.loads(pathlib.Path(args[args.index('--request') + 1]).read_text())
            operation = request['operation']
            with (root / 'workspace-requests.jsonl').open('a') as stream:
                stream.write(json.dumps(request) + '\\n')
            if operation == 'training-history':
                deadline = time.monotonic() + 20
                while (root / 'slow-training-history').exists():
                    if time.monotonic() > deadline:
                        print('Training history fixture was not released.', file=sys.stderr)
                        sys.exit(2)
                    time.sleep(0.05)
                if (root / 'fail-training-history').exists():
                    print('Fixture training evaluations unavailable: history is unreadable.', file=sys.stderr)
                    sys.exit(2)
                data = {'evaluations': json.loads((root / 'training-history.json').read_text()) if (root / 'training-history.json').exists() else []}
            elif operation in ('training-preview', 'training-evaluate'):
                prompts = request.get('prompt_suite', {}).get('prompts', [dict(id='prompt', text=request.get('prompt', ''), max_tokens=request.get('max_tokens', 128))])
                plan = dict(schema_version='text-training-evaluation/2' if 'prompt_suite' in request else 'text-training-evaluation/1',
                            preview_hash='fixture-evaluation-preview', base_repo='fixture/base', seed=42, temperature=0.0)
                if 'prompt_suite' in request:
                    plan['prompt_suite'] = request['prompt_suite']
                else:
                    plan.update(prompt=request['prompt'], max_tokens=request.get('max_tokens', 128))
                if operation == 'training-preview':
                    data = {'plan': plan}
                else:
                    assert request['preview_hash'] == plan['preview_hash']
                    samples = [dict(id=p['id'], prompt=p['text'], max_tokens=p['max_tokens'], outputs=dict(baseline='Base output for ' + p['text'], adapter='Adapter output for ' + p['text'])) for p in prompts]
                    report = dict(plan, judgment=None)
                    if 'prompt_suite' in request:
                        report['samples'] = samples
                    else:
                        report['outputs'] = samples[0]['outputs']
                    data = dict(evaluation_id='text_eval_suite', artifact_sha256='a' * 64, report=report, reviews=[])
                    (root / 'suite-evaluation.json').write_text(json.dumps(data))
                    history = json.loads((root / 'training-history.json').read_text())
                    history.append(dict(id='text_eval_suite', prompt_count=len(prompts), suite_name=request.get('prompt_suite', {}).get('name')))
                    (root / 'training-history.json').write_text(json.dumps(history))
            elif operation == 'training-review':
                if (root / 'fail-training-review').exists():
                    print('Fixture review save failed.', file=sys.stderr)
                    sys.exit(2)
                saved = json.loads((root / 'suite-evaluation.json').read_text())
                assert request['artifact_sha256'] == saved['artifact_sha256']
                reviews = [r for r in saved['reviews'] if r['prompt_id'] != request['prompt_id']]
                review = dict(id='review_' + str(len(reviews)), evaluation_id=saved['evaluation_id'], artifact_sha256=saved['artifact_sha256'],
                              prompt_id=request['prompt_id'], reviewer_id='fixture-reviewer', preference=request['preference'],
                              notes=request.get('notes', ''), created_at='2026-10-16T00:00:00Z')
                saved['reviews'] = reviews + [review]
                (root / 'suite-evaluation.json').write_text(json.dumps(saved))
                data = dict(evaluation_id=saved['evaluation_id'], artifact_sha256=saved['artifact_sha256'], review_id=review['id'], reviews=saved['reviews'])
            elif operation == 'training-inspect':
                time.sleep(0.5)
                if (root / 'fail-training-inspect').exists():
                    print('Fixture retained evaluation unavailable.', file=sys.stderr)
                    sys.exit(2)
                if request['evaluation_id'] == 'text_eval_suite':
                    data = json.loads((root / 'suite-evaluation.json').read_text())
                else:
                    data = {'report': {'recipe': 'fixture frozen recipe', 'outputs': {'baseline': 'fixture base output', 'adapter': 'fixture adapter output'}},
                            'artifact_sha256': 'fixture-evaluation-sha256'}
            elif operation == 'snapshot' and (root / 'study-review-enabled').exists():
                data = {'history': {'items': [{'id':'exp_fixture', 'sealed':not (root / 'study-reviewed.json').exists(),
                    'states':['completed','completed'], 'evidence_completeness':'complete'}]}, 'queue':[]}
            elif operation == 'review-start':
                data = {'session_id':'review_fixture', 'prompt':'Two moving squares'}
            elif operation == 'review-media':
                data = {'left':str(root / 'review-left.mp4'), 'right':str(root / 'review-right.mp4')}
            elif operation == 'review-submit':
                (root / 'study-reviewed.json').write_text(json.dumps(request))
                data = {'review_id':'review_fixture', 'revision':1}
            elif operation == 'reveal':
                assert (root / 'study-reviewed.json').exists()
                data = {'review_id':'review_fixture', 'revision':1, 'canonical_by_display':{'left':'baseline','right':'alternate'},
                    'variable_path':'inference_steps', 'baseline_value':8, 'alternate_value':9}
            elif operation == 'recipe-catalog':
                data = {'recipes': [{'model_id':'Wan-AI/Wan2.1-T2V-1.3B-Diffusers',
                    'display_name':'Wan 2.1 T2V 1.3B (MPS)', 'revisions':['a'*40],
                    'unavailable_reason':'Install video runtime in Studies → Runtime setup.' if (root / 'missing-study-runtime').exists() else None}]}
            elif operation == 'recipe-prepare':
                time.sleep(0.5)
                if (root / 'fail-study-capture').exists():
                    print('Fixture cache changed. Capture again.', file=sys.stderr); sys.exit(2)
                manifest = dict(request['settings'])
                manifest.update(model_revision=manifest.pop('revision'), model_id='Wan-AI/Wan2.1-T2V-1.3B-Diffusers',
                    adapter_id='diffusers.wan2.1-t2v-1.3b.mps.v1', model_checksum='sha256:'+'b'*64,
                    source_checksums={'model_index.json':'c'*64}, runtime_versions={'python':'3.12'})
                data = {'manifest': manifest}
            elif operation == 'preview':
                data = {'changed_paths':[request['draft']['variable_path']]}
            elif operation == 'create':
                (root / 'study-created.json').write_text(json.dumps(request['draft']))
                data = {'experiment_id':'exp_fixture', 'job_ids':['job_a','job_b']}
            else:
                data = {}
        elif args[:2] == ['lora', 'inspect']:
            time.sleep(0.5)
            if (root / 'fail-training-setup').exists():
                print('Fixture setup inspection failed.', file=sys.stderr)
                sys.exit(2)
            blocked = (root / 'invalid-training-data').exists()
            checks = [dict(id=key, status='ready', message='Training executable found.' if key == 'runtime' else 'Cached base found.' if key == 'base' else '8 examples; enough for batch size 4.')
                      for key in ['runtime', 'base', 'train', 'valid']]
            if blocked:
                checks[2].update(status='blocked', code='dataset_invalid', message='train.jsonl line 2 is not valid JSON.', remediation='Correct line 2, then check setup again.')
            data = dict(schema_version=1, ready=not blocked, checks=checks, batch_size=int(args[args.index('--batch-size') + 1]),
                        repo=args[args.index('--repo') + 1] if '--repo' in args else None,
                        data=args[args.index('--data') + 1] if '--data' in args else None)
        elif args[:2] == ['lora', 'start']:
            time.sleep(1)
            confirming = '--confirm' in args
            if (root / ('fail-training-submit' if confirming else 'fail-training-preview')).exists():
                print('Fixture training submission failed.' if confirming else 'Fixture training preview failed.', file=sys.stderr)
                sys.exit(2)
            if confirming:
                assert args[args.index('--preview-hash') + 1] == 'fixture-training-preview'
                (root / 'confirmed-training.json').write_text(json.dumps(args))
                data = {}
            else:
                data = {'preview_hash': 'fixture-training-preview'}
        elif args[:2] == ['wire', 'apply']:
            time.sleep(1.5)
            model = args[2]
            config_path = pathlib.Path(args[args.index('--path') + 1])
            assert config_path.is_absolute() and root in config_path.parents
            target = args[args.index('--target') + 1]
            original = config_path.read_text()
            digest = hashlib.sha256(json.dumps([model, str(config_path), target, original]).encode()).hexdigest()
            preview = {'preview_hash': digest, 'diff': 'Configure ' + model + ' for ' + target}
            confirming = '--confirm' in args
            hold_preview = root / 'hold-wire-preview'
            deadline = time.monotonic() + 10
            while not confirming and hold_preview.exists():
                if time.monotonic() >= deadline:
                    (root / 'wire-preview-hold-expired').write_text('preview hold expired')
                    print('Fixture manual wiring preview hold timed out.', file=sys.stderr)
                    sys.exit(2)
                time.sleep(0.05)
            if (root / ('fail-wire-apply' if confirming else 'fail-wire-preview')).exists():
                print('Fixture manual wiring failed: inspect the config file and preview again.', file=sys.stderr)
                sys.exit(2)
            if confirming:
                assert args[args.index('--preview-hash') + 1] == digest
                applied = not (root / 'false-wire-apply').exists()
                if applied:
                    config_path.write_text(json.dumps({'model': model, 'target': target}))
                data = {'preview': preview, 'applied': applied}
            else:
                if (root / 'missing-wire-hash').exists():
                    preview.pop('preview_hash')
                data = {'preview': preview, 'requires_confirmation': True}
        elif args[:2] in (['adopt', 'start'], ['adopt', 'status']):
            if args[1] == 'start' and (root / 'hold-adopt-cancellation').exists():
                state_path = pathlib.Path(args[args.index('--state') + 1])
                role = args[args.index('--role') + 1]
                state_path.write_text(json.dumps({'workflow_id': 'stopped-' + state_path.stem,
                    'request': {'roles': [role]}, 'status': 'running', 'phase': 'verify', 'recommendations': []}))
                (root / 'adopt-cancellation-pid').write_text(str(os.getpid()))
                deadline = time.monotonic() + 60
                while (root / 'hold-adopt-cancellation').exists() and time.monotonic() < deadline:
                    time.sleep(0.05)
                sys.exit(2)
            time.sleep(1.5)
            deadline = time.monotonic() + 20
            while (root / 'hold-adopt-request').exists():
                if time.monotonic() > deadline:
                    print('Adoption fixture was not released.', file=sys.stderr)
                    sys.exit(2)
                time.sleep(0.05)
            if '--state' not in args:
                print('No adoption state path was supplied.', file=sys.stderr)
                sys.exit(2)
            state_path = pathlib.Path(args[args.index('--state') + 1])
            assert state_path.is_absolute() and state_path.parent.is_dir()
            if args[1] == 'start':
                if (root / 'fail-adopt-start').exists():
                    print('Fixture adoption failed: inspect the saved handoff and retry.', file=sys.stderr)
                    sys.exit(2)
                assert not state_path.exists(), 'A previous adoption must not be overwritten'
                role = args[args.index('--role') + 1]
                assert role in ['vision', 'embedding', 'coding', 'reasoning', 'general', 'tool-use']
                recommendation = [] if (root / 'adopt-no-recommendation').exists() else [
                    {'role': role, 'repo': 'mlx-community/Qwen-Coding-Long-Repository-Name-For-Local-Adoption-4bit',
                     'evidence_strength': 'verified'}]
                state = {'workflow_id': 'workflow-' + state_path.stem, 'status': 'complete', 'phase': 'complete',
                         'request': {'roles': [role]}, 'recommendations': recommendation,
                         'shortlist': [{'repo': 'shortlisted-only/model'}]}
                if (root / 'adopt-unknown').exists():
                    state = {'workflow_id': 'workflow-' + state_path.stem, 'request': {'roles': [role]}}
                state_path.write_text(json.dumps(state))
            else:
                assert state_path.is_file(), 'Status must read the actual adoption handoff'
                if (root / 'fail-adopt-status').exists():
                    print('Fixture adoption status failed: the handoff is temporarily unreadable. Refresh to try again.', file=sys.stderr)
                    sys.exit(2)
                state = json.loads(state_path.read_text())
            data = {'state': state}
        else:
            data = {'servers': [], 'jobs': [], 'changes': []}
        print(json.dumps({'status': 'ok', 'data': data}))
        """
        try python.write(to: script, atomically: true, encoding: .utf8)
        let config: [String: Any] = [
            "mlx_agent_path": root.appendingPathComponent("agent").path,
            "mlx_roots": [root.appendingPathComponent("models").path], "gguf_roots": [],
            "output_dir": root.appendingPathComponent("output").path,
            "verification_enabled": false, "watch_enabled": false
        ]
        try JSONSerialization.data(withJSONObject: config).write(to: root.appendingPathComponent("config.json"))
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func launch(appearance: String, route: String = "doctor", isolatedHome: Bool = false, configURL: URL? = nil,
                        forcedRoute: String? = nil) {
        if appearance == "Light" || appearance == "Dark" {
            let requested: XCUIDevice.Appearance = appearance == "Dark" ? .dark : .light
            XCUIDevice.shared.appearance = requested
            XCTAssertEqual(XCUIDevice.shared.appearance, requested, "Guest appearance did not change")
        }
        app = XCUIApplication()
        app.launchEnvironment["MLX_WORKBENCH_CONFIG"] = (configURL ?? root.appendingPathComponent("config.json")).path
        app.launchEnvironment["XDG_STATE_HOME"] = root.appendingPathComponent("state").path
        app.launchEnvironment["MLX_WORKBENCH_PYTHON"] = "/usr/bin/python3"
        if isolatedHome { app.launchEnvironment["CFFIXED_USER_HOME"] = root.path }
        // NSArgumentDomain overrides writes to AppStorage. A mutable route
        // must be selected through the UI rather than forced as a launch default.
        app.launchArguments = ["-mlx-workbench.setupCompleted.v1", "YES"]
        if let forcedRoute { app.launchArguments += ["-mlx-workbench.selectedRoute", forcedRoute] }
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30))
        resizeWindow(width: 1050, height: 720)
        let destinations = ["doctor": "Health", "models": "Library", "training-studio": "Training", "settings": "Settings", "studies": "Studies"]
        if let destination = destinations[route] { select(destination) }
    }

    private func capture(_ name: String) {
        app.activate()
        XCTAssertEqual(app.state, .runningForeground, "Capture requires the guest app in the foreground")
        let window = app.windows.firstMatch
        let size = window.frame.size
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "\(name)-\(Int(size.width))x\(Int(size.height))"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func resizeWindow(width: CGFloat, height: CGFloat) {
        let window = app.windows.firstMatch
        let screen = NSScreen.main?.frame
        func moveHorizontally(_ delta: CGFloat) {
            let titlebar = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
                .withOffset(CGVector(dx: 0, dy: 20))
            titlebar.press(forDuration: 0.1, thenDragTo: titlebar.withOffset(CGVector(dx: delta, dy: 0)))
        }
        // A restored window may extend past the guest display. Bring its
        // resize handle on-screen before dragging, then keep the capture visible.
        if let screen, window.frame.maxX > screen.maxX - 4 {
            moveHorizontally(screen.maxX - window.frame.maxX - 8)
        }
        let fittedWidth = min(width, screen?.width ?? width)
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        let target = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: fittedWidth - 2, dy: height - 2))
        corner.press(forDuration: 0.1, thenDragTo: target)
        if let screen, window.frame.minX < screen.minX {
            moveHorizontally(screen.minX - window.frame.minX)
        }
    }

    private func select(_ route: String) {
        app.activate()
        let button = app.buttons[route].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), route)
        button.click()
    }

    private func selectRadioOption(_ label: String, in group: String) {
        let option = app.radioGroups[group].firstMatch.radioButtons[label]
        XCTAssertTrue(option.waitForExistence(timeout: 10))
        XCTAssertTrue(option.isEnabled)
        let window = app.windows.firstMatch
        let frame = option.frame
        XCTAssertTrue(frame.midX.isFinite && frame.midY.isFinite && frame.width > 0 && frame.height > 0)
        XCTAssertTrue(window.frame.contains(frame), "\(label) must be visible: \(frame)")
        if option.value as? Int != 1 {
            window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                dx: frame.midX - window.frame.minX, dy: frame.midY - window.frame.minY
            )).click()
        }
        XCTAssertEqual(option.value as? Int, 1, app.debugDescription)
    }

    private func replace(_ field: XCUIElement, with value: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(value)
    }

    private func waitForHittability(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForHistoryTaskState(_ state: String) -> Bool {
        let status = app.staticTexts["task-status"].firstMatch
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND (label CONTAINS[c] %@ OR value CONTAINS[c] %@)", state, state),
            object: status
        )
        return XCTWaiter.wait(for: [expectation], timeout: 15) == .completed
    }

    private func attachTaskSelectionFailure(_ name: String) {
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "\(name)-screenshot"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let accessibility = XCTAttachment(string: app.debugDescription)
        accessibility.name = "\(name)-accessibility"
        accessibility.lifetime = .keepAlways
        add(accessibility)
        let callsURL = root.appendingPathComponent("calls.jsonl")
        let calls = (try? String(contentsOf: callsURL, encoding: .utf8)) ?? "Fixture CLI call log unavailable."
        let callsAttachment = XCTAttachment(string: calls)
        callsAttachment.name = "\(name)-fixture-cli-calls"
        callsAttachment.lifetime = .keepAlways
        add(callsAttachment)
    }

    private var routes: [String] {
        ["Overview", "Library", "Prepare", "Compare", "Run", "Activity", "Reclaim", "Clients",
         "Health", "Discover", "Studies", "Training", "Settings"]
    }

    private func assertPageContent(_ route: String) {
        let titles = ["Library": "No models found", "Prepare": "Choose a model to prepare",
                      "Run": "Serve a model", "Activity": "Servers", "Reclaim": "Quarantine",
                      "Clients": "Client wiring", "Health": "Model inventory findings",
                      "Discover": "Discovery", "Training": "LoRA fine-tune"]
        let element: XCUIElement
        if let title = titles[route] { element = app.staticTexts[title].firstMatch }
        else if route == "Settings" { element = app.staticTexts["Engine status"].firstMatch }
        else if route == "Studies" { element = app.buttons["New experiment…"] }
        else if route == "Overview" { element = app.buttons["Open Health"] }
        else { element = app.buttons["New set…"] }
        XCTAssertTrue(element.waitForExistence(timeout: 20), "Missing \(route) content")
    }

    func testRealAgentInventoryAndPages() throws {
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let agent = checkout.appendingPathComponent("vendor/mlx-agent")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: agent.appendingPathComponent("scripts/mlx-agent").path))
        let config: [String: Any] = [
            "mlx_agent_path": agent.path,
            "mlx_roots": [root.appendingPathComponent("models").path],
            "gguf_roots": [root.appendingPathComponent("models").path],
            "output_dir": root.appendingPathComponent("output").path,
            "verification_enabled": false, "watch_enabled": false
        ]
        try JSONSerialization.data(withJSONObject: config).write(to: root.appendingPathComponent("config.json"))
        launch(appearance: "System", route: "models")
        XCTAssertTrue(app.staticTexts["No models found"].waitForExistence(timeout: 30))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("calls.jsonl").path),
                       "The real-agent test must not call the fixture backend")
        for route in routes {
            select(route)
            assertPageContent(route)
            capture("Real-agent-\(route)")
        }
    }

    func testLibraryFirstFailureCanRetry() throws {
        try Data().write(to: root.appendingPathComponent("fail-scan"))
        launch(appearance: "Light", route: "models")
        XCTAssertTrue(app.staticTexts["Library scan failed"].waitForExistence(timeout: 20))
        let failure = text(containing: "Fixture scan failed")
        if !failure.exists, app.buttons["Details"].exists { app.buttons["Details"].click() }
        XCTAssertTrue(failure.waitForExistence(timeout: 5))
        capture("Library-first-scan-error-details")
        if app.popovers.firstMatch.exists { app.typeKey(XCUIKeyboardKey.escape, modifierFlags: []) }
        XCTAssertTrue(app.buttons["Open Settings"].isHittable)
        capture("Library-first-scan-failed")
        try FileManager.default.removeItem(at: root.appendingPathComponent("fail-scan"))
        app.buttons["Retry scan"].click()
        XCTAssertTrue(app.buttons["Retry scan"].waitForNonExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["No models found"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["Library scan failed"].exists)
        capture("Library-retry-empty-success")
        let addModel = app.buttons["Add from Hugging Face…"]
        func assertAcquisitionActionsFit() {
            let window = app.windows.firstMatch.frame
            for button in [addModel, app.buttons["Open Settings"], app.buttons["Scan again"]] {
                XCTAssertTrue(button.isHittable, button.label)
                let frame = button.frame
                XCTAssertGreaterThanOrEqual(frame.minX, window.minX, button.label)
                XCTAssertGreaterThanOrEqual(frame.minY, window.minY, button.label)
                XCTAssertLessThanOrEqual(frame.maxX, window.maxX, button.label)
                XCTAssertLessThanOrEqual(frame.maxY, window.maxY, button.label)
            }
        }
        assertAcquisitionActionsFit()
        resizeWindow(width: 740, height: 612)
        assertAcquisitionActionsFit()
        capture("Library-empty-compact-actions")
        addModel.click()
        let intake = app.windows["Add from Hugging Face"]
        XCTAssertTrue(intake.waitForExistence(timeout: 10))
        let source = intake.textFields["https://huggingface.co/org/name"]
        XCTAssertTrue(source.exists)
        XCTAssertEqual(source.value as? String ?? "", "")
        intake.buttons["Close"].click()
        XCTAssertTrue(intake.waitForNonExistence(timeout: 10))
        app.buttons["Open Settings"].click()
        XCTAssertTrue(app.staticTexts["Engine status"].waitForExistence(timeout: 10))
        select("Library")
        resizeWindow(width: 1050, height: 720)
        let model: [String: Any] = ["path": root.appendingPathComponent("models/existing.gguf").path,
                                   "name": "Existing model", "bytes": 1024, "status": "ready", "outputs": [],
                                   "readable": true, "architecture": "llama", "quantization": "Q4_K_M",
                                   "model_key": "existing"]
        try JSONSerialization.data(withJSONObject: ["models": [model], "outputs": [], "pending": [],
            "duplicates": [], "totals": ["gguf": 1, "pending": 0, "converted": 0, "unreadable": 0,
                                          "bytes": 1024, "reclaimable_bytes": 0]])
            .write(to: root.appendingPathComponent("scan-result.json"))
        app.buttons["Scan again"].click()
        XCTAssertTrue(text(containing: "Existing model").waitForExistence(timeout: 20))
        app.popUpButtons["Readiness"].click()
        app.menuItems["Needs Conversion"].click()
        XCTAssertTrue(app.buttons["Clear filters"].waitForExistence(timeout: 10))
        XCTAssertFalse(addModel.exists)
        capture("Library-filtered-recovery")
        app.buttons["Clear filters"].click()
        XCTAssertTrue(text(containing: "Existing model").waitForExistence(timeout: 10))
        let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8)
        XCTAssertFalse(calls.contains("\"intake\", \"fetch\""))
        XCTAssertFalse(calls.contains("\"backend\", \"install\""))
    }

    private func installTaskModel(kind: String, name: String) throws -> URL {
        let model = root.appendingPathComponent("models/" + kind)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data("{\"model_type\":\"fixture\"}".utf8).write(to: model.appendingPathComponent("config.json"))
        let scan: [String: Any] = ["models": [], "outputs": [["path": model.path, "name": name,
            "model_key": kind, "bytes": 1024, "readable": true,
            "task": ["type": kind, "use_cases": [], "source": "registry", "confidence": "confirmed"]]],
            "pending": [], "duplicates": [], "totals": ["gguf": 0, "pending": 0, "converted": 1,
                "unreadable": 0, "bytes": 1024, "reclaimable_bytes": 0]]
        try JSONSerialization.data(withJSONObject: scan).write(to: root.appendingPathComponent("scan-result.json"))
        return model
    }

    private func taskSubmissions() throws -> [[String: Any]] {
        let path = root.appendingPathComponent("Library/Application Support/mlx-agent/tasks/fixture-tasks.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [[String: Any]])
    }

    private func openRecentTaskHistory() {
        let history = app.buttons["task-history-open"].firstMatch
        if history.waitForExistence(timeout: 2), history.isHittable {
            history.click()
            return
        }
        let overflow = app.popUpButtons["more toolbar items"].firstMatch
        XCTAssertTrue(overflow.waitForExistence(timeout: 10), app.debugDescription)
        overflow.click()
        let historyItem = app.menuItems["Recent tasks"].firstMatch
        XCTAssertTrue(historyItem.waitForExistence(timeout: 10), app.debugDescription)
        historyItem.click()
    }

    private func waitForTaskState(_ state: String) {
        let status = app.staticTexts["task-status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 15))
        let settled = expectation(for: NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", state, state), evaluatedWith: status)
        wait(for: [settled], timeout: 20)
    }

    func testLibraryClassifierTaskAndMissingModelHistory() throws {
        let model = try installTaskModel(kind: "classification", name: "Fixture classifier")
        launch(appearance: "Dark", route: "models", isolatedHome: true)
        let row = app.outlines.staticTexts["Fixture classifier"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15)); row.doubleClick()
        let state = app.textViews["task-classification-state"]
        replace(state, with: "A customer requests a refund for a duplicate charge.")
        replace(app.textFields["task-question-0-name"], with: "route")
        replace(app.textFields["task-question-0-instructions"], with: "Choose the team for this request.")
        replace(app.textFields["task-question-0-option-0"], with: "billing")
        replace(app.textFields["task-question-0-option-1"], with: "technical")
        XCTAssertTrue(try taskSubmissions().isEmpty, "Editing must not submit inference")
        let start = app.buttons["task-start"]
        XCTAssertTrue(start.isEnabled); start.click()
        waitForTaskState("succeeded")
        XCTAssertTrue(text(containing: "00000000-0000-0000-0000-000000000001").waitForExistence(timeout: 10))
        XCTAssertEqual(try taskSubmissions().count, 1)
        XCTAssertTrue(app.buttons["task-reuse"].waitForExistence(timeout: 10))
        app.buttons["task-reuse"].click()
        XCTAssertEqual(state.value as? String, "A customer requests a refund for a duplicate charge.")
        XCTAssertEqual(try taskSubmissions().count, 1, "Reuse must only fill the draft")
        capture("Library-classifier-result-and-reuse")
        app.terminate()
        try FileManager.default.removeItem(at: model)
        try FileManager.default.removeItem(at: root.appendingPathComponent("scan-result.json"))
        launch(appearance: "Dark", route: "models", isolatedHome: true)
        XCTAssertTrue(app.staticTexts["No models found"].waitForExistence(timeout: 15))
        openRecentTaskHistory()
        let recorded = app.buttons["task-history-row-00000000-0000-0000-0000-000000000001"]
        XCTAssertTrue(recorded.waitForExistence(timeout: 15))
        guard waitForHittability(recorded, timeout: 5) else {
            attachTaskSelectionFailure("Classifier-history-row-not-hittable")
            XCTFail("The recorded classifier row must be hittable")
            return
        }
        recorded.click()
        guard waitForHistoryTaskState("succeeded") else {
            attachTaskSelectionFailure("Classifier-history-selection-did-not-render")
            XCTFail("Selecting the recorded classifier task must show its succeeded details")
            return
        }
        XCTAssertTrue(text(containing: "billing").waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["task-reuse"].isEnabled)
        XCTAssertEqual(try taskSubmissions().count, 1)
        capture("Library-history-with-missing-model")
        app.terminate()
        _ = try installTaskModel(kind: "music_generation", name: "Fixture music")
        launch(appearance: "Dark", route: "models", isolatedHome: true)
        let otherModel = app.outlines.staticTexts["Fixture music"].firstMatch
        XCTAssertTrue(otherModel.waitForExistence(timeout: 15)); otherModel.doubleClick()
        XCTAssertTrue(app.staticTexts["Generate music"].waitForExistence(timeout: 10))
        app.sheets.firstMatch.buttons["Done"].click()
        openRecentTaskHistory()
        let otherModelHistory = app.buttons["task-history-row-00000000-0000-0000-0000-000000000001"]
        XCTAssertTrue(otherModelHistory.waitForExistence(timeout: 15), "Toolbar history must include tasks for other models")
        otherModelHistory.click()
        waitForTaskState("succeeded")
        XCTAssertEqual(try taskSubmissions().count, 1, "Browsing history must not submit another task")
        capture("Library-history-with-another-model-selected")
    }

    func testLibraryMusicTaskLifecycle() throws {
        _ = try installTaskModel(kind: "music_generation", name: "Fixture music")
        launch(appearance: "Dark", route: "models", isolatedHome: true)
        let row = app.outlines.staticTexts["Fixture music"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15)); row.doubleClick()
        replace(app.textFields["task-music-caption"], with: "Quiet instrumental piano")
        XCTAssertTrue(try taskSubmissions().isEmpty)
        app.buttons["task-start"].click()
        waitForTaskState("running")
        app.buttons["task-cancel"].click()
        waitForTaskState("cancelled")
        XCTAssertEqual(try taskSubmissions().count, 1)
        try Data().write(to: root.appendingPathComponent("finish-music-task"))
        app.buttons["task-start"].click()
        waitForTaskState("succeeded")
        XCTAssertEqual(try taskSubmissions().count, 2)
        let play = app.buttons["task-audio-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10)); XCTAssertTrue(play.isEnabled); play.click()
        XCTAssertTrue(app.buttons["task-audio-pause"].waitForExistence(timeout: 5))
        capture("Library-music-result-playback")
        let inspector = app.sheets.firstMatch
        inspector.buttons["Done"].click()
        XCTAssertTrue(inspector.waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.buttons["task-audio-pause"].exists)
        XCTAssertEqual(try taskSubmissions().count, 2, "Closing the inspector must not submit work")
    }

    func testLibrarySpeechTaskLifecycle() throws {
        var outputs: [[String: Any]] = []
        for (kind, name) in [("speech_to_text", "Fixture transcription"), ("text_to_speech", "Fixture speech")] {
            let model = root.appendingPathComponent("models/" + kind)
            try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
            try Data("{\"model_type\":\"fixture\"}".utf8).write(to: model.appendingPathComponent("config.json"))
            outputs.append(["path": model.path, "name": name, "model_key": kind, "bytes": 1024, "readable": true,
                            "task": ["type": kind, "use_cases": [], "source": "registry", "confidence": "confirmed"]])
        }
        try JSONSerialization.data(withJSONObject: ["models": [], "outputs": outputs, "pending": [], "duplicates": [],
            "totals": ["gguf": 0, "pending": 0, "converted": 2, "unreadable": 0, "bytes": 2048, "reclaimable_bytes": 0]])
            .write(to: root.appendingPathComponent("scan-result.json"))
        let source = root.appendingPathComponent("input.wav")
        try Data("RIFFfixtureWAVE".utf8).write(to: source)

        launch(appearance: "Dark", route: "models", isolatedHome: true)
        let transcribeModel = app.outlines.staticTexts["Fixture transcription"].firstMatch
        XCTAssertTrue(transcribeModel.waitForExistence(timeout: 15)); transcribeModel.doubleClick()
        replace(app.textFields["task-transcribe-audio-path"], with: source.path)
        XCTAssertTrue(app.buttons["task-start"].isEnabled)
        XCTAssertTrue(try taskSubmissions().isEmpty, "Editing the speech form must not submit inference")
        app.buttons["task-start"].click()
        waitForTaskState("succeeded")
        let transcript = app.staticTexts["task-transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        XCTAssertTrue(text(containing: "Fixture transcript retained from the accepted audio.").exists)
        let taskScroll = app.scrollViews.containing(.staticText, identifier: "task-transcript").firstMatch
        for _ in 0..<8 where !transcript.isHittable {
            taskScroll.scroll(byDeltaX: 0, deltaY: transcript.frame.midY < taskScroll.frame.minY ? 300 : -300)
        }
        XCTAssertTrue(transcript.isHittable, app.debugDescription)
        capture("Library-transcription-result")

        let transcription = try XCTUnwrap(taskSubmissions().first)
        let input = try XCTUnwrap(transcription["input_artifact"] as? [String: Any])
        let retainedPath = try XCTUnwrap(input["path"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedPath))
        let requestRef = try XCTUnwrap(transcription["request"] as? [String: Any])
        let requestPath = try XCTUnwrap(requestRef["path"] as? String)
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: requestPath))) as? [String: Any])
        let parameters = try XCTUnwrap(request["parameters"] as? [String: Any])
        XCTAssertEqual(request["schema"] as? String, "task-request/2")
        XCTAssertEqual(parameters["audio_path"] as? String, source.path)
        XCTAssertNil(parameters["language"])
        try FileManager.default.removeItem(at: source)

        let reuse = app.buttons["task-reuse"]
        XCTAssertTrue(reuse.waitForExistence(timeout: 10))
        for _ in 0..<8 where !reuse.isHittable {
            taskScroll.scroll(byDeltaX: 0, deltaY: reuse.frame.midY < taskScroll.frame.minY ? 300 : -300)
        }
        XCTAssertTrue(reuse.isHittable, app.debugDescription)
        reuse.click()
        let reusedAudio = app.textFields["task-transcribe-audio-path"]
        let reused = expectation(
            for: NSPredicate(format: "value == %@", retainedPath),
            evaluatedWith: reusedAudio
        )
        wait(for: [reused], timeout: 15)
        XCTAssertEqual(reusedAudio.value as? String, retainedPath, app.debugDescription)
        XCTAssertEqual(try taskSubmissions().count, 1, "Reuse fills the form without starting another task")
        capture("Library-transcription-result-and-reuse")

        app.buttons["Done"].click()
        let speakModel = app.outlines.staticTexts["Fixture speech"].firstMatch
        XCTAssertTrue(waitForHittability(speakModel, timeout: 10), app.debugDescription)
        speakModel.doubleClick()
        replace(app.textViews["task-speak-text"], with: "A short spoken result.")
        capture("Library-speech-form")
        let speakStart = app.buttons["task-start"]
        XCTAssertTrue(speakStart.isEnabled); speakStart.click()
        waitForTaskState("succeeded")
        let play = app.buttons["task-audio-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10)); XCTAssertTrue(play.isEnabled); play.click()
        XCTAssertTrue(app.buttons["task-audio-pause"].waitForExistence(timeout: 5))
        let speech = try XCTUnwrap(taskSubmissions().last)
        let speechRequestReference = try XCTUnwrap(speech["request"] as? [String: Any])
        let speechRequestPath = try XCTUnwrap(speechRequestReference["path"] as? String)
        let speechRequest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: speechRequestPath))) as? [String: Any])
        let speechParameters = try XCTUnwrap(speechRequest["parameters"] as? [String: Any])
        XCTAssertEqual(speechRequest["schema"] as? String, "task-request/2")
        XCTAssertNil(speechParameters["voice"])
        XCTAssertNil(speechParameters["speed"])
        XCTAssertNil(speechParameters["lang_code"])
        capture("Library-speech-result-playback")
        XCTAssertEqual(try taskSubmissions().count, 2)

        app.buttons["Done"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 10))
        let speechModel = app.outlines.staticTexts["Fixture speech"].firstMatch
        XCTAssertTrue(waitForHittability(speechModel, timeout: 10), app.debugDescription)
        speechModel.doubleClick()
        XCTAssertTrue(app.buttons["task-audio-play"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["task-audio-pause"].exists, app.debugDescription)
        XCTAssertEqual(try taskSubmissions().count, 2, "Reopening history must not submit another task")
        app.buttons["Done"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 10))
        let transcriptionModel = app.outlines.staticTexts["Fixture transcription"].firstMatch
        XCTAssertTrue(waitForHittability(transcriptionModel, timeout: 10), app.debugDescription)
        transcriptionModel.doubleClick()
        XCTAssertTrue(app.staticTexts["Transcribe audio"].waitForExistence(timeout: 10))
        app.buttons["Done"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 10))
        app.buttons["Compare"].firstMatch.click()
        let routeChanged = app.staticTexts["Compare"].firstMatch
        XCTAssertTrue(routeChanged.waitForExistence(timeout: 10))
        let playbackStoppedForRouteChange = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.buttons["task-audio-pause"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [playbackStoppedForRouteChange], timeout: 5), .completed, app.debugDescription)
    }

    func testLibraryImageTasksUseDurableHistoryAndRetainedInputs() throws {
        var outputs: [[String: Any]] = []
        for (kind, name) in [("image_generation", "Fixture image generator"), ("vision_language", "Fixture vision model")] {
            let model = root.appendingPathComponent("models/" + kind)
            try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
            try Data("{\"model_type\":\"fixture\"}".utf8).write(to: model.appendingPathComponent("config.json"))
            outputs.append(["path": model.path, "name": name, "model_key": kind, "bytes": 1024, "readable": true,
                            "task": ["type": kind, "use_cases": [], "source": "registry", "confidence": "confirmed"]])
        }
        try JSONSerialization.data(withJSONObject: ["models": [], "outputs": outputs, "pending": [], "duplicates": [],
            "totals": ["gguf": 0, "pending": 0, "converted": 2, "unreadable": 0, "bytes": 2048, "reclaimable_bytes": 0]])
            .write(to: root.appendingPathComponent("scan-result.json"))
        let source = root.appendingPathComponent("input.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let opaqueRed = NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1)
        for y in 0..<2 {
            for x in 0..<2 { bitmap.setColor(opaqueRed, atX: x, y: y) }
        }
        let sourcePNG = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let decodedSource = try XCTUnwrap(NSBitmapImageRep(data: sourcePNG))
        XCTAssertEqual(decodedSource.pixelsWide, 2)
        XCTAssertEqual(decodedSource.pixelsHigh, 2)
        for y in 0..<2 {
            for x in 0..<2 {
                let pixel = try XCTUnwrap(decodedSource.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                XCTAssertEqual(pixel.alphaComponent, 1, accuracy: 0.001)
                XCTAssertGreaterThan(pixel.redComponent, pixel.greenComponent)
                XCTAssertGreaterThan(pixel.redComponent, pixel.blueComponent)
            }
        }
        try sourcePNG.write(to: source)
        let legacyTasks = root.appendingPathComponent("legacy-image-tasks")
        try Data().write(to: legacyTasks)

        launch(appearance: "Dark", route: "models", isolatedHome: true)
        let generator = app.outlines.staticTexts["Fixture image generator"].firstMatch
        XCTAssertTrue(generator.waitForExistence(timeout: 15)); generator.doubleClick()
        XCTAssertTrue(app.staticTexts["Generate image"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["task-image-generation-prompt"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["task-image-generation-settings"].exists)
        XCTAssertEqual(app.staticTexts["task-image-generation-settings"].value as? String ?? app.staticTexts["task-image-generation-settings"].label,
                       "1024 × 1024 · 40 steps · seed 42")
        XCTAssertFalse(app.textFields["task-image-generation-width"].isHittable)
        XCTAssertFalse(app.textFields["task-image-generation-height"].isHittable)
        XCTAssertFalse(app.buttons["Generate"].exists, "Image generation must use the durable task panel")
        XCTAssertFalse(text(containing: "Describe the image to generate.").exists, "An untouched form must not show a validation error")
        replace(app.textFields["task-image-generation-prompt"], with: "A red cup on a white table")
        app.buttons["task-start"].click()
        let recovery = app.buttons["task-engine-setup"]
        XCTAssertTrue(recovery.waitForExistence(timeout: 10))
        XCTAssertEqual(try taskSubmissions().count, 0, "Unsupported engines must not start inference")
        capture("Library-image-engine-recovery")
        recovery.click()
        let setup = app.buttons["Setup Assistant…"]
        XCTAssertTrue(setup.waitForExistence(timeout: 10), app.debugDescription)
        setup.click()
        XCTAssertTrue(app.buttons["Skip setup"].waitForExistence(timeout: 10))
        app.buttons["Skip setup"].click()
        select("Library")
        XCTAssertTrue(app.textFields["task-image-generation-prompt"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.textFields["task-image-generation-prompt"].value as? String, "A red cup on a white table")
        try FileManager.default.removeItem(at: legacyTasks)
        let advanced = app.disclosureTriangles["Advanced options"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 10), app.debugDescription)
        func toggleAdvanced() {
            let window = app.windows.firstMatch
            let frame = advanced.frame.intersection(window.frame)
            XCTAssertFalse(frame.isNull)
            // Native disclosure frames include the label; click the leading arrow.
            window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                dx: frame.minX + 24 + frame.height / 4 - window.frame.minX,
                dy: frame.midY - window.frame.minY
            )).click()
        }
        toggleAdvanced()
        XCTAssertTrue(app.textFields["task-image-generation-width"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.textFields["task-image-generation-width"].value as? String, "1024")
        XCTAssertEqual(app.textFields["task-image-generation-height"].value as? String, "1024")
        XCTAssertEqual(app.textFields["task-image-generation-steps"].value as? String, "40")
        XCTAssertEqual(app.textFields["task-image-generation-seed"].value as? String, "42")
        capture("Library-image-generation-advanced")
        toggleAdvanced()
        capture("Library-image-generation-form")
        app.buttons["task-start"].click()
        waitForTaskState("succeeded")
        XCTAssertTrue(app.buttons["task-export-image"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.images["task-image-output"].exists || app.otherElements["task-image-output"].exists)
        XCTAssertFalse(app.buttons["task-audio-play"].exists, "PNG results must not offer WAV playback")
        let generationScroll = app.scrollViews.containing(.button, identifier: "task-export-image").firstMatch
        let generatedImage = app.images["task-image-output"]
        for _ in 0..<8 where !generatedImage.isHittable || generatedImage.frame.minY < generationScroll.frame.minY || generatedImage.frame.maxY > generationScroll.frame.maxY {
            let delta = max(-300, min(300, generationScroll.frame.midY - generatedImage.frame.midY))
            generationScroll.scroll(byDeltaX: 0, deltaY: delta)
        }
        XCTAssertTrue(generatedImage.isHittable)
        XCTAssertGreaterThanOrEqual(generatedImage.frame.minY, generationScroll.frame.minY)
        XCTAssertLessThanOrEqual(generatedImage.frame.maxY, generationScroll.frame.maxY)
        capture("Library-image-generation-result")
        let imageExport = app.buttons["task-export-image"]
        for _ in 0..<8 where !imageExport.isHittable || imageExport.frame.minY < generationScroll.frame.minY || imageExport.frame.maxY > generationScroll.frame.maxY {
            let delta = max(-300, min(300, generationScroll.frame.midY - imageExport.frame.midY))
            generationScroll.scroll(byDeltaX: 0, deltaY: delta)
        }
        XCTAssertTrue(imageExport.isHittable)
        XCTAssertGreaterThanOrEqual(imageExport.frame.minY, generationScroll.frame.minY)
        XCTAssertLessThanOrEqual(imageExport.frame.maxY, generationScroll.frame.maxY)
        capture("Library-image-generation-export")
        let generated = try XCTUnwrap(taskSubmissions().first)
        let generatedRequest = try XCTUnwrap(generated["request"] as? [String: Any])
        let generatedRequestPath = try XCTUnwrap(generatedRequest["path"] as? String)
        let generatedRequestJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: generatedRequestPath))) as? [String: Any])
        let generatedParameters = try XCTUnwrap(generatedRequestJSON["parameters"] as? [String: Any])
        XCTAssertEqual(generatedRequestJSON["schema"] as? String, "task-request/2")
        XCTAssertEqual(Set(generatedParameters.keys), ["prompt", "width", "height", "steps", "seed"])
        XCTAssertEqual(generatedParameters["width"] as? Int, 1024)
        XCTAssertEqual(generatedParameters["height"] as? Int, 1024)
        XCTAssertEqual(generatedParameters["steps"] as? Int, 40)
        XCTAssertEqual(generatedParameters["seed"] as? Int, 42)

        app.buttons["Done"].click()
        let vision = app.outlines.staticTexts["Fixture vision model"].firstMatch
        XCTAssertTrue(waitForHittability(vision, timeout: 10), app.debugDescription); vision.doubleClick()
        XCTAssertTrue(app.staticTexts["Understand image"].waitForExistence(timeout: 10))
        replace(app.textFields["task-image-understanding-path"], with: source.path)
        replace(app.textFields["task-image-understanding-prompt"], with: "What color is the main object?")
        XCTAssertTrue(try taskSubmissions().count == 1, "Editing the form must not start inference")
        capture("Library-image-understanding-form")
        app.buttons["task-start"].click()
        waitForTaskState("succeeded")
        XCTAssertTrue(text(containing: "The image shows a red object against a light background.").waitForExistence(timeout: 10))
        let understanding = try XCTUnwrap(taskSubmissions().first)
        let retained = try XCTUnwrap(understanding["input_artifact"] as? [String: Any])
        let retainedPath = try XCTUnwrap(retained["path"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedPath))
        try FileManager.default.removeItem(at: source)
        let understandingRequest = try XCTUnwrap(understanding["request"] as? [String: Any])
        let understandingRequestPath = try XCTUnwrap(understandingRequest["path"] as? String)
        let understandingRequestJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: understandingRequestPath))) as? [String: Any])
        let understandingParameters = try XCTUnwrap(understandingRequestJSON["parameters"] as? [String: Any])
        XCTAssertEqual(understandingRequestJSON["schema"] as? String, "task-request/2")
        XCTAssertEqual(Set(understandingParameters.keys), ["image_path", "prompt"])
        XCTAssertEqual(understandingParameters["image_path"] as? String, source.path)
        XCTAssertNil(understandingParameters["fps"])
        let answer = app.staticTexts["task-image-understanding-result"]
        let understandingScroll = app.scrollViews.containing(.staticText, identifier: "task-image-understanding-result").firstMatch
        let inputPreview = app.images["task-image-input"]
        for _ in 0..<8 where !inputPreview.isHittable || inputPreview.frame.minY < understandingScroll.frame.minY || inputPreview.frame.maxY > understandingScroll.frame.maxY {
            let delta = max(-300, min(300, understandingScroll.frame.midY - inputPreview.frame.midY))
            understandingScroll.scroll(byDeltaX: 0, deltaY: delta)
        }
        XCTAssertTrue(inputPreview.isHittable)
        XCTAssertGreaterThanOrEqual(inputPreview.frame.minY, understandingScroll.frame.minY)
        XCTAssertLessThanOrEqual(inputPreview.frame.maxY, understandingScroll.frame.maxY)
        capture("Library-image-understanding-input")
        for _ in 0..<8 where !answer.isHittable || answer.frame.minY < understandingScroll.frame.minY || answer.frame.maxY > understandingScroll.frame.maxY {
            let delta = max(-300, min(300, understandingScroll.frame.midY - answer.frame.midY))
            understandingScroll.scroll(byDeltaX: 0, deltaY: delta)
        }
        XCTAssertTrue(answer.isHittable)
        XCTAssertGreaterThanOrEqual(answer.frame.minY, understandingScroll.frame.minY)
        XCTAssertLessThanOrEqual(answer.frame.maxY, understandingScroll.frame.maxY)
        capture("Library-image-understanding-answer")
        let reuse = app.buttons["task-reuse"]
        XCTAssertTrue(reuse.waitForExistence(timeout: 10))
        for _ in 0..<8 where !reuse.isHittable {
            understandingScroll.scroll(byDeltaX: 0, deltaY: reuse.frame.midY < understandingScroll.frame.minY ? 300 : -300)
        }
        XCTAssertTrue(reuse.isHittable, app.debugDescription)
        reuse.click()
        let reusedImage = app.textFields["task-image-understanding-path"]
        let reuseScroll = app.scrollViews.containing(.textField, identifier: "task-image-understanding-path").firstMatch
        XCTAssertTrue(reusedImage.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<8 where !reusedImage.isHittable {
            reuseScroll.scroll(byDeltaX: 0, deltaY: reusedImage.frame.midY < reuseScroll.frame.minY ? 300 : -300)
        }
        let retainedImage = expectation(for: NSPredicate(format: "value == %@", retainedPath), evaluatedWith: reusedImage)
        let reuseWait = XCTWaiter.wait(for: [retainedImage], timeout: 15)
        if reuseWait != .completed || reusedImage.value as? String != retainedPath {
            let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            screenshot.name = "Image-reuse-failure-screenshot"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let accessibility = XCTAttachment(string: app.debugDescription)
            accessibility.name = "Image-reuse-failure-accessibility"
            accessibility.lifetime = .keepAlways
            add(accessibility)
            let reuseState = "value=\(String(describing: reusedImage.value))\nhittable=\(reusedImage.isHittable)\nframe=\(reusedImage.frame)\nscrollFrame=\(reuseScroll.frame)\n"
            let stateAttachment = XCTAttachment(string: reuseState)
            stateAttachment.name = "Image-reuse-failure-field-state"
            stateAttachment.lifetime = .keepAlways
            add(stateAttachment)
            let calls = (try? String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8)) ?? "Fixture CLI call log unavailable."
            let callsAttachment = XCTAttachment(string: calls)
            callsAttachment.name = "Image-reuse-failure-fixture-calls"
            callsAttachment.lifetime = .keepAlways
            add(callsAttachment)
            let taskPath = root.appendingPathComponent("Library/Application Support/mlx-agent/tasks/fixture-tasks.json")
            let tasks = (try? String(contentsOf: taskPath, encoding: .utf8)) ?? "Fixture task state unavailable."
            let tasksAttachment = XCTAttachment(string: tasks)
            tasksAttachment.name = "Image-reuse-failure-fixture-tasks"
            tasksAttachment.lifetime = .keepAlways
            add(tasksAttachment)
        }
        XCTAssertEqual(reuseWait, .completed, app.debugDescription)
        XCTAssertEqual(reusedImage.value as? String, retainedPath, app.debugDescription)
        XCTAssertEqual(try taskSubmissions().count, 2, "Reusing the owned image only fills the form")
        capture("Library-image-understanding-result-and-reuse")
    }

    @MainActor
    func testLibraryVideoTasksUseDurableHistoryAndRetainedInputs() async throws {
        let generator = root.appendingPathComponent("models/video_generation")
        let vision = root.appendingPathComponent("models/vision_language")
        for model in [generator, vision] {
            try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
            try Data("{\"model_type\":\"fixture\"}".utf8).write(to: model.appendingPathComponent("config.json"))
        }
        let outputs: [[String: Any]] = [
            ["path": generator.path, "name": "Fixture video generator", "model_key": "video-generator", "bytes": 1024, "readable": true,
             "task": ["type": "video_generation", "use_cases": [], "source": "registry", "confidence": "confirmed"]],
            ["path": vision.path, "name": "Fixture video understanding", "model_key": "vision-language", "bytes": 1024, "readable": true,
             "task": ["type": "vision_language", "use_cases": [], "source": "registry", "confidence": "confirmed"]],
        ]
        try JSONSerialization.data(withJSONObject: ["models": [], "outputs": outputs, "pending": [], "duplicates": [],
            "totals": ["gguf": 0, "pending": 0, "converted": 2, "unreadable": 0, "bytes": 2048, "reclaimable_bytes": 0]])
            .write(to: root.appendingPathComponent("scan-result.json"))
        let source = root.appendingPathComponent("input.mp4")
        try writeStudyReviewClip(to: source, frames: 30)
        let sourceAsset = AVURLAsset(url: source)
        let sourceDuration = try await sourceAsset.load(.duration).seconds
        let sourceTracks = try await sourceAsset.loadTracks(withMediaType: .video)
        XCTAssertGreaterThan(sourceDuration, 0)
        XCTAssertFalse(sourceTracks.isEmpty)
        try FileManager.default.copyItem(at: source, to: root.appendingPathComponent("fixture-video.mp4"))

        launch(appearance: "Dark", route: "models", isolatedHome: true)
        func expand(_ title: String) {
            let disclosure = app.disclosureTriangles[title]
            XCTAssertTrue(disclosure.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(disclosure.isHittable, app.debugDescription)
            let window = app.windows.firstMatch
            let frame = disclosure.frame.intersection(window.frame)
            XCTAssertFalse(frame.isNull)
            if disclosure.value as? Int != 1 {
                // Native disclosure hit frames include the label; toggle via the leading arrow.
                window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                    dx: frame.minX + 24 + frame.height / 4 - window.frame.minX,
                    dy: frame.midY - window.frame.minY
                )).click()
            }
            if disclosure.value as? Int != 1 {
                let screenshot = XCTAttachment(screenshot: window.screenshot())
                screenshot.name = "Video-disclosure-\(title)-not-expanded"
                screenshot.lifetime = .keepAlways
                add(screenshot)
                let accessibility = XCTAttachment(string: app.debugDescription)
                accessibility.name = "Video-disclosure-\(title)-accessibility"
                accessibility.lifetime = .keepAlways
                add(accessibility)
            }
            XCTAssertEqual(disclosure.value as? Int, 1, app.debugDescription)
        }
        func videoControl(_ identifier: String, label: String) -> XCUIElement {
            app.buttons.matching(identifier: identifier)
                .matching(NSPredicate(format: "label == %@", label)).firstMatch
        }
        func reveal(_ element: XCUIElement, in scroll: XCUIElement) {
            let wheelOrigin = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5))
            XCTAssertTrue(scroll.frame.contains(wheelOrigin.screenPoint))
            XCTAssertLessThan(wheelOrigin.screenPoint.x, element.frame.minX)
            for _ in 0..<8 where !element.isHittable || element.frame.minY < scroll.frame.minY || element.frame.maxY > scroll.frame.maxY {
                let before = element.frame
                let delta = max(-300, min(300, scroll.frame.midY - element.frame.midY))
                wheelOrigin.scroll(byDeltaX: 0, deltaY: delta)
                let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in element.frame != before }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed,
                               "The scroll wheel must move content at the visible non-video gutter. Before: \(before), after: \(element.frame)")
            }
            XCTAssertTrue(element.isHittable, app.debugDescription)
            XCTAssertGreaterThanOrEqual(element.frame.minY, scroll.frame.minY)
            XCTAssertLessThanOrEqual(element.frame.maxY, scroll.frame.maxY)
        }
        let generationModel = app.outlines.staticTexts["Fixture video generator"].firstMatch
        XCTAssertTrue(generationModel.waitForExistence(timeout: 15)); generationModel.doubleClick()
        XCTAssertTrue(app.staticTexts["Generate video"].waitForExistence(timeout: 10))
        replace(app.textFields["task-video-generation-prompt"], with: "A red square moves across a white background")
        expand("Video settings")
        replace(app.textFields["task-video-generation-width"], with: "256")
        replace(app.textFields["task-video-generation-height"], with: "256")
        replace(app.textFields["task-video-generation-frames"], with: "17")
        replace(app.textFields["task-video-generation-fps"], with: "8")
        replace(app.textFields["task-video-generation-steps"], with: "8")
        replace(app.textFields["task-video-generation-seed"], with: "42")
        XCTAssertTrue(try taskSubmissions().isEmpty, "Editing the form must not submit inference")
        capture("Library-video-generation-form")
        app.buttons["task-start"].click()
        waitForTaskState("succeeded")
        let videoPlay = videoControl("task-video-output", label: "Play")
        XCTAssertTrue(videoPlay.waitForExistence(timeout: 15), app.debugDescription)
        let playerReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: videoPlay)
        XCTAssertEqual(XCTWaiter.wait(for: [playerReady], timeout: 15), .completed, app.debugDescription)
        let generatedPreview = app.descendants(matching: .any).matching(identifier: "task-video-output").firstMatch
        let generationScroll = app.scrollViews.containing(.button, identifier: "task-export-video").firstMatch
        reveal(generatedPreview, in: generationScroll)
        capture("Library-video-generation-result")
        let videoExport = app.buttons["task-export-video"]
        reveal(videoExport, in: generationScroll)
        capture("Library-video-generation-export")
        let generation = try XCTUnwrap(taskSubmissions().first)
        let generationRequestReference = try XCTUnwrap(generation["request"] as? [String: Any])
        let generationRequestPath = try XCTUnwrap(generationRequestReference["path"] as? String)
        let generationRequest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: generationRequestPath))) as? [String: Any])
        let generationParameters = try XCTUnwrap(generationRequest["parameters"] as? [String: Any])
        XCTAssertEqual(generationRequest["schema"] as? String, "task-request/2")
        XCTAssertEqual(generationParameters["prompt"] as? String, "A red square moves across a white background")
        XCTAssertEqual(generationParameters["width"] as? Int, 256)
        XCTAssertEqual(generationParameters["height"] as? Int, 256)
        XCTAssertEqual(generationParameters["frames"] as? Int, 17)
        XCTAssertEqual(generationParameters["fps"] as? Int, 8)
        XCTAssertEqual(generationParameters["steps"] as? Int, 8)
        XCTAssertEqual(generationParameters["seed"] as? Int, 42)

        app.buttons["Done"].click()
        let understandingModel = app.outlines.staticTexts["Fixture video understanding"].firstMatch
        XCTAssertTrue(waitForHittability(understandingModel, timeout: 10), app.debugDescription)
        understandingModel.doubleClick()
        let mode = app.radioGroups["task-understanding-mode"]
        let videoMode = mode.radioButtons["Video"]
        selectRadioOption("Video", in: "task-understanding-mode")
        XCTAssertTrue(app.staticTexts["Understand video"].waitForExistence(timeout: 10))
        replace(app.textFields["task-video-understanding-path"], with: source.path)
        replace(app.textFields["task-video-understanding-prompt"], with: "Which direction does the red square move?")
        expand("Advanced options")
        replace(app.textFields["task-video-understanding-fps"], with: "1")
        replace(app.textFields["task-video-understanding-temperature"], with: "0")
        replace(app.textFields["task-video-understanding-max-tokens"], with: "128")
        replace(app.textFields["task-video-understanding-max-pixels"], with: "65536")
        XCTAssertEqual(try taskSubmissions().count, 1, "Editing the form must not submit inference")
        capture("Library-video-understanding-form")
        app.buttons["task-start"].click()
        waitForTaskState("succeeded")
        let answer = app.staticTexts["task-video-understanding-result"]
        XCTAssertTrue(answer.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(answer.value as? String, "The red square moves from left to right.")
        let understandingScroll = app.scrollViews.containing(.staticText, identifier: "task-video-understanding-result").firstMatch
        let inputPreview = app.descendants(matching: .any).matching(identifier: "task-video-input").firstMatch
        reveal(inputPreview, in: understandingScroll)
        capture("Library-video-understanding-input")
        reveal(answer, in: understandingScroll)
        capture("Library-video-understanding-answer")
        let understanding = try XCTUnwrap(taskSubmissions().first)
        let retained = try XCTUnwrap(understanding["input_artifact"] as? [String: Any])
        let retainedPath = try XCTUnwrap(retained["path"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedPath))
        let requestReference = try XCTUnwrap(understanding["request"] as? [String: Any])
        let requestPath = try XCTUnwrap(requestReference["path"] as? String)
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: requestPath))) as? [String: Any])
        let parameters = try XCTUnwrap(request["parameters"] as? [String: Any])
        XCTAssertEqual(request["schema"] as? String, "task-request/2")
        XCTAssertEqual(Set(parameters.keys), ["video_path", "prompt", "fps", "temperature", "max_tokens", "max_pixels"])
        XCTAssertEqual(parameters["video_path"] as? String, source.path)
        try FileManager.default.removeItem(at: source)
        let imageMode = mode.radioButtons["Image"]
        let taskScroll = app.scrollViews.containing(.staticText, identifier: "task-video-understanding-result").firstMatch
        reveal(imageMode, in: taskScroll)
        selectRadioOption("Image", in: "task-understanding-mode")
        let reuse = app.buttons["task-reuse"]
        reveal(reuse, in: taskScroll)
        reuse.click()
        let reusedVideoMode = app.radioGroups["task-understanding-mode"].radioButtons["Video"]
        let videoModeRestored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 1"), object: reusedVideoMode)
        XCTAssertEqual(XCTWaiter.wait(for: [videoModeRestored], timeout: 15), .completed, app.debugDescription)
        XCTAssertEqual(reusedVideoMode.value as? Int, 1, app.debugDescription)
        let reusedPath = app.textFields["task-video-understanding-path"]
        let retainedValue = expectation(for: NSPredicate(format: "value == %@", retainedPath), evaluatedWith: reusedPath)
        XCTAssertEqual(XCTWaiter.wait(for: [retainedValue], timeout: 15), .completed, app.debugDescription)
        XCTAssertEqual(reusedPath.value as? String, retainedPath, app.debugDescription)
        XCTAssertEqual(try taskSubmissions().count, 2, "Reuse fills the form without starting another task")
        capture("Library-video-understanding-result-and-reuse")
        let inputPlay = videoControl("task-video-input", label: "Play")
        XCTAssertTrue(inputPlay.waitForExistence(timeout: 10), app.debugDescription)
        let inputReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: inputPlay)
        XCTAssertEqual(XCTWaiter.wait(for: [inputReady], timeout: 15), .completed, app.debugDescription)
        reveal(inputPlay, in: taskScroll)
        inputPlay.click()
        let inputPause = videoControl("task-video-input", label: "Pause")
        XCTAssertTrue(inputPause.waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["Done"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 10))
        XCTAssertTrue(waitForHittability(understandingModel, timeout: 10), app.debugDescription)
        understandingModel.doubleClick()
        let reopenedPlay = videoControl("task-video-input", label: "Play")
        XCTAssertTrue(reopenedPlay.waitForExistence(timeout: 10), app.debugDescription)
        let reopenedReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: reopenedPlay)
        XCTAssertEqual(XCTWaiter.wait(for: [reopenedReady], timeout: 15), .completed, app.debugDescription)
        XCTAssertFalse(videoControl("task-video-input", label: "Pause").exists, app.debugDescription)
    }

    func testDiscoveryStopRetryAndRetainedResults() throws {
        func writeCandidate(_ repo: String) throws {
            try JSONSerialization.data(withJSONObject: [["repo": repo, "roles": ["coding"], "est_ram_gb": 4,
                "fits": true, "license": "apache-2.0"]]).write(to: root.appendingPathComponent("discover-candidates.json"))
        }
        func expectContent(_ element: XCUIElement, _ value: String) {
            XCTAssertTrue(element.waitForExistence(timeout: 15))
            wait(for: [expectation(for: NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", value, value),
                                   evaluatedWith: element)], timeout: 15)
        }
        let first = "example/Discovery-Original-4bit", second = "example/Discovery-Retry-4bit"
        try writeCandidate(first)
        launch(appearance: "Dark", route: "scout", isolatedHome: true)
        select("Discover")
        let discover = app.scrollViews.containing(.staticText, identifier: "Discovery").buttons["Discover"].firstMatch
        XCTAssertTrue(discover.waitForExistence(timeout: 10))
        discover.click()
        XCTAssertTrue(text(containing: first).waitForExistence(timeout: 15))
        let context = app.staticTexts["discover-result-context"]
        expectContent(context, "Repository inspection")
        app.checkBoxes["Fast"].click()
        expectContent(context, "Repository inspection")
        try Data().write(to: root.appendingPathComponent("hold-discover"))
        discover.click()
        let stop = app.buttons["discover-stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        XCTAssertFalse(discover.isEnabled)
        XCTAssertFalse(app.buttons["Clear"].isEnabled)
        XCTAssertFalse(app.checkBoxes["Fast"].isEnabled)
        expectContent(context, "Showing previous search results")
        XCTAssertTrue(text(containing: first).exists)
        resizeWindow(width: 740, height: 612)
        capture("Discovery-retained-while-running-740")
        XCTAssertTrue(stop.isHittable)
        stop.click()
        XCTAssertTrue(text(containing: "Discovery stopped.").waitForExistence(timeout: 15))
        XCTAssertTrue(discover.isEnabled)
        XCTAssertTrue(text(containing: first).exists)
        try FileManager.default.removeItem(at: root.appendingPathComponent("hold-discover"))
        try Data().write(to: root.appendingPathComponent("fail-discover"))
        discover.click()
        XCTAssertTrue(text(containing: "Fixture discovery failed").waitForExistence(timeout: 15))
        XCTAssertTrue(text(containing: first).exists)
        expectContent(context, "Repository inspection")
        resizeWindow(width: 1050, height: 900)
        capture("Discovery-retained-after-failure-1050")
        try FileManager.default.removeItem(at: root.appendingPathComponent("fail-discover"))
        try writeCandidate(second)
        discover.click()
        XCTAssertTrue(text(containing: second).waitForExistence(timeout: 15))
        XCTAssertFalse(text(containing: first).exists)
        expectContent(context, "Search results")
        expectContent(context, "Fast")
        capture("Discovery-retry-current-results-1050")
        app.buttons["Clear"].click()
        XCTAssertFalse(text(containing: second).exists)
        let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8)
            .split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String] }
        XCTAssertEqual(calls.filter { $0.first == "discover" }.count, 4)
        XCTAssertFalse(calls.contains { Array($0.prefix(2)) == ["intake", "fetch"] })
        XCTAssertFalse(calls.contains { Array($0.prefix(2)) == ["serve", "start"] })
    }

    func testDiscoveryAndStudyReadinessGuidance() throws {
        func expectContent(_ element: XCUIElement, _ text: String) {
            XCTAssertTrue(element.waitForExistence(timeout: 15))
            let condition = NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", text, text)
            wait(for: [expectation(for: condition, evaluatedWith: element)], timeout: 15)
        }
        for appearance in ["Light", "Dark"] {
            launch(appearance: appearance, route: "scout", isolatedHome: true)
            select("Discover")
            let guidance = app.staticTexts["discover-inspection-guidance"]
            expectContent(guidance, "never runs a model")
            app.checkBoxes["Fast"].click()
            expectContent(guidance, "Sizes and memory-fit estimates may be missing")
            for width in [1050.0, 740.0] {
                resizeWindow(width: width, height: width == 740 ? 612 : 720)
                capture("Discover-guidance-\(appearance)-\(Int(width))")
            }
            let scroll = app.scrollViews.containing(.staticText, identifier: "Discovery").firstMatch
            let catalog = app.staticTexts["discover-catalog-guidance"]
            for _ in 0..<8 where !catalog.isHittable {
                scroll.scroll(byDeltaX: 0, deltaY: -200)
            }
            XCTAssertTrue(catalog.isHittable)
            expectContent(catalog, "no provider is configured")
            XCTAssertFalse(app.buttons["Refresh Metadata"].isEnabled)
            capture("Discover-catalog-unavailable-\(appearance)")
            selectRadioOption("Recommend for a task", in: "discovery-mode")
            let recommendation = app.staticTexts["adopt-inspection-guidance"]
            let recommendations = app.scrollViews.containing(.popUpButton, identifier: "adopt-role").firstMatch
            recommendations.checkBoxes["Fast"].click()
            expectContent(recommendation, "still receive verification prompts")
            capture("Discover-recommendation-guidance-\(appearance)")
            resizeWindow(width: 1050, height: 900)
            select("Studies")
            let create = app.buttons["New experiment…"]
            XCTAssertTrue(create.waitForExistence(timeout: 15))
            XCTAssertEqual(app.buttons["Studies"].value as? String, "Selected")
            resizeWindow(width: 740, height: 612)
            XCTAssertTrue(create.isHittable)
            create.click()
            let sheet = app.sheets.firstMatch
            let recipeGuidance = sheet.staticTexts["study-recipe-guidance"]
            expectContent(recipeGuidance, "Enter a prompt")
            XCTAssertFalse(app.buttons["Capture recipe"].isEnabled)
            let prompt = app.textFields["Shared prompt"].exists ? app.textFields["Shared prompt"] : app.textViews["Shared prompt"]
            replace(prompt, with: "A boat on a quiet lake")
            XCTAssertTrue(app.buttons["Capture recipe"].isEnabled)
            replace(app.textFields["Width"], with: "257")
            expectContent(recipeGuidance, "Width")
            XCTAssertFalse(app.buttons["Capture recipe"].isEnabled)
            XCTAssertFalse(app.buttons["Validate pair"].isEnabled)
            capture("Studies-invalid-setting-\(appearance)")
            XCTAssertLessThanOrEqual(sheet.frame.width, app.windows.firstMatch.frame.width)
            sheet.buttons["Cancel"].click()
            XCTAssertTrue(sheet.buttons["Discard changes"].firstMatch.waitForExistence(timeout: 5))
            sheet.buttons["Discard changes"].firstMatch.click()
            try Data().write(to: root.appendingPathComponent("missing-study-runtime"))
            app.buttons["New experiment…"].click()
            expectContent(recipeGuidance, "Install video runtime")
            XCTAssertFalse(app.buttons["Capture recipe"].isEnabled)
            capture("Studies-runtime-guidance-\(appearance)")
            sheet.buttons["Cancel"].click()
            try FileManager.default.removeItem(at: root.appendingPathComponent("missing-study-runtime"))
            let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8)
            for operation in ["adopt", "discover"] {
                XCTAssertFalse(calls.contains("\"" + operation + "\""), "Guidance must not start \(operation)")
            }
            let requests = try String(contentsOf: root.appendingPathComponent("workspace-requests.jsonl"), encoding: .utf8)
                .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
            let operations = requests.compactMap { $0["operation"] as? String }
            XCTAssertEqual(operations.count, requests.count)
            XCTAssertTrue(operations.contains("recipe-catalog"))
            XCTAssertTrue(Set(operations).isSubset(of: ["snapshot", "study-list", "recipe-catalog"]),
                          "Guidance may only read the workspace and recipe catalog: \(operations)")
            app.terminate()
        }
    }

    func testHealthAndDiscoveryResultsAndRecovery() throws {
        func statusText(_ element: XCUIElement) -> String { element.value as? String ?? element.label }
        func entries(_ audioState: String) -> [[String: Any]] {
            [("mlx-audio", audioState, "speech_to_text"), ("mflux", "absent", "image_generation"),
             ("mlx-vlm", "failed", "vision_language"), ("future-backend", "future-state", "future_task")].map { id, state, task in
                ["id": id, "version": "1.0", "builtin": false, "state": state,
                 "categories": [task], "model_types": 1, "registry_source": "snapshot"]
            }
        }
        func writeBackends(_ state: String) throws {
            try JSONSerialization.data(withJSONObject: entries(state)).write(to: root.appendingPathComponent("backends.json"))
        }
        func reveal(_ element: XCUIElement) {
            app.activate()
            XCTAssertEqual(app.state, .runningForeground)
            let scroll = app.scrollViews.containing(.button, identifier: "Refresh backends").firstMatch
            XCTAssertTrue(scroll.waitForExistence(timeout: 10))
            for _ in 0..<8 where !element.isHittable {
                // SwiftUI's scroll container may have no AX hit point; disabled
                // installation controls cannot receive a wheel event either.
                let anchor = scroll.buttons.allElementsBoundByIndex.first(where: { $0.isEnabled && $0.isHittable })
                    ?? scroll.staticTexts.allElementsBoundByIndex.first(where: { $0.isHittable })
                guard let anchor else {
                    let diagnostic = XCTAttachment(string: app.debugDescription)
                    diagnostic.name = "Health scroll hierarchy"
                    diagnostic.lifetime = .keepAlways
                    self.add(diagnostic)
                    capture("Health-scroll-unavailable")
                    XCTFail("Health needs visible content for scrolling")
                    return
                }
                anchor.scroll(byDeltaX: 0, deltaY: element.frame.midY < scroll.frame.minY ? 300 : -300)
            }
            XCTAssertTrue(element.isHittable)
        }
        defer {
            if let calls = try? String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8) {
                let attachment = XCTAttachment(string: calls)
                attachment.name = "Recovery CLI requests"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        try writeBackends("installed")
        launch(appearance: "Light", isolatedHome: true)
        let audio = app.staticTexts["health-backend-mlx-audio-status"]
        XCTAssertTrue(audio.waitForExistence(timeout: 15))
        XCTAssertEqual(statusText(audio), "Installed")
        XCTAssertEqual(statusText(app.staticTexts["health-backend-mflux-status"]), "Not installed")
        XCTAssertEqual(statusText(app.staticTexts["health-backend-mlx-vlm-status"]), "Install failed")
        XCTAssertEqual(statusText(app.staticTexts["health-backend-future-backend-status"]), "Unknown")
        let refresh = app.buttons["Refresh backends"]
        reveal(refresh)
        capture("Health-backends-installation-status")
        try Data().write(to: root.appendingPathComponent("fail-backends"))
        refresh.click()
        XCTAssertTrue(text(containing: "Fixture backend status unavailable").waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["health-backends-stale"].exists)
        XCTAssertEqual(statusText(audio), "Installed")
        capture("Health-backends-retained-after-failure")
        try FileManager.default.removeItem(at: root.appendingPathComponent("fail-backends"))
        try writeBackends("absent")
        refresh.click()
        let recovered = expectation(for: NSPredicate(format: "value == %@ OR label == %@", "Not installed", "Not installed"), evaluatedWith: audio)
        wait(for: [recovered], timeout: 15)
        XCTAssertFalse(app.staticTexts["health-backends-stale"].exists)
        resizeWindow(width: 814, height: 900)
        reveal(refresh)
        capture("Health-backends-compact-recovery")
        let add = app.buttons["Add from Hugging Face…"].firstMatch
        reveal(add)
        add.click()
        let intake = app.windows["Add from Hugging Face"]
        XCTAssertTrue(intake.waitForExistence(timeout: 10))
        XCTAssertEqual(intake.textFields["https://huggingface.co/org/name"].value as? String, "")
        intake.buttons["Close"].click()
        let run = app.buttons["Open Run"]
        reveal(run)
        run.click()
        XCTAssertTrue(app.staticTexts["Serve a model"].waitForExistence(timeout: 10))
        select("Health")
        resizeWindow(width: 1050, height: 720)
        let idle = "Inventory has not been checked. Run doctor to check local model files."
        XCTAssertTrue(app.staticTexts[idle].waitForExistence(timeout: 10))
        app.buttons["Run doctor"].click()
        XCTAssertTrue(app.staticTexts["No inventory issues found in the latest doctor run."].waitForExistence(timeout: 15))
        capture("Health-clean-success")
        app.buttons["Clear"].click()
        XCTAssertTrue(app.staticTexts[idle].exists)
        try Data().write(to: root.appendingPathComponent("fail-doctor"))
        app.buttons["Run doctor"].click()
        XCTAssertTrue(text(containing: "Fixture doctor failed").waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["No inventory issues found in the latest doctor run."].exists)
        capture("Health-failed-recovery")

        select("Discover")
        let discover = app.scrollViews.containing(.staticText, identifier: "Discovery")
            .buttons["Discover"].firstMatch
        XCTAssertTrue(discover.waitForExistence(timeout: 5))
        XCTAssertTrue(discover.isHittable)
        discover.click()
        let empty = "No candidates matched. Try another role or adjust the limit, then Discover again."
        XCTAssertTrue(app.staticTexts[empty].waitForExistence(timeout: 15))
        capture("Discover-empty-success")
        try Data().write(to: root.appendingPathComponent("fail-discover"))
        discover.click()
        XCTAssertTrue(text(containing: "Fixture discovery failed").waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts[empty].exists)
        let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8)
            .split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String] }
        XCTAssertEqual(calls.filter { $0.first == "discover" }.count, 2,
                       "Both Discover actions must reach the CLI")
        XCTAssertGreaterThanOrEqual(calls.filter { Array($0.prefix(2)) == ["backend", "list"] }.count, 3)
        XCTAssertFalse(calls.contains { Array($0.prefix(2)) == ["backend", "install"] })
        XCTAssertFalse(calls.contains { Array($0.prefix(2)) == ["intake", "fetch"] })
        capture("Discover-failed-recovery")

        select("Library")
        app.popUpButtons["library-source"].firstMatch.click()
        app.menuItems["LM Studio files"].click()
        XCTAssertTrue(app.buttons["Scan Again"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.textFields.firstMatch.exists, "The shelf reads LM Studio's folders; it takes no typed path")
        capture("LMStudio-shelf")
    }

    func testTrainingEditsRequireNewPreview() throws {
        launch(appearance: "Light", route: "training-studio")
        replace(app.textFields["Base model repo id"], with: "fixture/base")
        replace(app.textFields["Dataset path"], with: root.path)
        app.buttons["Preview Training"].click()
        XCTAssertTrue(app.buttons["Confirm & Train"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Confirm & Train"].isEnabled)
        capture("Training-reviewed-request")
        replace(app.textFields["Iterations"], with: "200")
        XCTAssertTrue(!app.buttons["Confirm & Train"].exists || !app.buttons["Confirm & Train"].isEnabled)
        capture("Training-edited-preview-invalidated")
        let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8)
        XCTAssertFalse(calls.contains("--confirm"))
    }

    func testStudyDraftCancellationPreservesEdits() throws {
        launch(appearance: "Dark", route: "studies", isolatedHome: true)
        let newExperiment = app.buttons["New experiment…"]
        XCTAssertTrue(newExperiment.waitForExistence(timeout: 15))
        let sheet = app.sheets.firstMatch
        func open() {
            newExperiment.click()
            XCTAssertTrue(text(containing: "Enter a prompt").waitForExistence(timeout: 15))
        }
        func cancelKeepingEdits() {
            sheet.buttons["Cancel"].click()
            XCTAssertTrue(sheet.buttons["Keep editing"].firstMatch.waitForExistence(timeout: 5))
            sheet.buttons["Keep editing"].firstMatch.click()
            XCTAssertTrue(sheet.exists)
        }
        func discard() {
            sheet.buttons["Cancel"].click()
            XCTAssertTrue(sheet.buttons["Discard changes"].firstMatch.waitForExistence(timeout: 5))
            capture("Studies-confirm-discard")
            sheet.buttons["Discard changes"].firstMatch.click()
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
        }
        open()
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "Catalog initialization must not dirty an untouched draft")
        open()
        let prompt = app.textFields["Shared prompt"].exists ? app.textFields["Shared prompt"] : app.textViews["Shared prompt"]
        replace(prompt, with: "Keep this experiment prompt")
        replace(app.textFields["Width"], with: "257")
        cancelKeepingEdits()
        XCTAssertEqual(prompt.value as? String, "Keep this experiment prompt")
        XCTAssertEqual(app.textFields["Width"].value as? String, "257")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(sheet.buttons["Keep editing"].firstMatch.waitForExistence(timeout: 5))
        sheet.buttons["Keep editing"].firstMatch.click()
        sheet.radioButtons["Recipe file"].click()
        cancelKeepingEdits()
        sheet.radioButtons["Cached model"].click()
        XCTAssertEqual(prompt.value as? String, "Keep this experiment prompt", "Hidden cached fields remain part of the draft")
        discard()
        open()
        sheet.radioButtons["Recipe file"].click()
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "Changing only the source tab is not authored work")
        open()
        sheet.radioButtons["Recipe file"].click()
        let recipe = root.appendingPathComponent("generation-recipe.json")
        try JSONSerialization.data(withJSONObject: ["model_id": "fixture/model", "adapter_id": "fixture.adapter",
            "prompt": "Imported experiment", "inference_steps": 20]).write(to: recipe)
        sheet.buttons["Choose generation recipe…"].click()
        let choose = app.buttons["OKButton"].firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 10), app.debugDescription)
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(recipe.path)
        app.typeKey(.return, modifierFlags: [])
        choose.click()
        XCTAssertTrue(sheet.buttons["generation-recipe.json"].waitForExistence(timeout: 10))
        cancelKeepingEdits()
        XCTAssertEqual(prompt.value as? String, "Imported experiment")
        replace(app.textFields["Alternate value"], with: "invalid")
        cancelKeepingEdits()
        XCTAssertEqual(app.textFields["Alternate value"].value as? String, "invalid")
        capture("Studies-retained-imported-draft")
        discard()
        let requests = try String(contentsOf: root.appendingPathComponent("workspace-requests.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertTrue(requests.allSatisfy { ["snapshot", "study-list", "recipe-catalog"].contains($0["operation"] as? String ?? "") },
                      "Cancel, keep and discard must not capture, validate, create or run an experiment")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("study-created.json").path))
    }

    func testStudyRecipeCaptureAndQueue() throws {
        for appearance in ["Light", "Dark"] {
            for file in ["study-review-enabled", "study-reviewed.json"] {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(file))
            }
            launch(appearance: appearance, route: "studies")
            XCTAssertTrue(app.buttons["New experiment…"].waitForExistence(timeout: 15))
            app.buttons["New experiment…"].click()
            let captureRecipe = app.buttons["Capture recipe"]
            XCTAssertTrue(captureRecipe.waitForExistence(timeout: 15))
            XCTAssertFalse(captureRecipe.isEnabled)
            let prompt = app.textFields["Shared prompt"].exists ? app.textFields["Shared prompt"] : app.textViews["Shared prompt"]
            replace(prompt, with: "A boat on a quiet lake")
            XCTAssertTrue(captureRecipe.isEnabled)
            try Data().write(to: root.appendingPathComponent("fail-study-capture"))
            captureRecipe.click()
            XCTAssertTrue(text(containing: "Fixture cache changed").waitForExistence(timeout: 15))
            XCTAssertFalse(app.buttons["Validate pair"].isEnabled)
            try FileManager.default.removeItem(at: root.appendingPathComponent("fail-study-capture"))
            captureRecipe.click()
            XCTAssertTrue(app.staticTexts["study-recipe-captured"].waitForExistence(timeout: 15))
            XCTAssertTrue(app.buttons["Validate pair"].isEnabled)
            XCTAssertTrue(app.textFields["Alternate value"].isHittable)
            replace(app.textFields["Alternate value"], with: "9")
            replace(app.textFields["Width"], with: "257")
            XCTAssertFalse(app.buttons["Validate pair"].isEnabled)
            XCTAssertFalse(captureRecipe.isEnabled)
            replace(app.textFields["Width"], with: "256")
            captureRecipe.click()
            XCTAssertTrue(app.staticTexts["study-recipe-captured"].waitForExistence(timeout: 15))
            app.buttons["Validate pair"].click()
            let create = app.buttons["Create experiment"]
            let enabled = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: create)
            wait(for: [enabled], timeout: 15)
            capture("Studies-recipe-validated-\(appearance)")
            let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screen.name = "Studies-recipe-confirmation-screen-\(appearance)"
            screen.lifetime = .keepAlways
            add(screen)
            create.click()
            let dismissed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.sheets.firstMatch)
            wait(for: [dismissed], timeout: 15)
            let saved = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("study-created.json"))) as? [String: Any])
            XCTAssertEqual(saved["variable_path"] as? String, "inference_steps")
            XCTAssertEqual(saved["alternate_value"] as? Int, 9)
            XCTAssertEqual((saved["baseline"] as? [String: Any])?["prompt"] as? String, "A boat on a quiet lake")
            try Data().write(to: root.appendingPathComponent("missing-study-runtime"))
            app.buttons["New experiment…"].click()
            XCTAssertTrue(text(containing: "Install video runtime").waitForExistence(timeout: 15))
            XCTAssertFalse(app.buttons["Capture recipe"].isEnabled)
            let imported = app.radioButtons["Recipe file"]
            XCTAssertTrue(imported.exists)
            imported.click()
            XCTAssertTrue(app.buttons["Choose generation recipe…"].waitForExistence(timeout: 5))
            capture("Studies-recipe-import-\(appearance)")
            app.sheets.buttons["Cancel"].click()
            try FileManager.default.removeItem(at: root.appendingPathComponent("missing-study-runtime"))
            try Data().write(to: root.appendingPathComponent("study-review-enabled"))
            let clips = ["review-left.mp4", "review-right.mp4"].map { root.appendingPathComponent($0) }
            for clip in clips { try Data("Invalid video".utf8).write(to: clip) }
            select("Library"); select("Studies")
            resizeWindow(width: 1050, height: 900)
            let review = app.buttons["Blind review…"]
            XCTAssertTrue(review.waitForExistence(timeout: 15))
            review.click()
            let sheet = app.sheets.firstMatch
            XCTAssertTrue(sheet.staticTexts["Blind video review"].waitForExistence(timeout: 10))
            sheet.radioButtons["Left"].click()
            let scores = sheet.popUpButtons.matching(NSPredicate(format: "identifier != %@", "study-review-audio"))
            XCTAssertEqual(scores.count, 10)
            for picker in scores.allElementsBoundByIndex {
                picker.click()
                picker.menuItems["5"].click()
                XCTAssertEqual(picker.value as? String, "5")
            }
            let submit = sheet.buttons["Submit immutable review"]
            XCTAssertFalse(submit.isEnabled, "Unavailable clips must block a new immutable review even with complete scores")
            XCTAssertTrue(text(containing: "Video unavailable").waitForExistence(timeout: 10))
            capture("Studies-review-unavailable-\(appearance)")
            try writeStudyReviewClip(to: clips[0], frames: 45)
            try writeStudyReviewClip(to: clips[1], frames: 30)
            sheet.buttons["Retry videos"].click()
            let playable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: submit)
            XCTAssertEqual(XCTWaiter.wait(for: [playable], timeout: 15), .completed)
            XCTAssertFalse(text(containing: "Video unavailable").exists)
            XCTAssertTrue(sheet.buttons["Play together"].isEnabled)
            let framesReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: sheet.buttons["Next frame"])
            XCTAssertEqual(XCTWaiter.wait(for: [framesReady], timeout: 10), .completed)
            let position = sheet.staticTexts["study-review-position"]
            func elapsed() -> String { "\(position.value as? String ?? "")|\(position.label)" }
            let beforeStep = elapsed()
            sheet.buttons["Next frame"].click()
            let stepped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                elapsed() != beforeStep
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [stepped], timeout: 5), .completed, "Before: \(beforeStep), after: \(elapsed())")
            sheet.buttons["Play together"].click()
            XCTAssertTrue(sheet.buttons["Pause"].isEnabled)
            sheet.buttons["Pause"].click()
            capture("Studies-review-playable-\(appearance)")
            submit.click()
            XCTAssertTrue(text(containing: "Review saved: review_fixture").waitForExistence(timeout: 15))
            XCTAssertFalse(submit.exists)
            sheet.buttons["Close"].click()
            for clip in clips { try Data("Unavailable again".utf8).write(to: clip) }
            review.click()
            XCTAssertTrue(text(containing: "Review saved: review_fixture").waitForExistence(timeout: 15))
            XCTAssertFalse(app.sheets.buttons["Submit immutable review"].exists)
            XCTAssertTrue(text(containing: "Video unavailable").waitForExistence(timeout: 10))
            capture("Studies-review-retained-without-media-\(appearance)")
            app.sheets.buttons["Close"].click()
            app.terminate()
        }
        let requests = try String(contentsOf: root.appendingPathComponent("workspace-requests.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertFalse(requests.contains { ["run", "study-run"].contains($0["operation"] as? String ?? "") })
        XCTAssertEqual(requests.filter { $0["operation"] as? String == "create" }.count, 2)
        XCTAssertEqual(requests.filter { $0["operation"] as? String == "review-submit" }.count, 2)
    }

    private func writeStudyReviewClip(to url: URL, frames: Int) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 128])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 128, kCVPixelBufferHeightKey as String: 128])
        XCTAssertTrue(writer.canAdd(input)); writer.add(input)
        XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            let deadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            let pool = try XCTUnwrap(adaptor.pixelBufferPool)
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            let pixel = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: 128, height: 128,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            context.setFillColor(CGColor(gray: 0.1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
            context.setFillColor(CGColor(red: 1, green: 0.8, blue: 0, alpha: 1))
            context.fill(CGRect(x: frame * 2 % 100, y: 48, width: 24, height: 24))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            XCTAssertTrue(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 15)))
        }
        input.markAsFinished(); writer.endSession(atSourceTime: CMTime(value: Int64(frames), timescale: 15))
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        XCTAssertEqual(finished.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(writer.status, .completed)
    }

    func testActivityRevealsTheModelThroughRetainedLibraryFilters() throws {
        let target = root.appendingPathComponent("models/target-image-mlx").path
        let scan: [String: Any] = ["models": [], "outputs": [["path": target, "name": "Target image model",
            "model_key": "target-image", "bytes": 1024, "readable": true,
            "task": ["type": "image_generation", "use_cases": [], "source": "registry", "confidence": "confirmed"]]],
            "pending": [], "duplicates": [], "totals": ["gguf": 0, "pending": 0, "converted": 1,
                "unreadable": 0, "bytes": 1024, "reclaimable_bytes": 0]]
        try JSONSerialization.data(withJSONObject: scan).write(to: root.appendingPathComponent("scan-result.json"))
        let support = root.appendingPathComponent("Library/Application Support/mlx-workbench")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let workflow: [String: Any] = ["id": UUID().uuidString, "sourcePath": root.appendingPathComponent("source.gguf").path,
            "outputPath": target, "completedModelPath": target, "state": "completed", "serveState": "idle",
            "createdAt": Date().timeIntervalSinceReferenceDate, "updatedAt": Date().timeIntervalSinceReferenceDate]
        try JSONSerialization.data(withJSONObject: [workflow]).write(to: support.appendingPathComponent("model-workflows.json"))
        launch(appearance: "Dark", route: "models", isolatedHome: true)
        XCTAssertTrue(text(containing: "Target image model").waitForExistence(timeout: 15))
        app.popUpButtons["Readiness"].click(); app.menuItems["Needs Conversion"].click()
        XCTAssertTrue(app.buttons["Clear filters"].waitForExistence(timeout: 10))
        for attempt in 0..<2 {
            select("Activity")
            let open = app.buttons["Open in Library"].firstMatch
            guard open.waitForExistence(timeout: 15) else {
                let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
                screenshot.name = "Activity-open-in-library-not-hittable-\(attempt)"
                screenshot.lifetime = .keepAlways
                add(screenshot)
                let accessibility = XCTAttachment(string: app.debugDescription)
                accessibility.name = "Activity-open-in-library-accessibility-\(attempt)"
                accessibility.lifetime = .keepAlways
                add(accessibility)
                XCTFail("Open in Library must become hittable after Activity navigation")
                return
            }
            XCTAssertTrue(open.isEnabled, app.debugDescription)
            let window = app.windows.firstMatch
            let frame = open.frame
            XCTAssertTrue(frame.midX.isFinite && frame.midY.isFinite && frame.width > 0 && frame.height > 0)
            XCTAssertTrue(window.frame.contains(frame), "Open in Library must be inside the visible window: \(frame)")
            if waitForHittability(open, timeout: 10) {
                open.click()
            } else {
                window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                    dx: frame.midX - window.frame.minX, dy: frame.midY - window.frame.minY
                )).click()
            }
            let inspector = app.sheets.firstMatch
            XCTAssertTrue(inspector.waitForExistence(timeout: 10), "Explicit reveals must open the requested inspector")
            NSPasteboard.general.clearContents()
            let more = inspector.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "More actions for Target image model")).firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 10)); more.click()
            app.menuItems["Copy Path"].click()
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), target, "The inspector must belong to the exact requested model")
            capture("Library-explicit-reveal-\(attempt)")
            inspector.buttons["Done"].click()
            XCTAssertTrue(inspector.waitForNonExistence(timeout: 10))
            XCTAssertFalse(app.buttons["Clear filters"].exists)
        }
        app.popUpButtons["Readiness"].click(); app.menuItems["Needs Conversion"].click()
        select("Overview"); select("Library")
        XCTAssertTrue(app.buttons["Clear filters"].waitForExistence(timeout: 10), "Ordinary navigation must preserve filters after the intent is consumed")
        XCTAssertFalse(app.sheets.firstMatch.exists)
    }

    func testRunningTrainingJobRefreshesToCompletion() throws {
        let file = root.appendingPathComponent("training-jobs.json")
        var job: [String: Any] = ["receipt": "fixture-trained-adapter", "repo": "fixture/base",
                                  "out": root.appendingPathComponent("adapter").path, "pid": 123, "state": "running"]
        try JSONSerialization.data(withJSONObject: [job]).write(to: file)
        launch(appearance: "Dark", route: "training-studio", isolatedHome: true)
        resizeWindow(width: 1024, height: 680)
        XCTAssertTrue(app.buttons["Cancel training"].waitForExistence(timeout: 15))
        job["state"] = "done"
        job["adapter_identity"] = ["sha256": "fixture-adapter-identity"]
        try JSONSerialization.data(withJSONObject: [job]).write(to: file)
        let compare = app.buttons["Compare with base"]
        XCTAssertTrue(compare.waitForExistence(timeout: 15), "A finished job must expose evaluation without a manual refresh")
        XCTAssertFalse(app.buttons["Cancel training"].exists)
        let scroll = app.scrollViews.containing(.textField, identifier: "Base model repo id").firstMatch
        for _ in 0..<8 where !compare.isHittable { scroll.scroll(byDeltaX: 0, deltaY: -280) }
        XCTAssertTrue(compare.isHittable)
        capture("Training-completed-without-refresh")
    }

    func testActivityRetriesTrainingStatusAndOpensFailedJobLogWithoutRestarting() throws {
        let log = root.appendingPathComponent("failed-training.log")
        try (String(repeating: "older log line\n", count: 8000) + "Training failed: fixture runtime error\n").write(to: log, atomically: true, encoding: .utf8)
        let job: [String: Any] = ["receipt": "fixture-failed-adapter", "repo": "fixture/failed-base",
            "out": root.appendingPathComponent("adapter").path, "pid": 123, "state": "failed", "log_path": log.path]
        let file = root.appendingPathComponent("training-jobs.json")
        let original = try JSONSerialization.data(withJSONObject: [job])
        try original.write(to: file)
        try Data().write(to: root.appendingPathComponent("fail-training-status"))
        launch(appearance: "Dark", isolatedHome: true)
        select("Activity")
        let retry = app.buttons["Retry status"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Open Health"].firstMatch.isEnabled)
        capture("Activity-training-status-recovery")
        try FileManager.default.removeItem(at: root.appendingPathComponent("fail-training-status"))
        let canRetry = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: retry)
        wait(for: [canRetry], timeout: 10)
        retry.click()
        let setup = app.buttons["Review training setup"].firstMatch
        XCTAssertTrue(setup.waitForExistence(timeout: 15))
        XCTAssertFalse(retry.exists)
        XCTAssertTrue(app.staticTexts["fixture/failed-base"].firstMatch.exists)
        let viewLog = app.buttons["View log"].firstMatch
        XCTAssertTrue(viewLog.isHittable); viewLog.click()
        let sheet = app.sheets.firstMatch
        let tail = sheet.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "fixture runtime error", "fixture runtime error")).firstMatch
        XCTAssertTrue(tail.waitForExistence(timeout: 10))
        XCTAssertTrue(sheet.staticTexts["(truncated to the tail)"].exists)
        capture("Activity-failed-training-log-tail")
        sheet.buttons["Close"].click()
        setup.click()
        XCTAssertTrue(app.textFields["Base model repo id"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Confirm & Train"].exists)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("confirmed-training.json").path))
    }

    func testTrainingDatasetCreationSavesWithoutStartingWork() throws {
        launch(appearance: "Dark", route: "training-studio", isolatedHome: true)
        let scroll = app.scrollViews.containing(.textField, identifier: "Dataset path").firstMatch
        func reveal(_ element: XCUIElement) {
            XCTAssertTrue(element.waitForExistence(timeout: 10), app.debugDescription)
            for _ in 0..<8 where !element.isHittable {
                scroll.scroll(byDeltaX: 0, deltaY: element.frame.midY < scroll.frame.minY ? 180 : -180)
            }
            XCTAssertTrue(element.isHittable)
        }
        func replace(_ field: XCUIElement, _ value: String) {
            field.click()
            app.typeKey("a", modifierFlags: .command)
            field.typeText(value)
        }
        let batch = app.textFields["Batch size"]
        reveal(batch); replace(batch, "1")
        let create = app.buttons["training-create-dataset"]
        reveal(create); create.click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        let save = sheet.buttons["Save dataset…"]
        XCTAssertFalse(save.isEnabled)
        capture("Dataset-editor-empty-standard")
        replace(sheet.textFields["dataset-train-1-prompt"], "What is a local model?")
        replace(sheet.textFields["dataset-train-1-reply"], "A model that runs on your own computer.")
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(sheet.buttons["Keep editing"].firstMatch.waitForExistence(timeout: 5))
        sheet.buttons["Keep editing"].firstMatch.click()
        let validation = sheet.radioButtons.matching(NSPredicate(format: "label BEGINSWITH %@", "Validation")).firstMatch
        XCTAssertTrue(validation.exists, app.debugDescription)
        validation.click()
        replace(sheet.textFields["dataset-valid-1-prompt"], "Why keep validation examples separate?")
        replace(sheet.textFields["dataset-valid-1-reply"], "They check performance on examples held out from learning.")
        XCTAssertTrue(save.isEnabled)
        capture("Dataset-editor-ready-standard")
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(sheet.buttons["Discard changes"].firstMatch.waitForExistence(timeout: 5))
        sheet.buttons["Discard changes"].firstMatch.click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
        resizeWindow(width: 740, height: 560)
        reveal(create); create.click()
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        replace(sheet.textFields["dataset-train-1-prompt"], "What is a local model?")
        replace(sheet.textFields["dataset-train-1-reply"], "A model that runs on your own computer.")
        sheet.radioButtons.matching(NSPredicate(format: "label BEGINSWITH %@", "Validation")).firstMatch.click()
        replace(sheet.textFields["dataset-valid-1-prompt"], "Why keep validation examples separate?")
        replace(sheet.textFields["dataset-valid-1-reply"], "They check performance on held-out examples.")
        let bounds = sheet.frame, window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(bounds.minX, window.minX)
        XCTAssertLessThanOrEqual(bounds.maxX, window.maxX)
        XCTAssertGreaterThanOrEqual(bounds.minY, window.minY)
        XCTAssertLessThanOrEqual(bounds.maxY, window.maxY)
        capture("Dataset-editor-ready-minimum")
        save.click()
        let createFolder = app.dialogs["save-panel"].buttons["OKButton"]
        XCTAssertTrue(createFolder.waitForExistence(timeout: 10), app.debugDescription)
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(root.path)
        app.typeKey(.return, modifierFlags: [])
        createFolder.click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 15), app.debugDescription)
        let target = root.appendingPathComponent("Training dataset")
        XCTAssertEqual(app.textFields["Dataset path"].value as? String, target.path)
        for file in ["train.jsonl", "valid.jsonl"] {
            let data = try Data(contentsOf: target.appendingPathComponent(file))
            XCTAssertNotNil(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        capture("Dataset-selected-without-training")
        let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8)
        let requests = calls.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String] }
        XCTAssertFalse(requests.contains { Array($0.prefix(2)) == ["lora", "inspect"] || Array($0.prefix(2)) == ["lora", "start"] },
                       "Creating a dataset must not inspect, preview, or start training; read-only status refreshes remain allowed")
    }

    func testTrainingDatasetGuidanceRevealsHiddenExamples() throws {
        launch(appearance: "Dark", route: "training-studio", isolatedHome: true)
        let scroll = app.scrollViews.containing(.textField, identifier: "Dataset path").firstMatch
        func reveal(_ element: XCUIElement) {
            XCTAssertTrue(element.waitForExistence(timeout: 10), app.debugDescription)
            for _ in 0..<8 where !element.isHittable {
                scroll.scroll(byDeltaX: 0, deltaY: element.frame.midY < scroll.frame.minY ? 180 : -180)
            }
            XCTAssertTrue(element.isHittable)
        }
        func replace(_ field: XCUIElement, _ value: String) {
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            XCTAssertTrue(field.isHittable, app.debugDescription)
            field.click()
            app.typeKey("a", modifierFlags: .command)
            field.typeText(value)
        }
        let batch = app.textFields["Batch size"]
        reveal(batch); replace(batch, "1")
        let create = app.buttons["training-create-dataset"]
        reveal(create); create.click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        for number in 1...5 {
            if number > 1 { sheet.buttons["Add example"].click() }
            replace(sheet.textFields["dataset-train-\(number)-prompt"], "Training request \(number)")
            replace(sheet.textFields["dataset-train-\(number)-reply"], "Training reply \(number)")
        }
        sheet.buttons["Add example"].click()
        let validation = sheet.radioButtons.matching(NSPredicate(format: "label BEGINSWITH %@", "Validation")).firstMatch
        validation.click()
        replace(sheet.textFields["dataset-valid-1-prompt"], "Held-out question")
        replace(sheet.textFields["dataset-valid-1-reply"], "Held-out answer")
        let fix = sheet.buttons["dataset-fix-example"]
        XCTAssertEqual(fix.label, "Fix training example")
        XCTAssertFalse(sheet.buttons["Save dataset…"].isEnabled)
        fix.click()
        let hidden = sheet.textFields["dataset-train-6-prompt"]
        XCTAssertTrue(hidden.waitForExistence(timeout: 5))
        XCTAssertTrue(hidden.isHittable, app.debugDescription)
        XCTAssertTrue(sheet.staticTexts["dataset-example-guidance"].exists)
        capture("Dataset-guidance-hidden-training-example")
        replace(hidden, "Training request 6")
        replace(sheet.textFields["dataset-train-6-reply"], "Training reply 6")
        XCTAssertTrue(sheet.buttons["Save dataset…"].isEnabled)
        XCTAssertFalse(fix.exists)
        validation.click()
        replace(sheet.textFields["dataset-valid-1-prompt"], "Training request 1")
        replace(sheet.textFields["dataset-valid-1-reply"], "Training reply 1")
        sheet.radioButtons.matching(NSPredicate(format: "label BEGINSWITH %@", "Training")).firstMatch.click()
        XCTAssertEqual(fix.label, "Fix validation example")
        fix.click()
        XCTAssertTrue(sheet.textFields["dataset-valid-1-prompt"].isHittable)
        XCTAssertTrue((sheet.staticTexts["dataset-example-guidance"].value as? String)?.contains("both splits") == true, sheet.debugDescription)
        capture("Dataset-guidance-overlapping-validation-example")
        replace(sheet.textFields["dataset-valid-1-reply"], "Independent answer")
        XCTAssertTrue(sheet.buttons["Save dataset…"].isEnabled)
        sheet.buttons["Cancel"].click()
        sheet.buttons["Discard changes"].firstMatch.click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
        let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8)
        let requests = calls.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String] }
        XCTAssertFalse(requests.contains { Array($0.prefix(2)) == ["lora", "inspect"] || Array($0.prefix(2)) == ["lora", "start"] })
    }

    func testTrainingDatasetEntryBaseline() {
        launch(appearance: "Dark", route: "training-studio", isolatedHome: true)
        let field = app.textFields["Dataset path"]
        let scroll = app.scrollViews.containing(.textField, identifier: "Dataset path").firstMatch
        for narrow in [false, true] {
            if narrow { resizeWindow(width: 740, height: 560) }
            for _ in 0..<8 where !field.isHittable { scroll.scroll(byDeltaX: 0, deltaY: -180) }
            XCTAssertTrue(field.isHittable)
            capture(narrow ? "Training-dataset-before-minimum" : "Training-dataset-before-standard")
        }
    }

    func testTrainingWorkflowGuidanceAndResults() throws {
        let before = ProcessInfo.processInfo.environment["MLX_WORKBENCH_CAPTURE_STAGE"] == "before"
        func flag(_ name: String, _ enabled: Bool) throws {
            let url = root.appendingPathComponent(name)
            if enabled { try Data().write(to: url) }
            else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        func write(_ name: String, _ value: Any) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(name))
        }
        for appearance in ["Light", "Dark"] {
            for name in ["fail-training-status", "fail-training-history", "fail-training-preview", "fail-training-submit",
                         "slow-training-status", "slow-training-history", "fail-training-inspect",
                         "fail-training-setup", "invalid-training-data", "fail-training-review"] { try flag(name, false) }
            try write("training-jobs.json", [])
            try write("training-history.json", [])
            launch(appearance: appearance, route: "training-studio", isolatedHome: true)
            resizeWindow(width: 1024, height: 680)
            let scroll = app.scrollViews.containing(.textField, identifier: "Base model repo id").firstMatch
            func reveal(_ element: XCUIElement) {
                XCTAssertTrue(element.waitForExistence(timeout: 10))
                for _ in 0..<10 {
                    let viewport = scroll.frame
                    let frame = element.frame
                    if viewport.contains(frame) && element.isHittable { return }
                    scroll.scroll(byDeltaX: 0, deltaY: frame.minY < viewport.minY ? 280 : -280)
                }
                XCTAssertTrue(scroll.frame.contains(element.frame), "Element must be visible before interaction")
                XCTAssertTrue(element.isHittable)
            }
            func message(_ identifier: String) -> String {
                let element = app.staticTexts[identifier]
                XCTAssertTrue(element.waitForExistence(timeout: 10), identifier)
                return element.value as? String ?? element.label
            }
            func waitEnabled(_ button: XCUIElement) {
                let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: button)
                XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed)
            }
            let model = app.textFields["Base model repo id"]
            let dataset = app.textFields["Dataset path"]
            let iterations = app.textFields["Iterations"]
            let preview = before ? app.buttons["Preview Training"] : app.buttons["training-preview"]
            XCTAssertTrue(preview.waitForExistence(timeout: 10))
            XCTAssertFalse(preview.isEnabled)
            if !before {
                XCTAssertTrue(message("training-guidance").contains("base model"))
                let fix = app.buttons["training-fix-field"]
                reveal(fix); fix.click()
                app.typeText("fixture/base")
                XCTAssertEqual(model.value as? String, "fixture/base", "Fix field must focus the real input")
                XCTAssertTrue(message("training-guidance").contains("dataset"))
                reveal(fix); fix.click(); app.typeText(root.path)
                XCTAssertEqual(dataset.value as? String, root.path)
                XCTAssertTrue(preview.isEnabled)
                let check = app.buttons["training-check-setup"]
                try flag("invalid-training-data", true)
                reveal(check); check.click()
                XCTAssertTrue(text(containing: "train.jsonl line 2 is not valid JSON.").waitForExistence(timeout: 10))
                XCTAssertFalse(app.buttons["training-confirm"].exists, "Inspection cannot authorize training")
                reveal(app.staticTexts["training-inspection-valid"])
                XCTAssertTrue(message("training-inspection-valid").contains("8 examples"))
                capture("Training-\(appearance)-setup-blocked")
                resizeWindow(width: 740, height: 560)
                reveal(app.staticTexts["training-inspection-valid"])
                capture("Training-\(appearance)-setup-blocked-minimum")
                resizeWindow(width: 1024, height: 680)
                try flag("invalid-training-data", false)
                reveal(check); check.click()
                XCTAssertTrue(text(containing: "Local setup checks passed").waitForExistence(timeout: 10))
                reveal(app.staticTexts["training-inspection-summary"])
                capture("Training-\(appearance)-setup-ready")
                try flag("fail-training-setup", true)
                reveal(check); check.click()
                XCTAssertTrue(text(containing: "Fixture setup inspection failed.").waitForExistence(timeout: 10))
                XCTAssertFalse(app.staticTexts["training-inspection-summary"].exists)
                try flag("fail-training-setup", false)
                reveal(iterations); replace(iterations, with: "0")
                XCTAssertFalse(preview.isEnabled)
                XCTAssertTrue(message("training-guidance").contains("positive whole number"))
                reveal(fix); fix.click()
                app.typeKey("a", modifierFlags: .command); app.typeText("100")
                XCTAssertEqual(iterations.value as? String, "100")
                XCTAssertEqual(model.value as? String, "fixture/base")
                XCTAssertEqual(dataset.value as? String, root.path)
                XCTAssertTrue(preview.isEnabled)
                reveal(app.staticTexts["training-jobs-empty"])
                XCTAssertTrue(app.staticTexts["training-history-empty"].exists)
                capture("Training-\(appearance)-empty-results-scrolled")
                reveal(model)
            }
            capture("Training-\(appearance)-setup")
            if before {
                reveal(model); replace(model, with: "fixture/base")
                reveal(dataset); replace(dataset, with: root.path)
            }
            reveal(preview); preview.click()
            let confirm = before ? app.buttons["Confirm & Train"] : app.buttons["training-confirm"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 15)); waitEnabled(confirm)
            reveal(confirm)
            capture("Training-\(appearance)-captured-request")
            resizeWindow(width: 740, height: 680)
            reveal(confirm); capture("Training-\(appearance)-narrow-request")
            resizeWindow(width: 740, height: 560)
            let minimum = app.windows.firstMatch.frame.size
            resizeWindow(width: 740, height: 520)
            XCTAssertEqual(app.windows.firstMatch.frame.size.height, minimum.height, accuracy: 3)
            reveal(confirm); capture("Training-\(appearance)-minimum-request")
            if before { app.terminate(); continue }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("confirmed-training.json").path))
            resizeWindow(width: 1024, height: 680)
            reveal(iterations); replace(iterations, with: "200")
            XCTAssertFalse(confirm.exists, "Any setup edit must discard the old preview")
            try flag("fail-training-preview", true)
            reveal(preview); preview.click()
            XCTAssertTrue(text(containing: "Fixture training preview failed.").waitForExistence(timeout: 15))
            reveal(text(containing: "Fixture training preview failed.")); capture("Training-\(appearance)-preview-failed")
            try flag("fail-training-preview", false)
            reveal(preview); preview.click()
            XCTAssertFalse(preview.isEnabled, "Duplicate preview must be locked while preparing")
            XCTAssertTrue(confirm.waitForExistence(timeout: 15)); waitEnabled(confirm)
            try flag("fail-training-submit", true)
            reveal(confirm); confirm.click()
            XCTAssertFalse(confirm.isEnabled, "Duplicate submission must be locked")
            XCTAssertTrue(text(containing: "Fixture training submission failed.").waitForExistence(timeout: 15))
            waitEnabled(confirm)
            capture("Training-\(appearance)-submission-failed")
            try flag("fail-training-submit", false)
            reveal(confirm); confirm.click()
            XCTAssertTrue(text(containing: "Training submitted. See Activity.").waitForExistence(timeout: 15))
            let submitted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("confirmed-training.json"))) as? [String])
            XCTAssertEqual(submitted[try XCTUnwrap(submitted.firstIndex(of: "--iters")) + 1], "200")
            XCTAssertEqual(submitted[try XCTUnwrap(submitted.firstIndex(of: "--preview-hash")) + 1], "fixture-training-preview")
            capture("Training-\(appearance)-submitted")

            let jobs: [[String: Any]] = [["receipt": "fixture-trained-adapter", "repo": "fixture/base", "out": root.appendingPathComponent("adapter").path,
                                        "pid": 123, "state": "done", "adapter_identity": ["sha256": "fixture-adapter-identity"],
                                        "log_path": root.appendingPathComponent("training.log").path]]
            try write("training-jobs.json", jobs)
            try write("training-history.json", [["id": "fixture-evaluation", "created_at": "2026-10-12T12:00:00Z"]])
            let refreshJobs = app.buttons["training-refresh-jobs"]
            let refreshHistory = app.buttons["training-refresh-history"]
            try flag("slow-training-status", true)
            reveal(refreshJobs); refreshJobs.click()
            XCTAssertTrue(app.staticTexts["training-jobs-loading"].waitForExistence(timeout: 5))
            XCTAssertFalse(refreshJobs.isEnabled)
            capture("Training-\(appearance)-jobs-loading")
            try flag("slow-training-status", false)
            XCTAssertTrue(app.buttons["Compare with base"].waitForExistence(timeout: 15))
            let compareAdapter = app.buttons["Compare with base"]
            reveal(compareAdapter); compareAdapter.click()
            let evaluationSheet = app.sheets.firstMatch
            XCTAssertTrue(evaluationSheet.waitForExistence(timeout: 10))
            XCTAssertTrue(evaluationSheet.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Workspace:' OR value BEGINSWITH 'Workspace:'")).firstMatch.waitForExistence(timeout: 10))
            func revealEvaluation(_ element: XCUIElement) {
                XCTAssertTrue(element.waitForExistence(timeout: 10))
                let scroll = evaluationSheet.scrollViews.firstMatch
                for _ in 0..<10 {
                    if scroll.frame.contains(element.frame) && element.isHittable { return }
                    scroll.scroll(byDeltaX: 0, deltaY: element.frame.midY < scroll.frame.minY ? 240 : -240)
                }
                XCTAssertTrue(element.isHittable)
            }
            let sourceMenu = evaluationSheet.descendants(matching: .any)["training-evaluation-source"]
            sourceMenu.click(); app.menuItems["Coding basics"].click()
            evaluationSheet.buttons["Preview"].click()
            let runEvaluation = evaluationSheet.buttons["Run comparison"]
            waitEnabled(runEvaluation); runEvaluation.click()
            XCTAssertTrue(evaluationSheet.staticTexts["training-evaluation-retained"].waitForExistence(timeout: 15))
            let preference = evaluationSheet.descendants(matching: .any)["training-evaluation-preference"]
            revealEvaluation(preference); preference.click(); app.menuItems["Trained adapter"].click()
            let notes = evaluationSheet.descendants(matching: .any)["training-evaluation-review-notes"]
            revealEvaluation(notes); replace(notes, with: "More actionable.")
            let saveReview = evaluationSheet.buttons["training-evaluation-save-review"]
            try flag("fail-training-review", true)
            revealEvaluation(saveReview); saveReview.click()
            XCTAssertTrue(text(containing: "Fixture review save failed.").waitForExistence(timeout: 10))
            XCTAssertTrue(evaluationSheet.debugDescription.contains("More actionable."))
            capture("Training-\(appearance)-evaluation-review-failed")
            try flag("fail-training-review", false)
            revealEvaluation(saveReview); saveReview.click()
            XCTAssertTrue(evaluationSheet.staticTexts["training-evaluation-review-saved"].waitForExistence(timeout: 10))
            capture("Training-\(appearance)-evaluation-suite-reviewed")
            evaluationSheet.buttons["Close"].click()
            XCTAssertTrue(evaluationSheet.waitForNonExistence(timeout: 10))
            let inspectSuite = app.buttons["training-inspect-text_eval_suite"]
            reveal(inspectSuite); inspectSuite.click()
            let reviewRetained = app.buttons["training-review-retained"]
            reveal(reviewRetained); reviewRetained.click()
            XCTAssertTrue(app.sheets.firstMatch.staticTexts["Review retained evaluation"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.sheets.firstMatch.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Workspace:' OR value BEGINSWITH 'Workspace:'")).firstMatch.exists)
            XCTAssertFalse(app.sheets.firstMatch.buttons["Run comparison"].exists)
            XCTAssertTrue(app.sheets.firstMatch.debugDescription.contains("More actionable."))
            capture("Training-\(appearance)-evaluation-suite-reopened")
            app.sheets.firstMatch.buttons["Close"].click()
            XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 10))
            try flag("slow-training-history", true)
            reveal(refreshHistory); refreshHistory.click()
            XCTAssertTrue(app.staticTexts["training-history-loading"].waitForExistence(timeout: 5))
            XCTAssertFalse(refreshHistory.isEnabled)
            capture("Training-\(appearance)-history-loading")
            try flag("slow-training-history", false)
            let evaluation = app.buttons["training-inspect-fixture-evaluation"]
            XCTAssertTrue(evaluation.waitForExistence(timeout: 15))
            reveal(evaluation); evaluation.click()
            XCTAssertTrue(text(containing: "fixture-evaluation-sha256").waitForExistence(timeout: 15))
            reveal(text(containing: "fixture-evaluation-sha256"))
            let reportTitle = "Evaluation fixture-: outputs and frozen recipe"
            let report = app.disclosureTriangles[reportTitle]
            if report.exists {
                reveal(report)
                // Native disclosure frames include the label; click the leading arrow.
                let window = app.windows.firstMatch
                let frame = report.frame.intersection(scroll.frame)
                XCTAssertFalse(frame.isNull)
                if report.value as? Int != 1 {
                    window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                        dx: frame.minX + frame.height / 4 - window.frame.minX,
                        dy: frame.midY - window.frame.minY
                    )).click()
                }
                XCTAssertEqual(report.value as? Int, 1)
            }
            else {
                let disclosure = app.buttons[reportTitle]
                reveal(disclosure); disclosure.click()
            }
            XCTAssertTrue(text(containing: "fixture frozen recipe").waitForExistence(timeout: 10))
            capture("Training-\(appearance)-populated-evaluation")
            try flag("fail-training-inspect", true)
            reveal(evaluation); evaluation.click()
            XCTAssertTrue(message("training-inspection-error").contains("Evaluation couldn't be inspected"))
            XCTAssertTrue(text(containing: "fixture-evaluation-sha256").exists, "Inspection failure must retain the prior report")
            capture("Training-\(appearance)-inspection-failed-retained")
            try flag("fail-training-inspect", false)
            reveal(evaluation); evaluation.click()
            waitEnabled(evaluation)
            XCTAssertFalse(app.staticTexts["training-inspection-error"].exists)
            try flag("fail-training-status", true)
            reveal(refreshJobs); refreshJobs.click()
            XCTAssertTrue(message("training-jobs-error").contains("Training jobs couldn't load"))
            XCTAssertTrue(app.buttons["Compare with base"].exists, "A failed refresh must retain jobs")
            XCTAssertTrue(evaluation.exists, "A jobs failure must not clear evaluations")
            reveal(app.staticTexts["training-jobs-error"]); capture("Training-\(appearance)-jobs-refresh-failed")
            try flag("fail-training-status", false)
            reveal(refreshJobs); refreshJobs.click(); waitEnabled(refreshJobs)
            XCTAssertFalse(app.staticTexts["training-jobs-error"].exists)
            try flag("fail-training-history", true)
            reveal(refreshHistory); refreshHistory.click()
            XCTAssertTrue(message("training-history-error").contains("Evaluations couldn't load"))
            XCTAssertTrue(evaluation.exists, "A failed refresh must retain history")
            XCTAssertTrue(app.buttons["Compare with base"].exists)
            reveal(app.staticTexts["training-history-error"]); capture("Training-\(appearance)-history-refresh-failed")
            try flag("fail-training-history", false)
            reveal(refreshHistory); refreshHistory.click(); waitEnabled(refreshHistory)
            XCTAssertFalse(app.staticTexts["training-history-error"].exists)
            app.terminate()
            try flag("confirmed-training.json", false)
        }
    }

    private func text(containing value: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", value, value)).firstMatch
    }

    func testSettingsInputsExposeSemanticLabels() {
        launch(appearance: "Light", route: "settings")
        XCTAssertTrue(app.textFields["mlx-agent checkout"].waitForExistence(timeout: 10))
        let labels = ["Output directory", "Quarantine directory",
                      "Fit reserve in gigabytes", "Stale after days", "Comparison maximum tokens"]
        for label in labels {
            let field = app.textFields[label]
            for _ in 0..<8 where !field.isHittable {
                app.scrollViews.allElementsBoundByIndex.last?.scroll(byDeltaX: 0, deltaY: -350)
            }
            XCTAssertTrue(field.exists, label)
            XCTAssertTrue(field.isHittable, label)
        }
        capture("Settings-scrolled-semantic-inputs")
    }

    func testSettingsValidationRecoveryAndSaveFeedback() throws {
        let configURL = root.appendingPathComponent(String(repeating: "settings-", count: 18) + "config.json")
        var initial = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("config.json"))) as? [String: Any])
        initial["future_feature"] = "preserve-me"
        initial["host"] = "::1"
        initial["port"] = 54321
        let original = try JSONSerialization.data(withJSONObject: initial)
        for appearance in ["Light", "Dark"] {
            try original.write(to: configURL)
            launch(appearance: appearance, route: "settings", isolatedHome: true, configURL: configURL)
            resizeWindow(width: 1024, height: 680)
            capture("Settings-\(appearance)-clean")
            XCTAssertFalse(app.textFields["Workbench API host"].exists)
            XCTAssertFalse(app.textFields["Workbench API port"].exists)
            let reserve = app.textFields["Fit reserve in gigabytes"]
            let staleDays = app.textFields["Stale after days"]
            let maxTokens = app.textFields["Comparison maximum tokens"]
            let scroll = app.scrollViews.containing(.textField, identifier: "Fit reserve in gigabytes").firstMatch
            func reveal(_ field: XCUIElement) {
                XCTAssertTrue(field.waitForExistence(timeout: 10))
                for _ in 0..<8 where !scroll.frame.contains(field.frame) || !field.isHittable {
                    scroll.scroll(byDeltaX: 0, deltaY: field.frame.minY < scroll.frame.minY ? 300 : -300)
                }
                XCTAssertTrue(scroll.frame.contains(field.frame), "Input must be inside the editor before clicking")
                XCTAssertTrue(field.isHittable)
            }
            func focusedReplace(_ value: String) {
                app.typeKey("a", modifierFlags: .command)
                app.typeText(value)
            }
            func feedbackText(_ identifier: String) -> String {
                let element = app.staticTexts[identifier]
                XCTAssertTrue(element.waitForExistence(timeout: 5))
                return element.value as? String ?? element.label
            }
            reveal(reserve)
            replace(reserve, with: "invalid")
            app.typeText("!")
            XCTAssertEqual(reserve.value as? String, "invalid!", "Validation feedback must not steal input focus")
            reveal(staleDays); replace(staleDays, with: "1")
            reveal(maxTokens); replace(maxTokens, with: "63")
            app.typeText("!")
            XCTAssertEqual(maxTokens.value as? String, "63!", "Validation feedback must not move focus to an earlier field")
            let save = app.buttons["settings-save"]
            XCTAssertFalse(save.isEnabled)
            XCTAssertEqual(try Data(contentsOf: configURL), original)
            capture("Settings-\(appearance)-multiple-invalid")
            resizeWindow(width: 740, height: 680)
            XCTAssertEqual(app.windows.firstMatch.frame.width, 740, accuracy: 2)
            XCTAssertEqual(app.windows.firstMatch.frame.height, 680, accuracy: 2)
            for _ in 0..<4 where reserve.isHittable { scroll.scroll(byDeltaX: 0, deltaY: -350) }
            XCTAssertFalse(reserve.isHittable, "Recovery must begin with the first invalid input offscreen")
            capture("Settings-\(appearance)-multiple-invalid-narrow")
            do {
                let fix = app.buttons["settings-fix-field"]
                let guidance = app.staticTexts["settings-save-guidance"]
                let windowFrame = app.windows.firstMatch.frame
                let guidanceFrame = guidance.frame
                if !windowFrame.contains(guidanceFrame) {
                    let hierarchy = XCTAttachment(string: app.debugDescription)
                    hierarchy.name = "Settings feedback layout"
                    hierarchy.lifetime = .keepAlways
                    add(hierarchy)
                }
                XCTAssertTrue(windowFrame.contains(guidanceFrame), "Feedback \(guidanceFrame) must remain inside window \(windowFrame); Save \(save.frame)")
                XCTAssertTrue(app.windows.firstMatch.frame.contains(save.frame), "Save must remain inside the window")
                XCTAssertTrue(fix.isHittable, "Recovery must remain visible in the pinned bar")
                XCTAssertTrue(feedbackText("settings-save-guidance").contains("Fit reserve"))
                fix.click()
                XCTAssertTrue(reserve.isHittable)
                XCTAssertEqual(staleDays.value as? String, "1")
                XCTAssertEqual(maxTokens.value as? String, "63!")
                XCTAssertEqual(reserve.value as? String, "invalid!")
                XCTAssertEqual(try Data(contentsOf: configURL), original)
                focusedReplace("8")
                XCTAssertEqual(reserve.value as? String, "8", "Fix field must focus the actual input")
                XCTAssertTrue(feedbackText("settings-save-guidance").contains("Stale after"))
                fix.click()
                focusedReplace("90")
                app.typeText(" ")
                XCTAssertEqual(staleDays.value as? String, "90 ")
                XCTAssertTrue(feedbackText("settings-save-guidance").contains("Comparison max tokens"))
                fix.click()
                focusedReplace("1024")
                XCTAssertEqual(maxTokens.value as? String, "1024")
                XCTAssertFalse(fix.exists)
            }
            XCTAssertTrue(save.isEnabled)
            XCTAssertEqual(try Data(contentsOf: configURL), original, "Recovery must not save the draft")
            capture("Settings-\(appearance)-valid-draft-narrow")
            save.click()
            XCTAssertTrue(text(containing: "Saved to").waitForExistence(timeout: 10))
            let savedBytes = try Data(contentsOf: configURL)
            let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: savedBytes) as? [String: Any])
            XCTAssertEqual(saved["host"] as? String, "::1")
            XCTAssertEqual(saved["port"] as? Int, 54321)
            XCTAssertEqual(saved["fit_reserve_gb"] as? Double, 8)
            XCTAssertEqual(saved["reclaim_stale_days"] as? Int, 90)
            XCTAssertEqual(saved["comparison_max_tokens"] as? Int, 1024)
            XCTAssertEqual(saved["future_feature"] as? String, "preserve-me")
            capture("Settings-\(appearance)-saved-narrow")
            resizeWindow(width: 1024, height: 680)
            capture("Settings-\(appearance)-saved")
            reveal(maxTokens)
            replace(maxTokens, with: "abc")
            XCTAssertTrue(feedbackText("settings-save-guidance").contains("Comparison max tokens"), "A prior success must not obscure validation")
            replace(maxTokens, with: "2048")
            // A real read failure on a test-owned config exercises the existing
            // persistence boundary without a production error-injection seam.
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: configURL.path)
            let expectedFailure: String
            do {
                _ = try Data(contentsOf: configURL)
                XCTFail("The owned config must be unreadable")
                return
            } catch { expectedFailure = error.localizedDescription }
            XCTAssertGreaterThan(expectedFailure.count, 180)
            save.click()
            XCTAssertTrue(text(containing: expectedFailure).waitForExistence(timeout: 10))
            XCTAssertEqual(feedbackText("settings-save-error"), expectedFailure)
            XCTAssertTrue(app.windows.firstMatch.frame.contains(app.staticTexts["settings-save-error"].frame))
            XCTAssertEqual(maxTokens.value as? String, "2048", "Save failure must retain the draft")
            XCTAssertTrue(save.isEnabled)
            capture("Settings-\(appearance)-save-failed")
            resizeWindow(width: 740, height: 680)
            XCTAssertEqual(feedbackText("settings-save-error"), expectedFailure)
            XCTAssertTrue(app.windows.firstMatch.frame.contains(app.staticTexts["settings-save-error"].frame))
            XCTAssertTrue(app.windows.firstMatch.frame.contains(save.frame))
            capture("Settings-\(appearance)-save-failed-narrow")
            do {
                resizeWindow(width: 740, height: 560)
                let minimumFrame = app.windows.firstMatch.frame
                XCTAssertEqual(minimumFrame.width, 740, accuracy: 2)
                XCTAssertLessThan(minimumFrame.height, 680)
                // The native title bar adds to the content minimum. Confirm
                // AppKit's actual resize limit instead of assuming its height.
                resizeWindow(width: 740, height: minimumFrame.height - 80)
                XCTAssertEqual(app.windows.firstMatch.frame.height, minimumFrame.height, accuracy: 2)
                XCTAssertEqual(feedbackText("settings-save-error"), expectedFailure)
                XCTAssertTrue(app.windows.firstMatch.frame.contains(app.staticTexts["settings-save-error"].frame))
                XCTAssertTrue(app.windows.firstMatch.frame.contains(save.frame))
                XCTAssertTrue(app.windows.firstMatch.frame.contains(app.buttons["settings-discard"].frame))
                XCTAssertTrue(save.isHittable)
                capture("Settings-\(appearance)-save-failed-minimum")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
            XCTAssertEqual(try Data(contentsOf: configURL), savedBytes, "Failed Save must not write")
            save.click()
            XCTAssertTrue(text(containing: "Saved to").waitForExistence(timeout: 10))
            let retried = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
            XCTAssertEqual(retried["host"] as? String, "::1")
            XCTAssertEqual(retried["port"] as? Int, 54321)
            XCTAssertEqual(retried["comparison_max_tokens"] as? Int, 2048)
            XCTAssertEqual(retried["future_feature"] as? String, "preserve-me")
            app.terminate()
        }
    }

    func testRunChoosesTheExactEndpointForClients() throws {
        let config = root.appendingPathComponent(".config/opencode/opencode.jsonc")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"theme":"dark"}"#.utf8)
        try original.write(to: config)
        let servers: [[String: Any]] = [
            ["repo": "org/Qwen", "runtime": "mlx_lm", "port": 8766, "pid": 123, "state": "running", "receipt": "/fixture/first.json"],
            ["repo": "org/Qwen", "runtime": "mlx_lm", "port": 8767, "pid": 456, "state": "running", "receipt": "/fixture/second.json",
             "adapter_path": "/fixture/adapters/tuned", "adapter_identity": ["adapters.safetensors": ["sha256": "fixture", "bytes": 4]]]
        ]
        try JSONSerialization.data(withJSONObject: servers).write(to: root.appendingPathComponent("servers.json"))
        launch(appearance: "Dark", isolatedHome: true)
        select("Run")
        let configure = app.buttons["run-configure-clients-8767"]
        XCTAssertTrue(configure.waitForExistence(timeout: 15)); configure.click()
        let preview = app.buttons["Preview client wiring"]
        XCTAssertTrue(preview.waitForExistence(timeout: 15))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: preview)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        XCTAssertEqual(try Data(contentsOf: config), original, "Navigation must not write configuration")
        preview.click()
        let confirm = app.buttons["Confirm client wiring"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["client-wiring-reviewed-model"].value as? String, "org/Qwen")
        XCTAssertEqual(app.staticTexts["client-wiring-reviewed-endpoint"].value as? String, "http://127.0.0.1:8767/v1")
        XCTAssertEqual(try Data(contentsOf: config), original, "Preview must not write configuration")
        capture("Run-to-Clients-reviewed-endpoint")
        confirm.click()
        XCTAssertTrue(text(containing: "Wired 1 client").waitForExistence(timeout: 15))
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
        let providers = try XCTUnwrap(written["provider"] as? [String: Any])
        let provider = try XCTUnwrap(providers["mlx-local"] as? [String: Any])
        let options = try XCTUnwrap(provider["options"] as? [String: Any])
        XCTAssertEqual(options["baseURL"] as? String, "http://127.0.0.1:8767/v1")
        XCTAssertEqual(written["theme"] as? String, "dark")
        capture("Run-to-Clients-applied-endpoint")
    }

    func testSetupDoctorCreatesMissingClientAndOffersHostConnections() throws {
        let config = root.appendingPathComponent(".config/opencode/opencode.jsonc")
        let servers: [[String: Any]] = [["repo": "org/Qwen", "runtime": "mlx_lm", "port": 8766,
                                        "pid": 123, "state": "running"]]
        try JSONSerialization.data(withJSONObject: servers).write(to: root.appendingPathComponent("servers.json"))
        launch(appearance: "Dark", isolatedHome: true)
        select("Clients")
        let open = app.buttons["open-client-setup-doctor"]
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: open)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed)
        open.click()
        XCTAssertTrue(text(containing: "Setup check finished.").waitForExistence(timeout: 15))
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.deletingLastPathComponent().path), "Checking must not create folders")
        let review = app.buttons["setup-client-opencode"]
        XCTAssertFalse(review.isEnabled)
        XCTAssertFalse(app.buttons["setup-client-continue"].isEnabled)
        let endpoint = app.popUpButtons["setup-doctor-endpoint"]
        endpoint.click()
        app.menuItems["org/Qwen :8766"].click()
        XCTAssertTrue(review.isEnabled)
        capture("Setup-doctor-missing-client")
        review.click()
        let confirm = app.buttons["Confirm client wiring"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.path), "Preview must not write")
        for _ in 0..<6 where !confirm.isHittable { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -220) }
        confirm.click()
        XCTAssertTrue(text(containing: "Wired 1 client").waitForExistence(timeout: 15))
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
        XCTAssertEqual(written["model"] as? String, "mlx-local/org/Qwen")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".config/zed").path))
        capture("Setup-doctor-client-created")
        app.buttons["Roll back last wiring"].click()
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.path))

        for _ in 0..<6 where !open.isHittable { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: 220) }
        open.click()
        XCTAssertTrue(text(containing: "Setup check finished.").waitForExistence(timeout: 15))
        for (provider, defaultURL) in [("lmStudio", "http://127.0.0.1:1234"), ("comfyUI", "http://127.0.0.1:8188"),
                                       ("ollama", "http://127.0.0.1:11434")] {
            let add = app.buttons["setup-host-\(provider)"]
            for _ in 0..<8 where !add.isHittable { app.scrollViews["setup-doctor-scroll"].scroll(byDeltaX: 0, deltaY: -200) }
            XCTAssertTrue(add.isHittable)
            if provider == "ollama" { capture("Setup-doctor-host-presets") }
            add.click()
            let url = app.textFields["model-host-url"]
            XCTAssertTrue(url.waitForExistence(timeout: 10))
            XCTAssertEqual(url.value as? String, defaultURL)
            if provider == "ollama" {
                replace(url, with: "http://127.0.0.1:1")
                app.buttons["test-model-host-connection"].click()
                XCTAssertTrue(text(containing: "The local host could not be reached.").waitForExistence(timeout: 15))
                capture("Setup-doctor-host-check-failed")
            }
            app.buttons["Cancel"].click()
        }
        app.buttons["Done"].click()
        select("Health")
        let healthDoctor = app.buttons["health-client-setup-doctor"]
        for _ in 0..<15 where !healthDoctor.isHittable { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -240) }
        XCTAssertTrue(healthDoctor.isHittable)
        healthDoctor.click()
        XCTAssertTrue(text(containing: "Setup check finished.").waitForExistence(timeout: 15))
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.path), "Health navigation must not recreate a rolled-back config")
    }

    func testClientWiringPreviewAndEndpointSelection() throws {
        let config = root.appendingPathComponent(".config/opencode/opencode.jsonc")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{\"theme\":\"dark\"}".utf8)
        try original.write(to: config)
        let servers: [[String: Any]] = [
            ["repo": "org/Qwen-first", "runtime": "mlx_lm", "port": 8766, "pid": 123, "state": "running"],
            ["repo": "org/Qwen-second", "runtime": "mlx_lm", "port": 8767, "pid": 456, "state": "running"]
        ]
        try JSONSerialization.data(withJSONObject: servers).write(to: root.appendingPathComponent("servers.json"))
        let isBeforeCapture = ProcessInfo.processInfo.environment["MLX_WORKBENCH_CAPTURE_STAGE"] == "before"
        for appearance in ["Light", "Dark"] {
            try original.write(to: config)
            launch(appearance: appearance, isolatedHome: true)
            select("Clients")
            // The preserved app exposes its endpoint picker without an AX label.
            let endpoint = isBeforeCapture ? app.popUpButtons.firstMatch : app.popUpButtons["client-wiring-endpoint"].firstMatch
            XCTAssertTrue(endpoint.waitForExistence(timeout: 10))
            endpoint.click()
            app.menuItems["Qwen-first :8766"].click()
            XCTAssertFalse(app.buttons["Confirm client wiring"].exists)
            capture("Clients-\(appearance)-before-preview")
            app.buttons["Preview client wiring"].click()
            let confirm = app.buttons["Confirm client wiring"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 10))
            XCTAssertTrue(confirm.isEnabled)
            if isBeforeCapture {
                XCTAssertEqual(try Data(contentsOf: config), original)
                capture("Clients-\(appearance)-matching-preview")
                resizeWindow(width: 740, height: 680)
                for _ in 0..<6 where !confirm.isHittable {
                    app.scrollViews.allElementsBoundByIndex.last?.scroll(byDeltaX: 0, deltaY: -220)
                }
                XCTAssertTrue(confirm.isHittable)
                capture("Clients-\(appearance)-matching-preview-narrow")
                app.terminate()
                continue
            }
            let refreshPreview = app.buttons["Refresh preview"]
            XCTAssertTrue(refreshPreview.exists)
            XCTAssertFalse(app.buttons["Preview client wiring"].exists)
            let reviewedModel = app.staticTexts["client-wiring-reviewed-model"]
            let reviewedEndpoint = app.staticTexts["client-wiring-reviewed-endpoint"]
            XCTAssertEqual(reviewedModel.value as? String, "org/Qwen-first")
            XCTAssertEqual(reviewedEndpoint.value as? String, "http://127.0.0.1:8766/v1")
            XCTAssertEqual(try Data(contentsOf: config), original, "Preview must not write a client config")
            capture("Clients-\(appearance)-matching-preview")

            try Data().write(to: root.appendingPathComponent("slow-server-status"))
            refreshPreview.click()
            XCTAssertTrue(app.buttons["Refreshing…"].waitForExistence(timeout: 10))
            XCTAssertFalse(confirm.isEnabled)
            XCTAssertFalse(refreshPreview.isEnabled)
            capture("Clients-\(appearance)-refreshing-preview")
            try FileManager.default.removeItem(at: root.appendingPathComponent("slow-server-status"))
            XCTAssertTrue(app.buttons["Refresh clients and servers"].waitForExistence(timeout: 10))
            XCTAssertEqual(try Data(contentsOf: config), original, "Refreshing a preview must not write")

            endpoint.click()
            app.menuItems["Qwen-second :8767"].click()
            XCTAssertFalse(confirm.isEnabled)
            XCTAssertEqual(reviewedModel.value as? String, "org/Qwen-first")
            XCTAssertEqual(reviewedEndpoint.value as? String, "http://127.0.0.1:8766/v1")
            XCTAssertTrue(text(containing: "Endpoint changed. Preview client wiring again.").exists)
            capture("Clients-\(appearance)-changed-endpoint")
            app.buttons["Preview client wiring"].click()
            XCTAssertTrue(app.buttons["Refresh preview"].waitForExistence(timeout: 10))
            XCTAssertEqual(reviewedModel.value as? String, "org/Qwen-second")
            XCTAssertEqual(reviewedEndpoint.value as? String, "http://127.0.0.1:8767/v1")
            resizeWindow(width: 740, height: 680)
            for _ in 0..<6 where !confirm.isHittable {
                app.scrollViews.allElementsBoundByIndex.last?.scroll(byDeltaX: 0, deltaY: -220)
            }
            XCTAssertTrue(confirm.isHittable)
            capture("Clients-\(appearance)-matching-preview-narrow")

            confirm.click()
            XCTAssertTrue(text(containing: "Wired 1 client to org/Qwen-second.").waitForExistence(timeout: 10))
            let landed = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any]
            let provider = landed?["provider"] as? [String: Any]
            let local = provider?["mlx-local"] as? [String: Any]
            XCTAssertEqual((local?["options"] as? [String: Any])?["baseURL"] as? String, "http://127.0.0.1:8767/v1")
            XCTAssertEqual(landed?["theme"] as? String, "dark")
            XCTAssertFalse(confirm.exists)
            capture("Clients-\(appearance)-confirmed")
            app.buttons["Roll back last wiring"].click()
            XCTAssertEqual(try Data(contentsOf: config), original)

            app.buttons["Preview client wiring"].click()
            XCTAssertTrue(confirm.waitForExistence(timeout: 10))
            let externalEdit = Data("{\"theme\":\"light\"}".utf8)
            try externalEdit.write(to: config)
            confirm.click()
            XCTAssertTrue(text(containing: "config file changed after the preview").waitForExistence(timeout: 10))
            XCTAssertEqual(try Data(contentsOf: config), externalEdit, "Failed confirmation must retain external edits")
            capture("Clients-\(appearance)-confirmation-file-drift")

            app.buttons["Preview client wiring"].click()
            XCTAssertTrue(confirm.waitForExistence(timeout: 10))
            try Data().write(to: root.appendingPathComponent("fail-server-status"))
            app.buttons["Refresh clients and servers"].click()
            XCTAssertTrue(text(containing: "Server status unavailable.").waitForExistence(timeout: 10))
            XCTAssertFalse(confirm.isEnabled)
            XCTAssertEqual(reviewedModel.value as? String, "org/Qwen-second")
            XCTAssertEqual(try Data(contentsOf: config), externalEdit)
            capture("Clients-\(appearance)-status-unavailable")
            try FileManager.default.removeItem(at: root.appendingPathComponent("fail-server-status"))
            app.terminate()
        }
    }

    func testClientWiringOutcomesAndRecovery() throws {
        let opencode = root.appendingPathComponent(".config/opencode/opencode.jsonc")
        let zed = root.appendingPathComponent(".config/zed/settings.json")
        let original = Data("{\"theme\":\"dark\"}".utf8)
        let externalEdit = Data("{\"theme\":\"light\"}".utf8)
        try FileManager.default.createDirectory(at: opencode.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [["repo": "org/Qwen-first", "runtime": "mlx_lm",
            "port": 8766, "pid": 123, "state": "running"]]).write(to: root.appendingPathComponent("servers.json"))
        let isBefore = ProcessInfo.processInfo.environment["MLX_WORKBENCH_CAPTURE_STAGE"] == "before"
        for appearance in ["Light", "Dark"] {
            try? FileManager.default.removeItem(at: zed.deletingLastPathComponent())
            try original.write(to: opencode)
            launch(appearance: appearance, isolatedHome: true)
            select("Clients")
            let endpoint = isBefore ? app.popUpButtons.firstMatch : app.popUpButtons["client-wiring-endpoint"]
            XCTAssertTrue(endpoint.waitForExistence(timeout: 10))
            endpoint.click()
            app.menuItems["Qwen-first :8766"].click()
            app.buttons["Preview client wiring"].click()
            let confirm = app.buttons["Confirm client wiring"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 10))
            try externalEdit.write(to: opencode)
            confirm.click()
            XCTAssertTrue(text(containing: "config file changed after the preview").waitForExistence(timeout: 10))
            XCTAssertEqual(try Data(contentsOf: opencode), externalEdit)
            let result = app.staticTexts["client-wiring-result"]
            if !isBefore {
                XCTAssertEqual(result.value as? String ?? result.label, "No clients were wired. 1 client failed.")
                XCTAssertFalse(app.buttons["Roll back last wiring"].exists)
                XCTAssertFalse(app.buttons["Measure this workflow…"].exists)
                let failures = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "config file changed after the preview", "config file changed after the preview"))
                XCTAssertEqual(failures.count, 1)
                XCTAssertEqual(failures.firstMatch.value as? String ?? failures.firstMatch.label, "opencode: the config file changed after the preview; preview again.")
            }
            capture("Clients-\(appearance)-zero-wired")
            resizeWindow(width: 740, height: 680)
            XCTAssertEqual(app.windows.firstMatch.frame.width, 740, accuracy: 2)
            XCTAssertEqual(app.windows.firstMatch.frame.height, 680, accuracy: 2)
            capture("Clients-\(appearance)-zero-wired-narrow")
            resizeWindow(width: 1024, height: 680)

            try FileManager.default.createDirectory(at: zed.deletingLastPathComponent(), withIntermediateDirectories: true)
            let zedOriginal = Data("{\"vim_mode\":true}".utf8)
            try zedOriginal.write(to: zed)
            app.buttons["Preview client wiring"].click()
            XCTAssertTrue(confirm.waitForExistence(timeout: 10))
            if !isBefore { XCTAssertFalse(result.exists) }
            try original.write(to: opencode)
            confirm.click()
            XCTAssertTrue(text(containing: "config file changed after the preview").waitForExistence(timeout: 10))
            XCTAssertEqual(try Data(contentsOf: opencode), original)
            let zedConfig = try JSONSerialization.jsonObject(with: Data(contentsOf: zed)) as? [String: Any]
            XCTAssertNotNil(zedConfig?["language_models"])
            if !isBefore {
                XCTAssertEqual(result.value as? String ?? result.label, "Wired 1 of 2 clients to org/Qwen-first. 1 client failed.")
                XCTAssertTrue(app.buttons["Measure this workflow…"].exists)
                XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "config file changed after the preview", "config file changed after the preview")).count, 1)
            }
            capture("Clients-\(appearance)-partial-wiring")
            app.buttons["Roll back last wiring"].click()
            XCTAssertEqual(try Data(contentsOf: zed), zedOriginal)
            XCTAssertEqual(try Data(contentsOf: opencode), original)
            if !isBefore {
                XCTAssertFalse(result.exists)
                XCTAssertFalse(app.buttons["Measure this workflow…"].exists)
            }
            capture("Clients-\(appearance)-after-rollback")

            app.buttons["Preview client wiring"].click()
            XCTAssertTrue(confirm.waitForExistence(timeout: 10))
            confirm.click()
            let success = isBefore ? "Wired 2 client(s) to org/Qwen-first." : "Wired 2 clients to org/Qwen-first."
            XCTAssertTrue(text(containing: success).waitForExistence(timeout: 10))
            for config in [opencode, zed] {
                XCTAssertTrue(try String(contentsOf: config).contains("127.0.0.1:8766/v1"))
            }
            capture("Clients-\(appearance)-full-wiring")
            app.buttons["Preview client wiring"].click()
            XCTAssertTrue(confirm.waitForExistence(timeout: 10))
            if !isBefore {
                XCTAssertFalse(result.exists)
                XCTAssertFalse(app.buttons["Measure this workflow…"].exists)
            }
            capture("Clients-\(appearance)-new-preview")
            app.terminate()
        }
    }

    func testManualWiringRequiresCurrentReview() throws {
        let before = ProcessInfo.processInfo.environment["MLX_WORKBENCH_CAPTURE_STAGE"] == "before"
        let config = root.appendingPathComponent("manual-runtime-configuration-with-a-long-filename.json")
        let original = Data("{}".utf8)
        for appearance in ["Light", "Dark"] {
            for flag in ["fail-wire-preview", "fail-wire-apply", "false-wire-apply", "missing-wire-hash"] {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(flag))
            }
            try original.write(to: config)
            let installed = root.appendingPathComponent(".config/opencode/opencode.jsonc")
            try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: installed)
            let servers: [[String: Any]] = [["repo": "fixture/ReviewedModel", "runtime": "mlx_lm", "port": 8766, "pid": 123, "state": "running"]]
            try JSONSerialization.data(withJSONObject: servers).write(to: root.appendingPathComponent("servers.json"))
            launch(appearance: appearance, isolatedHome: true)
            select("Clients")
            resizeWindow(width: 1024, height: 680)
            XCTAssertEqual(app.windows.firstMatch.frame.width, 1024, accuracy: 2)
            XCTAssertEqual(app.windows.firstMatch.frame.height, 680, accuracy: 2)
            var scroll: XCUIElement { app.scrollViews.containing(.disclosureTriangle, identifier: "Advanced: manual single-file wiring").firstMatch }
            var advanced: XCUIElement { app.disclosureTriangles["Advanced: manual single-file wiring"] }
            for _ in 0..<6 where !advanced.isHittable { scroll.scroll(byDeltaX: 0, deltaY: -300) }
            XCTAssertTrue(advanced.isHittable)
            capture("ManualWire-\(appearance)-collapsed-standard")
            // The native disclosure's accessibility frame includes the scroll
            // page inset. Only its leading arrow toggles the section on macOS.
            let window = app.windows.firstMatch
            let frame = advanced.frame.intersection(scroll.frame)
            XCTAssertFalse(frame.isNull)
            window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                dx: frame.minX + 24 + frame.height / 4 - window.frame.minX,
                dy: frame.midY - window.frame.minY
            )).click()
            XCTAssertEqual(advanced.value as? Int, 1)
            var model: XCUIElement { app.textFields[before ? "Model repo id" : "manual-wire-model"] }
            var path: XCUIElement { app.textFields[before ? "Config file path" : "manual-wire-path"] }
            func reveal(_ element: XCUIElement) {
                XCTAssertTrue(element.waitForExistence(timeout: 10))
                for _ in 0..<6 where !element.isHittable {
                    let above = element.frame.midY < scroll.frame.minY
                    scroll.scroll(byDeltaX: 0, deltaY: above ? 300 : -300)
                }
                XCTAssertTrue(element.isHittable)
            }
            reveal(model)
            replace(model, with: "fixture/ReviewedModel")
            reveal(path)
            replace(path, with: config.path)
            capture("ManualWire-\(appearance)-unreviewed-standard")
            var preview: XCUIElement { before ? app.buttons["Preview Wire"] : app.buttons["manual-wire-preview"] }
            var confirm: XCUIElement { before ? app.buttons["Apply Wiring"] : app.buttons["manual-wire-confirm"] }
            reveal(preview)
            let holdPreview = root.appendingPathComponent("hold-wire-preview")
            let expiredPreviewHold = root.appendingPathComponent("wire-preview-hold-expired")
            if !before { try Data().write(to: holdPreview) }
            preview.click()
            if !before {
                XCTAssertTrue(app.descendants(matching: .any)["manual-wire-progress"].waitForExistence(timeout: 5))
                XCTAssertFalse(preview.isEnabled)
                capture("ManualWire-\(appearance)-previewing")
                XCTAssertTrue(FileManager.default.fileExists(atPath: holdPreview.path), "The preview fixture must remain blocked until released")
                try FileManager.default.removeItem(at: holdPreview)
                XCTAssertFalse(FileManager.default.fileExists(atPath: expiredPreviewHold.path), "The bounded preview hold must not expire")
            }
            reveal(confirm)
            XCTAssertTrue(confirm.isEnabled)
            XCTAssertEqual(try Data(contentsOf: config), original)
            capture("ManualWire-\(appearance)-reviewed-standard")
            resizeWindow(width: 740, height: 680)
            XCTAssertEqual(app.windows.firstMatch.frame.width, 740, accuracy: 2)
            XCTAssertEqual(app.windows.firstMatch.frame.height, 680, accuracy: 2)
            reveal(confirm)
            capture("ManualWire-\(appearance)-reviewed-scrolled-narrow")
            if before { app.terminate(); continue }

            let capturedPath = app.staticTexts["manual-wire-reviewed-path"]
            XCTAssertTrue(capturedPath.exists)
            reveal(model)
            replace(model, with: "fixture/ChangedModel")
            XCTAssertTrue(!confirm.exists || !confirm.isEnabled)
            capture("ManualWire-\(appearance)-edited-review-invalidated")
            reveal(preview)
            preview.click()
            reveal(confirm)
            XCTAssertTrue(confirm.isEnabled)
            try Data().write(to: root.appendingPathComponent("false-wire-apply"))
            confirm.click()
            XCTAssertTrue(app.descendants(matching: .any)["manual-wire-progress"].waitForExistence(timeout: 5))
            XCTAssertFalse(preview.isEnabled)
            capture("ManualWire-\(appearance)-applying")
            XCTAssertTrue(text(containing: "Wiring was not applied.").waitForExistence(timeout: 15))
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: preview)
            waitForExpectations(timeout: 15)
            XCTAssertEqual(try Data(contentsOf: config), original)
            XCTAssertFalse(text(containing: "Wiring applied.").exists)
            XCTAssertTrue(!confirm.exists || !confirm.isEnabled)
            capture("ManualWire-\(appearance)-not-applied")
            try FileManager.default.removeItem(at: root.appendingPathComponent("false-wire-apply"))
            reveal(preview)
            preview.click()
            reveal(confirm)
            confirm.click()
            XCTAssertTrue(text(containing: "Wiring applied.").waitForExistence(timeout: 15))
            XCTAssertTrue(!confirm.exists || !confirm.isEnabled)
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: String]
            XCTAssertEqual(saved["model"], "fixture/ChangedModel")
            XCTAssertEqual(saved["target"], "mlx_lm")
            let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl")).split(separator: "\n")
                .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String] }
                .filter { $0.prefix(2) == ["wire", "apply"] && $0.contains("--confirm") }
            XCTAssertEqual(calls.count, appearance == "Light" ? 2 : 4)
            XCTAssertTrue(calls.allSatisfy { $0[2] == "fixture/ChangedModel" && $0.contains(config.path) })
            capture("ManualWire-\(appearance)-applied")

            try Data().write(to: root.appendingPathComponent("fail-wire-preview"))
            reveal(preview)
            preview.click()
            XCTAssertTrue(text(containing: "Fixture manual wiring failed").waitForExistence(timeout: 15))
            capture("ManualWire-\(appearance)-preview-error")
            app.terminate()
        }
    }

    func testLegacyLMStudioRouteOpensTheLibrarySource() throws {
        launch(appearance: "Light", route: "lmstudio", isolatedHome: true, forcedRoute: "lmstudio")
        XCTAssertTrue(app.buttons["Scan Again"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["Library"].value as? String, "Selected")
        XCTAssertEqual(app.popUpButtons["library-source"].firstMatch.value as? String, "LM Studio files")
        capture("Library-legacy-lmstudio")
    }

    func testLegacyAdoptRouteOpensDiscoverRecommendations() throws {
        launch(appearance: "Light", route: "adopt", isolatedHome: true, forcedRoute: "adopt")
        XCTAssertTrue(app.buttons["adopt-start"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["Discover"].value as? String, "Selected")
        XCTAssertFalse(app.buttons["Adopt"].exists)
        capture("Discover-legacy-adopt")
    }

    func testAdoptionHandoffAndRecovery() throws {
        let before = ProcessInfo.processInfo.environment["MLX_WORKBENCH_CAPTURE_STAGE"] == "before"
        let repository = "mlx-community/Qwen-Coding-Long-Repository-Name-For-Local-Adoption-4bit"
        for appearance in ["Light", "Dark"] {
            for flag in ["fail-adopt-start", "fail-adopt-status", "adopt-no-recommendation", "adopt-unknown"] {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(flag))
            }
            func selectRecommendations() {
                select("Discover")
                selectRadioOption("Recommend for a task", in: "discovery-mode")
            }
            launch(appearance: appearance, isolatedHome: true)
            selectRecommendations()
            resizeWindow(width: 1024, height: 680)
            XCTAssertEqual(app.windows.firstMatch.frame.width, 1024, accuracy: 2)
            XCTAssertEqual(app.windows.firstMatch.frame.height, 680, accuracy: 2)
            capture("Adopt-\(appearance)-idle-standard")
            if before { app.terminate(); continue }

            let callsURL = root.appendingPathComponent("calls.jsonl")
            func calls() throws -> [[String]] {
                guard FileManager.default.fileExists(atPath: callsURL.path) else { return [] }
                return try String(contentsOf: callsURL).split(separator: "\n").map {
                    try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String]
                }.filter { $0.first == "adopt" }
            }

            var picker: XCUIElement { app.popUpButtons["adopt-role"] }
            func chooseRole(_ title: String) {
                XCTAssertTrue(picker.waitForExistence(timeout: 10))
                XCTAssertTrue(picker.isEnabled)
                let frame = picker.frame
                XCTAssertTrue(frame.midX.isFinite && frame.midY.isFinite && frame.width > 0 && frame.height > 0)
                let control = XCTAttachment(string: "Role picker: frame=\(frame), enabled=\(picker.isEnabled), hittable=\(picker.isHittable)")
                control.name = "Adopt-\(appearance)-role-\(title)-bounds"
                control.lifetime = .keepAlways
                add(control)
                let window = app.windows.firstMatch
                window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                    dx: frame.midX - window.frame.minX, dy: frame.midY - window.frame.minY
                )).click()
                let item = picker.menuItems[title]
                XCTAssertTrue(item.waitForExistence(timeout: 5))
                item.click()
                XCTAssertEqual(picker.value as? String, title)
            }
            chooseRole("Coding")
            let recommendations = app.scrollViews.containing(.popUpButton, identifier: "adopt-role").firstMatch
            let fast = recommendations.checkBoxes["Fast"]
            fast.click()
            XCTAssertEqual(fast.value as? Int, 1)
            recommendations.checkBoxes["Offline metadata"].click()
            var start: XCUIElement { app.buttons["adopt-start"] }
            var refresh: XCUIElement { app.buttons["adopt-refresh"] }
            XCTAssertEqual(start.label, "Verify and recommend")
            XCTAssertFalse(recommendations.buttons["Start"].exists)
            let callsBeforeHiddenReturn = try calls()
            selectRadioOption("Browse candidates", in: "discovery-mode")
            app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
            selectRecommendations()
            XCTAssertEqual(picker.value as? String, "Coding")
            XCTAssertEqual(fast.value as? Int, 1)
            XCTAssertEqual(recommendations.checkBoxes["Offline metadata"].value as? Int, 1)
            XCTAssertEqual(try calls(), callsBeforeHiddenReturn, "Mode changes and Return in Browse must not start verification")
            select("Library")
            app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
            selectRecommendations()
            XCTAssertEqual(try calls(), callsBeforeHiddenReturn, "A hidden Adopt route must not handle Return")
            try Data().write(to: root.appendingPathComponent("hold-adopt-request"))
            start.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
            XCTAssertTrue(app.descendants(matching: .any)["adopt-progress"].waitForExistence(timeout: 5))
            XCTAssertFalse(start.isEnabled)
            XCTAssertFalse(picker.isEnabled)
            capture("Adopt-\(appearance)-starting")
            select("Library")
            selectRecommendations()
            try FileManager.default.removeItem(at: root.appendingPathComponent("hold-adopt-request"))
            XCTAssertTrue(text(containing: repository).waitForExistence(timeout: 15))
            capture("Adopt-\(appearance)-recommendation-standard")
            XCTAssertTrue(refresh.isEnabled)

            let firstStart = try XCTUnwrap(calls().last { $0.prefix(2) == ["adopt", "start"] })
            XCTAssertTrue(firstStart.contains("--fast"))
            XCTAssertTrue(firstStart.contains("--offline"))
            let stateIndex = try XCTUnwrap(firstStart.firstIndex(of: "--state")) + 1
            let firstPath = firstStart[stateIndex]
            XCTAssertTrue(firstPath.hasPrefix(root.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: firstPath))

            chooseRole("Reasoning")
            XCTAssertTrue(text(containing: repository).exists, "Draft edits retain the recorded recommendation")
            let recordedRole = app.staticTexts["adopt-requested-role"]
            XCTAssertEqual(recordedRole.value as? String ?? recordedRole.label, "Coding")
            try Data().write(to: root.appendingPathComponent("hold-adopt-request"))
            refresh.click()
            XCTAssertTrue(app.descendants(matching: .any)["adopt-progress"].waitForExistence(timeout: 5))
            XCTAssertFalse(refresh.isEnabled)
            capture("Adopt-\(appearance)-refreshing")
            try FileManager.default.removeItem(at: root.appendingPathComponent("hold-adopt-request"))
            XCTAssertTrue(refresh.waitForExistence(timeout: 10))
            XCTAssertTrue(text(containing: repository).waitForExistence(timeout: 10))
            let predicate = NSPredicate(format: "enabled == true")
            expectation(for: predicate, evaluatedWith: refresh)
            waitForExpectations(timeout: 10)
            let statusCall = try XCTUnwrap(calls().last { $0.prefix(2) == ["adopt", "status"] })
            XCTAssertEqual(statusCall[try XCTUnwrap(statusCall.firstIndex(of: "--state")) + 1], firstPath)

            try Data().write(to: root.appendingPathComponent("fail-adopt-status"))
            refresh.click()
            XCTAssertTrue(text(containing: "Fixture adoption status failed").waitForExistence(timeout: 15))
            XCTAssertTrue(app.descendants(matching: .any)["adopt-last-known"].exists)
            XCTAssertTrue(text(containing: repository).exists)
            capture("Adopt-\(appearance)-refresh-error")
            resizeWindow(width: 740, height: 680)
            XCTAssertEqual(app.windows.firstMatch.frame.width, 740, accuracy: 2)
            XCTAssertEqual(app.windows.firstMatch.frame.height, 680, accuracy: 2)
            XCTAssertTrue(start.isHittable)
            XCTAssertTrue(picker.isHittable)
            capture("Adopt-\(appearance)-recommendation-narrow")
            var outcome: XCUIElement { app.scrollViews.containing(.staticText, identifier: "adopt-model").firstMatch }
            var details: XCUIElement { app.disclosureTriangles["Workflow details"] }
            func toggleDetails(expectedValue: Int) {
                let frame = details.frame.intersection(outcome.frame)
                XCTAssertFalse(frame.isNull)
                XCTAssertTrue(details.isHittable)
                let window = app.windows.firstMatch
                window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                    dx: frame.minX + frame.height / 4 - window.frame.minX,
                    dy: frame.midY - window.frame.minY
                )).click()
                XCTAssertEqual(details.value as? Int, expectedValue)
            }
            outcome.scroll(byDeltaX: 0, deltaY: -outcome.frame.height)
            toggleDetails(expectedValue: 1)
            outcome.scroll(byDeltaX: 0, deltaY: -outcome.frame.height)
            XCTAssertTrue(app.staticTexts["adopt-state-path"].waitForExistence(timeout: 5))
            capture("Adopt-\(appearance)-details-scrolled")
            toggleDetails(expectedValue: 0)
            outcome.scroll(byDeltaX: 0, deltaY: outcome.frame.height)
            try FileManager.default.removeItem(at: root.appendingPathComponent("fail-adopt-status"))
            resizeWindow(width: 1024, height: 680)

            try Data().write(to: root.appendingPathComponent("adopt-no-recommendation"))
            start.click()
            XCTAssertTrue(text(containing: "No recommendation reported").waitForExistence(timeout: 15))
            XCTAssertFalse(text(containing: "shortlisted-only/model").exists)
            let secondStart = try XCTUnwrap(calls().last { $0.prefix(2) == ["adopt", "start"] })
            let secondPath = secondStart[try XCTUnwrap(secondStart.firstIndex(of: "--state")) + 1]
            XCTAssertNotEqual(firstPath, secondPath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: firstPath))
            capture("Adopt-\(appearance)-no-recommendation")

            try Data().write(to: root.appendingPathComponent("fail-adopt-start"))
            start.click()
            XCTAssertTrue(text(containing: "Fixture adoption failed").waitForExistence(timeout: 15))
            XCTAssertTrue(start.isEnabled)
            capture("Adopt-\(appearance)-start-error")
            try FileManager.default.removeItem(at: root.appendingPathComponent("fail-adopt-start"))
            try Data().write(to: root.appendingPathComponent("adopt-unknown"))
            start.click()
            XCTAssertTrue(text(containing: "No recommendation reported").waitForExistence(timeout: 15))
            XCTAssertFalse(text(containing: repository).exists)
            capture("Adopt-\(appearance)-missing-fields")

            try FileManager.default.removeItem(at: root.appendingPathComponent("adopt-unknown"))
            try FileManager.default.removeItem(at: root.appendingPathComponent("adopt-no-recommendation"))
            let hold = root.appendingPathComponent("hold-adopt-cancellation")
            let pidFile = root.appendingPathComponent("adopt-cancellation-pid")
            try? FileManager.default.removeItem(at: pidFile)
            try Data().write(to: hold)
            start.click()
            let started = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: pidFile.path)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 10), .completed)
            let cancelledStart = try XCTUnwrap(calls().last { $0.prefix(2) == ["adopt", "start"] })
            let cancelledPath = cancelledStart[try XCTUnwrap(cancelledStart.firstIndex(of: "--state")) + 1]
            let savedState = try Data(contentsOf: URL(fileURLWithPath: cancelledPath))
            let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
            let stop = app.buttons["adopt-stop"]
            XCTAssertTrue(stop.waitForExistence(timeout: 5))
            XCTAssertTrue(stop.isHittable)
            XCTAssertFalse(start.isEnabled)
            capture("Adopt-\(appearance)-stop-standard")
            resizeWindow(width: 740, height: 680)
            XCTAssertTrue(stop.isHittable)
            capture("Adopt-\(appearance)-stop-compact")
            stop.click()
            let stopped = app.descendants(matching: .any)["adopt-stopped"].firstMatch
            XCTAssertTrue(stopped.waitForExistence(timeout: 10))
            XCTAssertTrue(start.isEnabled)
            XCTAssertFalse(stop.exists)
            XCTAssertFalse(text(containing: "Waiting for the agent's recommendation").exists)
            XCTAssertTrue(text(containing: "No recommendation reported").exists)
            let processStatus = kill(pid, 0), processError = errno
            XCTAssertEqual(processStatus, -1, "The cancelled recommendation process must have exited")
            XCTAssertEqual(processError, ESRCH)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: cancelledPath)), savedState)
            XCTAssertFalse(text(containing: repository).exists)
            capture("Adopt-\(appearance)-stopped")
            refresh.click()
            let refreshed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: refresh)
            XCTAssertEqual(XCTWaiter.wait(for: [refreshed], timeout: 10), .completed)
            XCTAssertTrue(stopped.exists, "Reading partial saved state must retain the stopped notice")
            try FileManager.default.removeItem(at: hold)
            resizeWindow(width: 1024, height: 680)
            start.click()
            XCTAssertTrue(text(containing: repository).waitForExistence(timeout: 15))
            XCTAssertFalse(stopped.exists)
            let restarted = try XCTUnwrap(calls().last { $0.prefix(2) == ["adopt", "start"] })
            XCTAssertNotEqual(restarted[try XCTUnwrap(restarted.firstIndex(of: "--state")) + 1], cancelledPath)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: cancelledPath)), savedState)
            app.terminate()
        }
    }

    func testChatResultsWorkspace() throws {
        let folder = root.appendingPathComponent("Library/Application Support/mlx-workbench")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("comparison-runs.json")
        let prompts: [[String: Any]] = [
            ["id": "p1", "text": "Write a Python function that returns the nth Fibonacci number. Code only.", "maxTokens": 256],
            ["id": "p2", "text": "Explain a Python context manager in two sentences.", "maxTokens": 256]
        ]
        func sample(_ prompt: String, _ text: String, _ finish: String?) -> [String: Any] {
            var value: [String: Any] = ["promptID": prompt, "outputExcerpt": text, "fullOutput": text,
                "tokensPerSecond": 98.0, "timeToFirstTokenSeconds": 0.21,
                "timeToFirstAnswerSeconds": 0.21, "durationSeconds": 1.2, "completionTokens": 75]
            value["finishReason"] = finish
            return value
        }
        let results: [[String: Any]] = [
            ["modelPath": "/models/Qwen2.5-7B-Instruct-4bit", "samples": [
                sample("p1", "```python\ndef fib(n):\n    a, b = 0, 1\n    for _ in range(n):\n        a, b = b, a + b\n    return a\n```", "stop"),
                sample("p2", "A context manager wraps setup and cleanup around a block. The with statement ensures cleanup runs when the block exits.", "stop")],
             "aggregateTokensPerSecond": 97.9, "aggregateTTFTSeconds": 0.21],
            ["modelPath": "/models/Qwen2.5-VL-3B-Instruct-4bit", "samples": [], "error": "The declared mlx-vlm backend is not installed."],
            ["modelPath": "/models/Qwen3-4B-4bit", "samples": [sample("p1", "<think>Check the Fibonacci recurrence before writing the function.", "length"),
                sample("p2", "<think>Consider setup and cleanup.</think>A context manager controls a resource lifetime.", "stop")],
             "aggregateTokensPerSecond": 205.2, "aggregateTTFTSeconds": 0.16],
            ["modelPath": "/models/Legacy-4bit", "samples": [sample("p1", "Saved answer with no finish reason.", nil)],
             "aggregateTokensPerSecond": 74.2]
        ]
        for appearance in ["Dark", "Light"] {
            for legacy in [false, true] {
                var run: [String: Any] = ["id": UUID().uuidString, "promptSetID": "results-fixture", "promptSetName": "Coding basics",
                    "variants": results.map { $0["modelPath"]! }, "results": results,
                    "startedAt": 800000000.0, "finishedAt": 800000020.0, "state": "completed"]
                if !legacy { run["promptEntries"] = prompts }
                let recorded = try JSONSerialization.data(withJSONObject: [run], options: [.sortedKeys])
                try recorded.write(to: file)
                launch(appearance: appearance, isolatedHome: true)
                resizeWindow(width: 1440, height: 900)
                select("Compare")
                XCTAssertTrue(app.staticTexts["Models in this run"].firstMatch.waitForExistence(timeout: 15))
                XCTAssertTrue(app.staticTexts[legacy ? "Completion unknown · entire run" : "2/2 finished · entire run"].firstMatch.exists)
                XCTAssertTrue(app.buttons["comparison-cell-1-0"].label.contains("Blocked"))
                if !legacy {
                    XCTAssertTrue(app.buttons["Use model A…"].exists)
                    XCTAssertFalse(app.buttons["Use model C…"].exists)
                    app.buttons["comparison-cell-2-1"].click()
                    XCTAssertTrue(app.staticTexts["Prompt 2 of 2"].exists)
                    XCTAssertTrue(app.staticTexts["A context manager wraps setup and cleanup around a block. The with statement ensures cleanup runs when the block exits."].exists)
                    XCTAssertTrue(app.staticTexts["A context manager controls a resource lifetime."].exists)
                    capture("Compare-board-\(appearance)-wide")
                    app.buttons["Previous prompt"].click()
                    XCTAssertTrue(app.staticTexts["Prompt 1 of 2"].exists)
                    app.buttons["Next prompt"].click()
                    app.radioButtons["Differences"].firstMatch.click()
                    XCTAssertTrue(app.staticTexts["− Left model · + Right model · unchanged lines have no sign"].exists)
                    capture("Compare-board-\(appearance)-differences")
                    app.radioButtons["Read"].firstMatch.click()
                    app.buttons["comparison-cell-1-1"].click()
                    XCTAssertTrue(app.staticTexts["The declared mlx-vlm backend is not installed."].exists)
                    app.buttons["comparison-cell-0-1"].click()
                } else { capture("Compare-board-\(appearance)-legacy-wide") }
                resizeWindow(width: 740, height: 560)
                app.scrollViews["comparison-scroll"].firstMatch.scroll(byDeltaX: 0, deltaY: 1200)
                XCTAssertTrue(app.radioButtons["Read right"].firstMatch.waitForExistence(timeout: 5))
                app.radioButtons["Read right"].firstMatch.click()
                XCTAssertEqual(app.radioButtons["Read right"].firstMatch.value as? Int, 1)
                let window = app.windows.firstMatch.frame
                for control in [app.radioButtons["Read left"].firstMatch,
                                app.radioButtons["Read right"].firstMatch,
                                app.buttons["Next prompt"].firstMatch] {
                    XCTAssertGreaterThanOrEqual(control.frame.minX, window.minX)
                    XCTAssertLessThanOrEqual(control.frame.maxX, window.maxX)
                }
                capture("Compare-board-\(appearance)-\(legacy ? "legacy" : "mixed")-minimum")
                app.terminate()
                XCTAssertEqual(try Data(contentsOf: file), recorded, "Reading must not rewrite historical runs")
            }
        }
    }

    func testOverviewUsesTaskSpecificStages() throws {
        for (kind, canVerify, canCompare) in [("music_generation", false, true),
                                              ("image_generation", true, true),
                                              ("speculative_draft", false, false)] {
            let name = "Overview " + kind
            _ = try installTaskModel(kind: kind, name: name)
            launch(appearance: "Dark", route: "models", isolatedHome: true)
            let row = app.outlines.staticTexts[name].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 15)); row.click()
            select("Overview")
            func stage(_ title: String) -> XCUIElement {
                app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title + ":")).firstMatch
            }
            XCTAssertTrue(stage("Prepared").waitForExistence(timeout: 10))
            XCTAssertFalse(stage("Serving").exists)
            XCTAssertEqual(stage("Verified").exists, canVerify)
            XCTAssertEqual(stage("Measured").exists, canCompare)
            resizeWindow(width: 1440, height: 900)
            capture("Overview-\(kind)-wide")
            resizeWindow(width: 740, height: 560)
            capture("Overview-\(kind)-minimum")
            app.terminate()
        }
        let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8)
        for command in ["\"task\", \"start\"", "\"serve\", \"start\"", "\"convert\", \"start\"", "\"backend\", \"install\""] {
            XCTAssertFalse(calls.contains(command), "Guidance and navigation must not start work")
        }
    }

    func testMissingModelBackendRepairReturnsToOriginalModel() throws {
        let model = try installTaskModel(kind: "speech_to_text", name: "Local speech model")
        let scanURL = root.appendingPathComponent("scan-result.json")
        var scan = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: scanURL)) as? [String: Any])
        var outputs = try XCTUnwrap(scan["outputs"] as? [[String: Any]])
        outputs[0]["backend"] = ["id": "mlx-audio", "installed": false]
        outputs[0]["provenance"] = "speech-original"
        scan["outputs"] = outputs
        try JSONSerialization.data(withJSONObject: scan).write(to: scanURL)
        try JSONSerialization.data(withJSONObject: [["id": "mlx-audio", "version": "1.0", "builtin": false,
            "state": "absent", "categories": ["speech_to_text"], "model_types": 1, "registry_source": "snapshot"]])
            .write(to: root.appendingPathComponent("backends.json"))
        try Data().write(to: root.appendingPathComponent("allow-runtime-repair"))
        try Data().write(to: root.appendingPathComponent("fail-runtime-repair"))
        launch(appearance: "Dark", route: "models", isolatedHome: true)
        let row = app.outlines.staticTexts["Local speech model"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.doubleClick()
        let repair = app.buttons["Repair runtime…"].firstMatch
        XCTAssertTrue(repair.waitForExistence(timeout: 10))
        repair.click()
        let review = app.buttons["Review installation…"].firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 15))
        XCTAssertTrue(review.isEnabled)
        XCTAssertFalse(app.descendants(matching: .any)["library-source"].exists,
                       "The retained Library picker must not cover Health's controls")
        var calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8)
        XCTAssertFalse(calls.contains("\"backend\", \"install\""))
        capture("Runtime-repair-selected-model")
        XCTAssertTrue(waitForHittability(review, timeout: 10), app.debugDescription)
        review.click()
        let confirm = app.buttons["Confirm installation"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        XCTAssertTrue(text(containing: "/fixture/backends/mlx-audio").exists)
        resizeWindow(width: 740, height: 560)
        XCTAssertTrue(confirm.isHittable)
        capture("Runtime-repair-review-minimum")
        confirm.click()
        XCTAssertTrue(text(containing: "Installing mlx-audio failed.").waitForExistence(timeout: 15))
        XCTAssertFalse(confirm.exists, "Failures invalidate the preview")
        let logButton = app.buttons["View installation log…"].firstMatch
        XCTAssertTrue(logButton.waitForExistence(timeout: 10))
        logButton.click()
        let logSheet = app.sheets.firstMatch
        XCTAssertTrue(logSheet.waitForExistence(timeout: 10))
        XCTAssertTrue(text(containing: "Fixture dependency resolution failed.").waitForExistence(timeout: 10))
        capture("Runtime-repair-installation-log-minimum")
        logSheet.buttons["Done"].click()
        XCTAssertTrue(logSheet.waitForNonExistence(timeout: 10))
        try FileManager.default.removeItem(at: root.appendingPathComponent("backend-install.log"))
        logButton.click()
        XCTAssertTrue(text(containing: "The recorded installation log could not be read.").waitForExistence(timeout: 10))
        logSheet.buttons["Done"].click()
        XCTAssertTrue(logSheet.waitForNonExistence(timeout: 10))
        let beforeRetry = try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8)
            .split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String] }
        XCTAssertEqual(beforeRetry.filter { Array($0.prefix(2)) == ["backend", "install"] }.count, 2,
                       "Reading logs must not preview or retry installation")
        try FileManager.default.removeItem(at: root.appendingPathComponent("fail-runtime-repair"))
        review.click()
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        confirm.click()
        XCTAssertTrue(app.staticTexts["runtime-repair-installed"].waitForExistence(timeout: 15))
        let backendStatus = app.staticTexts["health-backend-mlx-audio-status"]
        let refreshed = expectation(for: NSPredicate(format: "value == %@ OR label == %@", "Installed", "Installed"), evaluatedWith: backendStatus)
        wait(for: [refreshed], timeout: 15)
        let back = app.buttons["Return to model"]
        XCTAssertTrue(back.isHittable)
        capture("Runtime-repair-installed-minimum")
        back.click()
        XCTAssertTrue(app.buttons["Verify now"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(text(containing: "Local speech model").exists)
        capture("Runtime-repair-returned-to-model")
        calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8)
        let requests = calls.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String] }
        let installs = requests.filter { Array($0.prefix(2)) == ["backend", "install"] }
        XCTAssertEqual(installs.count, 4, "Each attempt must preview and explicitly confirm")
        XCTAssertTrue(installs.allSatisfy { $0[2] == "mlx-audio" })
        XCTAssertTrue(requests.filter { Array($0.prefix(2)) == ["convert", "scan"] }.count >= 2)
        for command in [["intake", "fetch"], ["serve", "start"], ["task", "start"], ["convert", "start"]] {
            XCTAssertFalse(requests.contains { Array($0.prefix(2)) == command })
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.path))
    }

    func testProcessMemoryInspectorReadsWithoutStartingWork() throws {
        launch(appearance: "Dark")
        select("Run")
        let inspect = app.buttons["inspect-process-memory"].firstMatch
        XCTAssertTrue(inspect.waitForExistence(timeout: 10))
        XCTAssertTrue(inspect.isHittable)
        inspect.click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        let table = sheet.outlines["process-memory-table"]
        XCTAssertTrue(table.waitForExistence(timeout: 10))
        let populated = expectation(for: NSPredicate(format: "count > 0"), evaluatedWith: table.outlineRows)
        wait(for: [populated], timeout: 15)
        XCTAssertTrue(sheet.staticTexts["process-memory-timestamp"].exists)
        XCTAssertFalse(sheet.staticTexts["process-memory-error"].exists)
        XCTAssertTrue(sheet.buttons["Open Activity Monitor"].isHittable)
        capture("Process-memory-standard")
        sheet.buttons["Refresh"].click()
        let refreshed = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: sheet.buttons["Refresh"])
        wait(for: [refreshed], timeout: 15)
        XCTAssertGreaterThan(table.outlineRows.count, 0)
        XCTAssertLessThanOrEqual(table.outlineRows.count, 15)
        sheet.buttons["Done"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
        resizeWindow(width: 740, height: 560)
        XCTAssertTrue(inspect.isHittable)
        inspect.click()
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        XCTAssertTrue(sheet.buttons["Done"].isHittable)
        XCTAssertTrue(sheet.buttons["Refresh"].isHittable)
        capture("Process-memory-minimum")
        sheet.buttons["Done"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
        app.buttons["system-memory-header"].click()
        let toolbarInspect = app.popovers.buttons["inspect-process-memory"].firstMatch
        XCTAssertTrue(toolbarInspect.waitForExistence(timeout: 10))
        toolbarInspect.click()
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        XCTAssertTrue(sheet.buttons["Done"].isHittable)
        let windowBounds = app.windows.firstMatch.frame
        let sheetBounds = sheet.frame
        XCTAssertGreaterThanOrEqual(sheetBounds.minX, windowBounds.minX)
        XCTAssertGreaterThanOrEqual(sheetBounds.minY, windowBounds.minY)
        XCTAssertLessThanOrEqual(sheetBounds.maxX, windowBounds.maxX)
        XCTAssertLessThanOrEqual(sheetBounds.maxY, windowBounds.maxY)
        capture("Process-memory-from-toolbar")
        sheet.buttons["Done"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
        let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8)
        let requests = calls.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String] }
        for command in [["intake", "fetch"], ["serve", "start"], ["task", "start"], ["convert", "start"], ["backend", "install"]] {
            XCTAssertFalse(requests.contains { Array($0.prefix(2)) == command })
        }
    }

    func testReclaimSuggestionActionsAlignAtWideAndNarrowWidths() throws {
        launch(appearance: "Dark", route: "duplicates", isolatedHome: true)
        select("Reclaim")
        let analyze = app.buttons["Analyze"]
        let review = app.buttons["Review model folder…"]
        let cache = app.buttons["Check HF cache"]
        for button in [analyze, review, cache] {
            XCTAssertTrue(button.waitForExistence(timeout: 15))
        }
        let scroll = app.scrollViews.containing(.button, identifier: "Analyze").firstMatch
        for width in [1050.0, 740.0] {
            resizeWindow(width: width, height: width == 740 ? 612 : 900)
            for _ in 0..<8 where ![analyze, review, cache].allSatisfy(\.isHittable) {
                scroll.scroll(byDeltaX: 0, deltaY: -180)
            }
            for button in [analyze, review, cache] { XCTAssertTrue(button.isHittable) }
            for button in [review, cache] {
                XCTAssertEqual(button.frame.height, analyze.frame.height, accuracy: 1)
                XCTAssertEqual(button.frame.midY, analyze.frame.midY, accuracy: 1)
            }
            capture("Reclaim-action-alignment-\(Int(width))")
        }
    }

    func testRouteCaptures() throws {
        // XCUIDevice changes only the disposable VM's appearance.
        for appearance in [ProcessInfo.processInfo.environment["MLX_WORKBENCH_CAPTURE_APPEARANCE"] ?? "System"] {
            launch(appearance: appearance)
            for route in routes {
                select(route)
                assertPageContent(route)
                capture("\(appearance)-standard-\(route)")
            }
            resizeWindow(width: 740, height: 560)
            let window = app.windows.firstMatch
            let split = app.splitGroups.firstMatch
            XCTAssertTrue(split.exists)
            XCTAssertLessThanOrEqual(split.frame.height, window.frame.height + 1,
                                     "Retained pages must fit the resized window")
            for route in routes {
                select(route)
                assertPageContent(route)
                capture("\(appearance)-minimum-\(route)")
            }
            app.terminate()
        }
    }

    func testOverviewPanelsRemainInsideWindowAndDoNotOverlap() {
        launch(appearance: ProcessInfo.processInfo.environment["MLX_WORKBENCH_CAPTURE_APPEARANCE"] ?? "Light")
        for narrow in [false, true] {
            if narrow { resizeWindow(width: 740, height: 560) }
            select("Overview")
            let budget = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH %@", "Model budget")).firstMatch
            let title = app.staticTexts["Review the model library"].firstMatch
            let action = app.buttons["Open Library"].firstMatch
            XCTAssertTrue(budget.waitForExistence(timeout: 10))
            XCTAssertTrue(title.waitForExistence(timeout: 10))
            let bounds = app.windows.firstMatch.frame
            for element in [budget, title, action, app.buttons["Library"].firstMatch] {
                XCTAssertGreaterThanOrEqual(element.frame.minX, bounds.minX - 1)
                XCTAssertLessThanOrEqual(element.frame.maxX, bounds.maxX + 1)
            }
            XCTAssertTrue(action.isHittable)
            XCTAssertTrue(app.buttons["Library"].firstMatch.isHittable)
            XCTAssertFalse(budget.frame.intersects(title.frame))
            XCTAssertFalse(budget.frame.intersects(action.frame))
            capture(narrow ? "Overview-window-boundary-narrow" : "Overview-window-boundary-standard")
        }
    }
}

/// Dogfoods the first-launch setup assistant with real clicks: sheet appears,
/// every step is navigable, skip and finish behave, and completion persists
/// across relaunch. Runs with an isolated config path; the launch argument
/// forces first-launch state without touching real user defaults.
final class SetupAssistantUITests: XCTestCase {
    private var app: XCUIApplication!
    private var configPath: String!

    override func setUpWithError() throws {
        try NativeUITestEnvironment.requireIsolatedAquaSession()
        continueAfterFailure = false
        configPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mlx-workbench-uitest-\(UUID().uuidString)")
            .appendingPathComponent("config.json")
            .path
    }

    private func launch(firstRun: Bool = true, python: String? = nil, home: URL? = nil, environment: [String: String] = [:]) {
        app = XCUIApplication()
        app.launchEnvironment.merge(environment) { _, supplied in supplied }
        app.launchEnvironment["MLX_WORKBENCH_CONFIG"] = configPath
        if let python { app.launchEnvironment["MLX_WORKBENCH_PYTHON"] = python }
        if let home { app.launchEnvironment["CFFIXED_USER_HOME"] = home.path }
        if firstRun {
            app.launchArguments = ["-mlx-workbench.setupCompleted.v1", "NO"]
        }
        app.launch()
        app.activate()
        _ = app.windows.firstMatch.waitForExistence(timeout: 30)
    }

    /// Attach a screenshot to the test result for dogfood evidence.
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testBundledEnginePreparationConfirmsAndPersistsPackagedSources() throws {
        let configURL = URL(fileURLWithPath: configPath)
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = configURL.deletingLastPathComponent().appendingPathComponent("existing-agent").path
        try JSONSerialization.data(withJSONObject: ["mlx_agent_path": original, "bundle_test_marker": true]).write(to: configURL)
        let home = configURL.deletingLastPathComponent().appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        launch(python: "/usr/bin/false", home: home)
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 15))
        let use = sheet.buttons["setup-bundled-runtime"]
        guard let path = ProcessInfo.processInfo.environment["MLX_WORKBENCH_RUNTIME_PAYLOAD"] else {
            XCTAssertFalse(use.exists, "An ordinary development build has no bundled runtime")
            return
        }
        let payload = URL(fileURLWithPath: path)
        let metadata = try Data(contentsOf: payload.appendingPathComponent("manifest.json"))
        let identity = SHA256.hash(data: metadata).map { String(format: "%02x", $0) }.joined()
        let root = home
            .appendingPathComponent("Library/Application Support/mlx-workbench/runtimes/" + identity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(use.waitForExistence(timeout: 15))
        use.click()
        app.sheets.buttons["Cancel"].firstMatch.click()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "Cancelling confirmation must not copy sources")
        use.click()
        app.sheets.buttons["Prepare engine"].firstMatch.click()
        XCTAssertTrue(sheet.staticTexts["setup-bundled-runtime-prepared"].waitForExistence(timeout: 30))
        let saved = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
        XCTAssertEqual(saved["mlx_agent_path"] as? String, root.appendingPathComponent("vendor/mlx-agent").path)
        XCTAssertEqual(saved["bundle_test_marker"] as? Bool, true)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("manifest.json")), metadata)
        let manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: metadata) as? [String: Any])
        for file in try XCTUnwrap(manifest["files"] as? [[String: Any]]) {
            let name = try XCTUnwrap(file["path"] as? String)
            let digest = SHA256.hash(data: try Data(contentsOf: root.appendingPathComponent(name)))
                .map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, file["sha256"] as? String, name)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".venv").path))
        capture("Bundled-engine-prepared")
        sheet.buttons["Continue"].click()
        XCTAssertTrue(sheet.buttons["Install Runtime…"].waitForExistence(timeout: 15))
        capture("Bundled-engine-dependencies-remain-explicit")
    }

    func testRuntimePrerequisitesAreCheckedWithoutStartingInstallation() throws {
        // An unavailable developer directory exercises recovery without changing macOS tools.
        launch(python: "/usr/bin/false", environment: ["DEVELOPER_DIR": "/nonexistent/workbench-ui-check"])
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 30))
        sheet.buttons["Continue"].click()
        let status = sheet.staticTexts["runtime-prerequisites-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        let scroll = sheet.scrollViews.firstMatch
        func reveal(_ element: XCUIElement) {
            XCTAssertTrue(element.waitForExistence(timeout: 10), app.debugDescription)
            for _ in 0..<10 where !element.isHittable {
                scroll.scroll(byDeltaX: 0, deltaY: element.frame.midY < scroll.frame.minY ? 180 : -180)
            }
            XCTAssertTrue(element.isHittable, app.debugDescription)
        }
        let install = sheet.buttons["runtime-install-start"]
        XCTAssertTrue(install.exists)
        XCTAssertEqual(install.isEnabled, status.label == "Prerequisites found")
        let recheck = sheet.buttons["runtime-prerequisites-recheck"]
        XCTAssertTrue(recheck.isEnabled)
        reveal(recheck)
        recheck.click()
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        XCTAssertFalse(sheet.buttons["runtime-install-cancel"].exists)
        let copy = sheet.buttons["runtime-prerequisite-copy-xcode-select --install"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10), app.debugDescription)
        reveal(copy)
        let previousClipboard = NSPasteboard.general.string(forType: .string)
        copy.click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "xcode-select --install")
        let copied = expectation(for: NSPredicate(format: "label == %@", "Copied"), evaluatedWith: copy)
        wait(for: [copied], timeout: 5)
        let guide = sheet.descendants(matching: .any)["runtime-prerequisite-guide-uv"].firstMatch
        XCTAssertTrue(guide.exists, app.debugDescription)
        XCTAssertFalse(install.isEnabled)
        XCTAssertFalse(sheet.buttons["runtime-install-cancel"].exists)
        capture("Runtime-prerequisite-copy-and-guide")
        let window = app.windows.firstMatch
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        corner.press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 738, dy: 610)))
        reveal(copy)
        reveal(guide)
        reveal(recheck)
        let bounds = sheet.frame
        XCTAssertGreaterThanOrEqual(bounds.minX, window.frame.minX)
        XCTAssertGreaterThanOrEqual(bounds.minY, window.frame.minY)
        XCTAssertLessThanOrEqual(bounds.maxX, window.frame.maxX)
        XCTAssertLessThanOrEqual(bounds.maxY, window.frame.maxY)
        XCTAssertTrue(sheet.buttons["Continue"].isHittable)
        capture("Runtime-prerequisite-guide-minimum")
        NSPasteboard.general.clearContents()
        if let previousClipboard { NSPasteboard.general.setString(previousClipboard, forType: .string) }
    }

    func testPackagedRuntimeInstallsFromCleanSetup() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let uvPath = environment["MLX_WORKBENCH_RUNTIME_INSTALL_UV"],
              let uvDigest = environment["MLX_WORKBENCH_RUNTIME_INSTALL_UV_SHA256"],
              let payloadPath = environment["MLX_WORKBENCH_RUNTIME_PAYLOAD"] else {
            throw XCTSkip("Requires the explicit packaged-runtime installation runner option.")
        }
        executionTimeAllowance = 2400
        let configURL = URL(fileURLWithPath: configPath)
        let home = configURL.deletingLastPathComponent().appendingPathComponent("home")
        let fm = FileManager.default
        let tool = URL(fileURLWithPath: uvPath)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let uvData = try Data(contentsOf: URL(fileURLWithPath: uvPath))
        XCTAssertEqual(SHA256.hash(data: uvData).map { String(format: "%02x", $0) }.joined(), uvDigest)
        let metadata = try Data(contentsOf: URL(fileURLWithPath: payloadPath).appendingPathComponent("manifest.json"))
        let identity = SHA256.hash(data: metadata).map { String(format: "%02x", $0) }.joined()
        let root = home.appendingPathComponent("Library/Application Support/mlx-workbench/runtimes/" + identity)
        let cache = home.appendingPathComponent("cache/uv")
        let pythonInstall = home.appendingPathComponent("python")
        XCTAssertFalse(fm.fileExists(atPath: root.path))
        XCTAssertFalse(fm.fileExists(atPath: cache.path))
        XCTAssertFalse(fm.fileExists(atPath: pythonInstall.path))
        try JSONSerialization.data(withJSONObject: ["mlx_agent_path": "", "gguf_roots": [], "mlx_roots": [],
            "output_dir": home.appendingPathComponent("outputs").path,
            "quarantine_dir": home.appendingPathComponent("quarantine").path]).write(to: configURL)
        launch(home: home, environment: [
            "PATH": tool.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin", "UV_CACHE_DIR": cache.path,
            "UV_PYTHON_INSTALL_DIR": pythonInstall.path, "UV_NO_CONFIG": "1",
            "PIP_CONFIG_FILE": "/dev/null", "PIP_CACHE_DIR": home.appendingPathComponent("cache/pip").path,
            "HF_HOME": home.appendingPathComponent("cache/huggingface").path, "HF_HUB_OFFLINE": "1",
        ])
        if let expectedApp = environment["MLX_WORKBENCH_RUNTIME_INSTALL_APP"] {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.cavi.mlxworkbench")
            XCTAssertEqual(running.count, 1, "Release acceptance must run only the installed candidate")
            let candidate = try XCTUnwrap(running.first)
            XCTAssertEqual(candidate.bundleURL?.resolvingSymlinksInPath().path,
                           URL(fileURLWithPath: expectedApp).resolvingSymlinksInPath().path)
            let executable = try XCTUnwrap(candidate.executableURL)
            let digest = SHA256.hash(data: try Data(contentsOf: executable)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, environment["MLX_WORKBENCH_RUNTIME_INSTALL_APP_SHA256"])
            let receipt = try JSONSerialization.data(withJSONObject: ["app_path": expectedApp,
                "pid": candidate.processIdentifier, "binary_sha256": digest], options: [.prettyPrinted, .sortedKeys])
            let attachment = XCTAttachment(data: receipt, uniformTypeIdentifier: "public.json")
            attachment.name = "Packaged-runtime-running-app.json"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 30))
        XCTAssertTrue(sheet.buttons["setup-bundled-runtime"].waitForExistence(timeout: 30))
        sheet.buttons["setup-bundled-runtime"].click()
        app.sheets.buttons["Prepare engine"].firstMatch.click()
        XCTAssertTrue(sheet.staticTexts["setup-bundled-runtime-prepared"].waitForExistence(timeout: 60))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("manifest.json")), metadata)
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent(".venv").path))
        sheet.buttons["Continue"].click()
        XCTAssertTrue(sheet.staticTexts["runtime-prerequisites-status"].waitForExistence(timeout: 60))
        capture("Packaged-runtime-prerequisites")
        let prerequisiteDetails = XCTAttachment(string: sheet.debugDescription)
        prerequisiteDetails.name = "Packaged-runtime-prerequisites.txt"
        prerequisiteDetails.lifetime = .keepAlways
        add(prerequisiteDetails)
        let install = sheet.buttons["runtime-install-start"]
        XCTAssertTrue(install.waitForExistence(timeout: 15))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: install)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed,
                       "The reused uv tool and system Python must satisfy setup prerequisites")
        install.click()
        app.sheets.buttons["Cancel"].firstMatch.click()
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent(".venv").path))
        install.click()
        app.sheets.buttons["Run make install"].firstMatch.click()
        let terminal = NSPredicate { _, _ in
            let status = sheet.staticTexts["runtime-install-status"]
            let text = (status.value as? String) ?? status.label
            return status.exists && (text == "Install command finished" || text.hasPrefix("Install failed:"))
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: terminal, object: nil)], timeout: 1800)
        capture("Packaged-runtime-install-result")
        if sheet.staticTexts["Install log"].firstMatch.exists { sheet.staticTexts["Install log"].firstMatch.click() }
        let log = sheet.staticTexts.allElementsBoundByIndex.map { ($0.value as? String) ?? $0.label }.joined(separator: "\n")
        let logAttachment = XCTAttachment(string: log)
        logAttachment.name = "Packaged-runtime-install-log"
        logAttachment.lifetime = .keepAlways
        add(logAttachment)
        XCTAssertEqual(result, .completed, "Runtime installation did not reach a terminal state")
        let python = root.appendingPathComponent(".venv/bin/python")
        XCTAssertTrue(fm.isExecutableFile(atPath: python.path))
        let installed = try inspectInstalledRuntime(python: python, root: root)
        let evidence = try JSONSerialization.data(withJSONObject: installed, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: evidence, uniformTypeIdentifier: "public.json")
        attachment.name = "Packaged-runtime-install.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        let completedStatus = sheet.staticTexts["runtime-install-status"]
        XCTAssertEqual((completedStatus.value as? String) ?? completedStatus.label, "Install command finished", log)
        XCTAssertEqual(installed["python"] as? String, "3.12")
        XCTAssertEqual(installed["pins_match"] as? Bool, true)
        let checks = try XCTUnwrap(installed["runtime"] as? [String: Any])
        XCTAssertEqual(checks["ok"] as? Bool, true)
        XCTAssertTrue(sheet.staticTexts["Convert and serve runtimes are ready."].waitForExistence(timeout: 60))
        let saved = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
        XCTAssertEqual(saved["mlx_agent_path"] as? String, root.appendingPathComponent("vendor/mlx-agent").path)
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent("outputs").path))
        capture("Packaged-runtime-ready")
    }

    private func inspectInstalledRuntime(python: URL, root: URL) throws -> [String: Any] {
        let process = Process()
        let output = Pipe()
        process.executableURL = python
        process.currentDirectoryURL = root
        process.arguments = ["-I", "-c", """
        import importlib.metadata, json, pathlib, re, sys
        root = pathlib.Path(sys.argv[1])
        sys.path.insert(0, str(root))
        from mlx_workbench import deps
        pins = {}
        for file in [root / 'requirements.txt', root / 'vendor/mlx-agent/requirements-lab.txt']:
            for name, version in re.findall(r'^([a-zA-Z0-9_.-]+)==([^\\s#]+)', file.read_text(), re.M):
                pins[name] = version
        actual = {}
        for name in pins:
            try: actual[name] = importlib.metadata.version(name)
            except importlib.metadata.PackageNotFoundError: actual[name] = None
        print(json.dumps({'python': f'{sys.version_info.major}.{sys.version_info.minor}',
                          'pins': pins, 'installed': actual, 'pins_match': pins == actual,
                          'runtime': deps.runtime_report()}))
        """, root.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = python.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        let exit = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exit.signal() }
        try process.run()
        if exit.wait(timeout: .now() + 60) == .timedOut {
            process.terminate()
            if exit.wait(timeout: .now() + 5) == .timedOut { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            XCTFail("Installed-runtime inspection timed out")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: data, as: UTF8.self))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testFirstLaunchWalksEveryStepAndPersistsCompletion() throws {
        let configURL = URL(fileURLWithPath: configPath)
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["mlx_agent_path": configURL.deletingLastPathComponent().appendingPathComponent("missing-engine").path])
            .write(to: configURL)
        launch(firstRun: true, python: "/usr/bin/false")

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 30), "Setup assistant did not appear on first launch")
        XCTAssertTrue(sheet.staticTexts["Connect mlx-agent"].exists)
        capture("01-step-agent")

        // Every middle step is reachable and navigable both ways.
        sheet.buttons["Continue"].click()
        XCTAssertTrue(sheet.staticTexts["Python runtime"].waitForExistence(timeout: 15))
        capture("02-step-runtime")
        sheet.buttons["Back"].click()
        XCTAssertTrue(sheet.staticTexts["Connect mlx-agent"].waitForExistence(timeout: 15))
        sheet.buttons["Continue"].click()
        sheet.buttons["Continue"].click()
        XCTAssertTrue(sheet.staticTexts["Choose model roots"].waitForExistence(timeout: 15))
        capture("03-step-roots")
        sheet.buttons["Continue"].click()
        XCTAssertTrue(sheet.staticTexts["Review setup"].waitForExistence(timeout: 15))
        XCTAssertTrue(sheet.staticTexts["Setup needs attention"].exists)
        XCTAssertFalse(sheet.buttons["Scan my library"].exists)
        capture("04-step-done")

        sheet.buttons["Review engine"].click()
        XCTAssertTrue(sheet.staticTexts["Connect mlx-agent"].waitForExistence(timeout: 15))
        for _ in 0..<3 { sheet.buttons["Continue"].click() }
        XCTAssertTrue(sheet.staticTexts["Review setup"].waitForExistence(timeout: 15))
        sheet.buttons["Review runtime"].click()
        XCTAssertTrue(sheet.staticTexts["Python runtime"].waitForExistence(timeout: 15))
        for _ in 0..<2 { sheet.buttons["Continue"].click() }
        sheet.buttons["Finish for now"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 15), "Assistant did not dismiss after finishing")
        capture("05-after-finish")

        // Completion persists: a relaunch without the first-run override
        // must not re-present the assistant.
        app.terminate()
        launch(firstRun: false, python: "/usr/bin/false")
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 15),
                      "Assistant re-appeared after completion")
    }

    func testSkipDismissesWithoutPersisting() throws {
        launch(firstRun: true)

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 30))
        capture("06-skip-before")
        sheet.buttons["Skip setup"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 15))

        app.terminate()
        launch(firstRun: true)
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 30),
                      "Assistant did not return after being skipped")
        capture("07-skip-returned")
    }

    func testLibraryModelInspectionAndDeletionReviewDoNotMutateTheModel() throws {
        let screen = try XCTUnwrap(NSScreen.main).frame
        let root = URL(fileURLWithPath: configPath).deletingLastPathComponent()
        let model = root.appendingPathComponent("models/Qwen3-4B-4bit")
        let script = root.appendingPathComponent("agent/scripts/mlx-agent")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"quantization\":{\"bits\":4}}".utf8).write(to: model.appendingPathComponent("config.json"))
        try Data("fixture weights".utf8).write(to: model.appendingPathComponent("model.safetensors"))
        let scan: [String: Any] = ["models": [], "outputs": [["path": model.path, "name": "Qwen3-4B-4bit", "model_key": "qwen3-4b", "quantization": ["bits": 4]]], "pending": [], "duplicates": [], "totals": ["gguf": 0, "pending": 0, "converted": 1, "unreadable": 0, "bytes": 14, "reclaimable_bytes": 0]]
        try JSONSerialization.data(withJSONObject: scan).write(to: root.appendingPathComponent("scan.json"))
        let python = """
        import json, pathlib, sys
        root = pathlib.Path(__file__).resolve().parents[2]
        if sys.argv[1:3] == ['convert', 'scan']:
            data = json.loads((root / 'scan.json').read_text())
        else:
            data = {'servers': [], 'jobs': [], 'changes': []}
        print(json.dumps({'status': 'ok', 'data': data}))
        """
        try python.write(to: script, atomically: true, encoding: .utf8)
        let config: [String: Any] = ["mlx_agent_path": root.appendingPathComponent("agent").path, "mlx_roots": [model.deletingLastPathComponent().path], "gguf_roots": [], "output_dir": root.appendingPathComponent("output").path, "verification_enabled": false, "watch_enabled": false]
        try JSONSerialization.data(withJSONObject: config).write(to: URL(fileURLWithPath: configPath))
        defer { app?.terminate(); try? FileManager.default.removeItem(at: root) }
        app = XCUIApplication()
        app.launchEnvironment["MLX_WORKBENCH_CONFIG"] = configPath
        app.launchEnvironment["CFFIXED_USER_HOME"] = root.path
        app.launchEnvironment["XDG_STATE_HOME"] = root.appendingPathComponent("state").path
        app.launchEnvironment["MLX_WORKBENCH_PYTHON"] = "/usr/bin/python3"
        app.launchArguments = ["-mlx-workbench.setupCompleted.v1", "YES", "-library.groupMode", "family"]
        app.launch(); app.activate()
        let library = app.buttons["Library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 45))
        library.click()
        let modelRow = app.outlines.staticTexts["Qwen3-4B-4bit"].firstMatch
        XCTAssertTrue(modelRow.waitForExistence(timeout: 45))
        capture("08-library-startup-inspector")
        assertLibraryNavigationVisible()
        if screen.width < 1100 {
            let sidebar = app.outlines["Workbench navigation"]
            sidebar.scroll(byDeltaX: 0, deltaY: -300)
            let settings = app.buttons["Settings"]
            let window = app.windows.firstMatch
            XCTAssertTrue(window.frame.contains(settings.frame))
            XCTAssertTrue(settings.isHittable)
            window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                dx: settings.frame.midX - window.frame.minX, dy: settings.frame.midY - window.frame.minY
            )).click()
            XCTAssertTrue(app.staticTexts["page-heading-settings"].waitForExistence(timeout: 10))
            capture("08a-library-small-desktop-settings")
            sidebar.scroll(byDeltaX: 0, deltaY: 300)
            library.click()
            XCTAssertTrue(app.staticTexts["page-heading-models"].waitForExistence(timeout: 10))
        }
        library.click()
        XCTAssertTrue(app.buttons["Settings"].exists)
        XCTAssertTrue(app.buttons["Discover"].exists)
        let sourcePicker = app.popUpButtons["library-source"].firstMatch
        let heading = app.staticTexts["page-heading-models"]
        XCTAssertTrue(sourcePicker.exists)
        XCTAssertTrue(heading.exists)
        XCTAssertTrue(sourcePicker.isHittable)
        XCTAssertEqual(sourcePicker.value as? String, "All local models")
        XCTAssertTrue(heading.isHittable)
        XCTAssertGreaterThanOrEqual(sourcePicker.frame.minY, app.windows.firstMatch.frame.minY)
        XCTAssertLessThanOrEqual(sourcePicker.frame.maxY, heading.frame.minY)
        capture("08-library-visible-model-and-sidebar")
        modelRow.doubleClick()
        let memoryFit = app.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", "Memory fit: ")).firstMatch
        XCTAssertTrue(memoryFit.waitForExistence(timeout: 10))
        capture("08b-library-inspector-after-selection")
        if screen.width < 1100 {
            let details = app.sheets.firstMatch
            XCTAssertTrue(details.waitForExistence(timeout: 10))
            XCTAssertTrue(details.buttons["Done"].isHittable)
            details.buttons["Done"].click()
            XCTAssertTrue(details.waitForNonExistence(timeout: 10))
        } else {
            assertLibraryNavigationVisible()
            app.buttons["Inspector"].click()
            XCTAssertTrue(app.buttons["Run model"].waitForNonExistence(timeout: 10))
            let window = app.windows.firstMatch
            let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
                .withOffset(CGVector(dx: -2, dy: -2))
            corner.press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: 1118, dy: 718)))
            XCTAssertEqual(window.frame.width, 1120, accuracy: 2)
            modelRow.doubleClick()
            XCTAssertTrue(app.buttons["Run model"].waitForExistence(timeout: 10))
            capture("08c-library-inspector-at-1120")
        }
        assertLibraryNavigationVisible()
        modelRow.rightClick()
        let delete = app.menuItems["Delete…"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        capture("09-library-delete-context-menu")
        delete.click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 30))
        capture("10-library-delete-review")
        let reviewedPath = sheet.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", model.path, model.path)).firstMatch
        XCTAssertTrue(reviewedPath.waitForExistence(timeout: 5), sheet.debugDescription)
        XCTAssertTrue(sheet.buttons["Move to Trash"].exists)
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.path))

        let window = app.windows.firstMatch
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        let target = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 738, dy: 558))
        corner.press(forDuration: 0.1, thenDragTo: target)
        XCTAssertEqual(window.frame.width, 740, accuracy: 2)
        XCTAssertFalse(app.sheets.firstMatch.exists)
        XCTAssertTrue(app.buttons["Run model"].waitForNonExistence(timeout: 10),
                      "The wide inspector must close before opening compact model details.")
        capture("10b-library-compact-content")
        print("Compact Library bounds: window=\(window.frame), source=\(sourcePicker.frame), heading=\(heading.frame)")
        XCTAssertTrue(sourcePicker.isHittable, app.debugDescription)
        XCTAssertEqual(sourcePicker.value as? String, "All local models")
        XCTAssertTrue(heading.isHittable)
        XCTAssertGreaterThanOrEqual(sourcePicker.frame.minY, app.windows.firstMatch.frame.minY)
        XCTAssertLessThanOrEqual(sourcePicker.frame.maxY, heading.frame.minY)
        app.typeKey("i", modifierFlags: [.command, .option])
        let details = app.sheets.firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 10))
        XCTAssertTrue(details.buttons["Done"].isHittable)
        XCTAssertGreaterThanOrEqual(details.frame.minX, window.frame.minX)
        XCTAssertLessThanOrEqual(details.frame.maxX, window.frame.maxX)
        capture("11-library-compact-inspector")
        details.buttons["Done"].click()
        XCTAssertTrue(details.waitForNonExistence(timeout: 10))
        XCTAssertTrue(modelRow.isHittable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.path))
    }

    private func assertLibraryNavigationVisible(file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch
        guard let screen = NSScreen.main?.frame else { XCTFail("The guest screen is unavailable.", file: file, line: line); return }
        print("Library inspector bounds: window=\(window.frame), screen=\(screen)")
        XCTAssertGreaterThanOrEqual(window.frame.minX, screen.minX, file: file, line: line)
        XCTAssertLessThanOrEqual(window.frame.maxX, screen.maxX, file: file, line: line)
        for name in ["Library", "Prepare", "Run"] {
            let button = app.buttons[name].firstMatch
            XCTAssertTrue(button.exists, name, file: file, line: line)
            XCTAssertTrue(window.frame.contains(button.frame), "\(name) lies outside the window: \(button.frame)", file: file, line: line)
            XCTAssertTrue(button.isHittable, name, file: file, line: line)
        }
    }
}
