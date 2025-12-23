// ============================================================================
// visionOS 相对头部固定的3D模型录屏系统
// 实现效果：模型跟随头部，环境做反向运动，录屏中模型看起来固定
// ============================================================================

import SwiftUI
import RealityKit
import ReplayKit
import AVFoundation
import UniformTypeIdentifiers
import Foundation
import Combine
import VideoToolbox
import Photos

// 通知名称
extension Notification.Name {
    static let startRecordingInImmersive = Notification.Name("startRecordingInImmersive")
}

// MARK: - 录制管理器

class ScreenRecordingManager: ObservableObject {
    static let shared = ScreenRecordingManager()
    
    @Published var isRecording: Bool = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var errorMessage: String? = nil
    @Published var saveMessage: String? = nil
    
    private let recorder = RPScreenRecorder.shared()
    private var videoWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var startTime: Date?
    private var recordingTimer: Timer?
    private var isWriterInitialized = false
    
    private init() {
        recorder.isMicrophoneEnabled = false
    }
    
    func startRecording() {
        guard !isRecording else { return }
        
        if recorder.isRecording {
            print("警告:RPScreenRecorder 内部状态显示正在录制,尝试先停止。")
            recorder.stopCapture { error in
                DispatchQueue.main.async {
                    if let error = error {
                        print("强制停止失败: \(error.localizedDescription)")
                        self.errorMessage = "录制状态异常,强制停止失败: \(error.localizedDescription)"
                    } else {
                        print("强制停止成功,重新尝试启动录制。")
                        self.attemptStartCapture()
                    }
                }
            }
        } else {
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
                    self?.errorMessage = "启动失败: \(error.localizedDescription)"
                    self?.isRecording = false
                    print("RPScreenRecorder startCapture 失败: \(error.localizedDescription)")
                } else {
                    self?.isRecording = true
                    self?.startTime = Date()
                    self?.startDurationTimer()
                }
            }
        }
    }
    
    func stopRecording(completion: @escaping (URL?) -> Void) {
        stopDurationTimer()
        
        guard recorder.isRecording else {
            print("RPScreenRecorder 内部未在录制,执行状态清理。")
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
                    self.saveMessage = "没有相册权限,无法保存"
                }
            }
        }
    }
    
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
        guard let writer = videoWriter, let input = videoWriterInput else {
            print("Finalize: Writer 或 Input 为空")
            completion(nil)
            return
        }

        if writer.status == .writing {
            input.markAsFinished()
            
            writer.finishWriting {
                DispatchQueue.main.async {
                    if writer.status == .completed {
                        print("录制成功完成: \(writer.outputURL)")
                        completion(writer.outputURL)
                    } else {
                        print("录制失败,状态: \(writer.status.rawValue), 错误: \(String(describing: writer.error))")
                        completion(nil)
                    }
                    self.cleanupWriter()
                }
            }
        } else {
            print("警告:尝试结束录制时 Writer 状态不正确: \(writer.status.rawValue)")
            self.cleanupWriter()
            completion(nil)
        }
    }

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
            entity.name = "UserModel"
            
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

// MARK: - 录制指示器

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

// MARK: - 沉浸式视图（核心修改）

