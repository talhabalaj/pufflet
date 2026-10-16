import AppKit
import ApplicationServices
func attr(_ a: AXUIElement,_ k: String)->CFTypeRef?{var v:CFTypeRef?;AXUIElementCopyAttributeValue(a,k as CFString,&v);return v}
func walk(_ a: AXUIElement,_ depth:Int){
 let title=attr(a,"AXTitle") as? String ?? "";let desc=attr(a,"AXDescription") as? String ?? ""
 if (attr(a,"AXRole") as? String)=="AXDockItem",(title+desc).range(of:"Muck|wine|Steam|Pufflet|dockhost|explorer|services|winedevice|Crash",options:.regularExpression) != nil {
  print("title=\(title) description=\(desc) running=\(String(describing:attr(a,"AXIsApplicationRunning")))")
 }
 if depth<5, let children=attr(a,"AXChildren") as? [AXUIElement]{for child in children{walk(child,depth+1)}}
}
if let app=NSWorkspace.shared.runningApplications.first(where:{$0.bundleIdentifier=="com.apple.dock"}){walk(AXUIElementCreateApplication(app.processIdentifier),0)}
