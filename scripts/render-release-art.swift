import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let out = root.appendingPathComponent("docs/assets")
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(calibratedRed:r,green:g,blue:b,alpha:1) }
let ink = color(0.09,0.105,0.105), muted = color(0.37,0.41,0.40), paper = color(0.94,0.95,0.93), mint = color(0.54,0.88,0.73)
func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ size: CGFloat, _ weight: NSFont.Weight = .regular, _ c: NSColor = ink) {
    let p = NSMutableParagraphStyle(); p.lineSpacing = size * 0.07
    (s as NSString).draw(in: NSRect(x:x,y:y,width:width,height:size*5), withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:weight),.foregroundColor:c,.paragraphStyle:p])
}
func image(_ name: String, _ rect: NSRect) {
    NSImage(contentsOf:root.appendingPathComponent(name))!.draw(in:rect,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
}
func render(_ file: String, _ width: Int, _ height: Int, _ draw: () -> Void) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)!
    // Top-left coordinates for editorial composition.
    let t=NSAffineTransform();t.translateX(by:0,yBy:CGFloat(height));t.scaleX(by:1,yBy:-1);t.concat()
    NSGraphicsContext.current = NSGraphicsContext(cgContext:NSGraphicsContext.current!.cgContext,flipped:true)
    paper.setFill();NSRect(x:0,y:0,width:width,height:height).fill();draw()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using:.png,properties:[:])!.write(to:out.appendingPathComponent(file))
}
try render("hero.png",1920,1080) {
    image("Resources/app-icon.png",NSRect(x:74,y:64,width:104,height:104))
    text("UTUVO / ORBIT",204,90,650,27,.semibold)
    text("Your Mac.\nIn one\nsmall orbit.",94,248,1000,106,.semibold)
    text("Power. Network. Audio.\nOne compact icon. One useful panel.",100,670,900,30,.regular,muted)
    mint.setFill();NSRect(x:100,y:840,width:90,height:5).fill()
    text("NATIVE MACOS     /     MIT OPEN SOURCE",100,892,900,21,.medium,muted)
    text("0.4.1",100,974,600,19,.regular,muted)
    image("docs/assets/overview-dark-en.png",NSRect(x:1178,y:108,width:630,height:784))
    text("ACTUAL APP · DEMO DATA · macOS 27",1182,972,660,18,.medium,muted)
}
try render("social.png",1200,630) {
    image("Resources/app-icon.png",NSRect(x:47,y:38,width:84,height:84))
    text("UTUVO ORBIT",153,61,550,21,.semibold)
    text("Your Mac.\nOne small orbit.",56,200,710,63,.semibold)
    text("Power, network and audio.\nNative macOS. MIT open source.",60,389,650,23,.regular,muted)
    mint.setFill();NSRect(x:60,y:527,width:64,height:4).fill()
    text("0.4.1  /  DEMO DATA",60,555,600,16,.medium,muted)
    image("docs/assets/overview-dark-en.png",NSRect(x:804,y:64,width:356,height:443))
}
try render("dmg-background.png",720,460) {
    text("UTUVO Orbit",52,37,630,34,.semibold)
    text("Your Mac. In one small orbit.",54,91,610,17,.regular,muted)
    text("Drag Orbit into Applications.",54,366,650,22,.medium)
    text("macOS 14+ · Apple Silicon · 0.4.1",54,408,650,13,.regular,muted)
    let arrow=NSBezierPath();arrow.move(to:NSPoint(x:329,y:244));arrow.line(to:NSPoint(x:400,y:244));arrow.move(to:NSPoint(x:386,y:231));arrow.line(to:NSPoint(x:400,y:244));arrow.line(to:NSPoint(x:386,y:257));arrow.lineWidth=3;arrow.lineCapStyle = .round;muted.setStroke();arrow.stroke()
}
