// ============================================================================
// visionOS 简化版录屏应用 - 关键修复：录制状态同步和清理
// 1. 修复 ModelManager 状态传递 (保证架构正确)
// 2. 增强录制启动前的状态检查和清理 (应对 -5830 错误)
// 3. 重新引入相册保存功能 (提供完整功能)
// ============================================================================

import SwiftUI
import RealityKit
import ReplayKit
import AVFoundation
import UniformTypeIdentifiers
import Foundation
import Combine
import VideoToolbox
import Photos // 引入相册库

// 新增通知名称，供 ContentView -> ImmersiveView 协调在沉浸式内启动录制
extension Notification.Name {
    static let startRecordingInImmersive = Notification.Name("startRecordingInImmersive")
}

// MARK: - 录制管理器

class ScreenRecordingManager: ObservableObject {
    static let shared = ScreenRecordingManager()
    
    @Published var isRecording: Bool = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var errorMessage: String? = nil
    @Published var saveMessage: String? = nil // 用于相册保存反馈
    
    private let recorder = RPScreenRecorder.shared()
    private var videoWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var startTime: Date?
    private var recordingTimer: Timer?
    private var isWriterInitialized = false
    
    private init() {
        recorder.isMicrophoneEnabled = false
    }
    
    // 关键修改 1: 在开始录制前，先检查并停止可能残留的录制状态
    func startRecording() {
        // 如果应用内部状态显示正在录制，则直接返回
        guard !isRecording else { return }
        
        // 关键修改 2: 如果 ReplayKit 认为正在录制但应用状态不同步，先尝试停止
        if recorder.isRecording {
            print("警告：RPScreenRecorder 内部状态显示正在录制，尝试先停止。")
            recorder.stopCapture { error in
                DispatchQueue.main.async {
                    if let error = error {
                        print("强制停止失败: \(error.localizedDescription)")
                        self.errorMessage = "录制状态异常，强制停止失败: \(error.localizedDescription)"
                    } else {
                        print("强制停止成功，重新尝试启动录制。")
                        self.attemptStartCapture()
                    }
                }
            }
        } else {
            // ReplayKit 内部状态干净，直接尝试启动
            attemptStartCapture()
        }
    }
    
    private func attemptStartCapture() {
        isWriterInitialized = false
        errorMessage = nil
        saveMessage = nil
        
        recorder.startCapture(handler: { [weak self] sampleBuffer, bufferType, error in
            if let error = error {
                DispatchQueue.main.async {
                    // 如果在录制过程中断，确保 UI 状态更新
                    self?.errorMessage = "录制中断: \(error.localizedDescription)"
                    self?.stopRecording { _ in }
                }
                return
            }
            
            if bufferType == .video {
                self?.processSampleBuffer(sampleBuffer)
            }
        }) { [weak self] error in
            DispatchQueue.main.async {
                if let error = error {
                    // 录制启动失败，更新状态，让按钮恢复可点击
                    self?.errorMessage = "启动失败: \(error.localizedDescription)"
                    self?.isRecording = false
                    print("RPScreenRecorder startCapture 失败: \(error.localizedDescription)")
                } else {
                    // 录制成功启动，更新状态，让按钮变为停止
                    self?.isRecording = true
                    self?.startTime = Date()
                    self?.startDurationTimer()
                }
            }
        }
    }
    
