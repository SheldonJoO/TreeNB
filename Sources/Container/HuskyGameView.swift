//
//  HuskyGameView.swift
//  TreeNB —— Husk 翻译层游戏运行视图
//
//  一个 APK 一个实例（GPU surface 绑定在 CAMetalLayer 上，引擎不能启动两次）。
//  view 进入 window 且尺寸就绪时才 launch，与 Husk 官方 TLUnityUIView 一致。
//  触摸按 UITouch 身份分配稳定的指针 id 转发给翻译层。
//

import UIKit
import QuartzCore
import HuskyEngine

/// 翻译层游戏的全屏运行视图。
final class HuskyGameView: UIView {

    private let apk: String
    private let engine: String
    private let dataDir: String
    private let extraApks: [String]
    private let scale: CGFloat

    private var launched = false
    private var pointers: [ObjectIdentifier: Int32] = [:]

    /// 退出游戏（三指点击）回调。
    var onExitRequested: (() -> Void)?

    init(apk: String, engine: String, dataDir: String, extraApks: [String] = [], scale: CGFloat = 2) {
        self.apk = apk
        self.engine = engine
        self.dataDir = dataDir
        self.extraApks = extraApks
        self.scale = scale
        super.init(frame: .zero)

        backgroundColor = .black
        isMultipleTouchEnabled = true
        contentScaleFactor = scale
        if let metal = layer as? CAMetalLayer {
            metal.pixelFormat = .bgra8Unorm
            metal.framebufferOnly = true
            metal.contentsScale = scale
            metal.isOpaque = true
        }

        let three = UITapGestureRecognizer(target: self, action: #selector(threeFingerTapped))
        three.numberOfTouchesRequired = 3
        three.cancelsTouchesInView = false
        three.delaysTouchesBegan = false
        three.delaysTouchesEnded = false
        addGestureRecognizer(three)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override class var layerClass: AnyClass { CAMetalLayer.self }

    @objc private func threeFingerTapped() { onExitRequested?() }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !launched, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        launched = true
        launch()
    }

    private func launch() {
        let engineObj = HuskyEngine.shared
        // 已经在跑同一个游戏则直接恢复。
        if engineObj.state == HuskyState.running, engineObj.loadedAPK == apk {
            engineObj.setPaused(false)
            return
        }
        if engineObj.state != HuskyState.idle {
            engineObj.unload()
        }

        // 运行前置：预置数据目录、共享存储、JIT-less dylib 目录、附加分包。
        try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let shared = docs.appendingPathComponent("HuskySharedStorage", isDirectory: true)
        try? FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        engineObj.setSharedStorageDirectory(shared.path)

        let bundle = Bundle.main
        let frameworks = bundle.privateFrameworksPath ?? ""
        let cache = docs.appendingPathComponent("HuskyJITless", isDirectory: true).path
        try? FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
        engineObj.prepareJITLess(withAOTDirectories: [frameworks, cache])

        for extra in extraApks.prefix(3) { engineObj.addPackage(extra) }

        let angle = bundle.path(forResource: "libANGLE-shared", ofType: "dylib")
            ?? (frameworks as NSString).appendingPathComponent("libANGLE-shared.dylib")
        let ca = bundle.path(forResource: "cacert", ofType: "pem") ?? ""

        let w = Int32(bounds.width * scale)
        let h = Int32(bounds.height * scale)
        let layerPtr = Unmanaged.passUnretained(self.layer).toOpaque()
        _ = engineObj.launchAPK(apk, engine: engine, dataDir: dataDir,
                                metalLayer: layerPtr, width: w, height: h,
                                anglePath: angle, caPath: ca)
    }

    func pause() { HuskyEngine.shared.setPaused(true) }
    func resume() { HuskyEngine.shared.setPaused(false) }

    // MARK: - 触摸

    private func pointerID(for touch: UITouch) -> Int32 {
        let key = ObjectIdentifier(touch)
        if let existing = pointers[key] { return existing }
        var next: Int32 = 0
        while pointers.values.contains(next) { next += 1 }
        pointers[key] = next
        return next
    }

    private func send(_ touches: Set<UITouch>, phase: Int32) {
        for t in touches {
            let p = t.location(in: self)
            let pid = pointerID(for: t)
            HuskyEngine.shared.touch(phase, pointer: pid,
                                     x: Float(p.x * scale), y: Float(p.y * scale))
            if phase == 2 || phase == 3 { pointers[ObjectIdentifier(t)] = nil }
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches, phase: 0) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches, phase: 1) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches, phase: 2) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        send(touches, phase: 3)
        pointers.removeAll()
    }
}
