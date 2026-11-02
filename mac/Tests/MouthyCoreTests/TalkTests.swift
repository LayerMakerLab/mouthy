import Foundation
import Testing
@testable import MouthyCore

private func object(_ json: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
}

@Test func geminiKeyTravelsInTheHeaderNotTheURL() {
    let format = GeminiLiveFormat(TalkSessionConfiguration())
    let request = format.request(apiKey: "test-key-123")
    #expect(request.url?.absoluteString == "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")
    #expect(request.url?.query == nil)
    #expect(!(request.url?.absoluteString.contains("test-key-123") ?? true))
    #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "test-key-123")
}

@Test func geminiSetupMatchesTheLiveReference() throws {
    let configuration = TalkSessionConfiguration(voice: "Kore", instructions: "Answer briefly.")
    #expect(configuration.model == "gemini-3.8-live")
    let messages = GeminiLiveFormat(configuration).openingMessages()
    #expect(messages.count == 1)
    let setup = try #require(object(messages[0])["setup"] as? [String: Any])
    #expect(object(messages[0]).count == 1)
    #expect(setup["model"] as? String == "models/gemini-3.8-live")
    let generation = try #require(setup["generationConfig"] as? [String: Any])
    #expect(generation["responseModalities"] as? [String] == ["AUDIO"])
    let voice = ((generation["speechConfig"] as? [String: Any])?["voiceConfig"] as? [String: Any])?["prebuiltVoiceConfig"] as? [String: Any]
    #expect(voice?["voiceName"] as? String == "Kore")
    let parts = (setup["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]]
    #expect(parts?.first?["text"] as? String == "Answer briefly.")
    #expect((setup["inputAudioTranscription"] as? [String: Any])?.isEmpty == true)
    #expect((setup["outputAudioTranscription"] as? [String: Any])?.isEmpty == true)
}

@Test func geminiSetupLeavesOutWhatTheHostDidNotAskFor() throws {
    let configuration = TalkSessionConfiguration(model: "models/gemini-3.1-flash-live-preview", voice: "", instructions: "  \n", transcribe: false)
    let setup = try #require(object(GeminiLiveFormat(configuration).openingMessages()[0])["setup"] as? [String: Any])
    #expect(setup["model"] as? String == "models/gemini-3.1-flash-live-preview")
    #expect((setup["generationConfig"] as? [String: Any])?["speechConfig"] == nil)
    #expect(setup["systemInstruction"] == nil)
    #expect(setup["inputAudioTranscription"] == nil && setup["outputAudioTranscription"] == nil)
}

@Test func geminiAudioMessageIsBase64PCMAt16kHz() throws {
    let pcm = PCM16.encode([0, 0.5, -0.5, 1] as [Float])
    let message = object(GeminiLiveFormat(TalkSessionConfiguration()).audioMessage(pcm))
    let audio = try #require((message["realtimeInput"] as? [String: Any])?["audio"] as? [String: Any])
    #expect(audio["mimeType"] as? String == "audio/pcm;rate=16000")
    #expect(Data(base64Encoded: audio["data"] as? String ?? "") == pcm)
}

@Test func geminiServerMessagesBecomeEvents() {
    var format = GeminiLiveFormat(TalkSessionConfiguration())
    #expect(format.read(#"{"setupComplete":{}}"#) == [.ready])
    let speech = Data([1, 0, 2, 0, 3, 0])
    let audio = #"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":""# + speech.base64EncodedString() + #""}}]}}}"#
    #expect(format.read(audio) == [.audio(speech)])
    #expect(format.read(#"{"serverContent":{"inputTranscription":{"text":" What time"}}}"#) == [.transcript(.user, " What time")])
    #expect(format.read(#"{"serverContent":{"outputTranscription":{"text":"It is noon."}}}"#) == [.transcript(.model, "It is noon.")])
    #expect(format.read(#"{"serverContent":{"outputTranscription":{"finished":true}}}"#) == [.transcriptFinished(.model)])
    #expect(format.read(#"{"serverContent":{"interrupted":true}}"#) == [.interrupted])
    #expect(format.read(#"{"serverContent":{"generationComplete":true}}"#) == [])
    #expect(format.read(#"{"goAway":{"timeLeft":"10s"}}"#) == [.closing("Gemini will end the connection in 10s.")])
    // Usage may ride along with another field; it is read before the turn completes so the turn's report counts.
    let usage = #"{"usageMetadata":{"promptTokenCount":120,"responseTokenCount":80,"totalTokenCount":200,"cachedContentTokenCount":7,"promptTokensDetails":[{"modality":"AUDIO","tokenCount":100},{"modality":"TEXT","tokenCount":20}],"responseTokensDetails":[{"modality":"AUDIO","tokenCount":75}]},"serverContent":{"turnComplete":true}}"#
    #expect(format.read(usage) == [.usage(TalkTokenCounts(input: 120, output: 80, total: 200, inputAudio: 100, outputAudio: 75, cachedInput: 7)), .turnComplete])
}

@Test func geminiIgnoresWhatItCannotRead() {
    var format = GeminiLiveFormat(TalkSessionConfiguration())
    #expect(format.read("not json") == [])
    #expect(format.read(#"{"toolCall":{"functionCalls":[]}}"#) == [])
    #expect(format.read(#"{"serverContent":{"modelTurn":{"parts":[{"text":"thinking"},{"inlineData":{"mimeType":"image/png","data":"AAAA"}}]}}}"#) == [])
}

@Test func pcm16IsLittleEndianAndClamped() {
    let data = PCM16.encode([1, -1, 2, -2, .nan, 0.5] as [Float])
    #expect(Array(data) == [0xFF, 0x7F, 0x00, 0x80, 0xFF, 0x7F, 0x00, 0x80, 0x00, 0x00, 0xFF, 0x3F])
    let back = PCM16.decode(data)
    #expect(back.count == 6 && abs(back[5] - 0.5) < 0.001 && back[1] == -1)
    #expect(PCM16.seconds(bytes: 32_000, sampleRate: 16_000) == 1)
    #expect(PCM16.seconds(bytes: 48_000, sampleRate: 24_000) == 1)
    #expect(PCM16.level(PCM16.encode([Float](repeating: 0, count: 100))) == 0)
    #expect(PCM16.level(PCM16.encode([Float](repeating: 0.1, count: 100))) > 0.5)
}

@Test func transcriptKeepsOneOpenTurnPerSide() {
    var transcript = TalkTranscript()
    transcript.append("What's the", from: .user)
    transcript.append("It's", from: .model)
    // The user's words arrive late, after the model started: they still join the user's turn.
    transcript.append(" weather?", from: .user)
    transcript.append(" sunny.", from: .model)
    #expect(transcript.turns.map(\.text) == ["What's the weather?", "It's sunny."])
    #expect(transcript.turns.map(\.role) == [.user, .model])
    // Barge-in ends the model's turn only; the person is still talking.
    transcript.append("Stop,", from: .user)
    #expect(transcript.turns.count == 2)
    transcript.complete(.model)
    transcript.append(" and the rain?", from: .model)
    #expect(transcript.turns.count == 3 && transcript.turns[2].text == " and the rain?")
    transcript.completeAll()
    transcript.append("Thanks.", from: .user)
    #expect(transcript.turns.count == 4 && transcript.turns.last?.text == "Thanks." && transcript.turns.last?.isComplete == false)
    #expect(Set(transcript.turns.map(\.id)).count == 4)
}

@Test func usageCountsTheLastReportOfEachTurn() {
    var meter = TalkUsageMeter(provider: .geminiLive, model: "gemini-3.8-live")
    meter.sent(bytes: 32_000 * 3, sampleRate: 16_000)
    meter.received(bytes: 48_000 * 2, sampleRate: 24_000)
    #expect(meter.total.tokens == nil)
    meter.report(TalkTokenCounts(input: 10, output: 5, total: 15))
    meter.report(TalkTokenCounts(input: 12, output: 6, total: 18))
    meter.endTurn()
    meter.report(TalkTokenCounts(input: 30, output: 10, total: 40, inputAudio: 25))
    // A turn still open at the end is counted.
    let usage = meter.total
    #expect(usage.secondsSent == 3 && usage.secondsReceived == 2)
    #expect(usage.tokens == TalkTokenCounts(input: 42, output: 16, total: 58, inputAudio: 25))
    #expect(usage.provider == .geminiLive && usage.model == "gemini-3.8-live")
}

@Test func openAIKeyTravelsInTheAuthorizationHeader() {
    let format = OpenAIRealtimeFormat(TalkSessionConfiguration(provider: .openAIRealtime))
    let request = format.request(apiKey: "test-key-123")
    #expect(request.url?.absoluteString == "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1")
    #expect(!(request.url?.absoluteString.contains("test-key-123") ?? true))
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + "test-key-123")
    // The GA interface takes no beta header.
    #expect(request.value(forHTTPHeaderField: "OpenAI-Beta") == nil)
    #expect(format.inputSampleRate == 24_000 && format.outputSampleRate == 24_000)
}

@Test func openAISessionUpdateMatchesTheGAShape() throws {
    let configuration = TalkSessionConfiguration(provider: .openAIRealtime, voice: "marin", instructions: "Answer briefly.")
    let messages = OpenAIRealtimeFormat(configuration).openingMessages()
    #expect(messages.count == 1)
    let update = object(messages[0])
    #expect(update["type"] as? String == "session.update")
    let session = try #require(update["session"] as? [String: Any])
    #expect(session["type"] as? String == "realtime")
    #expect(session["model"] as? String == "gpt-realtime-2.1")
    #expect(session["output_modalities"] as? [String] == ["audio"])
    #expect(session["instructions"] as? String == "Answer briefly.")
    let audio = try #require(session["audio"] as? [String: Any])
    let input = try #require(audio["input"] as? [String: Any]), output = try #require(audio["output"] as? [String: Any])
    for side in [input, output] {
        let format = side["format"] as? [String: Any]
        #expect(format?["type"] as? String == "audio/pcm" && format?["rate"] as? Int == 24_000)
    }
    let turns = try #require(input["turn_detection"] as? [String: Any])
    #expect(turns["type"] as? String == "server_vad" && turns["create_response"] as? Bool == true && turns["interrupt_response"] as? Bool == true)
    #expect((input["transcription"] as? [String: Any])?["model"] as? String == "gpt-4o-mini-transcribe")
    #expect(output["voice"] as? String == "marin")

    let bare = object(OpenAIRealtimeFormat(TalkSessionConfiguration(provider: .openAIRealtime, transcribe: false)).openingMessages()[0])
    let bareSession = try #require(bare["session"] as? [String: Any])
    #expect(bareSession["instructions"] == nil)
    let bareAudio = bareSession["audio"] as? [String: Any]
    #expect((bareAudio?["input"] as? [String: Any])?["transcription"] == nil && (bareAudio?["output"] as? [String: Any])?["voice"] == nil)
}

@Test func openAIEventsBecomeTalkEvents() {
    var format = OpenAIRealtimeFormat(TalkSessionConfiguration(provider: .openAIRealtime))
    let audio = PCM16.encode([Float](repeating: 0.1, count: 2_400))
    #expect(format.audioMessage(audio) == #"{"type":"input_audio_buffer.append","audio":""# + audio.base64EncodedString() + #""}"#)
    #expect(format.read(#"{"type":"session.created","session":{}}"#) == [])
    #expect(format.read(#"{"type":"error","error":{"type":"invalid_request_error","message":"Invalid voice."}}"#) == [.failure("Invalid voice.")])
    #expect(format.read(#"{"type":"session.updated","session":{}}"#) == [.ready])
    #expect(format.read(#"{"type":"session.updated","session":{}}"#) == [])
    #expect(format.read(#"{"type":"error","error":{"message":"Cancellation failed: no active response found"}}"#) == [.notice("Cancellation failed: no active response found")])
    #expect(format.read(#"{"type":"response.output_audio.delta","item_id":"item_1","delta":""# + audio.base64EncodedString() + #""}"#) == [.audio(audio)])
    #expect(format.read(#"{"type":"response.output_audio_transcript.delta","delta":"Hello"}"#) == [.transcript(.model, "Hello")])
    #expect(format.read(#"{"type":"response.output_audio_transcript.done","transcript":"Hello"}"#) == [.transcriptFinished(.model)])
    #expect(format.read(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"item_0","delta":"Hi"}"#) == [.transcript(.user, "Hi")])
    #expect(format.read(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item_0","transcript":"Hi"}"#) == [.transcriptFinished(.user)])
    // A transcription model that sends no deltas still gets its words in.
    #expect(format.read(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item_2","transcript":"Thanks"}"#) == [.transcript(.user, "Thanks"), .transcriptFinished(.user)])
    #expect(format.read(#"{"type":"input_audio_buffer.speech_started","audio_start_ms":900,"item_id":"item_3"}"#) == [.interrupted])
    let done = #"{"type":"response.done","response":{"status":"completed","usage":{"total_tokens":253,"input_tokens":132,"output_tokens":121,"input_token_details":{"text_tokens":119,"audio_tokens":13,"cached_tokens":64},"output_token_details":{"text_tokens":30,"audio_tokens":91}}}}"#
    #expect(format.read(done) == [.usage(TalkTokenCounts(input: 132, output: 121, total: 253, inputAudio: 13, outputAudio: 91, cachedInput: 64)), .turnComplete])
    #expect(format.read(#"{"type":"rate_limits.updated","rate_limits":[]}"#) == [])
}

@Test func openAITruncatesTheItemToWhatWasHeard() throws {
    var format = OpenAIRealtimeFormat(TalkSessionConfiguration(provider: .openAIRealtime))
    _ = format.read(#"{"type":"session.updated","session":{}}"#)
    // 1.5 s of speech arrives for item_7; the person cuts in with 0.6 s still queued.
    for _ in 0..<3 {
        let half = PCM16.encode([Float](repeating: 0.1, count: 12_000))
        _ = format.read(#"{"type":"response.output_audio.delta","item_id":"item_7","delta":""# + half.base64EncodedString() + #""}"#)
    }
    let messages = format.interruptionMessages(unplayedSeconds: 0.6)
    #expect(messages.count == 1)
    let truncate = object(try #require(messages.first))
    #expect(truncate["type"] as? String == "conversation.item.truncate")
    #expect(truncate["item_id"] as? String == "item_7" && truncate["content_index"] as? Int == 0)
    #expect(truncate["audio_end_ms"] as? Int == 900)
    // Nothing more to truncate, and nothing when all of it was heard.
    #expect(format.interruptionMessages(unplayedSeconds: 0.6).isEmpty)
    _ = format.read(#"{"type":"response.output_audio.delta","item_id":"item_8","delta":"AAAA"}"#)
    #expect(format.interruptionMessages(unplayedSeconds: 0).isEmpty)
    // Gemini keeps no client-side truncation.
    var gemini = GeminiLiveFormat(TalkSessionConfiguration())
    #expect(gemini.interruptionMessages(unplayedSeconds: 1).isEmpty)
}
