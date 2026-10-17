import Testing
@testable import DockmaCore

@Test func cmdlineCarriesHomeAndConsole() {
    let cmdline = KernelCmdline.build(home: "/Users/max", state: "/Users/max/.dockma")
    #expect(cmdline.contains("console=hvc0"))
    #expect(cmdline.contains("rdinit=/init"))
    #expect(cmdline.contains("panic=5"))
    #expect(cmdline.contains("dockma.home=/Users/max "))
    #expect(cmdline.hasSuffix("dockma.state=/Users/max/.dockma"))
}

@Test func cmdlinePercentEncodesUnsafeCharacters() {
    #expect(KernelCmdline.percentEncoded("/Users/Jane Doe") == "/Users/Jane%20Doe")
    #expect(KernelCmdline.percentEncoded("/Users/jürgen") == "/Users/j%C3%BCrgen")
    #expect(KernelCmdline.percentEncoded("/Users/a.b_c-d") == "/Users/a.b_c-d")
    #expect(!KernelCmdline.build(home: "/Users/x y\"z", state: "/Users/x y\"z/.dockma").contains(" y"))
}
