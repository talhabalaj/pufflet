func expect(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: " + message); exit(1) }
}

func receive(_ line: String, into report: inout SteamHostReport) {
    guard let event = SteamSessionEvent.parse(Data(line.utf8)) else { print("FAIL: dropped " + line); exit(1) }
    report.fields[event.key] = event.value
}

var report = SteamHostReport()
for line in ["install-request-result=0", "install-state=1030", "install-work-done-kib=18000", "install-work-total-kib=1380000", "install-no-progress=0"] {
    receive("[steam-host] pufflet2 request-id=1 app-id=480 " + line, into: &report)
}
expect(report.installWaitStatus == nil, "A progressing install shows its normal status")

receive("[steam-host] pufflet2 request-id=1 app-id=480 install-no-progress=1", into: &report)
expect(report.installWaitStatus?.hasPrefix("No recent progress") == true, "A long unpaused wait surfaces Stop and Retry guidance")
expect(!report.installComplete && report.fields["install-result"] == nil, "No progress never implies success or a terminal failure")

var verifying = report
receive("[steam-host] pufflet2 request-id=1 app-id=480 install-verifying=1", into: &verifying)
expect(verifying.installWaitStatus?.hasPrefix("Verification") == true, "Slow verification has distinct wording")

receive("[steam-host] pufflet2 request-id=1 app-id=480 install-work-done-kib=18001", into: &report)
receive("[steam-host] pufflet2 request-id=1 app-id=480 install-no-progress=0", into: &report)
expect(report.installWaitStatus == nil, "Dock clearing the status removes the notice")
expect(SteamSessionEvent.parse(Data("[steam-host] pufflet2 request-id=1 app-id=480 install-no-progress=x".utf8)) == nil, "Malformed values are still dropped")
print("PASS: install recovery regressions")
