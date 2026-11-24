import XCTest
@testable import LocalLectureSTT

final class SpeechSegmentationTests: XCTestCase {
    private func silence(_ ms: Int) -> [Float] { Array(repeating: 0, count: ms * 16) }
    private func voice(_ ms: Int) -> [Float] {
        (0..<(ms * 16)).map { Float(0.15 * sin(2 * .pi * 220 * Double($0) / 16_000)) }
    }

    func testShortUtterancesHaveExactPrefixAndSilenceDeadline() throws {
        var segmenter = UtteranceSegmenter()
        XCTAssertTrue(try segmenter.append(silence(700) + voice(120) + silence(780), at: 0).isEmpty)
        let partial = try XCTUnwrap(segmenter.openWindow())
        XCTAssertEqual(partial.boundary, .open)
        XCTAssertEqual(partial.mediaStart.rawValue, 400)
        XCTAssertEqual(partial.audio.duration.rawValue, 1_200)
        let closed = try XCTUnwrap(segmenter.append(silence(20), at: 1_600 * 16).only)
        XCTAssertEqual(closed.boundary, .silence)
        XCTAssertEqual(closed.audio.samples, silence(300) + voice(120) + silence(800))
        XCTAssertNil(try segmenter.openWindow())
        let next = try XCTUnwrap(segmenter.append(voice(80) + silence(800), at: closed.endFrame).only)
        XCTAssertEqual(next.mediaStart.rawValue, 1_320)
        XCTAssertEqual(next.overlapFrames, 0)
        XCTAssertTrue(try segmenter.flush().isEmpty)
    }

    func testTwoPhrasesWithAShortPauseRemainInOneWindow() throws {
        var segmenter = UtteranceSegmenter()
        let samples = voice(140) + silence(760) + voice(200) + silence(800)
        let window = try XCTUnwrap(segmenter.append(samples, at: 0).only)
        XCTAssertEqual(window.audio.samples, samples)
        XCTAssertEqual(window.mediaStart.rawValue, 0)
        XCTAssertEqual(window.audio.duration.rawValue, 1_900)
    }

    func testContinuousSpeechSplitsAtTwentySecondsAndKeepsExactOverlappingPCM() throws {
        let offset: Int64 = 1_920_007
        let samples = voice(41_337)
        var segmenter = UtteranceSegmenter()
        var windows = try segmenter.append(samples, at: offset)
        windows += try segmenter.flush()
        XCTAssertEqual(windows.map(\.startFrame), [offset, offset + 304_000, offset + 608_000])
        XCTAssertEqual(windows.map(\.audio.frameCount), [320_000, 320_000, samples.count - 608_000])
        XCTAssertEqual(windows.map(\.overlapFrames), [0, 16_000, 16_000])
        XCTAssertEqual(windows.map(\.boundary), [.maximumDuration, .maximumDuration, .flush])
        for w in windows {
            let start = Int(w.startFrame - offset)
            XCTAssertEqual(w.audio.samples, Array(samples[start..<(start + w.audio.frameCount)]))
        }
        var chunked = UtteranceSegmenter()
        var other: [SpeechWindow] = []
        for i in stride(from: 0, to: samples.count, by: 997) {
            other += try chunked.append(Array(samples[i..<min(i + 997, samples.count)]), at: offset + Int64(i))
        }
        other += try chunked.flush()
        XCTAssertEqual(other.map(\.audio), windows.map(\.audio))
        XCTAssertEqual(other.map(\.mediaStart), windows.map(\.mediaStart))
    }

    func testLengthCutFollowedBySilenceOrFlushDoesNotRepeatOverlap() throws {
        var segmenter = UtteranceSegmenter()
        XCTAssertEqual(try segmenter.append(voice(19_600) + silence(400), at: 0).only?.boundary, .maximumDuration)
        XCTAssertNil(try segmenter.openWindow())
        XCTAssertTrue(try segmenter.append(silence(400), at: 320_000).isEmpty)
        XCTAssertTrue(try segmenter.flush().isEmpty)
        XCTAssertEqual(try segmenter.append(voice(20_000), at: 400_000).count, 1)
        XCTAssertTrue(try segmenter.flush().isEmpty)
    }

    func testNoiseFloorAdaptsAndLongSilenceProducesNoWindows() throws {
        var seed: UInt32 = 8
        let noise = (0..<32_000).map { _ -> Float in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return (Float(seed) / Float(UInt32.max) - 0.5) * 0.12
        }
        var segmenter = UtteranceSegmenter()
        // After the room noise estimate rises, a much quieter coherent tone stays below it.
        XCTAssertTrue(try segmenter.append(noise + Array(repeating: 0.014, count: 3_200), at: 0).isEmpty)
        XCTAssertNil(try segmenter.openWindow())
        let actual = try segmenter.append(voice(200) + silence(60_000), at: 35_200)
        XCTAssertEqual(actual.only?.mediaStart.rawValue, 1_900)
        XCTAssertEqual(actual.only?.audio.duration.rawValue, 1_300)
        XCTAssertNil(try segmenter.openWindow())
    }

