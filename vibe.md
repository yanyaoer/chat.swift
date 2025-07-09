-- cc 07-09

> 使用 ReAct 方式集成mcp调用
  - 相关配置从 .config/chat.swift/mcp_server.json 读取服务信息
    配置示例：{ "mcpServers": { "mcp-video2text": { "command": "uv", "args": ["run", "mcp-video2text"] } } }
  - UI 显示 mcp 按钮，参考prompt列表，点击后展示当前已配置的 server 列表，可多选启用服务，并保存启用状态
    - 输出调用服务/工具的过程和结果 

> 从mcp服务输出的换行都没了，请优化一下输出的排版

> 参考 https://github.com/github/github-mcp-server/blob/main/docs/remote-server.md 使用 remote github mcp server 

-- gemini-cli 06-26

集成 https://github.com/modelcontextprotocol/swift-sdk.git 的mcp调用
- 相关配置从 .config/chat.swift/mcp_server.json 读取服务信息
  配置示例：{ "mcpServers": { "mcp-video2text": { "command": "uv", "args": ["run", "mcp-video2text"] } } }
- 通过 client.listTools / client.listResources 获取调用工具的说明信息
- UI 显示 mcp 按钮，参考prompt列表，点击后展示当前已配置的 server 列表，可多选启用服务，并保存启用状态
  - 输出调用服务/工具的过程和结果
