"""
MadhurVision — Voice Engine
==============================
Real-time offline speech recognition using Vosk.
Runs in a background thread, continuously listens to microphone,
and emits recognized text to callbacks.
"""

import os
import sys
import json
import queue
import threading
import logging
import zipfile
import urllib.request
from typing import Callable, Optional, List

logger = logging.getLogger("MadhurVision.VoiceEngine")

try:
    import sounddevice as sd
    SOUNDDEVICE_AVAILABLE = True
except ImportError:
    SOUNDDEVICE_AVAILABLE = False
    logger.warning("sounddevice not installed. Voice disabled.")

try:
    from vosk import Model, KaldiRecognizer, SetLogLevel
    VOSK_AVAILABLE = True
except ImportError:
    VOSK_AVAILABLE = False
    logger.warning("Vosk not installed. Voice disabled.")
    logger.warning("Install with: pip install vosk")

from configs.settings import settings

# Type alias for text callbacks
TextCallback = Callable[[str], None]


class VoiceEngine:
    """
    Real-time offline speech recognition.
    
    Uses Vosk for local speech-to-text (no internet required).
    Runs microphone capture in a background thread and emits
    recognized text through registered callbacks.
    
    Usage:
        engine = VoiceEngine()
        engine.on_text(lambda text: print(f"Heard: {text}"))
        engine.start()
        
        # ... runs in background ...
        
        engine.stop()
    """

    # Vosk model download URL (small English model)
    MODEL_URL = "https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip"
    MODEL_DIR = "models"

    def __init__(self):
        self._sample_rate = settings.voice.sample_rate
        self._model_path = settings.voice.model_path
        self._wake_word = settings.voice.wake_word.lower()
        self._auto_download = settings.voice.auto_download

        self._running = False
        self._thread: Optional[threading.Thread] = None
        self._audio_queue: queue.Queue = queue.Queue()
        self._callbacks: List[TextCallback] = []
        self._partial_callbacks: List[TextCallback] = []

        self._model: Optional['Model'] = None
        self._recognizer: Optional['KaldiRecognizer'] = None

        # State
        self._is_listening = True  # If wake word is empty, always listen
        self._last_text = ""
        self._text_count = 0

    def on_text(self, callback: TextCallback) -> None:
        """Register callback for finalized text."""
        self._callbacks.append(callback)

    def on_partial(self, callback: TextCallback) -> None:
        """Register callback for partial (in-progress) text."""
        self._partial_callbacks.append(callback)

    def start(self) -> None:
        """Start voice recognition in background thread."""
        if not VOSK_AVAILABLE:
            logger.error("Vosk not available. Cannot start voice engine.")
            return
        if not SOUNDDEVICE_AVAILABLE:
            logger.error("sounddevice not available. Cannot start voice engine.")
            return
        if self._running:
            return

        # Load model
        if not self._load_model():
            return

        self._running = True
        self._thread = threading.Thread(
            target=self._recognition_loop,
            name="VoiceEngine",
            daemon=True
        )
        self._thread.start()
        logger.info("VoiceEngine started")

    def _load_model(self) -> bool:
        """Load or download the Vosk model."""
        SetLogLevel(-1)  # Suppress Vosk logs

        if not os.path.exists(self._model_path):
            if self._auto_download:
                logger.info(f"Vosk model not found at {self._model_path}")
                if not self._download_model():
                    return False
            else:
                logger.error(
                    f"Vosk model not found at {self._model_path}. "
                    f"Download from https://alphacephei.com/vosk/models"
                )
                return False

        try:
            self._model = Model(self._model_path)
            self._recognizer = KaldiRecognizer(self._model, self._sample_rate)
            logger.info(f"Vosk model loaded: {self._model_path}")
            return True
        except Exception as e:
            logger.error(f"Failed to load Vosk model: {e}")
            return False

    def _download_model(self) -> bool:
        """Download the Vosk model automatically."""
        os.makedirs(self.MODEL_DIR, exist_ok=True)
        zip_path = os.path.join(self.MODEL_DIR, "vosk-model.zip")

        logger.info(f"Downloading Vosk model from {self.MODEL_URL}...")
        logger.info("This may take a few minutes...")

        try:
            urllib.request.urlretrieve(self.MODEL_URL, zip_path)
            logger.info("Download complete. Extracting...")

            with zipfile.ZipFile(zip_path, 'r') as zf:
                zf.extractall(self.MODEL_DIR)

            os.remove(zip_path)
            logger.info(f"Model extracted to {self._model_path}")
            return True
        except Exception as e:
            logger.error(f"Failed to download model: {e}")
            return False

    def _recognition_loop(self) -> None:
        """Background thread: capture audio and recognize speech."""

        def audio_callback(indata, frames, time_info, status):
            if status:
                logger.debug(f"Audio status: {status}")
            self._audio_queue.put(bytes(indata))

        try:
            with sd.RawInputStream(
                samplerate=self._sample_rate,
                blocksize=8000,
                dtype='int16',
                channels=1,
                callback=audio_callback
            ):
                logger.info("Microphone stream opened. Listening...")
                while self._running:
                    try:
                        data = self._audio_queue.get(timeout=1.0)
                    except queue.Empty:
                        continue

                    if self._recognizer.AcceptWaveform(data):
                        # Final result
                        result = json.loads(self._recognizer.Result())
                        text = result.get("text", "").strip()

                        if text:
                            self._process_text(text)
                    else:
                        # Partial result
                        partial = json.loads(self._recognizer.PartialResult())
                        partial_text = partial.get("partial", "").strip()

                        if partial_text:
                            for cb in self._partial_callbacks:
                                try:
                                    cb(partial_text)
                                except Exception as e:
                                    logger.error(f"Partial callback error: {e}")

        except Exception as e:
            logger.error(f"VoiceEngine error: {e}")
        finally:
            logger.info("VoiceEngine loop stopped")

    def _process_text(self, text: str) -> None:
        """Process finalized recognized text."""
        # Wake word filtering
        if self._wake_word:
            if not self._is_listening:
                if self._wake_word in text.lower():
                    self._is_listening = True
                    # Remove wake word from text
                    text = text.lower().replace(self._wake_word, "").strip()
                    if not text:
                        logger.info("Wake word detected. Listening...")
                        return
                else:
                    return  # Not listening and no wake word
            else:
                # Stop listening after 10 seconds of silence
                pass

        self._last_text = text
        self._text_count += 1
        logger.info(f"Recognized: '{text}'")

        for callback in self._callbacks:
            try:
                callback(text)
            except Exception as e:
                logger.error(f"Text callback error: {e}")

    @property
    def last_text(self) -> str:
        return self._last_text

    @property
    def is_listening(self) -> bool:
        return self._is_listening and self._running

    @property
    def text_count(self) -> int:
        return self._text_count

    def stop(self) -> None:
        """Stop voice recognition."""
        self._running = False
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=3.0)
        logger.info("VoiceEngine stopped")