    func testRepeatedLoudFricativesDoNotMaskTheFollowingQuietVowels() {
        var detector = AdaptiveEnergyVAD()
        let fricative: [Float] = (0..<320).map { $0.isMultiple(of: 2) ? 0.4 : -0.4 }
        let vowel = voice(20).map { $0 * 0.25 }
        let quiet = silence(20)
        for _ in 0..<40 {
            for _ in 0..<5 { XCTAssertFalse(detector.isSpeech(fricative)) }
            for _ in 0..<15 { XCTAssertTrue(detector.isSpeech(vowel)) }
            for _ in 0..<4 { XCTAssertFalse(detector.isSpeech(quiet)) }
        }
    }

    func testGapFlushesPendingFramesAndInvalidInputDoesNotMoveClock() throws {
        struct AlwaysSpeech: VoiceActivityDetector {
            func isSpeech(_ frame: [Float]) -> Bool { true }
            func reset() {}
        }
        var segmenter = UtteranceSegmenter(detector: AlwaysSpeech())
        let original = Array(repeating: Float.zero, count: 333)
        XCTAssertTrue(try segmenter.append(original, at: 24).isEmpty)
        for offset: Int64 in [-1, 356, .max] {
            XCTAssertThrowsError(try segmenter.append([0], at: offset))
        }
        XCTAssertThrowsError(try segmenter.append([.nan], at: 357))
        let old = try XCTUnwrap(segmenter.append([Float](repeating: 0, count: 31), at: 80_000).only)
        XCTAssertEqual(old.boundary, .discontinuity)
        XCTAssertEqual(old.mediaStart.rawValue, 2)
        XCTAssertEqual(old.audio.samples, original)
        let last = try XCTUnwrap(segmenter.flush().only)
        XCTAssertEqual(last.startFrame, 80_000)
        XCTAssertEqual(last.audio.frameCount, 31)
        XCTAssertEqual(last.overlapFrames, 0)
        XCTAssertTrue(try segmenter.flush().isEmpty)
    }

    private let ko = try! LanguageCode("ko")

    private func splitWindows() throws -> [SpeechWindow] {
        var segmenter = UtteranceSegmenter()
        let closed = try segmenter.append(voice(21_000), at: 0)
        return try closed + segmenter.flush()
    }

    private func result(_ window: SpeechWindow, _ spans: [(Int64, Int64, String)], session: STTSessionConfiguration,
                        kind: STTResponseKind = .final) throws -> STTResponse {
        let request = try STTInferenceRequest(session: session, requestID: .init(UUID()), sequence: window.startFrame,
                                              mediaStart: window.mediaStart, audio: window.audio)
        return try STTResponse(context: request.context, revision: 1, kind: kind, segments: spans.map {
            try STTHypothesisSegment(start: MediaMilliseconds($0.0), end: MediaMilliseconds($0.1), text: $0.2)
        })
    }

    func testKoreanSpacingAndEnglishCaseDeduplicateAcrossHypothesisBoundaries() throws {
        let windows = try splitWindows(), session = try STTTestFixture.session()
        let old = try result(windows[0], [(17_000, 19_450, "오늘은 신경망"), (19_450, 20_000, "Swift API.")], session: session)
        let new = try result(windows[1], [(19_010, 19_440, "신경 망"), (19_440, 20_500, "swift api, 다시"), (20_500, 21_000, "정리합니다.")], session: session)
        var reconciler = TranscriptReconciler(session: session)
        let first = try reconciler.reconcile(old, for: windows[0], language: ko)
        let second = try reconciler.reconcile(new, for: windows[1], language: ko)
        XCTAssertEqual((first + second).map(\.text), ["오늘은 신경망", "Swift API.", "다시", "정리합니다."])
        XCTAssertEqual(second.map(\.originalText), second.map(\.text))
        XCTAssertEqual((first + second).map(\.sequence.rawValue), [0, 1, 2, 3])
        XCTAssertEqual(second.map(\.startMs.rawValue), [19_440, 20_500])
        XCTAssertEqual(second.map(\.endMs.rawValue), [20_500, 21_000])
        XCTAssertTrue(try reconciler.reconcile(new, for: windows[1], language: ko).isEmpty)
        var replay = TranscriptReconciler(session: session)
        XCTAssertEqual(try replay.reconcile(old, for: windows[0], language: ko), first)
        XCTAssertEqual(try replay.reconcile(new, for: windows[1], language: ko), second)
        XCTAssertEqual(Set((first + second).map(\.id)).count, 4)
    }

    func testRepeatedSpeechWithDistinctTimingAndPartialKoreanWordsArePreserved() throws {
        let w = try splitWindows(), session = try STTTestFixture.session()
        for (old, new, start, expected) in [
            ("반복", "반복", 19_500, "반복"),     // distinct times within copied audio
            ("반복", "반복", 20_100, "반복"),     // beyond the overlap
            ("설정", "정답", 19_100, "정답"),     // partial word collision
            ("대형 신경 모델", "새 용어", 19_100, "새 용어")
        ] {
            var reconciler = TranscriptReconciler(session: session)
            _ = try reconciler.reconcile(result(w[0], [(19_000, 19_400, old)], session: session), for: w[0], language: ko)
            let next = try result(w[1], [(Int64(start), 21_000, new)], session: session)
            XCTAssertEqual(try reconciler.reconcile(next, for: w[1], language: ko).only?.text, expected)
        }
    }

