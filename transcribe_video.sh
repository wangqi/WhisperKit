#!/bin/bash

echo "Transcribe video $1 in language $2"
swift run whisperkit-cli transcribe --model-path "Models/whisperkit-coreml/openai_whisper-large-v3" --audio-path "$1" --language "$2"  > "$1_transcribe.txt"
