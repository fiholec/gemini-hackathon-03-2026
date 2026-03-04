const AudioStreamer = {
  mounted() {
    this.audioContext = null;
    this.processor = null;
    this.mediaStream = null;
    this.isRecording = false;
    this.micEnabled = false;

    // Start recording immediately when this component mounts!
    this.startRecording();

    this.handleEvent("enable_mic", () => {
      this.micEnabled = true;
      console.log("Microphone broadcasting ENABLED (Walkie-Talkie: User Turn)");
    });

    this.handleEvent("disable_mic", () => {
      this.micEnabled = false;
      console.log("Microphone broadcasting DISABLED (Walkie-Talkie: AI Turn)");
    });

    this.handleEvent("stop_recording", () => {
      this.stopRecording();
    });

    // Handle incoming audio from Gemini via LiveView (if we choose to route it this way)
    this.handleEvent("play_audio", ({ audio_base64 }) => {
      this.playAudio(audio_base64);
    });
  },

  async startRecording() {
    try {
      this.mediaStream = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });

      this.audioContext = new (window.AudioContext || window.webkitAudioContext)({
        sampleRate: 16000 // Gemini API requires 16kHz
      });

      const source = this.audioContext.createMediaStreamSource(this.mediaStream);

      // We use a ScriptProcessorNode for simplicity instead of AudioWorklet for now to capture raw PCM
      // 4096 buffer size is a good balance between latency and JS overhead
      this.processor = this.audioContext.createScriptProcessor(4096, 1, 1);

      this.processor.onaudioprocess = (e) => {
        if (!this.isRecording || !this.micEnabled) return;

        const inputData = e.inputBuffer.getChannelData(0);
        let sumSquares = 0.0;
        const pcmData = new Int16Array(inputData.length);
        for (let i = 0; i < inputData.length; i++) {
          const val = inputData[i];
          sumSquares += val * val;
          pcmData[i] = Math.max(-1, Math.min(1, val)) * 0x7FFF;
        }

        // Silence Detection (VAD)
        const rms = Math.sqrt(sumSquares / inputData.length);
        const silenceThreshold = 0.01;

        if (rms < silenceThreshold) {
          if (!this.silenceStart) {
            this.silenceStart = Date.now();
          } else if (Date.now() - this.silenceStart > 2000 && !this.silenceTriggered) {
            const isGeminiSpeaking = this.nextPlaybackTime && this.playbackContext && (this.playbackContext.currentTime < this.nextPlaybackTime);
            if (!isGeminiSpeaking) {
              this.silenceTriggered = true;
              this.pushEvent("user_silence_timeout", {});
              console.log("Silence detected for 2s, nudging Gemini...");
            } else {
              this.silenceStart = Date.now(); // Reset if Gemini is speaking
            }
          }
        } else {
          this.silenceStart = null;
          this.silenceTriggered = false;
        }

        // Convert to Base64 to send to Phoenix
        const base64Data = this.bufferToBase64(pcmData.buffer);

        // Push the audio chunk back to the LiveView
        this.pushEvent("audio_chunk", { data: base64Data });
      };

      source.connect(this.processor);
      this.processor.connect(this.audioContext.destination); // Needed for Chrome to keep firing events

      this.isRecording = true;
      console.log("Audio recording started at 16kHz");

    } catch (err) {
      console.error("Microphone access denied or error:", err);
      // Let the backend know we failed
      this.pushEvent("mic_error", { reason: err.message });
    }
  },

  stopRecording() {
    this.isRecording = false;

    if (this.processor) {
      this.processor.disconnect();
      this.processor = null;
    }

    if (this.audioContext) {
      this.audioContext.close();
      this.audioContext = null;
    }

    if (this.mediaStream) {
      this.mediaStream.getTracks().forEach(t => t.stop());
      this.mediaStream = null;
    }

    console.log("Audio recording stopped.");
  },

  bufferToBase64(buffer) {
    let binary = '';
    const bytes = new Uint8Array(buffer);
    const len = bytes.byteLength;
    for (let i = 0; i < len; i++) {
      binary += String.fromCharCode(bytes[i]);
    }
    return window.btoa(binary);
  },

  // To play back the 24kHz PCM audio coming back from Gemini
  async playAudio(base64Data) {
    console.log("playAudio triggered! Audio length:", base64Data.length);
    if (!this.playbackContext) {
      this.playbackContext = window.globalAudioContext || new (window.AudioContext || window.webkitAudioContext)({ sampleRate: 24000 });
      console.log("Initialized playback AudioContext at 24kHz");
    }
    if (this.playbackContext.state === 'suspended') {
      console.log("Resuming suspended AudioContext");
      this.playbackContext.resume();
    }

    const binaryString = window.atob(base64Data);
    const len = binaryString.length;
    const bytes = new Uint8Array(len);
    for (let i = 0; i < len; i++) {
      bytes[i] = binaryString.charCodeAt(i);
    }

    // The data from Gemini is PCM 16-bit little-endian.
    const int16Array = new Int16Array(bytes.buffer);

    // Convert back to Float32 for Web Audio API
    const float32Array = new Float32Array(int16Array.length);
    for (let i = 0; i < int16Array.length; i++) {
      float32Array[i] = int16Array[i] / 32768.0;
    }

    const audioBuffer = this.playbackContext.createBuffer(1, float32Array.length, 24000);
    audioBuffer.getChannelData(0).set(float32Array);

    const source = this.playbackContext.createBufferSource();
    source.buffer = audioBuffer;
    source.connect(this.playbackContext.destination);

    if (!this.nextPlaybackTime || this.nextPlaybackTime < this.playbackContext.currentTime) {
      this.nextPlaybackTime = this.playbackContext.currentTime;
    }

    source.start(this.nextPlaybackTime);
    this.nextPlaybackTime += audioBuffer.duration;
  },

  destroyed() {
    this.stopRecording();
  }
};

export default AudioStreamer;