    func testIdenticalOverlapIsSuppressedButFollowingRepetitionSurvives() throws {
        let w = try splitWindows(), session = try STTTestFixture.session()
        var reconciler = TranscriptReconciler(session: session)
        _ = try reconciler.reconcile(result(w[0], [(19_200, 20_000, "네 네")], session: session), for: w[0], language: ko)
        let next = try result(w[1], [(19_200, 20_000, "네 네"), (20_100, 21_000, "네 네")], session: session)
        XCTAssertEqual(try reconciler.reconcile(next, for: w[1], language: ko).map(\.text), ["네 네"])
    }

    func testRepeatedOverlapCanEndBeforeThePreviousFinalHypothesis() throws {
        let w = try splitWindows(), session = try STTTestFixture.session()
        var reconciler: any TranscriptReconciling = TranscriptReconciler(session: session)
        let first = try result(w[0], [(19_000, 19_500, "선형 대수"), (19_500, 20_000, "정리")], session: session)
        _ = try reconciler.reconcile(first, for: w[0], language: ko)
        let next = try result(w[1], [(19_020, 19_450, "선형 대수"), (20_100, 21_000, "새 문장")], session: session)
        let additions = try reconciler.reconcile(next, for: w[1], language: ko)
        XCTAssertEqual(additions.only?.text, "새 문장")
        XCTAssertEqual(additions.only?.sequence.rawValue, 2)
    }

    func testSeparateUtterancesCanRepeatAndEmptyFinalConsumesNoSequence() throws {
        var segmenter = UtteranceSegmenter()
        let phrase = voice(200) + silence(800)
        let windows = try segmenter.append(phrase + phrase + phrase, at: 0)
        XCTAssertEqual(windows.count, 3)
        let session = try STTTestFixture.session()
        var reconciler = TranscriptReconciler(session: session)
        for (i, window) in windows.enumerated() {
            let start = Int64(i * 1_000)
            let next = try result(window, i == 1 ? [] : [(start, start + 200, "같은 문장")], session: session)
            let additions = try reconciler.reconcile(next, for: window, language: ko)
            XCTAssertEqual(additions.map(\.sequence.rawValue), i == 1 ? [] : [i == 0 ? 0 : 1])
        }
        let old = try result(windows[0], [(0, 200, "늦은 결과")], session: session)
        XCTAssertThrowsError(try reconciler.reconcile(old, for: windows[0], language: ko))
    }

    private typealias TimedText = (Int64, Int64, String)

    private func additions(old: [TimedText], new: [TimedText]) throws -> [TranscriptSegment] {
        let windows = try splitWindows(), session = try STTTestFixture.session()
        var reconciler = TranscriptReconciler(session: session)
        let previous = try result(windows[0], old, session: session)
        _ = try reconciler.reconcile(previous, for: windows[0], language: ko)
        let incoming = try result(windows[1], new, session: session)
        let added = try reconciler.reconcile(incoming, for: windows[1], language: ko)
        XCTAssertTrue(try reconciler.reconcile(incoming, for: windows[1], language: ko).isEmpty)
        return added
    }

    func testTenMillisecondsOfSharedAudioPreservesRepeatedUtterance() throws {
        let added = try additions(old: [(19_450, 20_000, "다시")], new: [(19_990, 20_820, "다시")])
        XCTAssertEqual(added.map(\.text), ["다시"])
        XCTAssertEqual(added.first?.startMs.rawValue, 19_990)
        XCTAssertEqual(added.first?.endMs.rawValue, 20_820)
        // A short previous interval inside a long, mostly new hypothesis is also ambiguous.
        let broad = try additions(old: [(19_950, 20_000, "다시")], new: [(19_950, 20_900, "다시")])
        XCTAssertEqual(broad.map(\.text), ["다시"])
    }

    func testTimedDuplicateBetweenNovelSegmentsKeepsBothNeighbors() throws {
        let added = try additions(old: [(19_400, 19_800, "기울기")], new: [
            (19_080, 19_300, "먼저"), (19_400, 19_800, "기울기"), (20_500, 21_000, "다음")
        ])
        XCTAssertEqual(added.map(\.text), ["먼저", "다음"])
        XCTAssertEqual(added.map(\.sequence.rawValue), [1, 2])
        XCTAssertEqual(added.map(\.startMs.rawValue), [19_080, 20_500])
    }

