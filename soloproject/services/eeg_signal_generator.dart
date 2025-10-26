import 'dart:math';

/// Generates synthetic EEG signals.
class EEGSignalGenerator {
  final Random _rand = Random();

  /// Generates an EEG signal with specified length and sample rate.
  List<double> generateEEGSignal(int n, int fs) {
    if (n <= 0 || fs <= 0) throw Exception('Invalid signal parameters');
    final List<double> signal = [];
    for (int i = 0; i < n; i++) {
      double t = i / fs.toDouble();
      double alpha = 1.0 * sin(2 * pi * 10 * t); // Alpha 10Hz
      double theta = 0.5 * sin(2 * pi * 6 * t); // Theta 6Hz
      double noise = 0.1 * (_rand.nextDouble() * 2 - 1); // White noise
      signal.add(alpha + theta + noise);
    }
    return signal;
  }
}