    func stopRecording(completion: @escaping (URL?) -> Void) {
        // 确保停止前清理计时器，防止计时器继续运行
        stopDurationTimer()
        
        // 关键修改 3: 只有当 RPScreenRecorder 内部认为正在录制时才调用 stopCapture
        guard recorder.isRecording else {
            print("RPScreenRecorder 内部未在录制，执行状态清理。")
            self.isRecording = false
            self.recordingDuration = 0
            self.finalizeVideo(completion: completion)
            return
        }
        
        recorder.stopCapture { [weak self] error in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                self.isRecording = false
                self.recordingDuration = 0
                
                if let error = error {
                    print("停止捕获警告: \(error.localizedDescription)")
                }
                
                self.finalizeVideo(completion: completion)
            }
        }
    }
    
    // 重新加入：保存视频到系统相册的方法
    func saveVideoToAlbum(url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            if status == .authorized || status == .limited {
                PHPhotoLibrary.shared().performChanges({
                    PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }) { success, error in
                    DispatchQueue.main.async {
                        if success {
                            self.saveMessage = "视频已成功保存到相册"
                             try? FileManager.default.removeItem(at: url)
                        } else {
                            self.saveMessage = "保存相册失败: \(error?.localizedDescription ?? "未知错误")"
                        }
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.saveMessage = "没有相册权限，无法保存"
                }
            }
        }
    }
    
    // ... (processSampleBuffer, setupVideoWriter, finalizeVideo 保持不变)
    private func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        if !isWriterInitialized {
            guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            
            if setupVideoWriter(width: Int(dimensions.width), height: Int(dimensions.height), startTime: timestamp) {
                isWriterInitialized = true
            } else {
                return
            }
        }
        
        guard let input = videoWriterInput, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }
    
    private func setupVideoWriter(width: Int, height: Int, startTime: CMTime) -> Bool {
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let timestamp = Int(Date().timeIntervalSince1970)
        let videoPath = documentsPath.appendingPathComponent("recording_\(timestamp).mp4")
        
        try? FileManager.default.removeItem(at: videoPath)
        
        do {
            let writer = try AVAssetWriter(url: videoPath, fileType: .mp4)
            let dynamicBitrate = width * height * 4
            
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: dynamicBitrate,
                    AVVideoMaxKeyFrameIntervalKey: 30
                ]
            ]
            
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            input.expectsMediaDataInRealTime = true
            
            if writer.canAdd(input) {
                writer.add(input)
            } else {
                print("无法添加视频输入")
                return false
            }
            
            if writer.startWriting() {
                writer.startSession(atSourceTime: startTime)
                self.videoWriter = writer
                self.videoWriterInput = input
                return true
            } else {
                print("Writer startWriting 失败: \(String(describing: writer.error))")
                return false
            }
            
        } catch {
            print("初始化 Writer 异常: \(error.localizedDescription)")
            return false
        }
    }
    
    private func finalizeVideo(completion: @escaping (URL?) -> Void) {
        // 1. 检查 writer 和 input 是否存在
        guard let writer = videoWriter, let input = videoWriterInput else {
            print("Finalize: Writer 或 Input 为空")
            completion(nil)
            return
        }

        // 2. 只有在状态为 writing (status == 1) 时才能结束
        if writer.status == .writing {
            input.markAsFinished()
            
            // 关键修复：直接调用 finishWriting，不要在里面加复杂的判断
            writer.finishWriting {
                DispatchQueue.main.async {
                    if writer.status == .completed {
                        print("录制成功完成: \(writer.outputURL)")
                        completion(writer.outputURL)
                    } else {
                        print("录制失败，状态: \(writer.status.rawValue), 错误: \(String(describing: writer.error))")
                        completion(nil)
                    }
                    self.cleanupWriter()
                }
            }
        } else {
            print("警告：尝试结束录制时 Writer 状态不正确: \(writer.status.rawValue)")
            self.cleanupWriter()
            completion(nil)
        }
    }

    // 提取清理逻辑，确保资源释放
    private func cleanupWriter() {
        self.videoWriter = nil
        self.videoWriterInput = nil
        self.isWriterInitialized = false
    }

    
    private func startDurationTimer() {
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let startTime = self.startTime else { return }
            self.recordingDuration = Date().timeIntervalSince(startTime)
        }
    }
    
    private func stopDurationTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }
}

// MARK: - 模型管理器

class ModelManager: ObservableObject {
    @Published var currentModel: ModelEntity? = nil
    @Published var modelLoadError: String? = nil
    @Published var modelName: String = "未加载"
    
