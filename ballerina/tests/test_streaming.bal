// Copyright (c) 2025 WSO2 LLC (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/ai;
import ballerina/test;

const STREAM_SERVICE_URL = "http://localhost:8081/sse";
// Nothing listens on this port, so requests to it fail to connect.
const UNREACHABLE_SERVICE_URL = "http://localhost:8199";

isolated function streamProvider(string scenario) returns ModelProvider|ai:Error =>
    new (API_KEY, DEEPSEEK_CHAT, string `${STREAM_SERVICE_URL}/${scenario}`);

// Drains a chunk stream into a list, so a test can assert over the whole sequence.
isolated function collectChunks(stream<ai:ChatMessageChunk, ai:Error?> chunks)
        returns ai:ChatMessageChunk[]|ai:Error {
    ai:ChatMessageChunk[] collected = [];
    while true {
        record {|ai:ChatMessageChunk value;|}|ai:Error? next = chunks.next();
        if next is () {
            return collected;
        }
        if next is ai:Error {
            return next;
        }
        collected.push(next.value);
    }
}

// Concatenates every text fragment in a chunk sequence.
isolated function joinContent(ai:ChatMessageChunk[] chunks) returns string {
    string text = "";
    foreach ai:ChatMessageChunk chunk in chunks {
        text += chunk.content ?: "";
    }
    return text;
}

// Concatenates every reasoning fragment in a chunk sequence.
isolated function joinReasoning(ai:ChatMessageChunk[] chunks) returns string {
    string reasoning = "";
    foreach ai:ChatMessageChunk chunk in chunks {
        reasoning += chunk.reasoning ?: "";
    }
    return reasoning;
}

// The finish reason of the one chunk that carries it, or `()` when none does.
isolated function finishReasonOf(ai:ChatMessageChunk[] chunks) returns ai:FinishReason? {
    foreach ai:ChatMessageChunk chunk in chunks {
        ai:FinishReason? finishReason = chunk.finishReason;
        if finishReason is ai:FinishReason {
            return finishReason;
        }
    }
    return ();
}

@test:Config
function testChatAsStreamCollectsTextFragments() returns error? {
    ModelProvider model = check streamProvider("text");
    stream<ai:ChatMessageChunk, ai:Error?> chunkStream =
        check model->chatAsStream({role: ai:USER, content: "Say hello"});
    ai:ChatMessageChunk[] chunks = check collectChunks(chunkStream);

    test:assertEquals(joinContent(chunks), "Hello world");
    test:assertEquals(finishReasonOf(chunks), ai:STOP);
    test:assertEquals(chunks[0].id, "chat-1");
    // `role` must be set on every chunk, not only the first.
    foreach ai:ChatMessageChunk chunk in chunks {
        test:assertEquals(chunk.role, ai:ASSISTANT);
    }
}

@test:Config
function testChatAsStreamBindsChunksWithoutEnvelopeFields() returns error? {
    // A chunk type that required `id`, `object`, `created`, `model` or `system_fingerprint`
    // would fail to bind here, and the skip-on-failure path would hand the caller an empty
    // stream that looks successful.
    ModelProvider model = check streamProvider("minimal");
    stream<ai:ChatMessageChunk, ai:Error?> chunkStream =
        check model->chatAsStream({role: ai:USER, content: "Say hello"});
    ai:ChatMessageChunk[] chunks = check collectChunks(chunkStream);

    test:assertEquals(joinContent(chunks), "Lean envelope");
    test:assertEquals(finishReasonOf(chunks), ai:STOP);
}