    func testKoreanParticleAttachedToLatinTermAndDetachedPunctuation() throws {
        for (old, new) in [("API를 호출합니다.", "API 를 호출합니다."), ("API 를 호출합니다.", "api를 호출합니다 ."),
                           ("맞습니다.", "맞습니다 .")] {
            let added = try additions(old: [(19_000, 19_800, old)],
                                      new: [(19_000, 19_800, new), (20_500, 21_000, "다음")])
            XCTAssertEqual(added.map(\.text), ["다음"])
        }
        let partial = try additions(old: [(19_100, 19_800, "API를 호출합니다.")],
                                    new: [(19_100, 20_250, "api 를 호출합니다 . C++ 3.14")])
        XCTAssertEqual(partial.map(\.originalText), ["C++ 3.14"])
        let different = try additions(old: [(19_100, 19_800, "API")], new: [(19_100, 19_800, "API를")])
        XCTAssertEqual(different.map(\.text), ["API를"])
        let detached = try additions(old: [(19_000, 19_800, "맞습니다.")], new: [
            (19_000, 19_780, "맞습니다"), (19_780, 19_800, "."), (20_500, 21_000, "다음")
        ])
        XCTAssertEqual(detached.map(\.text), ["다음"])
        let rejoined = try additions(old: [(19_000, 19_780, "맞습니다"), (19_780, 19_800, ".")],
                                     new: [(19_000, 19_800, "맞습니다."), (20_500, 21_000, "다음")])
        XCTAssertEqual(rejoined.map(\.text), ["다음"])
        let term = try additions(old: [(19_000, 19_800, "NET")], new: [(19_000, 19_800, ".NET")])
        XCTAssertEqual(term.map(\.text), [".NET"])
    }

    func testTimingEvidenceAcrossSplitOrMergedHypothesesIsConsumedOnce() throws {
        let merged = try additions(old: [(19_000, 19_300, "첫째"), (19_300, 19_700, "둘째")],
                                   new: [(19_020, 19_680, "첫째 둘째"), (20_200, 20_500, "셋째")])
        XCTAssertEqual(merged.map(\.text), ["셋째"])
        let split = try additions(old: [(19_100, 19_900, "말")],
                                  new: [(19_100, 19_500, "말"), (19_500, 19_900, "말")])
        XCTAssertEqual(split.map(\.text), ["말"])
    }

    func testSameSentenceWithAWordMovedAcrossSegmentBoundariesIsEmittedOnce() throws {
        let old: [TimedText] = [(19_000, 19_400, "선형 대수"), (19_400, 19_800, "입니다")]
        for (start, split, end): (Int64, Int64, Int64) in [(19_000, 19_400, 19_800), (19_010, 19_390, 19_790)] {
            let incoming: [TimedText] = [(start, split, "선형"), (split, end, "대수 입니다")]
            let added = try additions(old: old, new: incoming + [(20_200, 20_700, "다음")])
            XCTAssertEqual(added.map(\.text), ["다음"])
            XCTAssertEqual(added.last?.sequence.rawValue, 2)
        }
        // The same sentence spoken again outside the copied audio must survive.
        let repeatAtNewTime = try additions(old: old, new: [(20_100, 20_500, "선형"), (20_500, 20_900, "대수 입니다")])
        XCTAssertEqual(repeatAtNewTime.map(\.text), ["선형", "대수 입니다"])
        let novelSuffix = try additions(old: [(19_000, 19_400, "앞말 선형 대수"), (19_400, 19_800, "입니다")],
                                        new: [(19_010, 19_390, "선형"), (19_390, 19_790, "대수 입니다 다음")])
        XCTAssertEqual(novelSuffix.map(\.originalText), ["다음"])
    }

    func testResegmentedRepeatedWordsAreConsumedOnceInEitherDirection() throws {
        let windows = try splitWindows(), session = try STTTestFixture.session()
        var partitions = [["네"]]
        for word in ["네", "선형", "대수", "입니다"] {
            partitions = partitions.flatMap { parts in
                var joined = parts
                joined[joined.count - 1] += " " + word
                return [joined, parts + [word]]
            }
        }
        func spans(_ parts: [String], at start: Int64) -> [TimedText] {
            parts.enumerated().map { i, text in
                (start + Int64(800 * i / parts.count), start + Int64(800 * (i + 1) / parts.count), text)
            }
        }
        for old in partitions {
            var baseline = TranscriptReconciler(session: session)
            _ = try baseline.reconcile(result(windows[0], spans(old, at: 19_000), session: session), for: windows[0], language: ko)
            for new in partitions {
                for start: Int64 in [19_000, 19_010] {
                    var reconciler = baseline
                    let final = try result(windows[1], spans(new, at: start) + [(20_100, 20_900, "네")], session: session)
                    let added = try reconciler.reconcile(final, for: windows[1], language: ko)
                    XCTAssertEqual(added.map(\.text), ["네"], "\(old) vs \(new), start \(start)")
                    XCTAssertEqual(added.last?.startMs.rawValue, 20_100)
                }
            }
        }
    }

