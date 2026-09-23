import Foundation
import Domain
import Support

/// The readers we know how to run. Public files on Hugging Face — no token needed.
public enum ModelCatalog {
    public static let gemma4E4B = LocalModelInfo(
        name: "Gemma 4 E4B", fileName: "gemma-4-E4B-it.litertlm",
        downloadURL: URL(string: "https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/main/gemma-4-E4B-it.litertlm")!,
        approximateBytes: 3_700_000_000, minimumMemoryGB: 8)
    public static let gemma4E2B = LocalModelInfo(
        name: "Gemma 4 E2B", fileName: "gemma-4-E2B-it.litertlm",
        downloadURL: URL(string: "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm")!,
        approximateBytes: 2_500_000_000, minimumMemoryGB: 8)

    public static func info(for id: String?) -> LocalModelInfo { id == "E2B" ? gemma4E2B : gemma4E4B }

    /// Resolution order: env override → Application Support → app bundle.
    public static func locate(_ info: LocalModelInfo) -> URL? {
        let fm = FileManager.default
        if let p = ProcessInfo.processInfo.environment["BROWNIE_MODEL_PATH"], fm.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        let support = Paths.models.appendingPathComponent(info.fileName)
        if fm.fileExists(atPath: support.path) { return support }
        if let b = Bundle.main.url(forResource: info.fileName, withExtension: nil) { return b }
        return nil
    }

    public static var physicalMemoryGB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) }
}