@test:Config
function testChatAsStreamForwardsToolCallFragments() returns error? {
    ModelProvider model = check streamProvider("tools");
    stream<ai:ChatMessageChunk, ai:Error?> chunkStream =
        check model->chatAsStream({role: ai:USER, content: "Weather and time?"});
    ai:ChatMessageChunk[] chunks = check collectChunks(chunkStream);

    // Fragments must be forwarded on every chunk, not just the first, and stay correlated
    // by `index` so the caller can accumulate the arguments of each call.
    map<string> argumentsByIndex = {};
    map<string> namesByIndex = {};
    map<string> idsByIndex = {};
    foreach ai:ChatMessageChunk chunk in chunks {
        test:assertEquals(chunk.role, ai:ASSISTANT);
        ai:ToolCallChunk[]? toolCalls = chunk.toolCalls;
        if toolCalls is () {
            continue;
        }
        foreach ai:ToolCallChunk toolCall in toolCalls {
            string key = toolCall.index.toString();
            string? id = toolCall?.id;
            if id is string {
                idsByIndex[key] = id;
            }
            string? name = toolCall?.name;
            if name is string {
                namesByIndex[key] = name;
            }
            string? arguments = toolCall?.arguments;
            if arguments is string {
                argumentsByIndex[key] = (argumentsByIndex[key] ?: "") + arguments;
            }
        }
    }

    test:assertEquals(idsByIndex, {"0": "call_a", "1": "call_b"});
    test:assertEquals(namesByIndex, {"0": "getWeather", "1": "getTime"});
    test:assertEquals(argumentsByIndex, {"0": string `{"city":"Colombo"}`, "1": "{}"});
    test:assertEquals(finishReasonOf(chunks), ai:TOOL_CALLS);
}

@test:Config
function testChatAsStreamMapsReasoningContent() returns error? {
    ModelProvider model = check streamProvider("reasoning");
    stream<ai:ChatMessageChunk, ai:Error?> chunkStream =
        check model->chatAsStream({role: ai:USER, content: "What is 6 times 7?"});
    ai:ChatMessageChunk[] chunks = check collectChunks(chunkStream);

    test:assertEquals(joinReasoning(chunks), "Let me think about it");
    test:assertEquals(joinContent(chunks), "42");
}

@test:Config
function testChatAsStreamMapsUnknownFinishReasonToNil() returns error? {
    // DeepSeek's `insufficient_system_resource` has no `ai:FinishReason` counterpart; it must
    // map to `()` rather than panic on a cast.
    ModelProvider model = check streamProvider("unknownfinish");
    stream<ai:ChatMessageChunk, ai:Error?> chunkStream =
        check model->chatAsStream({role: ai:USER, content: "Say hello"});
    ai:ChatMessageChunk[] chunks = check collectChunks(chunkStream);

    test:assertEquals(joinContent(chunks), "Partial");
    test:assertEquals(finishReasonOf(chunks), ());
}

@test:Config
function testFinishReasonMapping() {
    test:assertEquals(mapFinishReason("stop"), ai:STOP);
    test:assertEquals(mapFinishReason("length"), ai:LENGTH);
    test:assertEquals(mapFinishReason("tool_calls"), ai:TOOL_CALLS);
    test:assertEquals(mapFinishReason("function_call"), ai:TOOL_CALLS);
    test:assertEquals(mapFinishReason("content_filter"), ai:CONTENT_FILTER);
    test:assertEquals(mapFinishReason("insufficient_system_resource"), ());
    test:assertEquals(mapFinishReason(()), ());
}

@test:Config
function testToAiChunkSkipsEventsWithNothingForTheCaller() {
    // No choices at all.
    test:assertEquals(toAiChunk({choices: []}), ());
    // A role-only opening delta with empty content.
    test:assertEquals(toAiChunk({choices: [{index: 0, delta: {content: ""}}]}), ());
    // A usage-only trailing chunk carries no choices.
    test:assertEquals(toAiChunk({choices: [], usage: {prompt_tokens: 1, completion_tokens: 1}}), ());

    ai:ChatMessageChunk expectedContent = {role: ai:ASSISTANT, content: "Hi"};
    test:assertEquals(toAiChunk({choices: [{index: 0, delta: {content: "Hi"}}]}), expectedContent);

    ai:ChatMessageChunk expectedFinish = {id: "c1", role: ai:ASSISTANT, finishReason: ai:STOP};
    test:assertEquals(toAiChunk({id: "c1", choices: [{index: 0, delta: {}, finish_reason: "stop"}]}), expectedFinish);
}

