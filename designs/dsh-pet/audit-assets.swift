import Foundation
import AVFoundation
import ImageIO
import CoreGraphics
import CryptoKit

// 原始 MOV 保持字节不变；仅解码首帧、扫描所有帧的 alpha 包络。
let root = URL(fileURLWithPath: "native/Sources/DSHNativePet/Resources/DSHPet")
let auditURL = URL(fileURLWithPath: "designs/dsh-pet/animation-audit.json")
let poseNames = ["idle", "thinking", "working", "waiting", "completed", "error", "poke", "drag", "sleeping"]
struct Bounds: Codable {
    var x: Int; var y: Int; var width: Int; var height: Int
    func union(_ other: Bounds) -> Bounds {
        let left = min(x, other.x), top = min(y, other.y)
        return Bounds(x:left, y:top, width:max(x+width,other.x+other.width)-left, height:max(y+height,other.y+other.height)-top)
    }
    var dict: [String:Int] { ["x":x,"y":y,"width":width,"height":height] }
}
func hash(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
var audit: [String:Any] = [:]
var globalBounds: Bounds?
var canvasWidth = 0, canvasHeight = 0
var idleFootX = 0.5, idleFootY = 1.0
for pose in poseNames {
    let url = root.appendingPathComponent(pose+".mov")
    let asset = AVURLAsset(url:url)
    let track = try await asset.loadTracks(withMediaType:.video)[0]
    let duration = try await asset.load(.duration)
    let reader = try AVAssetReader(asset:asset)
    let output = AVAssetReaderTrackOutput(track:track, outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else { fatalError("Cannot read \(pose): \(String(describing: reader.error))") }
    var union: Bounds?
    var posterBounds: Bounds?
    var frames = 0, minimumTransparent = Int.max, minAlpha = 255, maxAlpha = 0
    var frameHashes = Set<String>()
    while let sample = output.copyNextSampleBuffer() {
        autoreleasepool {
            let pixel = CMSampleBufferGetImageBuffer(sample)!
            CVPixelBufferLockBaseAddress(pixel,.readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixel,.readOnly) }
            let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
            let stride = CVPixelBufferGetBytesPerRow(pixel)
            let ptr = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to:UInt8.self)
            var left = width, top = height, right = -1, bottom = -1, transparent = 0
            for y in 0..<height { for x in 0..<width {
                let alpha = Int(ptr[y*stride+x*4+3])
                minAlpha = min(minAlpha,alpha); maxAlpha = max(maxAlpha,alpha)
                if alpha == 0 { transparent += 1 }
                if alpha > 200 { left=min(left,x);right=max(right,x);top=min(top,y);bottom=max(bottom,y) }
            } }
            guard right >= left, bottom >= top else { fatalError("Empty frame \(pose) \(frames)") }
            let bounds = Bounds(x:left,y:top,width:right-left+1,height:bottom-top+1)
            union = union.map { $0.union(bounds) } ?? bounds
            minimumTransparent = min(minimumTransparent,transparent)
            // 三个时间点的完整解码像素哈希用于证实内容随时间变化。
            if frames % 30 == 0 { frameHashes.insert(hash(Data(bytes:ptr,count:stride*height))) }
            if frames == 0 {
                posterBounds = bounds
                if canvasWidth == 0 { canvasWidth=width;canvasHeight=height }
                precondition(canvasWidth == width && canvasHeight == height,"Canvas mismatch")
                let data = Data(bytes:ptr,count:stride*height)
                let provider = CGDataProvider(data:data as CFData)!
                let cg = CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:stride,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
                let dest = CGImageDestinationCreateWithURL(root.appendingPathComponent(pose+".png") as CFURL,"public.png" as CFString,1,nil)!
                CGImageDestinationAddImage(dest,cg,nil)
                precondition(CGImageDestinationFinalize(dest))
                if pose == "idle" {
                    var footLeft=width,footRight=0
                    for y in max(top,bottom-(bottom-top)/10)...bottom { for x in left...right {
                        if ptr[y*stride+x*4+3] > 200 { footLeft=min(footLeft,x);footRight=max(footRight,x) }
                    } }
                    idleFootX = Double(footLeft+footRight+1)/2/Double(width)
                    idleFootY = Double(bottom+1)/Double(height)
                }
            }
            frames += 1
        }
    }
    guard reader.status == .completed else { fatalError("Incomplete read \(pose): \(String(describing:reader.error))") }
    let bounds = union!
    globalBounds = globalBounds.map { $0.union(bounds) } ?? bounds
    let movData = try Data(contentsOf:url), pngData = try Data(contentsOf:root.appendingPathComponent(pose+".png"))
    audit[pose] = ["width":canvasWidth,"height":canvasHeight,"frameCount":frames,"durationSeconds":CMTimeGetSeconds(duration),"posterBounds":posterBounds!.dict,"videoBounds":bounds.dict,"minimumFullyTransparentPixelsPerFrame":minimumTransparent,"alphaRange":[minAlpha,maxAlpha],"uniqueSampledFrameHashes":frameHashes.count,"videoSha256":hash(movData),"videoBytes":movData.count,"posterSha256":hash(pngData),"posterBytes":pngData.count]
    print("\(pose): \(canvasWidth)x\(canvasHeight), \(frames)frames, alpha \(minAlpha)...\(maxAlpha), bbox \(bounds), poster \(posterBounds!), distinct \(frameHashes.count)")
}
let shared = globalBounds!
var poses: [String:Any] = [:]
for pose in poseNames {
    poses[pose] = ["file":pose+".png","video":pose+".mov","width":canvasWidth,"height":canvasHeight,"visibleBounds":shared.dict,"anchor":["x":idleFootX,"y":idleFootY]]
}
let referenceHeight = (audit["idle"] as! [String:Any])["posterBounds"] as! [String:Int]
let manifest: [String:Any] = ["referenceHeight":referenceHeight["height"]!,"canvas":["width":canvasWidth,"height":canvasHeight],"coordinateSystem":"top-left","visibleBoundsAlphaThreshold":200,"poses":poses]
let report: [String:Any] = ["referenceHeight":referenceHeight["height"]!,"referenceHeightBasis":"idle first decoded frame visible bounds height at alpha > 200","decoder":"AVFoundation AVAssetReader, 32BGRA","alphaThreshold":200,"scan":"every decoded video frame","sharedVisibleBounds":shared.dict,"sharedAnchor":["x":idleFootX,"y":idleFootY],"poses":audit]
try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("manifest.json"))
try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:auditURL)
print("Shared \(shared); idle foot \(idleFootX),\(idleFootY)")