    func testTrimmingAPrefixRequiresTimingEvidenceEvenWithFollowingWords() throws {
        let short: [TimedText] = [(19_950, 20_000, "다시")]
        for phrase in ["다시", "다시 확인합니다"] {
            let added = try additions(old: short, new: [(19_950, 20_900, phrase)])
            XCTAssertEqual(added.map(\.originalText), [phrase])
            XCTAssertEqual(added.first?.startMs.rawValue, 19_950)
            XCTAssertEqual(added.first?.endMs.rawValue, 20_900)
        }
        let supported = try additions(old: [(19_100, 19_900, "다시")], new: [(19_100, 20_100, "다시 확인합니다")])
        XCTAssertEqual(supported.map(\.text), ["확인합니다"])
        // Strong evidence for an adjacent word cannot cover this phrase's missing audio.
        let neighbors = try additions(old: [(19_000, 19_950, "먼저"), (19_950, 20_000, "다시")],
                                      new: [(19_000, 19_950, "먼저"), (19_950, 20_900, "다시 확인합니다")])
        XCTAssertEqual(neighbors.map(\.text), ["다시 확인합니다"])
        // Even inside the new interval, time from unrelated old words cannot support a cut.
        let unrelated = try additions(old: [(19_000, 19_950, "다른 설명"), (19_950, 20_000, "다시")],
                                      new: [(19_100, 20_700, "다시 확인합니다")])
        XCTAssertEqual(unrelated.map(\.text), ["다시 확인합니다"])
    }

    func testAdjacentOldSegmentsJointlySupportAMergedIncomingPrefix() throws {
        let incoming: [TimedText] = [(19_060, 20_100, "선형 대수 입니다 다음")]
        for start: Int64 in [18_930, 18_940] {
            let old: [TimedText] = [(start, 19_180, "앞말 선형"), (19_180, 19_910, "대수 입니다")]
            let added = try additions(old: old, new: incoming)
            XCTAssertEqual(added.map(\.text), ["다음"], "old start \(start)")
            XCTAssertEqual(added.map(\.originalText), ["다음"])
            XCTAssertEqual(added.map(\.sequence.rawValue), [2])
            XCTAssertEqual(added.map(\.startMs.rawValue), [19_060])
            XCTAssertEqual(added.map(\.endMs.rawValue), [20_100])
            let repeated = try additions(old: old, new: incoming + [(20_110, 20_400, "선형 대수 입니다")])
            XCTAssertEqual(repeated.map(\.text), ["다음", "선형 대수 입니다"])
            XCTAssertEqual(repeated.last?.startMs.rawValue, 20_110)
        }
    }

    func testBlankAndCommaIntervalsCannotSupplyMissingWordCoverage() throws {
        let phrase = "다시 확인합니다"
        let incoming: [TimedText] = [(19_150, 19_850, phrase), (20_110, 20_400, phrase)]
        // The words cover 20 + 30 ms of the first incoming hypothesis. Its middle 650 ms is a gap.
        let gaps: [[TimedText]] = [[], [(19_170, 19_820, " ")], [(19_170, 19_820, ",")]]
        let wordPairs: [(TimedText, TimedText)] = [
            ((18_800, 19_170, "앞말 다시"), (19_820, 20_000, "확인합니다")), // suffix of the old text
            ((19_150, 19_170, "다시"), (19_820, 19_850, "확인합니다"))    // whole phrase on both sides
        ]
        for (first, last) in wordPairs {
            for gap in gaps {
                let added = try additions(old: [first] + gap + [last], new: incoming)
                XCTAssertEqual(added.map(\.text), [phrase, phrase], "\(first), gap \(gap)")
                XCTAssertEqual(added.map(\.originalText), [phrase, phrase])
                XCTAssertEqual(added.map(\.startMs.rawValue), [19_150, 20_110])
                XCTAssertEqual(added.map(\.endMs.rawValue), [19_850, 20_400])
            }
        }
    }

    func testDetachedCommaCannotInvalidateMatchedWordCoverage() throws {
        let repeatPhrase: TimedText = (20_110, 20_400, "선형 대수 입니다")
        let merged: [TimedText] = [(19_060, 20_100, "선형 대수 입니다 다음"), repeatPhrase]
        let commas: [TimedText] = [(19_180, 19_180, ","), (19_180, 19_190, ","), (19_190, 19_200, ",")]
        for comma in commas {
            let old: [TimedText] = [(18_930, 19_180, "앞말 선형"), comma, (comma.1, 19_910, "대수 입니다")]
            let added = try additions(old: old, new: merged)
            XCTAssertEqual(added.map(\.text), ["다음", repeatPhrase.2], "comma \(comma)")
            XCTAssertEqual(added.map(\.startMs.rawValue), [19_060, 20_110])
        }
        // Move the point comma to the incoming decode. Its timestamp still supplies no speech.
        let split: [TimedText] = [(19_060, 19_180, "선형"), (19_180, 19_180, ","),
                                  (19_180, 19_910, "대수 입니다 다음"), repeatPhrase]
        let added = try additions(old: [(19_060, 19_910, "선형 대수 입니다")], new: split)
        XCTAssertEqual(added.map(\.text), ["다음", repeatPhrase.2])
        XCTAssertEqual(added.map(\.startMs.rawValue), [19_180, 20_110])
    }

