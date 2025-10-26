# EEG Realtime Console 🧠

This is a comprehensive **Flutter** application designed to simulate and visualize real-time Electroencephalography (EEG) data. It functions as a dynamic dashboard, offering immediate signal visualization alongside advanced spectral and statistical analysis, including a simulated AI interpretation of the brain state.

## ✨ Features

The application is structured as a high-contrast, scientific console for easy monitoring and analysis.

### 📊 Realtime Visualization
* **Raw EEG Plot:** Displays a live-scrolling plot of the simulated EEG signal over a 2-second window.
* **Signal Controls:** Adjustable **Speed** (sampling rate factor) and **Gain** (amplitude scaling) to explore signal dynamics.
* **Adaptive Y-Axis:** The signal plot's vertical range dynamically adjusts to the signal's peak amplitude.

---

### 🔬 Advanced Analysis Panel
The dedicated analysis panel offers multiple views for in-depth signal investigation:

| View | Description | Key Insight |
| :--- | :--- | :--- |
| **Signal Detail** | A zoomed-in view of the last 0.5 seconds of the raw signal. | Fine structure and noise identification. |
| **Spectrum** | Magnitude of the Fast Fourier Transform (FFT) across frequencies. | Shows which specific frequencies (e.g., 10 Hz Alpha) are strongest. |
| **PSD (Power Spectral Density)** | A smoothed, density-normalized version of the power spectrum. | Better visualization of total power distribution per frequency band. |
| **Bands (Radar Chart)** | Visualizes the power distribution across the four classical EEG bands (Delta, Theta, Alpha, Beta). | Quick comparison of dominant brain state activity. |
| **Stats/Hjorth** | Displays core time-domain and frequency metrics, including the **Alpha Z-Score**. | Quantifies signal stability and rhythmic prominence. |

---

### 🤖 Simulated AI Interpretation
A key feature is the **"AI Analysis"** button, which generates a written summary of the current signal state based on real-time metrics:

* It uses **rule-based logic** tied to the **Alpha Z-Score**, Hjorth **Activity** (variance), and Hjorth **Mobility** (mean frequency).
* It provides a plain-language summary of whether the signal indicates a state of relaxation (high Alpha) or alertness (low Alpha) and comments on the signal quality (noisy vs. rhythmic).

---

## 🛠️ Technology Stack

* **Framework:** Flutter
* **Language:** Dart
* **Core Libraries:** `dart:math`, `dart:async`
* **Charting:** `fl_chart` (Used for Line Charts and Radar Charts)

---
### EEG REALTIME SIGNAL ANALYSIS

### Prerequisites

* Flutter SDK installed and configured.
* A physical device or simulator running iOS, Android, or desktop.

### Installation and Run

1.  **Clone the repository:**
    ```bash
    git clone [repository_url_here]
    cd eeg_realtime_console
    ```

2.  **Get packages:**
    ```bash
    flutter pub get
    ```

3.  **Run the application:**
    ```bash
    flutter run
    ```
    *(Note: This application is best viewed on a tablet or desktop emulator/window due to the wide dashboard layout.)*

---

## ⚙️ Core Logic

The real-time processing is handled by the `SignalProcessor` class:

* **Signal Simulation:** Generates a synthetic signal composed of Sine waves at common EEG frequencies (e.g., 10Hz Alpha, 6Hz Theta) plus Gaussian noise.
* **Buffering:** A fixed-length circular buffer (`bufferLength = 4 seconds * 256 Hz = 1024 samples`) stores the most recent data.
* **FFT Calculation:** The `fft` function performs the Cooley-Tukey algorithm to convert the time-domain data into the frequency domain, enabling the Spectrum and Band Power analysis.
* **Hjorth Parameters:** Calculated from the buffered signal to quantify signal complexity and activity for the statistical analysis.
