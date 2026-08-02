// [FORK gmjain/AeroSpace]
public struct DumpTreeCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) {
        self.commonState = .init(rawArgs)
    }
    public static let parser: CmdParser<Self> = .init(
        kind: .dumpTree,
        help: dump_tree_help_generated,
        flags: [:],
        posArgs: [],
    )
}
