import Foundation
import ImageIO
import CoreGraphics
import CryptoKit
let root = "native/Sources/DSHNativePet/Resources/Character"
var poses: [String:Any] = [:]
var outputs: [String:Any] = [:]
for name in try FileManager.default.contentsOfDirectory(atPath:root).filter({ $0.hasSuffix(".png") }).sorted() {
  let url=URL(fileURLWithPath:root).appendingPathComponent(name)
  let raw=try Data(contentsOf:url)
  let src=CGImageSourceCreateWithData(raw as CFData,nil)!
  let img=CGImageSourceCreateImageAtIndex(src,0,nil)!
  let w=img.width,h=img.height
  var data=[UInt8](repeating:0,count:w*h*4)
  data.withUnsafeMutableBytes { p in
    let c=CGContext(data:p.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.draw(img,in:CGRect(x:0,y:0,width:w,height:h))
  }
  var minX=w,minY=h,maxX=0,maxY=0,clear=0
  for y in 0..<h { for x in 0..<w {
    let a=data[(y*w+x)*4+3]
    if a==0 { clear += 1 }
    if a>200 { minX=min(minX,x);minY=min(minY,y);maxX=max(maxX,x);maxY=max(maxY,y) }
  }}
  var footMin=w,footMax=0
  for y in max(minY,maxY-(maxY-minY)/10)...maxY {for x in minX...maxX {
    if data[(y*w+x)*4+3]>200 {footMin=min(footMin,x);footMax=max(footMax,x)}
  }}
  let id=String(name.dropLast(4))
  poses[id]=["file":name,"width":w,"height":h,"visibleBounds":["x":minX,"y":minY,"width":maxX-minX+1,"height":maxY-minY+1],"anchor":["x":Double(footMin+footMax+1)/2.0/Double(w),"y":Double(maxY+1)/Double(h)]]
  outputs[name]=["sha256":SHA256.hash(data:raw).map{String(format:"%02x",$0)}.joined(),"width":w,"height":h,"hasAlpha":true,"transparentPixelCount":clear]
  print("\(name): \(w)x\(h), visible \(minX),\(minY)-\(maxX),\(maxY), foot x \(footMin)-\(footMax)")
}
let manifest:[String:Any]=["canvas":["width":1024,"height":1024],"coordinateSystem":"top-left","visibleBoundsAlphaThreshold":200,"poses":poses]
try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:root).appendingPathComponent("manifest.json"))
let refsRoot=URL(fileURLWithPath:"designs/two-head-q-girl/references")
var sources:[String:Any]=[:]
let enumerator=FileManager.default.enumerator(at:refsRoot,includingPropertiesForKeys:nil)!
for case let url as URL in enumerator {
  guard !url.hasDirectoryPath else {continue}
  let data=try Data(contentsOf:url)
  let path=String(url.path.dropFirst(refsRoot.path.count+1))
  sources[path]=["sha256":SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined(),"bytes":data.count]
}
let provenance:[String:Any]=["sourceDirectory":"/Users/jiaoguo/github/hanzi-evolution-atlas/designs/ip-assets/two-head-q-girl","referenceDirectory":"references","generationTool":"Codex built-in image_gen","generationDate":"2026-10-23","sources":sources,"outputs":outputs]
try JSONSerialization.data(withJSONObject:provenance,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"designs/two-head-q-girl/sources.json"))