struct ImmersiveView: View {
    @ObservedObject var modelManager: ModelManager
    @ObservedObject var recordingManager: ScreenRecordingManager
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    
    var body: some View {
        RealityView { content, attachments in
            // 【核心1】创建环境容器（会做反向运动）
            let environmentContainer = Entity()
            environmentContainer.name = "EnvironmentContainer"
            content.add(environmentContainer)
            
            // 创建地板（加入环境容器）
            let floor = MeshResource.generatePlane(width: 10, depth: 10)
            let floorMaterial = SimpleMaterial(
                color: UIColor(red: 0.8, green: 0.8, blue: 0.9, alpha: 1.0),
                isMetallic: false
            )
            let floorEntity = ModelEntity(mesh: floor, materials: [floorMaterial])
            floorEntity.position = SIMD3<Float>(0, -0.5, 0)
            environmentContainer.addChild(floorEntity)
            
            // 添加光源（加入环境容器）
            let centralLight = PointLight()
            centralLight.light.intensity = 3000
            centralLight.light.attenuationRadius = 10
            centralLight.position = [0, 2, 0]
            environmentContainer.addChild(centralLight)
            
            // 【核心2】创建头部锚点容器（模型会跟随头部）
            // 模型直接添加到场景根节点（不是头部锚点）
            if let model = modelManager.currentModel {
                let cloned = model.clone(recursive: true)
                cloned.name = "UserModel"
                cloned.position = SIMD3<Float>(0, 1.2, -2.0)  // 初始世界位置
                content.add(cloned)  // 直接加到场景根部
            }

            // 【保留】头部锚点只用于录制指示器
            let headAnchor = AnchorEntity(.head)
            headAnchor.name = "HeadAnchor"
            content.add(headAnchor)

            if let indicatorView = attachments.entity(for: "recordingIndicator") {
                indicatorView.position = SIMD3<Float>(0, 0.15, -0.5)
                headAnchor.addChild(indicatorView)
            }
            
            // 添加录制指示器（跟随头部）
            if let indicatorView = attachments.entity(for: "recordingIndicator") {
                indicatorView.position = SIMD3<Float>(0, 0.15, -0.5)
                headAnchor.addChild(indicatorView)
            }
            
        }
        
        update: { content, attachments in
            // 1. 获取头部锚点（用于计算头部位置）
            guard let headAnchor = content.entities.first(where: { $0.name == "HeadAnchor" }) else {
                return
            }
            
            // 2. 确保模型已添加到场景（不是头部锚点的子节点）
            var modelEntity = content.entities.first(where: { $0.name == "UserModel" })
            
            if modelEntity == nil, let model = modelManager.currentModel {
                let cloned = model.clone(recursive: true)
                cloned.name = "UserModel"
                cloned.position = SIMD3<Float>(0, 1.2, -2.0)
                content.add(cloned)
                modelEntity = cloned
            }
            
            // 3. 【核心】计算头部移动量，让模型做反向移动
            if let modelEntity = modelEntity {
                // 获取头部在世界坐标系中的位置
                let headWorldTransform = headAnchor.transformMatrix(relativeTo: nil)
                let headWorldPosition = SIMD3<Float>(
                    headWorldTransform.columns.3.x,
                    headWorldTransform.columns.3.y,
                    headWorldTransform.columns.3.z
                )
                
                // 模型的目标位置 = 初始位置 + 头部移动量
                // 这样录屏时，模型看起来跟着头移动
                let targetPosition = SIMD3<Float>(0, 1.2, -2.0) - headWorldPosition * 1000000
                
                modelEntity.position = targetPosition
            }
            
            // 4. 更新录制指示器（跟随头部）
            if recordingManager.isRecording, let indicator = attachments.entity(for: "recordingIndicator") {
                if indicator.parent == nil {
                    indicator.position = [0, 0.15, -0.5]
                    headAnchor.addChild(indicator)
                }
            }
        }


        
        attachments: {
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
    @ObservedObject var modelManager: ModelManager
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
                            guard modelManager.currentModel != nil else { return }
                            
                            await openImmersiveSpace(id: "ImmersiveSpace")
                            isImmersiveSpaceOpen = true
                        }
                    }) {
                        Label("进入沉浸式空间", systemImage: "visionpro")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(modelManager.currentModel == nil ? .gray : .purple)
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
                
                if isImmersiveSpaceOpen {
                    Button(action: {
                        Task {
                            if recordingManager.isRecording {
                                recordingManager.stopRecording { _ in }
                            }
                            await dismissImmersiveSpace()
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
                
                // 录制按钮区域
                HStack(spacing: 16) {
                    if recordingManager.isRecording {
                        Button(action: {
                            recordingManager.stopRecording { url in
                                savedVideoURL = url
                                if let url = url {
                                    recordingManager.saveVideoToAlbum(url: url)
                                    showSaveAlert = true
                                } else {
                                    recordingManager.saveMessage = "视频文件创建失败或录制被中断,请检查错误信息"
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
                            if isImmersiveSpaceOpen {
                                NotificationCenter.default.post(name: .startRecordingInImmersive, object: nil)
                            } else {
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
                    
                    if recordingManager.isRecording {
                        RecordingIndicator(duration: recordingManager.recordingDuration)
                    }
                }
                
                Spacer()
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("使用说明:")
                        .font(.headline)
                    Text("• 模型会跟随您的头部移动")
                    Text("• 环境会做反向运动,录屏中模型看起来固定")
                    Text("• 您可以自由走动观察模型,效果会实时更新")
                    Text("• 完成录制后,视频将自动保存到【相册】")
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .padding()
                .background(.gray.opacity(0.1))
                .cornerRadius(12)
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
    @StateObject private var modelManager = ModelManager()
    @StateObject private var recordingManager = ScreenRecordingManager.shared

    var body: some SwiftUI.Scene {
        WindowGroup {
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
