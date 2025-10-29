# EEG Realtime Console — Flutter (Individual Project for Cross-Platform Mobile App Development course)

A compact Flutter application that simulates, analyses, and visualises EEG-like signals in real time.

This repo provides a dark-themed dashboard with a synthetic EEG generator (alpha + theta + noise), a frequency-domain FFT spectrum, simple band-power metrics, an educational brain demo, and an integrated "AI Analysis" feature that can produce a concise interpretation using OpenAI.

---

## Quick summary

- Framework: Flutter (Dart)
- Purpose: Simulate an EEG signal, compute FFT and band power, and show interactive charts on a single-screen dashboard.
- Key features: raw time-series plot, FFT magnitude spectrum, band-power cards (Delta/Theta/Alpha/Beta), a LearnEEG educational demo, and an "AI Analysis" assistant for short automated interpretation.

---

## AI Analysis (what it does and how to use it)

The app includes a built-in AI-based interpretation helper:

- Trigger: Press the "AI Analysis" button in the right-hand action panel.
- What it sends: a small JSON-like prompt containing summary features (alpha peak frequency & power, Hjorth activity/mobility, alpha Z-score, and short time-domain statistics for the last 256 samples).
- Remote model: the app calls the OpenAI Chat Completions endpoint (`/v1/chat/completions`) and expects a chat-style response. The model string is currently configurable in the code.
- Fallback: if the network call fails or no API key is configured, the app displays a deterministic local summary (rule-based analysis) so the feature still produces useful output.

How to provide an API key:

1. Tap the key icon in the app bar ("OpenAI API Key").
2. Paste your OpenAI API key (`sk-...`) into the secure prompt and press Save.
3. The key is stored locally in the app documents directory by default (file `.openai_api_key`).

Model, privacy and limits:
- The prompt includes numerical features only (no raw user text). The app sends only aggregated stats and a short snippet summary (mean, RMS); it does not send full user files.
- Be aware of rate limits and costs associated with your OpenAI plan!!!

---

## Signal details (how the synthetic EEG is generated)

- Sample rate (Fs): 256 Hz
- Duration: 4 seconds → 1024 samples
- Composition: sum of
  - Alpha (10 Hz) — amplitude ~1.0
  - Theta (6 Hz) — amplitude ~0.5
  - Small Beta (20 Hz) — amplitude ~0.2
  - Additive white noise — amplitude ~0.08

These parameters are chosen so the FFT clearly shows a dominant peak at ~10 Hz and a smaller peak near 6 Hz.

---

## Signal processing implemented in the app

- FFT: time-domain → frequency-domain conversion (Dart implementation). The app computes raw magnitudes and uses a half-spectrum up to Nyquist (Fs/2).
- Band power: magnitude-averaging across canonical EEG bands:
  - Delta: 0.5–4 Hz
  - Theta: 4–8 Hz
  - Alpha: 8–13 Hz
  - Beta: 13–30 Hz

Notes: The implementation is intended for demonstration and teaching. For production-level PSD estimation use windowing (Hann), overlap, and normalization (or dedicated libraries).

---

## UI / Visualization

- Single-screen dashboard with a modern dark theme and responsive spacing.
- Panels:
  1. Raw signal line chart (time axis: 0–4 s).
  2. FFT magnitude chart (frequency axis: 0–128 Hz).
  3. Band-power radar chart and cards: Delta / Theta / Alpha / Beta.
  4. Educational Brain Demo (separate route) with an interactive 3D-like head projection.
- Charting: `fl_chart` is used for charts.

---

## Run & build (Windows development machine)

1. Verify Flutter and device:

```cmd
flutter doctor
flutter devices
```

2. Fetch packages and run:

```cmd
cd soloproject
flutter pub get
flutter run  # to run on the default device (emulator/desktop)
flutter run -d <device-id>  # to run on a specific device
```

---