    func testPointCommaInsideMatchedPhraseFollowsTheWordMatch() throws {
        let comma: TimedText = (19_180, 19_180, ",")
        let pointSpace: TimedText = (19_180, 19_180, " ")
        let cases: [(firstEnd: Int64, marks: [TimedText], lastStart: Int64)] = [
            (19_180, [pointSpace, comma], 19_180),
            (19_170, [comma], 19_190)
        ]
        for (firstEnd, marks, lastStart) in cases {
            let prefix = [(19_060, firstEnd, "선형")] + marks
            let old = prefix + [(lastStart, 19_910, "대수 입니다")]
            let incoming = prefix + [(lastStart, 19_910, "대수 입니다 다음")]
            let added = try additions(old: old, new: incoming)
            XCTAssertEqual(added.map(\.text), ["다음"], "first word ends at \(firstEnd)")
            XCTAssertEqual(added.map(\.originalText), ["다음"])
            XCTAssertEqual(added.map(\.startMs.rawValue), [lastStart])
            XCTAssertEqual(added.map(\.endMs.rawValue), [19_910])
            XCTAssertEqual(added.map(\.sequence.rawValue), [3])
        }
    }

    func testPointCommaAndLeadingCommaAreInterchangeableInEitherWindow() throws {
        func spellings(_ tail: String) -> [[TimedText]] {
            let first: TimedText = (19_060, 19_170, "선형")
            return [
                [first, (19_180, 19_180, " "), (19_180, 19_180, ","), (19_190, 19_910, tail)],
                [first, (19_190, 19_910, ", " + tail)],
                [first, (19_190, 19_910, "," + tail)]
            ]
        }
        for old in spellings("대수 입니다") {
            for incoming in spellings("대수 입니다 다음") {
                let added = try additions(old: old, new: incoming)
                XCTAssertEqual(added.map(\.text), ["다음"], "old \(old), incoming \(incoming)")
                XCTAssertEqual(added.map(\.originalText), ["다음"])
                XCTAssertEqual(added.map(\.startMs.rawValue), [19_190])
                XCTAssertEqual(added.map(\.endMs.rawValue), [19_910])
            }
        }
    }

    func testLeadingCommaPreservesWeaklyOverlappingSpeechAndLaterRepeat() throws {
        let old: [TimedText] = [(19_150, 19_170, "다시"), (19_170, 19_820, ","), (19_820, 19_850, "확인합니다")]
        for phrase in [", 다시 확인합니다", ",다시 확인합니다"] {
            let added = try additions(old: old, new: [(19_150, 19_850, phrase), (20_110, 20_400, "다시 확인합니다")])
            XCTAssertEqual(added.map(\.text), [phrase, "다시 확인합니다"])
            XCTAssertEqual(added.map(\.originalText), [phrase, "다시 확인합니다"])
            XCTAssertEqual(added.map(\.startMs.rawValue), [19_150, 20_110])
            XCTAssertEqual(added.map(\.endMs.rawValue), [19_850, 20_400])
        }
    }

    func testCommaBeforeFirstMatchedWordAcrossWindows() throws {
        let comma: TimedText = (19_180, 19_180, ",")
        let pointSpace: TimedText = (19_180, 19_180, " ")
        func forms(_ words: String) -> [[TimedText]] {
            [[comma, pointSpace, (19_190, 19_910, words)],
             [(19_190, 19_910, ", " + words)], [(19_190, 19_910, "," + words)]]
        }
        let later: TimedText = (20_110, 20_400, "대수 입니다")
        for old in forms("대수 입니다") {
            for incoming in forms("대수 입니다 다음") {
                let added = try additions(old: old, new: incoming + [later])
                XCTAssertEqual(added.map(\.originalText), ["다음", later.2], "\(old) → \(incoming)")
                XCTAssertEqual(added.map(\.startMs.rawValue), [19_190, later.0])
                XCTAssertEqual(added.map(\.endMs.rawValue), [19_910, later.1])
            }
        }
        let incoming = forms("대수 입니다 다음")[0]
        for old: [TimedText] in [[(19_190, 19_910, "대수 입니다")],
                                 [(19_190, 19_910, "! 대수 입니다")],
                                 [(19_130, 19_130, ","), (19_190, 19_910, "대수 입니다")],
                                 [(19_060, 19_185, "앞말"), (19_190, 19_910, ",대수 입니다")],
                                 [(19_190, 19_910, ", 앞말 대수 입니다")]] {
            let added = try additions(old: old, new: incoming)
            XCTAssertEqual(added.map(\.text), [",", "다음"], "unmatched leading comma in \(old)")
        }
        let weak = try additions(old: [(19_950, 20_000, ", 다시 확인합니다")],
                                 new: [(19_940, 19_940, ","), (19_950, 20_900, "다시 확인합니다")])
        XCTAssertEqual(weak.map(\.originalText), [",", "다시 확인합니다"])
    }

