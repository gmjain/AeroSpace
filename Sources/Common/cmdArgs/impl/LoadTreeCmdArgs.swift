// [FORK gmjain/AeroSpace]
public struct LoadTreeCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) {
        self.commonState = .init(rawArgs)
    }
    public static let parser: CmdParser<Self> = .init(
        kind: .loadTree,
        help: load_tree_help_generated,
        flags: [
            // The CLI forwards stdin only for commands that opt in (see Cli/_main.swift);
            // without this flag `aerospace load-tree < f` reached the server with empty stdin.
            "--stdin": ArgParser(\.commonState.explicitStdinFlag, constSubArgParserFun(true)),
            "--no-stdin": ArgParser(\.commonState.explicitStdinFlag, constSubArgParserFun(false)),
        ],
        posArgs: [],
        conflictingOptions: [
            ["--stdin", "--no-stdin"],
        ],
    )
}
