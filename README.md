# voice-server

`voice-server` is a simple HTTP server specifically designed for **macOS** that exposes the operating system's built-in Text-to-Speech (TTS) and Speech-to-Text (STT) capabilities via a network interface.

It allows applications (local or remote) to easily leverage macOS speech synthesis and recognition without needing direct integration with the specific macOS frameworks.

## Features

*   **HTTP Interface:** Provides simple RESTful endpoints for speech services.
*   **Text-to-Speech (TTS):** Converts text input (JSON payload) into WAV audio output using `NSSpeechSynthesizer`.
*   **Speech-to-Text (STT):** Transcribes audio input (multipart form upload) into text using `SFSpeechRecognizer`.
*   **Asynchronous Handling:** Uses Grand Central Dispatch (GCD) for non-blocking network I/O and concurrent request processing.
*   **Configurable:** Allows setting the listening host address and port via command-line arguments.
*   **Language Selection:** Supports specifying the desired language/voice for TTS and the language for STT.

## Installation & Building

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/eja/voice-server.git
    cd voice-server
    ```
2.  **Compile the code:**
    ```bash
    make
    ```
    This will create the executable file named `voice-server` in the current directory.

## Usage

1.  **Run the server:**
    ```bash
    ./voice-server [options]
    ```
    The server will start listening for incoming HTTP requests on the configured host and port.

2.  **Command-line Options:**
    ```
    Usage: voice-server [options]
    
     --port <number>      port (default: 35248)
     --host <address>     host (default: 127.0.0.1). Use 0.0.0.0 for all.
     --log-file <path>    redirect logs to a file (appends if exists)
     --help               this help
    
    ```

3.  **Permissions Reminder:** Ensure Speech Recognition permission is granted *before* sending your first STT request, otherwise the request will likely fail.

## API Documentation

### Text-to-Speech (TTS)

*   **Endpoint:** `POST /tts`
*   **Request:**
    *   `Content-Type: application/json`
    *   Body (JSON):
        ```json
        {
          "text": "Hello, this is a test of the speech synthesizer.",
          "language": "en-GB"
        }
        ```
        *   `text` (string, required): The text to be synthesized.
        *   `language` (string, optional): The BCP 47 language code (e.g., `en-US`, `it-IT`, `fr-FR`). If omitted or invalid, the system's default voice or a suitable fallback will be used.
*   **Response (Success):**
    *   Status Code: `200 OK`
    *   `Content-Type: audio/wav`
    *   Body: Raw WAV audio data.
*   **Response (Error):**
    *   Status Code: `400 Bad Request`, `415 Unsupported Media Type`, `500 Internal Server Error`, `504 Gateway Timeout`, etc.
    *   `Content-Type: application/json`
    *   Body (JSON):
        ```json
        {
          "error": "Descriptive error message"
        }
        ```

### Speech-to-Text (STT)

*   **Endpoint:** `POST /stt`
*   **Request:**
    *   `Content-Type: multipart/form-data`
    *   Body (Multipart Form Parts):
        *   **Part 1 (Optional):**
            *   `Content-Disposition: form-data; name="language"`
            *   Body: The BCP 47 language code for transcription (e.g., `en-US`, `it-IT`). Defaults to `en-US` if omitted.
        *   **Part 2 (Required):**
            *   `Content-Disposition: form-data; name="audio"; filename="your_audio.wav"`
            *   `Content-Type: audio/wav` (or other AVFoundation-supported format)
            *   Body: The raw audio data to be transcribed.
            
*   **Response (Success):**
    *   Status Code: `200 OK`
    *   `Content-Type: application/json`
    *   Body (JSON):
        ```json
        {
          "transcript": "This is the recognized text from the audio.",
          "language": "en-US"
        }
        ```
*   **Response (Error):**
    *   Status Code: `400 Bad Request`, `415 Unsupported Media Type`, `500 Internal Server Error`, `503 Service Unavailable`, `504 Gateway Timeout`, etc.
    *   `Content-Type: application/json`
    *   Body (JSON):
        ```json
        {
          "error": "Descriptive error message (e.g., No speech detected, Recognition failed)"
        }
        ```
