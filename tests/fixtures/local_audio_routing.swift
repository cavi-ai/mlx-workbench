import Foundation

@main struct AudioRoutingChecks {
    static func check(_ value: Bool) { precondition(value) }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        let file = root.appendingPathComponent("routing.json")
        let endpoint = LocalAudioEndpoint(model: root.path, port: 19084, kind: "music_generation", receiptsDirectory: root.path)
        try endpoint.validate()
        for purpose in AudioGenerationPurpose.allCases {
            let restored = AudioGenerationPurpose.restore(purpose.caption("Ocean waves"))
            check(restored.0 == purpose && restored.1 == "Ocean waves")
        }
        let music = LocalAudioRouting(source: .music)
        try LocalAudioRoutingStore.save(music, fileURL: file)
        check(try LocalAudioRoutingStore.load(fileURL: file) == music)
        let specific = LocalAudioRouting(source: .specific, endpoint: endpoint)
        try LocalAudioRoutingStore.save(specific, fileURL: file)
        check(try LocalAudioRoutingStore.load(fileURL: file) == specific)
        let data = try Data(contentsOf: file)
        let records = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        precondition(records.count == 1 && records[0]["id"] as? String == "artist-brain")
        let selected = records[0]["endpoint"] as! [String: Any]
        precondition(selected["base_url"] as? String == "http://127.0.0.1:19084")
        precondition(selected["receipts_dir"] as? String == root.path)
        for invalid in [LocalAudioRouting(source: .specific),
                        LocalAudioRouting(source: .specific, endpoint: .init(model: root.path, port: 0, kind: "music_generation", receiptsDirectory: root.path)),
                        LocalAudioRouting(source: .specific, endpoint: .init(model: root.path, port: 19084, kind: "speak", receiptsDirectory: root.path))] {
            do { try LocalAudioRoutingStore.save(invalid, fileURL: file); fatalError("Accepted invalid route") }
            catch { }
        }
        check(try Data(contentsOf: file) == data)
        try Data("damaged".utf8).write(to: file)
        do { try LocalAudioRoutingStore.save(music, fileURL: file); fatalError("Overwrote damaged settings") }
        catch { }
        check(try Data(contentsOf: file) == Data("damaged".utf8))
    }
}