    func testDottedTermsKeepTheirMeaningAfterLeadingPunctuation() throws {
        for term in [".NET", ".5"] {
            let bare = String(term.dropFirst())
            for decorated in [", " + term, "," + term, "(" + term + ")"] {
                for (old, incoming, duplicate) in [(term, decorated, true), (decorated, term, true),
                                                    (bare, decorated, false), (decorated, bare, false)] {
                    let phrase = incoming + " 다음"
                    let added = try additions(old: [(19_190, 19_910, old)], new: [(19_190, 19_910, phrase)])
                    XCTAssertEqual(added.map(\.originalText), [duplicate ? "다음" : phrase], "\(old) → \(incoming)")
                }
            }
        }
        let ellipsis = try additions(old: [(19_190, 19_910, "정리")], new: [(19_190, 19_910, "...정리 다음")])
        XCTAssertEqual(ellipsis.map(\.originalText), ["다음"])
    }

    func testTrailingCommaAfterPointSpaceBelongsToTheMatchedWord() throws {
        let word: TimedText = (19_060, 19_180, "선형")
        let comma: TimedText = (19_180, 19_180, ",")
        let incoming: [TimedText] = [word, (19_180, 19_180, " "), comma,
                                     (19_300, 19_700, "다음"), (19_700, 19_700, "!"),
                                     (20_110, 20_400, "선형")]
        let added = try additions(old: [word, comma], new: incoming)
        XCTAssertEqual(added.map(\.text), ["다음", "!", "선형"])
        XCTAssertEqual(added.map(\.startMs.rawValue), [19_300, 19_700, 20_110])
    }

    func testTrailingMarkAcrossAGapRequiresTheSameOldMarkAndTime() throws {
        let word: TimedText = (19_060, 19_170, "선형")
        let incoming: [TimedText] = [word, (19_180, 19_180, ","), (19_190, 19_910, "다음")]
        let repeated = try additions(old: [word, (19_180, 19_180, " ,")], new: incoming)
        XCTAssertEqual(repeated.map(\.text), ["다음"])
        for oldMark: TimedText in [(19_180, 19_180, "!"), (19_175, 19_175, ",")] {
            let novel = try additions(old: [word, oldMark], new: incoming)
            XCTAssertEqual(novel.map(\.text), [",", "다음"])
        }
        let edgeWord: TimedText = (19_600, 20_000, "선형")
        let outside = try additions(old: [edgeWord], new: [edgeWord, (20_000, 20_000, ","),
                                                            (20_110, 20_400, "선형")])
        XCTAssertEqual(outside.map(\.text), [",", "선형"])
    }

    private func lowPassNoise(seed initialSeed: UInt32) -> [Float] {
        var seed = initialSeed
        var filtered = 0.0
        let raw = (0..<(32 * 16_000)).map { _ -> Double in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let white = 2 * Double(seed) / Double(UInt32.max) - 1
            filtered = 0.92 * filtered + 0.08 * white
            return filtered
        }
        let gain = 0.025 / sqrt(raw.reduce(0) { $0 + $1 * $1 } / Double(raw.count))
        return raw.map { Float($0 * gain) }
    }

    func testIsolatedPeriodInBackgroundNoiseDoesNotStartAnUtterance() throws {
        var segmenter = UtteranceSegmenter()
        let noise = lowPassNoise(seed: 17)
        XCTAssertTrue(try (segmenter.append(noise, at: 0) + segmenter.flush()).isEmpty)
    }

    func testPersistentLowPassNoiseAndQuietSpeechOnTheSameBackground() throws {
        let noise = lowPassNoise(seed: 0xDA95)
        var vad = UtteranceSegmenter()
        let noiseOnly = try vad.append(noise, at: 0) + vad.flush()
        XCTAssertTrue(noiseOnly.isEmpty, "stationary noise produced \(noiseOnly.count) windows")

        var mix = noise
        let onset = 16_000 * 8
        let vowel = voice(600).map { $0 / 3 } // 0.035 RMS over the same 0.025 RMS background
        for i in vowel.indices { mix[onset + i] += vowel[i] }
        var speech = UtteranceSegmenter()
        let windows = try speech.append(mix, at: 0) + speech.flush()
        let spoken = try XCTUnwrap(windows.only)
        XCTAssertEqual(spoken.boundary, .silence)
        XCTAssertLessThanOrEqual(spoken.startFrame, Int64(onset))
        XCTAssertGreaterThanOrEqual(spoken.startFrame, Int64(onset - 4_800))
        XCTAssertGreaterThanOrEqual(spoken.endFrame, Int64(onset + vowel.count))
        XCTAssertLessThanOrEqual(spoken.endFrame, Int64(onset + vowel.count + 12_800))
    }

