import CoreML
import XCTest
@testable import FluidAudio

final class FluidAudioPatchTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        ModelHub.offlineMode = false
        try FileManager.default.removeItem(at: root)
    }

    private func bundle() throws -> URL {
        let folder = root.appendingPathComponent("test.mlmodelc")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("weights"), withIntermediateDirectories: true)
        try Data("header".utf8).write(to: folder.appendingPathComponent("coremldata.bin"))
        try Data("program { @model_path/weights/weight.bin\" }\n".utf8).write(to: folder.appendingPathComponent("model.mil"))
        try Data("weights".utf8).write(to: folder.appendingPathComponent("weights/weight.bin"))
        return folder
    }

    func testCompleteModelLayoutIsAccepted() throws {
        XCTAssertNoThrow(try ModelCache.validateCompiledModelLayout(at: bundle(), name: "test"))
    }

    func testMissingProgramIsRejectedBeforeCoreML() throws {
        let folder = try bundle()
        try FileManager.default.removeItem(at: folder.appendingPathComponent("model.mil"))
        XCTAssertThrowsError(try ModelCache.validateCompiledModelLayout(at: folder, name: "test"))
    }

    func testTruncatedProgramIsRejectedBeforeCoreML() throws {
        let folder = try bundle()
        try Data("program {".utf8).write(to: folder.appendingPathComponent("model.mil"))
        XCTAssertThrowsError(try ModelCache.validateCompiledModelLayout(at: folder, name: "test"))
    }

    func testMissingWeightsAreRejectedBeforeCoreML() throws {
        let folder = try bundle()
        try FileManager.default.removeItem(at: folder.appendingPathComponent("weights/weight.bin"))
        XCTAssertThrowsError(try ModelCache.validateCompiledModelLayout(at: folder, name: "test"))
    }

    func testEmptyWeightsAreRejectedBeforeCoreML() throws {
        let folder = try bundle()
        try Data().write(to: folder.appendingPathComponent("weights/weight.bin"))
        XCTAssertThrowsError(try ModelCache.validateCompiledModelLayout(at: folder, name: "test"))
    }

    func testSameSizeCorruptionIsOutsideLayoutValidation() throws {
        let folder = try bundle()
        try Data("changed".utf8).write(to: folder.appendingPathComponent("weights/weight.bin"))
        XCTAssertNoThrow(try ModelCache.validateCompiledModelLayout(at: folder, name: "test"))
    }

    func testWrongSizeManagedFileIsFetchedAgain() async throws {
        let file = root.appendingPathComponent("weights.bin")
        try Data("too long".utf8).write(to: file)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ModelFileProtocol.self]
        let outcome = try await FileDownloader.ensure(
            file: RemoteFile(path: "weights.bin", size: 4), from: "test/model", at: file,
            recoveringBlockedPaths: true, configuration: config)
        XCTAssertEqual(outcome, .downloaded)
        XCTAssertEqual(try Data(contentsOf: file), Data("good".utf8))
    }

    func testMatchingManagedFileIsPreserved() async throws {
        let file = root.appendingPathComponent("weights.bin")
        try Data("keep".utf8).write(to: file)
        let outcome = try await FileDownloader.ensure(
            file: RemoteFile(path: "weights.bin", size: 4), from: "test/model", at: file,
            recoveringBlockedPaths: true)
        XCTAssertEqual(outcome, .alreadyPresent)
        XCTAssertEqual(try Data(contentsOf: file), Data("keep".utf8))
    }

    func testUnmanagedFileIsNotReplaced() async throws {
        let file = root.appendingPathComponent("weights.bin")
        try Data("user file".utf8).write(to: file)
        let outcome = try await FileDownloader.ensure(
            file: RemoteFile(path: "weights.bin", size: 4), from: "test/model", at: file,
            recoveringBlockedPaths: false)
        XCTAssertEqual(outcome, .alreadyPresent)
        XCTAssertEqual(try Data(contentsOf: file), Data("user file".utf8))
    }

    func testOfflineIncompleteCacheIsRejectedBeforeLoading() async throws {
        let template = try bundle()
        let repository = root.appendingPathComponent(Repo.parakeetV3.folderName)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        for name in ModelNames.getRequiredModelNames(for: .parakeetV3, variant: "int8") {
            let target = repository.appendingPathComponent(name)
            if name.hasSuffix(".mlmodelc") {
                try FileManager.default.copyItem(at: template, to: target)
            } else {
                try Data("{}".utf8).write(to: target)
            }
        }
        let name = ParakeetEncoderPrecision.int8.encoderFileName
        try FileManager.default.removeItem(at: repository.appendingPathComponent("\(name)/model.mil"))
        ModelHub.offlineMode = true
        do {
            _ = try await ModelHub.loadModels(.parakeetV3, modelNames: [name], directory: root,
                                             computeUnits: .cpuOnly, variant: "int8")
            XCTFail("Incomplete cache must not reach Core ML")
        } catch DownloadError.modelMissing(_, let missing) {
            XCTAssertTrue(missing.contains(name))
        } catch {
            XCTFail("Expected a cache error before model loading, got \(error)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.path))
    }

    func testCachedJointBackingsPreservePrediction() throws {
        let path = AsrModels.defaultCacheDirectory(for: .v3).appendingPathComponent("JointDecisionv3.mlmodelc")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("Requires an already downloaded Parakeet v3 joint; no download is performed")
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: path, configuration: config)
        var inputs: [String: Any] = [:]
        for (name, feature) in model.modelDescription.inputDescriptionsByName {
            let constraint = try XCTUnwrap(feature.multiArrayConstraint)
            let array = try MLMultiArray(shape: constraint.shape, dataType: constraint.dataType)
            for i in 0..<array.count { array[i] = 0 }
            inputs[name] = array
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: inputs)
        let expected = try model.prediction(from: provider)
        var backings = try TdtModelInference.topKOutputBackings(for: model)
        XCTAssertEqual(Set(backings.keys), ["top_k_ids", "top_k_logits"])
        for name in ["token_id", "token_prob", "duration"] {
            let constraint = try XCTUnwrap(model.modelDescription.outputDescriptionsByName[name]?.multiArrayConstraint)
            backings[name] = try MLMultiArray(shape: constraint.shape, dataType: constraint.dataType)
        }
        let options = MLPredictionOptions()
        options.outputBackings = backings
        let actual = try model.prediction(from: provider, options: options)
        XCTAssertEqual(Set(backings.keys), expected.featureNames)
        for name in expected.featureNames {
            let lhs = try XCTUnwrap(expected.featureValue(for: name)?.multiArrayValue)
            let rhs = try XCTUnwrap(actual.featureValue(for: name)?.multiArrayValue)
            XCTAssertEqual(lhs.count, rhs.count)
            for i in 0..<lhs.count { XCTAssertEqual(lhs[i], rhs[i], name) }
        }
    }
}

private final class ModelFileProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "4"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("good".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
