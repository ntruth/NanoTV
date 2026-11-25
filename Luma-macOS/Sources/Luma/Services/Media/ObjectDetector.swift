import AppKit
import CoreML
import Foundation

/// 轻量物体检测（YOLO11n，COCO 80 类，模型内置 NMS）。
/// 只用来补充「猫 / 狗 / 汽车 / 披萨」这类明确主体，标签会与 SigLIP 结果去重。
final class ObjectDetector {
    static let shared = ObjectDetector()

    private let lock = NSLock()
    private var attempted = false
    private var model: MLModel?

    /// 返回命中的中文标准标签，按置信度从高到低，最多 4 个。
    func detect(cgImage: CGImage) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let model = ensureModel(),
              let tensor = ImageTensor.make(from: cgImage, size: 640) else { return [] }
        do {
            let input = try MLDictionaryFeatureProvider(dictionary: [
                "image": MLFeatureValue(multiArray: tensor),
                "iouThreshold": MLFeatureValue(double: 0.5),
                "confidenceThreshold": MLFeatureValue(double: 0.4)
            ])
            let output = try model.prediction(from: input)
            guard let confidence = output.featureValue(for: "confidence")?.multiArrayValue,
                  let coordinates = output.featureValue(for: "coordinates")?.multiArrayValue else { return [] }
            let rows = confidence.shape.first?.intValue ?? 0
            let classes = confidence.shape.count > 1 ? confidence.shape[1].intValue : 0
            guard rows > 0, classes > 0 else { return [] }
            var titles: [String] = []
            for row in 0..<rows {
                var bestClass = -1
                var bestScore: Float = 0
                for column in 0..<classes {
                    let value = confidence[[NSNumber(value: row), NSNumber(value: column)]].floatValue
                    if value > bestScore {
                        bestScore = value
                        bestClass = column
                    }
                }
                guard bestClass >= 0, bestScore >= 0.4,
                      bestClass < Self.cocoClasses.count else { continue }
                // 过滤极小的误检框（坐标为归一化 xywh）。
                if coordinates.shape.count > 1, coordinates.shape[1].intValue >= 4 {
                    let area = coordinates[[NSNumber(value: row), NSNumber(value: 2)]].doubleValue
                        * coordinates[[NSNumber(value: row), NSNumber(value: 3)]].doubleValue
                    if area < 0.01 { continue }
                }
                guard let title = Self.title(forCOCO: Self.cocoClasses[bestClass]) else { continue }
                if !titles.contains(title) { titles.append(title) }
                if titles.count >= 4 { break }
            }
            return titles
        } catch {
            NSLog("LumaYOLO: prediction failed %@", error.localizedDescription)
            return []
        }
    }

    private func ensureModel() -> MLModel? {
        if attempted { return model }
        attempted = true
        guard let url = LumaModelResources.directory("YOLO11n/YOLO11n.mlmodelc") else { return nil }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try? MLModel(contentsOf: url, configuration: configuration)
        if model == nil { NSLog("LumaYOLO: model failed to load") }
        return model
    }

    // MARK: - COCO 80 → 中文标准标签

    private static let cocoClasses: [String] = [
        "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat",
        "traffic light", "fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat",
        "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe", "backpack",
        "umbrella", "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard", "sports ball",
        "kite", "baseball bat", "baseball glove", "skateboard", "surfboard", "tennis racket",
        "bottle", "wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple",
        "sandwich", "orange", "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair",
        "couch", "potted plant", "bed", "dining table", "toilet", "tv", "laptop", "mouse",
        "remote", "keyboard", "cell phone", "microwave", "oven", "toaster", "sink", "refrigerator",
        "book", "clock", "vase", "scissors", "teddy bear", "hair drier", "toothbrush"
    ]

    private static let mapping: [String: String] = [
        "person": "人物",
        "bicycle": "自行车", "car": "汽车", "motorcycle": "摩托车", "airplane": "飞机",
        "bus": "公交车", "train": "火车", "truck": "汽车", "boat": "船",
        "bird": "鸟", "cat": "猫", "dog": "狗", "horse": "马", "sheep": "羊", "cow": "牛",
        "elephant": "大象", "bear": "野生动物", "zebra": "野生动物", "giraffe": "野生动物",
        "backpack": "包包", "umbrella": "雨伞", "handbag": "包包", "tie": "衣服", "suitcase": "包包",
        "frisbee": "运动器材", "skis": "运动器材", "snowboard": "运动器材", "sports ball": "运动器材",
        "kite": "玩具", "baseball bat": "运动器材", "baseball glove": "运动器材",
        "skateboard": "运动器材", "surfboard": "运动器材", "tennis racket": "运动器材",
        "bottle": "瓶子", "wine glass": "杯子", "cup": "杯子", "fork": "餐具", "knife": "餐具",
        "spoon": "餐具", "bowl": "餐具",
        "banana": "水果", "apple": "水果", "sandwich": "美食", "orange": "水果",
        "broccoli": "蔬菜", "carrot": "蔬菜", "hot dog": "美食", "pizza": "披萨",
        "donut": "甜点", "cake": "蛋糕",
        "chair": "家具", "couch": "家具", "potted plant": "盆栽", "bed": "家具", "dining table": "家具",
        "laptop": "电脑", "mouse": "电脑", "keyboard": "电脑", "cell phone": "手机",
        "book": "书本", "teddy bear": "玩具"
    ]

    private static func title(forCOCO name: String) -> String? {
        mapping[name]
    }
}
