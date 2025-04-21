# Minimal UI for llm chat without dependency

![](./assets/screenshot.png)

## Dev:
$ chmod +x main.swift
$ ./main.swift

## Build:
$ swiftc main.swift -o chat_swift

## Config:
Use your own config file located at `.config/chat.swift/config.json`

```json
{
    "models": {
        "openai": {
            "baseURL": "https://ark.cn-beijing.volces.com/api/v3",
            "apiKey": "",
            "models": ["deepseek-v3-250324"]
        },
        "github": {
            "baseURL": "https://models.inference.ai.azure.com/",
            "apiKey": "",
            "models": ["gpt-4o-mini", "gpt-4o", "gpt-4.1"]
        },
        "bailian": {
            "baseURL": "https://dashscope.aliyuncs.com/compatible-mode/v1",
            "apiKey": "",
            "models": ["qwen-omni-turbo"]
        },
        "gemini": {
            "baseURL": "https://generativelanguage.googleapis.com/v1beta/openai",
            "apiKey": "",
            "models": ["gemini-2.5-flash-preview-04-17", "gemini-2.5-pro-03-25"]
        }
    },
    "defaultModel": "deepseek-v3-250324"
} 
```

## shortcuts

example with [skhd](https://github.com/koekeishiya/skhd) or add Keyboard Shortcuts by System Settings

```
ctrl + alt + shift + cmd - k	:	chat_swift
```

## Feature:
- minimal chat UI
- always on top of desktop
- autoclose with last window
- support multiple models and remember the last model
- proxy for gemini
