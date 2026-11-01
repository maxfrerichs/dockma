import Testing
@testable import DockmaCore

@Test func cmdlineCarriesHomeAndConsole() {
    let cmdline = KernelCmdline.commandLine(home: "/Users/max", state: "/Users/max/.dockma", timeZone: "Europe/Berlin")
    #expect(cmdline.contains("console=hvc0"))
    #expect(cmdline.contains("rdinit=/init"))
    #expect(cmdline.contains("panic=5"))
    #expect(cmdline.contains("rcupdate.rcu_expedited=1"))
    #expect(cmdline.contains("dockma.home=/Users/max "))
    #expect(cmdline.contains("dockma.state=/Users/max/.dockma "))
    #expect(cmdline.hasSuffix("dockma.timezone=Europe/Berlin"))
}

@Test func cmdlinePercentEncodesUnsafeCharacters() {
    #expect(KernelCmdline.percentEncoded("/Users/Jane Doe") == "/Users/Jane%20Doe")
    #expect(KernelCmdline.percentEncoded("/Users/jürgen") == "/Users/j%C3%BCrgen")
    #expect(KernelCmdline.percentEncoded("/Users/a.b_c-d") == "/Users/a.b_c-d")
    #expect(KernelCmdline.percentEncoded("Etc/GMT+1") == "Etc/GMT%2B1")
    #expect(!KernelCmdline.commandLine(home: "/Users/x y\"z", state: "/Users/x y\"z/.dockma", timeZone: "UTC").contains(" y"))
}