    func loadModel(from url: URL) async {
        do {
            guard url.startAccessingSecurityScopedResource() else {
                await MainActor.run {
                    self.modelLoadError = "无法访问文件"
                }
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            
            let entity = try await ModelEntity(contentsOf: url)
            entity.scale = SIMD3<Float>(repeating: 0.5)
            entity.position = SIMD3<Float>(0, 0, -3)
            entity.name = "UserModel" // 确保有名字，方便 ImmersiveView 查找和替换
            
            if entity.model?.materials.isEmpty == true {
                var material = SimpleMaterial()
                material.color = .init(tint: .white)
                entity.model?.materials = [material]
            }
            
            await MainActor.run {
                self.currentModel = entity
                self.modelName = url.lastPathComponent
            }
        } catch {
            await MainActor.run {
                self.modelLoadError = "加载失败: \(error.localizedDescription)"
            }
        }
    }
    
    func loadModelFromPicker(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let firstURL = urls.first {
                Task {
                    await loadModel(from: firstURL)
                }
            } else {
                modelLoadError = "未选择文件"
            }
        case .failure(let error):
            modelLoadError = "选择失败: \(error.localizedDescription)"
        }
    }
    
    func clearModel() {
        currentModel = nil
        modelName = "未加载"
    }
}

// MARK: - 录制指示器 (保持不变)

