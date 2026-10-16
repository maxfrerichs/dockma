import Testing
@testable import DockmaCore

@Test func cmdlineCarriesHomeAndConsole() {
    let cmdline = KernelCmdline.build(home: "/Users/max")
    #expect(cmdline.contains("console=hvc0"))
    #expect(cmdline.contains("rdinit=/init"))
    #expect(cmdline.contains("dockma.home=/Users/max"))
}

@Test func cmdlinePercentEncodesUnsafeCharacters() {
    #expect(KernelCmdline.percentEncoded("/Users/Jane Doe") == "/Users/Jane%20Doe")
    #expect(KernelCmdline.percentEncoded("/Users/jürgen") == "/Users/j%C3%BCrgen")
    #expect(KernelCmdline.percentEncoded("/Users/a.b_c-d") == "/Users/a.b_c-d")
    #expect(!KernelCmdline.build(home: "/Users/x y\"z").contains(" y"))
}