    func testOnlyMatchingFinalsForClosedWindowsAdvanceSequence() throws {
        var segmenter = UtteranceSegmenter()
        _ = try segmenter.append(voice(200), at: 0)
        let open = try XCTUnwrap(segmenter.openWindow()), closed = try XCTUnwrap(segmenter.flush().only)
        let session = try STTTestFixture.session()
        let spans: [(Int64, Int64, String)] = [(5, 95, "테스트")]
        let final = try result(closed, spans, session: session)
        var reconciler = TranscriptReconciler(session: session)
        XCTAssertThrowsError(try reconciler.reconcile(final, for: open, language: ko))
        XCTAssertThrowsError(try reconciler.reconcile(result(closed, spans, session: session, kind: .partial), for: closed, language: ko))
        XCTAssertThrowsError(try reconciler.reconcile(result(closed, spans, session: STTTestFixture.session(2)), for: closed, language: ko))
        XCTAssertThrowsError(try reconciler.reconcile(final, for: closed, language: LanguageCode("en")))
        XCTAssertEqual(try reconciler.reconcile(final, for: closed, language: ko).only?.sequence.rawValue, 0)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}


extension SpeechSegmentationTests {
    func testReviewT20AcceptsExistingT18BoundaryShiftOutput() async throws {
        let windows = try splitWindows(), session = try STTTestFixture.session()
        var reconciler = TranscriptReconciler(session: session)
        let first = try reconciler.reconcile(result(windows[0], [
            (17_000, 19_450, "오늘은 신경망"), (19_450, 20_000, "Swift API.")
        ], session: session), for: windows[0], language: ko)
        let second = try reconciler.reconcile(result(windows[1], [
            (19_010, 19_440, "신경 망"), (19_440, 20_500, "swift api, 다시"),
            (20_500, 21_000, "정리합니다.")
        ], session: session), for: windows[1], language: ko)
        XCTAssertEqual((first + second).map(\.text), ["오늘은 신경망", "Swift API.", "다시", "정리합니다."])
        XCTAssertEqual((first + second).map(\.startMs.rawValue), [17_000, 19_450, 19_440, 20_500])
        var replay = TranscriptJournalReplay(sessionID: session.sessionID)
        for value in first + second {
            try replay.append(JSONEncoder().encode(TranscriptJournalRecord(sessionId: session.sessionID, segment: value)))
        }
        XCTAssertNoThrow(try TranscriptCanonical.compact(sessionID: session.sessionID,
            journal: replay.segments, existing: nil, duration: .init(21_000)))
        try await assertT20FileRoundTrip(first + second)
    }

    func testReviewT20AcceptsWeakOverlapPreservedByT18() async throws {
        let windows = try splitWindows(), session = try STTTestFixture.session()
        var reconciler = TranscriptReconciler(session: session)
        let first = try reconciler.reconcile(result(windows[0], [
            (19_150, 19_170, "다시"), (19_170, 19_820, ","), (19_820, 19_850, "확인합니다")
        ], session: session), for: windows[0], language: ko)
        let second = try reconciler.reconcile(result(windows[1], [
            (19_150, 19_850, "다시 확인합니다"), (20_110, 20_400, "다시 확인합니다")
        ], session: session), for: windows[1], language: ko)
        XCTAssertEqual(second.map(\.text), ["다시 확인합니다", "다시 확인합니다"])
        XCTAssertEqual(second.map(\.startMs.rawValue), [19_150, 20_110])
        XCTAssertNoThrow(try TranscriptCanonical.compact(sessionID: session.sessionID,
            journal: first + second, existing: nil, duration: .init(21_000)))
        try await assertT20FileRoundTrip(first + second)
    }

    private func assertT20FileRoundTrip(_ segments: [TranscriptSegment]) async throws {
        let f = try await FinalizationFixture.make(seconds: 21); defer { f.clean() }
        let store = try SQLiteSessionCatalogStore(applicationSupportDirectory: f.base.appendingPathComponent("catalog"))
        let catalog = SessionCatalogReconciler(scanner: SessionFileScanner(roots: f.roots), store: store)
        let repository = FileTranscriptRepository(roots: f.roots, catalog: catalog)
        for segment in segments {
            try await f.repository.appendTranscriptJournal(.init(sessionId: f.location.sessionID, segment: segment), at: f.location)
        }
        let journalBefore = try Data(contentsOf: f.url(SessionArtifact.transcriptJournal.relativePath))
        let worker = SessionFinalizationWorker(audio: f.worker(), transcripts: repository)
        let result = await worker.finalize(.init(location: f.location), control: .init(), progress: { _ in })
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.phase, .sessionReady)
        let document = try await f.repository.readTranscript(at: f.location)
        XCTAssertEqual(document.segments, segments, "IDs, sequence, text and immutable times must survive unchanged")
        let metadata = try await f.repository.readMetadata(at: f.location)
        let rendered = try TranscriptRenderer.render(document, metadata: metadata)
        XCTAssertEqual(try Data(contentsOf: f.url("transcript.txt")), rendered.text)
        XCTAssertEqual(try Data(contentsOf: f.url("transcript.md")), rendered.markdown)
        let reopened = await worker.finalize(.init(location: f.location, operation: .verifyExistingCanonical),
                                            control: .init(), progress: { _ in })
        XCTAssertEqual(reopened.phase, .sessionReady)
        let persisted = try await f.repository.readTranscript(at: f.location)
        XCTAssertEqual(persisted.segments, segments)
        XCTAssertEqual(try Data(contentsOf: f.url(SessionArtifact.transcriptJournal.relativePath)), journalBefore)
    }
}