struct RecordingIndicator: View {
    let duration: TimeInterval
    @State private var isBlinking = false
    
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 12, height: 12)
                .opacity(isBlinking ? 1.0 : 0.3)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isBlinking)
            
            Text("录制中 \(formatDuration(duration))")
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.red.opacity(0.8))
        .cornerRadius(20)
        .onAppear {
            isBlinking = true
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - 沉浸式视图

struct ImmersiveView: View {
    @ObservedObject var modelManager: ModelManager
    @ObservedObject var recordingManager: ScreenRecordingManager
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    
    var body: some View {
        RealityView { content, attachments in
            // 创建地板
            let floor = MeshResource.generatePlane(width: 10, depth: 10)
            let floorMaterial = SimpleMaterial(
                color: UIColor(red: 0.8, green: 0.8, blue: 0.9, alpha: 1.0),
                isMetallic: false
            )
            let floorEntity = ModelEntity(mesh: floor, materials: [floorMaterial])
            floorEntity.position = SIMD3<Float>(0, -0.5, 0)
            content.add(floorEntity)
            
            // 添加光源
            let centralLight = PointLight()
            centralLight.light.intensity = 3000
            centralLight.light.attenuationRadius = 10
            centralLight.position = [0, 2, 0]
            content.add(centralLight)
            
            // 首次添加录制指示器附件实体（使用头部锚点固定）
            if let indicatorView = attachments.entity(for: "recordingIndicator") {
                let anchorEntity = AnchorEntity(.head)
                indicatorView.position = SIMD3<Float>(0, 0.15, -0.5)
                anchorEntity.addChild(indicatorView)
                content.add(anchorEntity)
            }
            
        }
        // ImmersiveView.swift -> update 闭包

        update: { content, attachments in
            // 1. 获取或创建随头动的容器
            let containerName = "InverseMovingContainer"
            var container = content.entities.first { $0.name == containerName }
            
            if container == nil {
                let headAnchor = AnchorEntity(.head)
                headAnchor.name = containerName
                content.add(headAnchor)
                container = headAnchor
            }
            
            // 2. 确保模型已加载
            if let model = modelManager.currentModel, container?.children.isEmpty == true {
                let cloned = model.clone(recursive: true)
                cloned.name = "MyVisualModel"
                container?.addChild(cloned)
            }
            
            // 3. 【核心修复】计算逆变换以锁定世界位置
            if let container = container, let modelEntity = container.findEntity(named: "MyVisualModel") {
                // 获取头部在世界中的实时变换
                let headMatrix = container.transformMatrix(relativeTo: nil)
                
                // 如果矩阵无效（全0），跳过本帧
                guard headMatrix.columns.3.w != 0 else { return }
                
                // 我们希望模型在世界坐标中的位置始终是 [0, 1.2, -2.0] (水平面以上1.2米，前方2米)
                var targetWorldMatrix = matrix_identity_float4x4
                targetWorldMatrix.columns.3 = [0, 1.2, -2.0, 1]
                
                // 计算公式：模型在容器内的本地变换 = 容器(头)世界变换的逆 * 目标世界变换
                let localMatrix = headMatrix.inverse * targetWorldMatrix
                
                modelEntity.setTransformMatrix(localMatrix, relativeTo: container)
            }
            
            // 录制指示器跟随头部（保持在视线上方）
            if recordingManager.isRecording, let indicator = attachments.entity(for: "recordingIndicator") {
                if indicator.parent == nil {
                    let indicatorAnchor = AnchorEntity(.head)
                    indicator.position = [0, 0.4, -0.8]
                    indicatorAnchor.addChild(indicator)
                    content.add(indicatorAnchor)
                }
            }
        }



        attachments: {
            // 关键：定义附件内容
            Attachment(id: "recordingIndicator") {
                if recordingManager.isRecording {
                    RecordingIndicator(duration: recordingManager.recordingDuration)
                        .glassBackgroundEffect()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .startRecordingInImmersive)) { _ in
            recordingManager.startRecording()
        }
    }
}


// MARK: - 主视图

struct ContentView: View {
    // 关键修复 4: 移除 @StateObject，使用 @ObservedObject 接收共享实例
    @ObservedObject var modelManager: ModelManager // 从 App 传入
    @StateObject private var recordingManager = ScreenRecordingManager.shared
    
    @State private var showSaveAlert: Bool = false
    @State private var savedVideoURL: URL? = nil
    
    @State private var showFilePicker = false
    @State private var isImmersiveSpaceOpen = false
    
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 30) {
                // ... (UI 保持不变)
                VStack(spacing: 10) {
                    Image(systemName: "video.badge.plus")
                        .font(.system(size: 60))
                        .foregroundColor(.blue)
                    
                    Text("沉浸式空间录制")
                        .font(.largeTitle)
                        .bold()
                    
                    Text("导入三维模型并在沉浸式空间中录制")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Divider()
                
                // 当前模型状态
                VStack(spacing: 15) {
                    Text("当前模型")
                        .font(.headline)
                    
                    if modelManager.currentModel != nil {
                        VStack(spacing: 8) {
                            Image(systemName: "cube.box.fill")
                                .font(.system(size: 40))
                                .foregroundColor(.green)
                            Text(modelManager.modelName)
                                .font(.body)
                            Text("已加载")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.green.opacity(0.1))
                        .cornerRadius(12)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "cube.box")
                                .font(.system(size: 40))
                                .foregroundColor(.gray)
                            Text("未加载模型")
                                .font(.body)
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.gray.opacity(0.1))
                        .cornerRadius(12)
                    }
                }
                
                // 功能按钮
                VStack(spacing: 15) {
                    Button(action: {
                        showFilePicker = true
                    }) {
                        Label("导入三维模型", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                    .disabled(isImmersiveSpaceOpen)
                    
                    Button(action: {
                        Task {
                            // 确保只有模型加载后才能进入
                            guard modelManager.currentModel != nil else { return }
                            
                            await openImmersiveSpace(id: "ImmersiveSpace")
                            isImmersiveSpaceOpen = true
                            
                        }
                    }) {
                        Label("进入沉浸式空间", systemImage: "visionpro")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(modelManager.currentModel == nil ? .gray : .purple) // 没模型时变灰
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                    .disabled(isImmersiveSpaceOpen || modelManager.currentModel == nil)
                    
                    if modelManager.currentModel != nil {
                        Button(action: {
                            modelManager.clearModel()
                        }) {
                            Label("清除模型", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(.red.opacity(0.2))
                                .foregroundColor(.red)
                                .cornerRadius(12)
                        }
                        .disabled(isImmersiveSpaceOpen)
                    }
                }
                
                // 新增/保留：在 ContentView 中提供退出沉浸式空间的按钮（当沉浸式已打开时显示）
                if isImmersiveSpaceOpen {
                    Button(action: {
                        Task {
                            if recordingManager.isRecording {
                                recordingManager.stopRecording { _ in }
                            }
                            await dismissImmersiveSpace()
                            // 主动同步状态
                            isImmersiveSpaceOpen = false
                        }
                    }) {
                        Label("退出沉浸式空间", systemImage: "escape")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.orange)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                }
                
                // 录制按钮区域（已从 ImmersiveView 移动到 ContentView）
                HStack(spacing: 16) {
                    if recordingManager.isRecording {
                        Button(action: {
                            // 停止录制并处理保存
                            recordingManager.stopRecording { url in
                                savedVideoURL = url
                                if let url = url {
                                    recordingManager.saveVideoToAlbum(url: url)
                                    showSaveAlert = true
                                } else {
                                    recordingManager.saveMessage = "视频文件创建失败或录制被中断，请检查错误信息"
                                    showSaveAlert = true
                                }
                            }
                        }) {
                            VStack(spacing: 4) {
                                Image(systemName: "stop.circle.fill")
                                    .font(.title)
                                Text("停止录制")
                                    .font(.caption)
                            }
                            .frame(width: 120, height: 60)
                            .background(.red.opacity(0.9))
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                    } else {
                        Button(action: {
                            // 如果当前处于沉浸式：通过通知让 ImmersiveView 在沉浸式上下文内调用 startRecording
                            if isImmersiveSpaceOpen {
                                NotificationCenter.default.post(name: .startRecordingInImmersive, object: nil)
                            } else {
                                // 普通界面直接启动录制
                                if !recordingManager.isRecording {
                                    recordingManager.startRecording()
                                }
                            }
                        }) {
                            VStack(spacing: 4) {
                                Image(systemName: "record.circle")
                                    .font(.title)
                                Text("开始录制")
                                    .font(.caption)
                            }
                            .frame(width: 120, height: 60)
                            .background(.regularMaterial)
                            .cornerRadius(12)
                        }
                    }
                    
                    // 可选：在 ContentView 中也显示录制状态指示
                    if recordingManager.isRecording {
                        RecordingIndicator(duration: recordingManager.recordingDuration)
                    }
                }
                
                Spacer()
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("提示:")
                        .font(.headline)
                    Text("• 如果录制按钮不切换，通常是因为 ReplayKit 内部状态残留，已添加自动修复。")
                    Text("• 如果依然失败，请检查 Xcode 的签名和功能设置 (Signing & Capabilities)。")
                    Text("• 完成录制后，视频将自动保存到系统【相册】。")
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .padding()
                .background(.gray.opacity(0.1))
                .cornerRadius(12)
                
                // 录制状态指示
            }
            .padding()
            .navigationTitle("录屏应用")
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.usdz, UTType(filenameExtension: "reality") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            modelManager.loadModelFromPicker(result: result)
        }
        .alert("发生错误", isPresented: .constant(
            recordingManager.errorMessage != nil ||
            modelManager.modelLoadError != nil
        )) {
            Button("确定") {
                recordingManager.errorMessage = nil
                modelManager.modelLoadError = nil
            }
        }
        // 录制结束/保存结果提示
        .alert("录制结束", isPresented: $showSaveAlert) {
            Button("确定") {
                savedVideoURL = nil
                recordingManager.saveMessage = nil
            }
        } message: {
            Text(recordingManager.saveMessage ?? "正在处理视频...")
        }
        .onChange(of: isImmersiveSpaceOpen) { _, newValue in
            if !newValue && recordingManager.isRecording {
                recordingManager.stopRecording { _ in }
            }
        }
    }
}

// MARK: - App 入口

@main
struct SimplifiedRecordingApp: App {
    // 唯一的 ModelManager 实例作为状态源
    @StateObject private var modelManager = ModelManager()
    @StateObject private var recordingManager = ScreenRecordingManager.shared

    var body: some SwiftUI.Scene {
        WindowGroup {
            // 关键修复 4: 将共享实例传入 ContentView
            ContentView(modelManager: modelManager)
        }
        
        ImmersiveSpace(id: "ImmersiveSpace") {
            ImmersiveView(
                modelManager: modelManager,
                recordingManager: recordingManager
            )
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
