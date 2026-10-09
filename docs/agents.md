# AI agents

Mouthy includes a local [MCP](https://modelcontextprotocol.io) server with one tool, `ask_user_dictation`. An agent such as Claude Code calls it with one or more questions; Mouthy shows them, records your spoken answer, and returns the text to the agent instead of typing it.

## Connect Claude Code

**Mac** (the exact command is also shown in Mouthy's Settings):

```sh
claude mcp add mouthy -- "$HOME/Library/Application Support/Mouthy/mcp-bridge.sh"
```

**Windows and Linux** (use the full path to `mouthy` or `mouthy.exe`; Settings shows it):

```sh
claude mcp add mouthy -- /path/to/mouthy --mcp-bridge
```

Other MCP clients work the same way: run the bridge as a stdio server.

## Answering

When an agent asks, the question appears in Mouthy's recording overlay (on the Mac, in the notch while the notch hub runs). Speak your answer and finish with your dictation shortcut; Escape cancels. The answer goes to the agent and is not typed into any app.

Agent questions can be turned off in Settings. On the Mac, Settings can also have Mouthy read each question aloud.

## How it is protected

The server listens only on this computer's loopback address (`127.0.0.1:51089`). Every request must be signed with a key stored in a file only your user account can read, and every reply is signed back, so:

- web pages cannot reach it (browsers also cannot send the headers it requires),
- other user accounts on the same computer cannot ask questions or pretend to be Mouthy,
- the bridge discards any reply that does not come from your Mouthy.

Programs running as your own user can read the key, as they can read your other files.
