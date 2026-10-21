import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import mlx_workbench

extension ComparisonMediaTests {
    func testReuseSavedInputsAfterOriginalChangesOrDisappears() throws {
        let store = ComparisonOutputStore(root: root.appendingPathComponent("saved-reuse"))
        for mode in [ComparisonMode.vision, .videoUnderstanding, .speechToText] {
            var run = historyRun(mode, "Saved inputs", at: 100)
            let original = root.appendingPathComponent("original-\(mode.rawValue).png")
            try Data("changed original".utf8).write(to: original)
            try store.createRunDirectory(run.id)
            let saved = store.inputsDirectory(run.id).appendingPathComponent("saved.png")
            try Data("recorded input".utf8).write(to: saved)
            run.promptEntries = [PromptEntry(id: "p", text: "Recorded text", inputKind: mode.inputKind,
                inputPath: original.path, expectedKeywords: ["recorded"])]
            run.inputArtifacts = ["p": "saved.png"]
            let history = run
            for removeOriginal in [false, true] {
                if removeOriginal { try FileManager.default.removeItem(at: original) }
                let setup = try ComparisonRunSetup(run: run, outputStore: store)
                XCTAssertTrue(setup.draft.prompts[0].usesSavedInput)
                XCTAssertFalse(setup.draft.prompts[0].inputFileUnavailable)
                XCTAssertEqual(setup.draft.prompts[0].inputPreviewURL, saved)
                let set = try setup.draft.promptSet()
                XCTAssertEqual(set.prompts[0].inputPath, saved.path)
                XCTAssertEqual(try Data(contentsOf: saved), Data("recorded input".utf8))
                XCTAssertEqual(try setup.savedDraft(named: "Copy").promptSet().prompts, set.prompts)
                XCTAssertEqual(run, history)
            }
        }
    }

    func testRevertInputPreservesOtherEditsAndRestoresOpenedSourceInEveryInputMode() throws {
        for mode in [ComparisonMode.vision, .videoUnderstanding, .speechToText] {
            let file = root.appendingPathComponent("\(mode.rawValue)-source.bin")
            let bytes = Data("source input".utf8)
            try bytes.write(to: file)
            for entry in [
                PromptEntry(id: "empty", text: "Original prompt", inputKind: mode.inputKind),
                PromptEntry(id: "builtin", text: "Original prompt", inputKind: mode.inputKind, builtinInput: "fixture"),
                PromptEntry(id: "saved", text: "Original prompt", inputKind: mode.inputKind, inputPath: file.path)
            ] {
                var prompt = PromptSetDraft.Prompt(entry, mode: mode, savedInput: entry.id == "saved")
                XCTAssertFalse(prompt.hasInputChanges)
                prompt.text = "Edited text"; prompt.keywords = "red|blue"; prompt.maxTokens = "invalid typed value"
                for replacement in ["/replacement", "relative path", " \n "] {
                    prompt.inputPath = replacement
                    XCTAssertTrue(prompt.hasInputChanges)
                    var expected = prompt; expected.inputPath = entry.inputPath ?? ""
                    prompt.revertInput()
                    XCTAssertEqual(prompt, expected, "Only the input choice may revert")
                    XCTAssertFalse(prompt.hasInputChanges)
                    XCTAssertEqual(prompt.builtinInput, entry.builtinInput)
                    XCTAssertEqual(prompt.usesSavedInput, entry.id == "saved")
                }
            }
            XCTAssertEqual(try Data(contentsOf: file), bytes, "Revert must not mutate input files")
            var missing = PromptSetDraft.Prompt(
                PromptEntry(id: "missing", text: "Describe this", inputKind: mode.inputKind, inputPath: file.path),
                mode: mode, savedInput: true)
            try FileManager.default.removeItem(at: file)
            missing.inputPath = "/replacement"; missing.revertInput()
            XCTAssertTrue(missing.usesSavedInput)
            XCTAssertTrue(missing.inputFileUnavailable, "Missing opened inputs must remain unavailable")
            XCTAssertNil(missing.inputPreviewURL)
            XCTAssertThrowsError(try missing.entry(for: mode), "The save boundary must refuse unavailable inputs")
        }
    }

