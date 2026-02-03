# Native Transcription on Mac

This is a background utility for macOS that enables system-wide push-to-talk speech transcription. It listens for a global hotkey combination to record audio, transcribes it locally using Whisper model, and pastes it into the text field.

The project uses [whisper.cpp](github.com/ggml-org/whisper.cpp) for Metal-optimised inference on Apple Silicon. The model used in this example is ggml-small.en-q8_0.bin, a quantised version of [Whisper model](https://huggingface.co/ggerganov/whisper.cpp/tree/main). 

To run this tool, you must first ensure you have the required model file in the whisper.cpp/models directory. You can use the included run.sh script to compile the Swift source files and launch the background process. The first time you run it, macOS will request Accessibility and Input Monitoring permissions which are necessary to to capture global key events and simulating keystrokes. After granting permissions, run the script again.

The default hotkey is configured to <u>Left Option + S</u>. Hold the keys to speak and release them to transcribe. The application logs its activity to transcriber.log in the project directory. Use the included launch script to setup transcriber at startup.