@test:Config
function testChatAsStreamSurfacesMidStreamError() returns error? {
    // Skipping the error frame would end the stream silently, handing the caller a truncated
    // answer that looks complete.
    ModelProvider model = check streamProvider("midstreamerror");
    stream<ai:ChatMessageChunk, ai:Error?> chunkStream =
        check model->chatAsStream({role: ai:USER, content: "Say hello"});
    ai:ChatMessageChunk[]|ai:Error result = collectChunks(chunkStream);

    if result is ai:ChatMessageChunk[] {
        test:assertFail("Expected the mid-stream error frame to fail the stream");
    }
    test:assertTrue(result.message().includes("Rate limit reached"),
            string `Expected the model's own message: ${result.message()}`);
}

@test:Config
function testChatAsStreamSurfacesMalformedFrame() returns error? {
    ModelProvider model = check streamProvider("malformed");
    stream<ai:ChatMessageChunk, ai:Error?> chunkStream =
        check model->chatAsStream({role: ai:USER, content: "Say hello"});
    ai:ChatMessageChunk[]|ai:Error result = collectChunks(chunkStream);

    if result is ai:ChatMessageChunk[] {
        test:assertFail("Expected an unparseable frame to fail the stream");
    }
    test:assertTrue(result is ai:LlmInvalidResponseError,
            string `Expected an invalid-response error: ${result.message()}`);
}

@test:Config
function testChatAsStreamSurfacesHttpErrorStatus() returns error? {
    ModelProvider model = check streamProvider("unauthorized");
    stream<ai:ChatMessageChunk, ai:Error?>|ai:Error result =
        model->chatAsStream({role: ai:USER, content: "Say hello"});

    if result !is ai:Error {
        test:assertFail("Expected a 401 to fail before the stream opens");
    }
    // The caller needs DeepSeek's own message, not just "the stream could not be opened".
    test:assertTrue(result.message().includes("401"), string `Expected the status: ${result.message()}`);
    test:assertTrue(result.message().includes("Authentication Fails"),
            string `Expected the API error message: ${result.message()}`);
}

@test:Config
function testChatAsStreamSurfacesInsufficientBalance() returns error? {
    ModelProvider model = check streamProvider("insufficientbalance");
    stream<ai:ChatMessageChunk, ai:Error?>|ai:Error result =
        model->chatAsStream({role: ai:USER, content: "Say hello"});

    if result !is ai:Error {
        test:assertFail("Expected a 402 to fail before the stream opens");
    }
    test:assertTrue(result.message().includes("Insufficient Balance"),
            string `Expected the API error message: ${result.message()}`);
}

@test:Config
function testChatAsStreamSurfacesConnectionFailure() returns error? {
    ModelProvider model = check new (API_KEY, DEEPSEEK_CHAT, UNREACHABLE_SERVICE_URL);
    stream<ai:ChatMessageChunk, ai:Error?>|ai:Error result =
        model->chatAsStream({role: ai:USER, content: "Say hello"});

    test:assertTrue(result is ai:LlmConnectionError,
            "Expected an 'LlmConnectionError' when the model is unreachable");
}

@test:Config
function testGenerateAsStreamProjectsTextFragments() returns error? {
    ModelProvider model = check streamProvider("text");
    stream<string, ai:Error?> fragments = check model->generateAsStream(`Say hello`);
    string text = "";
    check from string fragment in fragments
        do {
            text += fragment;
        };
    test:assertEquals(text, "Hello world");
}

@test:Config
function testGenerateAsStreamDropsReasoningFragments() returns error? {
    // Only the answer text is streamed; the chain-of-thought is not a partial answer.
    ModelProvider model = check streamProvider("reasoning");
    stream<string, ai:Error?> fragments = check model->generateAsStream(`What is 6 times 7?`);
    string text = "";
    check from string fragment in fragments
        do {
            text += fragment;
        };
    test:assertEquals(text, "42");
}

@test:Config
function testGenerateAsStreamSurfacesConnectionFailure() returns error? {
    ModelProvider model = check new (API_KEY, DEEPSEEK_CHAT, UNREACHABLE_SERVICE_URL);
    stream<string, ai:Error?>|ai:Error result = model->generateAsStream(`Say hello`);

    test:assertTrue(result is ai:LlmConnectionError,
            "Expected an 'LlmConnectionError' when the model is unreachable");
}