    @MainActor
    func testRevertInputButtonRestoresBuiltinWithoutSavingOrChangingFiles() async throws {
        func buttons(in view: NSView) -> [NSButton] {
            if let button = view as? NSButton { return [button] }
            return view.subviews.flatMap { buttons(in: $0) }
        }
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
        }
        let entry = PromptEntry(id: "p", text: "Describe the circle", inputKind: .image, builtinInput: "red-circle")
        let replacement = try await ComparisonMediaFixtures.generateInput(for: entry, into: root)
        let bytes = try Data(contentsOf: replacement)
        let set = PromptSet(id: "vision-revert", name: "Vision", useCase: nil,
            prompts: [entry], origin: .userCreated, mode: .vision)
        var draft = try PromptSetDraft(set: set)
        draft.prompts[0].inputPath = replacement.path
        draft.prompts[0].text = "Edited question"; draft.prompts[0].maxTokens = "128"
        let editor = ComparisonPromptSetEditor(draft: draft) { _ in
            XCTFail("Reverting input must not save"); return nil
        }.background(WorkbenchColor.canvas).preferredColorScheme(.dark)
        let host = NSHostingView(rootView: editor)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 620),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(scrollViews(in: host).max {
            ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0)
        })
        // AppKit titles are empty. This single card exposes its menu, minus
        // control and then Revert input as native buttons in content order.
        XCTAssertEqual(buttons(in: scroll).count, 3)
        let revert = try XCTUnwrap(buttons(in: scroll).last)
        for state in ["replaced", "reverted"] {
            if state == "reverted" {
                revert.performClick(nil)
                try await Task.sleep(for: .milliseconds(200))
                XCTAssertEqual(buttons(in: scroll).count, 2, "Only Revert input disappears after restoring the opened input")
            }
            host.layoutSubtreeIfNeeded(); window.setContentSize(host.fittingSize); host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "Vision input \(state)"; attachment.lifetime = .keepAlways; add(attachment)
            if let directory = ProcessInfo.processInfo.environment["MLX_INPUT_REVERT_PROOF_DIR"] {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(state).png"))
            }
        }
        XCTAssertEqual(try Data(contentsOf: replacement), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("sets.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("runs.json").path))
    }

    func testReuseMissingSavedInputsNeverFallsBackAndAcceptsExplicitReplacement() throws {
        let store = ComparisonOutputStore(root: root.appendingPathComponent("missing-reuse"))
        var run = historyRun(.vision, "Saved inputs", at: 100)
        let original = root.appendingPathComponent("available-original.png")
        try Data("current file".utf8).write(to: original)
        run.promptEntries = [PromptEntry(id: "p", text: "Describe", inputKind: .image,
            inputPath: original.path, builtinInput: "red-circle")]
        try store.createRunDirectory(run.id)
        let link = store.inputsDirectory(run.id).appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        for artifacts in [[String: String](), ["p": "missing.png"], ["p": "../available-original.png"], ["p": "link.png"]] {
            run.inputArtifacts = artifacts
            var setup = try ComparisonRunSetup(run: run, outputStore: store)
            XCTAssertTrue(setup.draft.prompts[0].usesSavedInput)
            XCTAssertTrue(setup.draft.prompts[0].inputFileUnavailable)
            XCTAssertNil(setup.draft.prompts[0].inputPreviewURL)
            XCTAssertNil(setup.draft.prompts[0].builtinInput)
            XCTAssertThrowsError(try setup.draft.promptSet())
            XCTAssertThrowsError(try setup.savedDraft(named: "Copy").promptSet())
            setup.draft.prompts[0].inputPath = original.path
            XCTAssertFalse(setup.draft.prompts[0].usesSavedInput)
            XCTAssertEqual(try setup.draft.promptSet().prompts[0].inputPath, original.path)
            XCTAssertNil(try setup.draft.promptSet().prompts[0].builtinInput)
            setup.draft.prompts[0].inputPath = link.path
            XCTAssertThrowsError(try setup.draft.promptSet(), "A replacement symbolic link cannot be snapshotted")
        }
    }

    @MainActor
    func testReuseOldestRetainedInputCopiesBeforePruningAndPreservesSpeechLanguage() async throws {
        let store = ComparisonOutputStore(root: root.appendingPathComponent("retained-reuse"))
        var run = historyRun(.speechToText, "Recorded speech", at: 100)
        let entry = ComparisonMediaFixtures.speechToTextSet.prompts[0]
        run.promptEntries = [entry]
        try store.createRunDirectory(run.id)
        let saved = store.inputsDirectory(run.id).appendingPathComponent("saved.wav")
        let contents = Data("saved speech fixture".utf8)
        try contents.write(to: saved)
        run.inputArtifacts = [entry.id: "saved.wav"]
        var history = [run]
        for index in 1..<ComparisonOutputStore.retainedRuns {
            let newer = historyRun(.speechToText, "Newer \(index)", at: 100 + Double(index))
            try store.createRunDirectory(newer.id)
            history.append(newer)
        }
        try JSONStore<ComparisonRun>(fileURL: root.appendingPathComponent("runs.json")).replaceAll(history)
        let runner = StubMediaRunner()
        let coordinator = makeCoordinator(runner: runner, store: store)
        let setup = try ComparisonRunSetup(run: run, outputStore: store)
        let set = try setup.draft.promptSet()
        XCTAssertEqual(set.prompts[0].inputPath, saved.path)
        coordinator.start(variants: [("/speech/a", "current")], promptSet: set)
        await waitForRun(coordinator)
        let requests = await runner.requests
        let request = try XCTUnwrap(requests.first)
        let input = try XCTUnwrap(request.inputURL)
        XCTAssertNotEqual(input, saved)
        XCTAssertEqual(try Data(contentsOf: input), contents)
        XCTAssertEqual(request.language, SpeechCanary.language)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.runDirectory(run.id).path))
        XCTAssertEqual(coordinator.runs.first { $0.id == run.id }, run)
        let next = try XCTUnwrap(coordinator.runs.first)
        XCTAssertEqual(next.state, .completed)
        XCTAssertNotNil(next.inputArtifacts?[entry.id])
        let directories = try FileManager.default.contentsOfDirectory(atPath: store.root.path)
        XCTAssertEqual(directories.count, ComparisonOutputStore.retainedRuns)
    }

    @MainActor
    func testReuseSheetLabelsSavedAndPrunedInputs() async throws {
        let store = ComparisonOutputStore(root: root.appendingPathComponent("reuse-proof"))
        var run = historyRun(.vision, "Bird descriptions · fixture", at: 100, models: ["/vision/a"])
        try store.createRunDirectory(run.id)
        let saved = store.inputsDirectory(run.id).appendingPathComponent("bird.png")
        try Data("input fixture".utf8).write(to: saved)
        run.promptEntries = [PromptEntry(id: "p", text: "Describe the bird and its surroundings", inputKind: .image,
            inputPath: root.appendingPathComponent("gone.png").path, expectedKeywords: ["bird", "snow"])]
        run.inputArtifacts = ["p": "bird.png"]
        for label in ["saved", "pruned"] {
            if label == "pruned" { try FileManager.default.removeItem(at: saved) }
            let sheet = ComparisonRunSetupSheet(setup: try ComparisonRunSetup(run: run, outputStore: store),
                availablePaths: ["/vision/a"], name: { _ in "Vision model · fixture" },
                onApply: { _, _ in XCTFail("Rendering must not apply or run"); return nil },
                onSave: { _ in XCTFail("Rendering must not save"); return nil })
            let host = NSHostingView(rootView: sheet.background(WorkbenchColor.canvas).preferredColorScheme(.dark))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 720),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "Reuse \(label) input"; attachment.lifetime = .keepAlways; add(attachment)
            if let directory = ProcessInfo.processInfo.environment["MLX_REUSE_SETUP_PROOF_DIR"] {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("reuse-input-\(label).png"))
            }
            window.close()
        }
    }

    @MainActor
    func testSavedReusedPromptSetOwnsInputsAfterRunCachePruningAndRestart() async throws {
        let outputs = ComparisonOutputStore(root: root.appendingPathComponent("cache"))
        var history = historyRun(.speechToText, "Saved speech", at: 100)
        try outputs.createRunDirectory(history.id)
        let source = outputs.inputsDirectory(history.id).appendingPathComponent("speech.wav")
        let bytes = Data("recorded speech".utf8)
        try bytes.write(to: source)
        var entry = ComparisonMediaFixtures.speechToTextSet.prompts[0]
        entry.inputPath = root.appendingPathComponent("original-gone.wav").path
        history.promptEntries = [entry]; history.inputArtifacts = [entry.id: source.lastPathComponent]
        let runs = JSONStore<ComparisonRun>(fileURL: root.appendingPathComponent("runs.json"))
        try runs.replaceAll([history])
        let historyBytes = try Data(contentsOf: runs.url)
        let runner = StubMediaRunner()
        let coordinator = makeCoordinator(runner: runner, store: outputs)
        let setup = try ComparisonRunSetup(run: history, outputStore: outputs)
        let result = await coordinator.createPromptSet(setup.savedDraft(named: "Durable speech"))
        let saved = try XCTUnwrap(result)
        let owned = URL(fileURLWithPath: try XCTUnwrap(saved.prompts[0].inputPath))
        XCTAssertNotNil(saved.inputStorageID)
        XCTAssertNotEqual(owned, source)
        XCTAssertEqual(try Data(contentsOf: owned), bytes)
        XCTAssertEqual(try Data(contentsOf: runs.url), historyBytes)
        XCTAssertFalse(coordinator.savingPromptSet)
        XCTAssertNil(coordinator.activeRunID)
        let requestsBefore = await runner.requests
        XCTAssertTrue(requestsBefore.isEmpty)
        outputs.prune(keeping: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: owned), bytes)
        let restarted = makeCoordinator(runner: runner, store: outputs)
        let restored = try XCTUnwrap(restarted.promptSets.first { $0.id == saved.id })
        XCTAssertEqual(restored, saved)
        restarted.start(variants: [("/speech/model", "current")], promptSet: restored)
        await waitForRun(restarted)
        let requests = await runner.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(request.inputURL)), bytes)
        XCTAssertEqual(request.language, SpeechCanary.language)
        XCTAssertEqual(restarted.runs.first?.state, .completed)
        XCTAssertEqual(restarted.runs.first { $0.id == history.id }, history)
    }

    @MainActor
    func testOwnedInputSaveRollsBackPartialCopiesAndFailedJSONThenRetries() async throws {
        let source = root.appendingPathComponent("original.png")
        try Data("original image".utf8).write(to: source)
        var draft = PromptSetDraft(mode: .vision)
        draft.name = "Saved images"; draft.prompts[0].text = "Describe"; draft.prompts[0].inputPath = source.path
        draft.addPrompt(); draft.prompts[1].text = "Describe again"; draft.prompts[1].inputPath = source.path
        let coordinator = makeCoordinator(runner: StubMediaRunner())
        let sets = root.appendingPathComponent("sets.json")
        let corrupt = Data("broken-json".utf8)
        try corrupt.write(to: sets)
        let failed = await coordinator.createPromptSet(draft)
        XCTAssertNil(failed)
        XCTAssertFalse(coordinator.promptSets.contains { $0.id == draft.id })
        XCTAssertEqual(try Data(contentsOf: sets), corrupt)
        let ownedRoot = root.appendingPathComponent("prompt-set-inputs")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: ownedRoot.path).isEmpty)
        XCTAssertFalse(coordinator.savingPromptSet)
        try JSONStore<PromptSet>(fileURL: sets).replaceAll([])
        let retried = await coordinator.createPromptSet(draft)
        let saved = try XCTUnwrap(retried)
        XCTAssertEqual(Set(saved.prompts.compactMap(\.inputPath)).count, 2)
        for entry in saved.prompts {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(entry.inputPath))), try Data(contentsOf: source))
        }
        let setBytes = try Data(contentsOf: sets)
        let idsBefore = try FileManager.default.contentsOfDirectory(atPath: ownedRoot.path)
        var bad = draft
        bad.name = "Unavailable"; bad.prompts[1].inputPath = root.appendingPathComponent("gone.png").path
        // The normal draft validates paths before copying; exercise a source disappearing
        // during the copy transaction through the storage boundary as well.
        let badSet = PromptSet(id: UUID().uuidString, name: "Partial", prompts: [
            PromptEntry(id: "a", text: "First", inputKind: .image, inputPath: source.path),
            PromptEntry(id: "b", text: "Second", inputKind: .image, inputPath: bad.prompts[1].inputPath)
        ], origin: .userCreated, mode: .vision)
        do { _ = try await ComparisonPromptInputStore(root: ownedRoot).copyingInputs(in: badSet); XCTFail("Missing second input must fail") }
        catch { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: ownedRoot.path), idsBefore)
        XCTAssertEqual(try Data(contentsOf: sets), setBytes)
        XCTAssertEqual(try Data(contentsOf: source), Data("original image".utf8))
    }

    @MainActor
    func testRemovingOwnedPromptInputsPreservesBorrowedReferencesAndOtherFolders() async throws {
        let source = root.appendingPathComponent("source.png")
        try Data("original".utf8).write(to: source)
        var draft = PromptSetDraft(mode: .vision)
        draft.name = "Owner"; draft.prompts[0].text = "Describe"; draft.prompts[0].inputPath = source.path
        let creator = makeCoordinator(runner: StubMediaRunner())
        let result = await creator.createPromptSet(draft)
        let owner = try XCTUnwrap(result)
        let path = try XCTUnwrap(owner.prompts.first?.inputPath)
        let borrowed = PromptSet(id: UUID().uuidString, name: "Borrowed", prompts: owner.prompts, origin: .userCreated, mode: .vision)
        let coordinator = try makeCoordinator(runner: StubMediaRunner(), saved: [borrowed])
        let inputStore = ComparisonPromptInputStore(root: root.appendingPathComponent("prompt-set-inputs"))
        let unrelated = inputStore.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        try Data("unrelated staged work".utf8).write(to: unrelated.appendingPathComponent("keep.txt"))
        let sets = root.appendingPathComponent("sets.json")
        let oldBytes = try Data(contentsOf: sets)
        try Data("corrupt".utf8).write(to: sets)
        try await assertAsyncFalse(await coordinator.removePromptSet(id: owner.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        try oldBytes.write(to: sets)
        try await assertAsyncTrue(await coordinator.removePromptSet(id: owner.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "Another durable set still references this copy")
        try await assertAsyncTrue(await coordinator.removePromptSet(id: borrowed.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.appendingPathComponent("keep.txt").path))
    }

    func testOwnedInputStoreRejectsSymlinksAndLegacySetsDecodeWithoutOwnership() async throws {
        let original = root.appendingPathComponent("original.png")
        try Data("original".utf8).write(to: original)
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let ownedRoot = root.appendingPathComponent("owned")
        try FileManager.default.createSymbolicLink(at: ownedRoot, withDestinationURL: outside)
        let set = PromptSet(id: UUID().uuidString, name: "Legacy", prompts: [
            PromptEntry(id: "p", text: "Describe", inputKind: .image, inputPath: original.path)
        ], origin: .userCreated, mode: .vision)
        do { _ = try await ComparisonPromptInputStore(root: ownedRoot).copyingInputs(in: set); XCTFail("Linked store must fail") }
        catch { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        try FileManager.default.removeItem(at: ownedRoot)
        let link = root.appendingPathComponent("linked-input.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        var linked = set; linked.prompts[0].inputPath = link.path
        do { _ = try await ComparisonPromptInputStore(root: ownedRoot).copyingInputs(in: linked); XCTFail("Linked input must fail") }
        catch { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: ownedRoot.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(set)) as? [String: Any])
        json.removeValue(forKey: "inputStorageID")
        let legacy = try JSONDecoder().decode(PromptSet.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy, set)
        XCTAssertNil(legacy.inputStorageID)
    }

    @MainActor
    func testNewMediaPromptSetsKeepTheirOwnInputsWhenOriginalsDisappear() async throws {
        let runner = StubMediaRunner(), coordinator = makeCoordinator(runner: runner)
        for mode in [ComparisonMode.vision, .videoUnderstanding, .speechToText] {
            let original = root.appendingPathComponent("original-\(mode.rawValue).input")
            let bytes = Data("original \(mode.rawValue)".utf8)
            try bytes.write(to: original)
            var draft = PromptSetDraft(mode: mode)
            draft.name = "New \(mode.title)"; draft.prompts[0].text = "Recorded reference"
            draft.prompts[0].inputPath = original.path
            let result = await coordinator.createPromptSet(draft)
            let set = try XCTUnwrap(result)
            let path = try XCTUnwrap(set.prompts.first?.inputPath)
            XCTAssertNotEqual(path, original.path)
            try FileManager.default.removeItem(at: original)
            let restarted = makeCoordinator(runner: runner)
            let edit = try XCTUnwrap(restarted.preparePromptSetEdit(id: set.id))
            XCTAssertFalse(edit.prompts[0].inputFileUnavailable)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
            restarted.start(variants: [("/model", nil)], promptSet: try edit.promptSet())
            await waitForRun(restarted)
            XCTAssertEqual(restarted.runs.first?.state, .completed)
            let requests = await runner.requests
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(requests.last?.inputURL)), bytes)
        }
    }

    @MainActor
    func testOwnedPromptEditsReuseUnchangedFilesAndCopyOnlyReplacements() async throws {
        let first = root.appendingPathComponent("first.png"), second = root.appendingPathComponent("second.png")
        try Data("first".utf8).write(to: first); try Data("second".utf8).write(to: second)
        var draft = PromptSetDraft(mode: .vision)
        draft.name = "Images"; draft.prompts[0].text = "First"; draft.prompts[0].inputPath = first.path
        draft.addPrompt(); draft.prompts[1].text = "Second"; draft.prompts[1].inputPath = second.path
        let coordinator = makeCoordinator(runner: StubMediaRunner())
        let result = await coordinator.createPromptSet(draft)
        let original = try XCTUnwrap(result)
        let store = ComparisonOutputStore(root: root.appendingPathComponent("prompt-set-inputs"))
        let originalID = try XCTUnwrap(original.inputStorageID)
        let before = try FileManager.default.contentsOfDirectory(atPath: store.inputsDirectory(originalID).path)
        var edit = try XCTUnwrap(coordinator.preparePromptSetEdit(id: original.id))
        edit.prompts[0].text = "Changed question"; edit.prompts[0].maxTokens = "512"
        let textSaved = await coordinator.savePromptSetEdits(edit)
        XCTAssertTrue(textSaved)
        let textOnly = try XCTUnwrap(coordinator.promptSets.first { $0.id == original.id })
        XCTAssertEqual(textOnly.inputStorageID, originalID)
        XCTAssertEqual(textOnly.prompts.map(\.inputPath), original.prompts.map(\.inputPath))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.inputsDirectory(originalID).path), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.root.path), [originalID.uuidString])
        let replacement = root.appendingPathComponent("replacement.png")
        try Data("replacement".utf8).write(to: replacement)
        edit = try XCTUnwrap(coordinator.preparePromptSetEdit(id: original.id))
        edit.prompts[0].inputPath = replacement.path
        let replaced = await coordinator.savePromptSetEdits(edit)
        XCTAssertTrue(replaced)
        let updated = try XCTUnwrap(coordinator.promptSets.first { $0.id == original.id })
        let newID = try XCTUnwrap(updated.inputStorageID)
        XCTAssertNotEqual(newID, originalID)
        XCTAssertEqual(updated.prompts[1].inputPath, original.prompts[1].inputPath)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.inputsDirectory(newID).path).count, 1)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(updated.prompts[0].inputPath))), Data("replacement".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.runDirectory(originalID).path), "The second prompt still owns its old input")
        edit = try XCTUnwrap(coordinator.preparePromptSetEdit(id: original.id))
        edit.removePrompt(id: edit.prompts[1].id)
        let removedPrompt = await coordinator.savePromptSetEdits(edit)
        XCTAssertTrue(removedPrompt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.runDirectory(originalID).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.runDirectory(newID).path))
        XCTAssertEqual(try Data(contentsOf: first), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("second".utf8))
        XCTAssertEqual(try Data(contentsOf: replacement), Data("replacement".utf8))
    }

    @MainActor
    func testOwnedPromptEditConflictAndCorruptStoreRollbackOnlyNewFiles() async throws {
        let source = root.appendingPathComponent("source.png"), replacement = root.appendingPathComponent("replacement.png")
        try Data("source".utf8).write(to: source); try Data("replacement".utf8).write(to: replacement)
        var draft = PromptSetDraft(mode: .vision)
        draft.name = "Images"; draft.prompts[0].text = "Describe"; draft.prompts[0].inputPath = source.path
        let coordinator = makeCoordinator(runner: StubMediaRunner())
        let result = await coordinator.createPromptSet(draft)
        let saved = try XCTUnwrap(result)
        let store = JSONStore<PromptSet>(fileURL: root.appendingPathComponent("sets.json"))
        let ownedRoot = root.appendingPathComponent("prompt-set-inputs")
        let folders = try FileManager.default.contentsOfDirectory(atPath: ownedRoot.path)
        var edit = try XCTUnwrap(coordinator.preparePromptSetEdit(id: saved.id))
        edit.prompts[0].inputPath = replacement.path
        var concurrent = saved; concurrent.prompts[0].text = "Another editor changed this"
        try store.replaceAll([concurrent])
        let conflicted = await coordinator.savePromptSetEdits(edit)
        XCTAssertFalse(conflicted)
        XCTAssertTrue(coordinator.promptSetManagementError?.contains("reopen") == true)
        XCTAssertEqual(try store.load(), [concurrent])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: ownedRoot.path), folders)
        edit = try XCTUnwrap(coordinator.preparePromptSetEdit(id: saved.id))
        edit.prompts[0].inputPath = replacement.path
        let corrupt = Data("broken-json".utf8)
        try corrupt.write(to: store.url)
        let failed = await coordinator.savePromptSetEdits(edit)
        XCTAssertFalse(failed)
        XCTAssertEqual(try Data(contentsOf: store.url), corrupt)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: ownedRoot.path), folders)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(saved.prompts.first?.inputPath))), Data("source".utf8))
        try store.replaceAll([concurrent])
        let retried = await coordinator.savePromptSetEdits(edit)
        XCTAssertTrue(retried)
        XCTAssertFalse(coordinator.savingPromptSet)
        XCTAssertNil(coordinator.promptSetManagementError)
    }

    @MainActor
    func testOwnedInputEditReclaimsUsingCurrentLegacyRunReferences() async throws {
        let source = root.appendingPathComponent("source.png"), replacement = root.appendingPathComponent("replacement.png")
        try Data("source".utf8).write(to: source); try Data("replacement".utf8).write(to: replacement)
        var draft = PromptSetDraft(mode: .vision)
        draft.name = "Images"; draft.prompts[0].text = "Describe"; draft.prompts[0].inputPath = source.path
        let coordinator = makeCoordinator(runner: StubMediaRunner())
        let result = await coordinator.createPromptSet(draft)
        let saved = try XCTUnwrap(result)
        var legacy = historyRun(.vision, "Legacy reference", at: 100)
        legacy.promptEntries = saved.prompts
        let runs = JSONStore<ComparisonRun>(fileURL: root.appendingPathComponent("runs.json"))
        // Simulate a durable reference added after this coordinator loaded runs.
        try runs.replaceAll([legacy])
        let historyBytes = try Data(contentsOf: runs.url)
        var edit = try XCTUnwrap(coordinator.preparePromptSetEdit(id: saved.id))
        edit.prompts[0].inputPath = replacement.path
        let updated = await coordinator.savePromptSetEdits(edit)
        XCTAssertTrue(updated)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(saved.prompts.first?.inputPath)))
        XCTAssertEqual(try Data(contentsOf: runs.url), historyBytes)
        // A failed authoritative run-store read must also prevent reclamation.
        let current = try XCTUnwrap(coordinator.promptSets.first { $0.id == saved.id })
        try Data("broken-runs".utf8).write(to: runs.url)
        try await assertAsyncTrue(await coordinator.removePromptSet(id: saved.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(current.prompts.first?.inputPath)))
    }

    @MainActor
    func testInputNamesSurviveOwnedCopiesEditsAndRecordedSetupReuse() async throws {
        let source = root.appendingPathComponent("Bird in snow.png")
        try Data("source image".utf8).write(to: source)
        var draft = PromptSetDraft(mode: .vision)
        draft.name = "Readable inputs"; draft.prompts[0].text = "Describe"; draft.prompts[0].inputPath = source.path
        let runner = StubMediaRunner(), coordinator = makeCoordinator(runner: runner)
        let result = await coordinator.createPromptSet(draft)
        let set = try XCTUnwrap(result)
        XCTAssertEqual(set.prompts[0].inputName, source.lastPathComponent)
        XCTAssertEqual(set.prompts[0].inputDisplayName, "Bird in snow.png")
        let ownedPath = try XCTUnwrap(set.prompts[0].inputPath)
        XCTAssertNotEqual(URL(fileURLWithPath: ownedPath).lastPathComponent, "Bird in snow.png")
        try FileManager.default.removeItem(at: source)
        let restored = try XCTUnwrap(JSONStore<PromptSet>(fileURL: root.appendingPathComponent("sets.json")).load().first)
        XCTAssertEqual(restored.prompts[0].inputDisplayName, "Bird in snow.png")
        var edit = try XCTUnwrap(coordinator.preparePromptSetEdit(id: set.id))
        XCTAssertEqual(edit.prompts[0].inputDisplayName, "Bird in snow.png")
        edit.prompts[0].text = "Describe the surroundings"
        let edited = await coordinator.savePromptSetEdits(edit)
        XCTAssertTrue(edited)
        let textOnly = try XCTUnwrap(coordinator.promptSets.first { $0.id == set.id })
        XCTAssertEqual(textOnly.prompts[0].inputName, "Bird in snow.png")
        coordinator.start(variants: [("/vision/model", nil)], promptSet: textOnly)
        await waitForRun(coordinator)
        let run = try XCTUnwrap(coordinator.runs.first)
        let reuse = try ComparisonRunSetup(run: run, outputStore: coordinator.outputStore)
        XCTAssertEqual(reuse.draft.prompts[0].inputDisplayName, "Bird in snow.png")
        let reused = await coordinator.createPromptSet(reuse.savedDraft(named: "Another copy"))
        XCTAssertEqual(reused?.prompts[0].inputName, "Bird in snow.png")
        XCTAssertNotEqual(reused?.prompts[0].inputPath, set.prompts[0].inputPath)
        let replacement = root.appendingPathComponent("New bird.jpg")
        try Data("replacement image".utf8).write(to: replacement)
        edit = try XCTUnwrap(coordinator.preparePromptSetEdit(id: set.id))
        edit.prompts[0].inputPath = replacement.path
        XCTAssertEqual(edit.prompts[0].inputDisplayName, "New bird.jpg")
        XCTAssertNil(try edit.promptSet().prompts[0].inputName, "Changing files must clear the previous display name")
        let replaced = await coordinator.savePromptSetEdits(edit)
        XCTAssertTrue(replaced)
        XCTAssertEqual(coordinator.promptSets.first { $0.id == set.id }?.prompts[0].inputName, "New bird.jpg")
    }

    func testInputNamesAreDisplayOnlyAndLegacyNamesAreNotInvented() throws {
        var entry = PromptEntry(id: "p", text: "Describe", inputKind: .image,
            inputPath: root.appendingPathComponent("actual.png").path)
        let originalPath = entry.inputPath
        XCTAssertEqual(entry.inputDisplayName, "actual.png")
        for invalid in ["", ".", "..", "../other.png", "/private/other.png", "folder\\other.png", "name\n.png", "name\u{7f}.png", String(repeating: "a", count: 256)] {
            entry.inputName = invalid
            XCTAssertEqual(entry.inputDisplayName, "actual.png")
            XCTAssertEqual(entry.inputPath, originalPath)
        }
        entry.inputName = "Readable source.png"
        XCTAssertEqual(entry.inputDisplayName, "Readable source.png")
        XCTAssertEqual(entry.inputPath, originalPath)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        json.removeValue(forKey: "inputName")
        let legacy = try JSONDecoder().decode(PromptEntry.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.inputName)
        XCTAssertEqual(legacy.inputDisplayName, "actual.png")
        var run = historyRun(.vision, "Legacy input", at: 100)
        run.promptEntries = [legacy]; run.inputArtifacts = ["p": "missing.png"]
        let setup = try ComparisonRunSetup(run: run, outputStore: ComparisonOutputStore(root: root))
        XCTAssertEqual(setup.draft.prompts[0].inputDisplayName, "actual.png")
        XCTAssertTrue(setup.draft.prompts[0].inputFileUnavailable)
        XCTAssertNil(setup.draft.prompts[0].inputPreviewURL)
        XCTAssertThrowsError(try setup.draft.promptSet(), "A name must never resolve an unavailable file")
        entry.inputPath = nil; entry.inputName = nil
        XCTAssertNil(entry.inputDisplayName)
    }

    @MainActor
    func testReuseSheetShowsRecordedFilenameForSavedAndMissingCopies() async throws {
        let store = ComparisonOutputStore(root: root.appendingPathComponent("name-proof"))
        var run = historyRun(.vision, "Named inputs · fixture", at: 100, models: ["/vision/a"])
        try store.createRunDirectory(run.id)
        let imageEntry = PromptEntry(id: "fixture", text: "Describe", inputKind: .image, builtinInput: "red-circle")
        let generated = try await ComparisonMediaFixtures.generateInput(for: imageEntry, into: root)
        let artifact = try await store.snapshotInput(from: generated, runID: run.id)
        run.promptEntries = [PromptEntry(id: "p", text: "Describe this bird and its surroundings", inputKind: .image,
            inputPath: root.appendingPathComponent("unknown-storage-name.png").path,
            inputName: "Bird photographs — winter reference.png")]
        run.inputArtifacts = ["p": artifact]
        for status in ["saved", "missing"] {
            if status == "missing" { try FileManager.default.removeItem(at: XCTUnwrap(store.inputArtifactURL(runID: run.id, artifact: artifact))) }
            let setup = try ComparisonRunSetup(run: run, outputStore: store)
            XCTAssertEqual(setup.draft.prompts[0].inputDisplayName, "Bird photographs — winter reference.png")
            let sheet = ComparisonRunSetupSheet(setup: setup, availablePaths: ["/vision/a"], name: { _ in "Vision model · fixture" },
                onApply: { _, _ in XCTFail("Rendering must not run"); return nil },
                onSave: { _ in XCTFail("Rendering must not save"); return nil })
            let host = NSHostingView(rootView: sheet.background(WorkbenchColor.canvas).preferredColorScheme(.dark))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 720),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "Input filename · \(status)"; attachment.lifetime = .keepAlways; add(attachment)
            if let directory = ProcessInfo.processInfo.environment["MLX_INPUT_NAME_PROOF_DIR"] {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("input-name-\(status).png"))
            }
            window.close()
        }
    }

    func testReuseOtherModesPreservesRecordedPromptsAndCreatesIndependentCopies() throws {
        let tool = BuiltinPromptSets.toolCalling.prompts[0].tool
        let input = root.appendingPathComponent("reference.png")
        try Data("reference".utf8).write(to: input)
        for mode in ComparisonMode.allCases where mode != .musicGeneration {
            var run = historyRun(mode, "Recorded", at: 100, models: ["/first", "/missing"])
            let entry = PromptEntry(id: "recorded", text: "Red bird", maxTokens: 77,
                tool: mode == .chat ? tool : nil, inputKind: mode.inputKind,
                inputPath: mode.inputKind == nil ? nil : input.path,
                expectedKeywords: ["red", "bird"],
                media: MediaParameters(size: 512, steps: 9, seed: 17, frames: 33, fps: 12))
            run.promptEntries = [entry]
            let original = run
            var setup = try ComparisonRunSetup(run: run)
            let temporary = try setup.draft.promptSet()
            XCTAssertNotEqual(temporary.id, run.promptSetID)
            XCTAssertEqual(temporary.effectiveMode, mode)
            XCTAssertEqual(temporary.prompts, [entry])
            XCTAssertEqual(setup.modelPaths, ["/first", "/missing"])
            setup.draft.prompts[0].text = "Blue bird"
            let saved = try setup.savedDraft(named: "Copy").promptSet()
            XCTAssertNotEqual(saved.id, temporary.id)
            XCTAssertEqual(saved.name, "Copy")
            XCTAssertEqual(saved.prompts[0].text, "Blue bird")
            XCTAssertEqual(saved.prompts[0].id, "recorded")
            XCTAssertEqual(saved.prompts[0].tool, entry.tool)
            XCTAssertEqual(run, original)
        }
        let chat = ComparisonRun(id: UUID(), promptSetID: "tools", promptSetName: "Tools", useCase: .coding,
            variants: ["/model"], results: [], startedAt: Date(), finishedAt: nil, state: .completed,
            promptEntries: [PromptEntry(id: "p", text: "Call a tool", tool: tool)])
        XCTAssertEqual(try ComparisonRunSetup(run: chat).draft.promptSet().useCase, .coding)
    }

    func testReuseOtherModesRejectsMissingSnapshotsAndInvalidSelections() throws {
        var run = historyRun(.imageGeneration, "Legacy", at: 100)
        XCTAssertThrowsError(try ComparisonRunSetup(run: run))
        run.promptEntries = []; XCTAssertThrowsError(try ComparisonRunSetup(run: run))
        run.promptEntries = [PromptEntry(id: "p", text: "A forest")]
        run.state = .running; XCTAssertThrowsError(try ComparisonRunSetup(run: run))
        run.state = .completed; run.mode = .musicGeneration
        XCTAssertEqual(try ComparisonRunSetup(run: run).draft.mode, .musicGeneration, "One setup reuses runs in every mode")
        run.mode = .imageGeneration
        run.promptEntries = [PromptEntry(id: "p", text: "A forest"), PromptEntry(id: "p", text: "Another forest")]
        XCTAssertThrowsError(try ComparisonRunSetup(run: run))
        for models in [[], [""], ["/model", "/model"], ["/a", "/b", "/c", "/d", "/e"]] {
            var invalid = historyRun(.chat, "Invalid selection", at: 100, models: models)
            invalid.promptEntries = [PromptEntry(id: "p", text: "Question")]
            XCTAssertThrowsError(try ComparisonRunSetup(run: invalid))
        }
    }

    func testReuseOtherModesFlagsMissingFilesAndAllowsReplacementOrBuiltinFixtures() throws {
        var run = historyRun(.vision, "Vision", at: 100)
        run.promptEntries = [PromptEntry(id: "p", text: "What is here?", inputKind: .image,
            inputPath: root.appendingPathComponent("gone.png").path)]
        var setup = try ComparisonRunSetup(run: run)
        XCTAssertTrue(setup.draft.prompts[0].inputFileUnavailable)
        XCTAssertThrowsError(try setup.draft.promptSet())
        let replacement = root.appendingPathComponent("new.png")
        try Data("reference".utf8).write(to: replacement)
        setup.draft.prompts[0].inputPath = replacement.path
        XCTAssertFalse(setup.draft.prompts[0].inputFileUnavailable)
        XCTAssertEqual(try setup.draft.promptSet().prompts[0].inputPath, replacement.path)
        run.promptEntries = [PromptEntry(id: "p", text: "What is here?", inputKind: .image, builtinInput: "red-circle")]
        let builtin = try ComparisonRunSetup(run: run)
        XCTAssertFalse(builtin.draft.prompts[0].inputFileUnavailable)
        XCTAssertEqual(try builtin.draft.promptSet().prompts[0].builtinInput, "red-circle")
    }

    @MainActor
    func testReusedVideoSetupSavesCopyAndStartsFreshRunWithoutChangingHistory() async throws {
        let runner = StubMediaRunner(), coordinator = makeCoordinator(runner: runner)
        var originalDraft = PromptSetDraft(mode: .videoGeneration)
        originalDraft.name = "Video"; originalDraft.prompts[0].text = "A forest"
        originalDraft.prompts[0].steps = "9"; originalDraft.prompts[0].seed = "17"
        let created = await coordinator.createPromptSet(originalDraft)
        let originalSet = try XCTUnwrap(created)
        coordinator.start(variants: [("/video/a", "old-signature")], promptSet: originalSet)
        await waitForRun(coordinator)
        let runID = try XCTUnwrap(coordinator.runs.first?.id)
        await coordinator.reviewQuality(runID: runID, modelPath: "/video/a", score: 4)?.value
        let originalRun = try XCTUnwrap(coordinator.runs.first)
        let historyBefore = try Data(contentsOf: root.appendingPathComponent("runs.json"))
        var setup = try ComparisonRunSetup(run: originalRun)
        setup.draft.prompts[0].steps = "12"
        let copied = await coordinator.createPromptSet(setup.savedDraft(named: "Video copy"))
        let saved = try XCTUnwrap(copied)
        XCTAssertNotEqual(saved.id, originalSet.id)
        XCTAssertEqual(coordinator.promptSets.first { $0.id == originalSet.id }, originalSet)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("runs.json")), historyBefore)
        XCTAssertNil(coordinator.activeRunID)
        let requestsBeforeRun = await runner.requests
        XCTAssertEqual(requestsBeforeRun.count, 1)
        let temporary = try setup.draft.promptSet()
        coordinator.start(variants: [(setup.modelPaths[0], "new-signature")], promptSet: temporary)
        await waitForRun(coordinator)
        let next = try XCTUnwrap(coordinator.runs.first { $0.id != runID })
        XCTAssertEqual(next.state, .completed)
        XCTAssertEqual(next.promptEntries?.first?.media?.steps, 12)
        XCTAssertEqual(next.promptEntries?.first?.media?.seed, 17)
        XCTAssertEqual(next.results.first?.modelSignature, "new-signature")
        XCTAssertTrue(next.qualityReviews?.isEmpty ?? true)
        XCTAssertEqual(coordinator.runs.first { $0.id == runID }, originalRun)
    }

    func testReuseValidatesTextAndCanClearExplicitParametersToDefaults() throws {
        var run = historyRun(.musicGeneration, "Saved music", at: 100)
        run.promptEntries = [PromptEntry(id: "p", text: "Piano", media:
            MediaParameters(size: 512, steps: 12, seed: 7, durationSeconds: 12.5, lyrics: "[instrumental]"))]
        var setup = try ComparisonRunSetup(run: run)
        setup.draft.prompts[0].duration = ""; setup.draft.prompts[0].steps = ""
        setup.draft.prompts[0].seed = ""; setup.draft.prompts[0].lyrics = ""
        let cleared = try setup.draft.promptSet().prompts[0]
        XCTAssertEqual(cleared.media, MediaParameters(size: 512), "Unedited media fields must survive")
        for caption in ["   ", "Piano\u{0}", String(repeating: "🎹", count: 2001)] {
            setup.draft.prompts[0].text = caption
            XCTAssertThrowsError(try setup.draft.promptSet())
        }
        setup.draft.prompts[0].text = String(repeating: "🎹", count: 2000)
        XCTAssertNoThrow(try setup.draft.promptSet())
        for lyrics in ["  ", "Song\u{1}", String(repeating: "a", count: 10001)] {
            setup.draft.prompts[0].lyrics = lyrics
            XCTAssertThrowsError(try setup.draft.promptSet())
        }
        run.promptEntries?[0].media?.lyrics = ""
        XCTAssertNotNil(try ComparisonRunSetup(run: run).draft.validationError)
        run = historyRun(.musicGeneration, "Duplicate models", at: 100, models: ["/model", "/model"])
        run.promptEntries = [PromptEntry(id: "p", text: "Piano")]
        XCTAssertThrowsError(try ComparisonRunSetup(run: run))
    }

    @MainActor
    func testReusedMusicSetupStartsFreshRunWithoutMutatingSavedInputsOrReviews() async throws {
        let runner = StubMediaRunner(), runsURL = root.appendingPathComponent("reuse-runs.json")
        var set = promptSet(for: .musicGeneration)
        set.origin = .userCreated
        set.prompts = [PromptEntry(id: "recorded", text: "Instrumental jazz-funk",
            media: MediaParameters(steps: 12, seed: 7, durationSeconds: 12.5, lyrics: "[instrumental]"))]
        let coordinator = try makeCoordinator(runner: runner, saved: [set], runsURL: runsURL)
        coordinator.start(variants: [("/music/a", nil)], promptSet: set)
        await waitForRun(coordinator)
        let originalID = try XCTUnwrap(coordinator.runs.first?.id)
        await coordinator.reviewQuality(runID: originalID, modelPath: "/music/a", score: 4)?.value
        let original = try XCTUnwrap(coordinator.runs.first)
        var setup = try ComparisonRunSetup(run: original)
        setup.draft.prompts[0].duration = "20"
        let prepared = try setup.draft.promptSet()
        let presetsBefore = try Data(contentsOf: root.appendingPathComponent("sets.json"))
        coordinator.start(variants: [("/music/a", nil)], promptSet: prepared)
        await waitForRun(coordinator)
        let newRun = try XCTUnwrap(coordinator.runs.first { $0.id != originalID })
        XCTAssertEqual(newRun.state, .completed)
        XCTAssertEqual(newRun.promptEntries, prepared.prompts)
        XCTAssertTrue(newRun.qualityReviews?.isEmpty ?? true)
        XCTAssertEqual(coordinator.runs.first { $0.id == originalID }, original)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("sets.json")), presetsBefore)
        let requests = await runner.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.last?.entry, prepared.prompts.first)
        XCTAssertEqual(requests.last?.entry.media?.durationSeconds, 20)
        XCTAssertEqual(requests.last?.entry.media?.seed, 7)
        XCTAssertEqual(requests.last?.entry.media?.steps, 12)
        XCTAssertEqual(requests.last?.modelPath, "/music/a")
        XCTAssertEqual(try JSONStore<ComparisonRun>(fileURL: runsURL).load().count, 2)
    }

    @MainActor
    func testReuseMusicSheetRendersRecordedFieldsAndUnavailableModel() async throws {
        var run = historyRun(.musicGeneration, "Instrumental comparison", at: 100, models: ["/music/8bit", "/music/4bit"])
        run.promptEntries = [PromptEntry(id: "recorded", text: "Instrumental jazz-funk with Rhodes, bass and drums",
            media: MediaParameters(steps: 12, seed: 7, durationSeconds: 12.5, lyrics: "[instrumental]"))]
        let view = ComparisonRunSetupSheet(setup: try ComparisonRunSetup(run: run), availablePaths: ["/music/8bit"],
            name: { $0 == "/music/8bit" ? "Music model · 8-bit" : "Music model · 4-bit" },
            onApply: { _, _ in XCTFail("Rendering must not apply or generate"); return nil },
            onSave: { _ in XCTFail("Rendering must not save"); return nil })
            .background(WorkbenchColor.canvas).preferredColorScheme(.dark)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 590),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "Reuse music setup"; attachment.lifetime = .keepAlways; add(attachment)
        if let path = ProcessInfo.processInfo.environment["MLX_REUSE_PROOF_PATH"] { try png.write(to: URL(fileURLWithPath: path)) }
    }

    @MainActor
    func testReuseOtherModeSheetRendersMissingInputsWithoutSavingOrRunning() async throws {
        var run = historyRun(.vision, "Bird descriptions", at: 100, models: ["/vision/a", "/vision/missing"])
        run.promptEntries = [PromptEntry(id: "recorded", text: "Describe the bird and its surroundings", maxTokens: 512,
            inputKind: .image, inputPath: root.appendingPathComponent("missing-bird.png").path,
            expectedKeywords: ["bird", "snow"])]
        let sheet = ComparisonRunSetupSheet(setup: try ComparisonRunSetup(run: run), availablePaths: ["/vision/a"],
            name: { $0 == "/vision/a" ? "Vision model · 8-bit" : "Vision model · 4-bit" },
            onApply: { _, _ in XCTFail("Rendering must not apply or run"); return nil },
            onSave: { _ in XCTFail("Rendering must not save"); return nil })
        let host = NSHostingView(rootView: sheet.background(WorkbenchColor.canvas).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 720),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "Reuse vision setup · missing model and file"; attachment.lifetime = .keepAlways; add(attachment)
        if let directory = ProcessInfo.processInfo.environment["MLX_REUSE_SETUP_PROOF_DIR"] {
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("reuse-vision.png"))
        }
        window.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("sets.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("runs.json").path))
    }

    @MainActor
    func testReusedSetupSaveFailureRetainsDraftAndCanRetryAsIndependentCopy() async throws {
        var run = historyRun(.imageGeneration, "Images", at: 100)
        run.promptEntries = [PromptEntry(id: "p", text: "A red bird", media: MediaParameters(size: 768, steps: 9, seed: 17))]
        var setup = try ComparisonRunSetup(run: run)
        setup.draft.prompts[0].seed = "42"
        let coordinator = makeCoordinator(runner: StubMediaRunner())
        let storeURL = root.appendingPathComponent("sets.json")
        let corrupt = Data("broken-json".utf8); try corrupt.write(to: storeURL)
        let failed = await coordinator.createPromptSet(setup.savedDraft(named: "Copy"))
        XCTAssertNil(failed)
        XCTAssertEqual(try Data(contentsOf: storeURL), corrupt)
        XCTAssertEqual(try setup.draft.promptSet().prompts[0].media?.seed, 42)
        XCTAssertTrue(coordinator.promptSets.allSatisfy { $0.origin == .builtin })
        try FileManager.default.removeItem(at: storeURL)
        let retried = await coordinator.createPromptSet(setup.savedDraft(named: "Copy"))
        let saved = try XCTUnwrap(retried)
        XCTAssertNotEqual(saved.id, setup.draft.id)
        XCTAssertNil(coordinator.promptSetManagementError)
        XCTAssertEqual(saved.prompts[0].media, MediaParameters(size: 768, steps: 9, seed: 42))
        XCTAssertTrue(coordinator.runs.isEmpty)
        XCTAssertNil(coordinator.activeRunID)
    }
}
