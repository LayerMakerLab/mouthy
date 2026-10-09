#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
mode="${1:-}"
if [[ -n "$mode" && "$mode" != "--native" && "$mode" != "--microphone" && "$mode" != "--parakeet" && "$mode" != "--whisper" && "$mode" != "--delivery" ]]; then
    print -u2 'Usage: ./scripts/test.sh [--native|--microphone|--parakeet|--whisper|--delivery]'
    exit 2
fi
if [[ "$mode" == "--delivery" ]]; then
    export MOUTHY_TEST_DELIVERY=1
    swift test --filter HeadlessDelivery
    exit
fi
if [[ "$mode" == "--native" || "$mode" == "--microphone" || "$mode" == "--parakeet" || "$mode" == "--whisper" ]]; then
    fixture_dir="$(mktemp -d /private/tmp/mouthy-tests.XXXXXX)"
    trap 'rm -rf -- "$fixture_dir"' EXIT
    say -o "$fixture_dir/speech.aiff" 'The morning light filled the garden. I made a cup of coffee and wrote three notes for the afternoon meeting.'
    export MOUTHY_TEST_AUDIO="$fixture_dir/speech.aiff"
    if [[ "$mode" == "--native" ]]; then
        export MOUTHY_TEST_NATIVE=1
    elif [[ "$mode" == "--parakeet" ]]; then
        export MOUTHY_TEST_PARAKEET=1
        swift test --filter "localParakeetRecognizesFixtureAndSilence|parakeetVocabularyBoostsRareTerms|speechModelsTranscribeFileForHosts"
        exit
    elif [[ "$mode" == "--whisper" ]]; then
        export MOUTHY_TEST_WHISPER=1
        swift test --filter localWhisperRecognizesFixtureAndSilence
        exit
    else
        export MOUTHY_TEST_MICROPHONE=1
        swift test --filter liveMicrophoneLoopbackAndCancellation
        exit
    fi
fi
swift test
