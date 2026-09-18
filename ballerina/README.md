## Overview

DeepSeek provides high-performance large language models (LLMs) optimized for various natural language processing tasks.

The DeepSeek connector offers APIs for connecting with DeepSeek Large Language Models (LLMs), enabling the integration of advanced conversational AI and language processing capabilities into applications.

### Key Features

- Connect and interact with DeepSeek Large Language Models (LLMs)
- Support for DeepSeek-V3, DeepSeek-Coder, and other models
- Efficient handling of conversational prompts and completions
- Secure communication with API key authentication
- Streaming responses, so the answer can be shown as it is produced

## Prerequisites

Before using this module in your Ballerina application, first you must obtain the necessary configuration to engage the LLM.



## Quickstart

To use the `ai.deepseek` module in your Ballerina application, update the `.bal` file as follows:

### Step 1: Import the module

Import the `ai.deepseek;` module.

```ballerina
import ballerinax/ai.deepseek;
```

### Step 2: Initialize the Model Provider

Here's how to initialize the Model Provider:

```ballerina
import ballerina/ai;
import ballerinax/ai.deepseek;

final ai:ModelProvider deepseekModel = check new deepseek:ModelProvider("deepseekApiKey");
```

### Step 3: Invoke chat completion

```ballerina
ai:ChatMessage[] chatMessages = [{role: "user", content: "hi"}];
ai:ChatAssistantMessage response = check deepseekModel->chat(chatMessages, tools = []);

chatMessages.push(response);
```

### Step 4: Stream the response

To show the answer as it is produced rather than waiting for all of it, use `generateAsStream` for
the generated text, or `chatAsStream` for the raw chunks:

```ballerina
stream<string, ai:Error?> fragments = check deepseekModel->generateAsStream(`Tell me about Ballerina`);
check from string fragment in fragments
    do {
        io:print(fragment);
    };
```

Each `ai:ChatMessageChunk` from `chatAsStream` carries `role` (always `ASSISTANT`), plus text,
reasoning and tool-call fragments, and the last one carries the finish reason. Tool-call fragments
are correlated by `index`, so a caller accumulates the arguments of each call across chunks.

`generateAsStream` streams text only, since a partial generation is a valid value only for `string`;
use `generate` for structured output. It also streams the answer text only - on `deepseek-reasoner`,
the chain-of-thought that precedes the answer is dropped. To observe it, use `chatAsStream` and read
`reasoning`:

```ballerina
final ai:ModelProvider reasoner = check new deepseek:ModelProvider("deepseekApiKey", deepseek:DEEPSEEK_REASONER);
stream<ai:ChatMessageChunk, ai:Error?> chunks =
    check reasoner->chatAsStream({role: ai:USER, content: "What is 6 times 7?"});
check from ai:ChatMessageChunk chunk in chunks
    do {
        io:print(chunk.reasoning ?: chunk.content ?: "");
    };
```
