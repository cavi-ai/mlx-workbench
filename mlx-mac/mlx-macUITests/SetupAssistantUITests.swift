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
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workbench-review-\(UUID().uuidString)")
        let script = root.appendingPathComponent("agent/scripts/mlx-agent")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("models"), withIntermediateDirectories: true)
        let python = """
        import hashlib, json, os, pathlib, sys, time
        root = pathlib.Path(__file__).resolve().parents[2]
        args = sys.argv[1:]
        with (root / 'calls.jsonl').open('a') as f:
            f.write(json.dumps(args) + '\\n')
        if args[:2] == ['convert', 'scan']:
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
        elif args and args[0] == 'doctor':
            time.sleep(0.5)
            if (root / 'fail-doctor').exists():
                print('Fixture doctor failed: inventory unavailable.', file=sys.stderr)
                sys.exit(2)
            data = {'findings': [], 'prune_count': 0}
        elif args and args[0] == 'discover':
            time.sleep(0.5)
            if (root / 'fail-discover').exists():
                print('Fixture discovery failed: catalog unavailable.', file=sys.stderr)
                sys.exit(2)
            data = {'candidates': []}
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
            let scroll = app.scrollViews.containing(.button, identifier: "Refresh backends").firstMatch
            for _ in 0..<8 where !element.isHittable {
                scroll.scroll(byDeltaX: 0, deltaY: element.frame.midY < scroll.frame.minY ? 300 : -300)
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
        launch(appearance: "Light")
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
        selectRadioOption("LM Studio", in: "library-source")
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
        try FileManager.default.removeItem(at: url)
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
            XCTAssertTrue(open.waitForExistence(timeout: 15)); open.click()
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
            preview.click()
            if !before {
                XCTAssertTrue(app.descendants(matching: .any)["manual-wire-progress"].waitForExistence(timeout: 5))
                XCTAssertFalse(preview.isEnabled)
                capture("ManualWire-\(appearance)-previewing")
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
        XCTAssertEqual(app.radioGroups["library-source"].radioButtons["LM Studio"].value as? Int, 1)
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
        launch(python: "/usr/bin/false")
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 30))
        sheet.buttons["Continue"].click()
        let status = sheet.staticTexts["runtime-prerequisites-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        let install = sheet.buttons["runtime-install-start"]
        XCTAssertTrue(install.exists)
        XCTAssertEqual(install.isEnabled, status.label == "Prerequisites found")
        let recheck = sheet.buttons["runtime-prerequisites-recheck"]
        XCTAssertTrue(recheck.isEnabled)
        recheck.click()
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        XCTAssertFalse(sheet.buttons["runtime-install-cancel"].exists)
        capture("Runtime-prerequisites-before-confirmation")
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
        let sourcePicker = app.radioGroups["library-source"]
        let heading = app.staticTexts["page-heading-models"]
        XCTAssertTrue(sourcePicker.exists)
        XCTAssertTrue(heading.exists)
        XCTAssertTrue(sourcePicker.radioButtons["All models"].isHittable)
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
        XCTAssertTrue(sourcePicker.radioButtons["All models"].isHittable, app.debugDescription)
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
