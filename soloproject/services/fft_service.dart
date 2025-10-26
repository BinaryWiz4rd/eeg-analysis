import 'dart:math';
import '../config/band_config.dart';
import '../models/complex.dart';

/// Service class for performing FFT and related signal processing tasks.
class FFTService {
  /// Computes the FFT of a real-valued signal and returns magnitude and frequency axis.
  Future<Map<String, List<double>>> computeFFT(List<double> signal, int sampleRate) async {
    try {
      if (signal.isEmpty) throw Exception('Signal cannot be empty');
      if (sampleRate <= 0) throw Exception('Sample rate must be positive');

      int n = signal.length;
      int m = pow(2, (log(n) / log(2)).ceil()).toInt();
      List<double> padded = List<double>.from(signal)..addAll(List.filled(m - n, 0));
      List<Complex> x = padded.map((v) => Complex(v, 0)).toList();
      List<Complex> X = _fftRecursive(x);

      int half = m ~/ 2;
      List<double> mag = List.generate(half, (i) => X[i].abs() / m); // Normalize magnitude
      List<double> freq = List.generate(half, (i) => i * sampleRate / m);
      return {'mag': mag, 'freq': freq};
    } catch (e) {
      throw Exception('FFT computation failed: $e');
    }
  }

  /// Recursive Cooley-Tukey FFT with precomputed twiddle factors.
  List<Complex> _fftRecursive(List<Complex> x) {
    int n = x.length;
    if (n == 1) return [x[0]];

    List<Complex> even = _fftRecursive([for (int i = 0; i < n; i += 2) x[i]]);
    List<Complex> odd = _fftRecursive([for (int i = 1; i < n; i += 2) x[i]]);
    List<Complex> X = List.filled(n, const Complex(0, 0));

    // Precompute twiddle factors
    List<Complex> twiddles = List.generate(n ~/ 2, (k) => Complex(0, 0).expi(-2 * pi * k / n));
    for (int k = 0; k < n ~/ 2; k++) {
      Complex t = odd[k] * twiddles[k];
      X[k] = even[k] + t;
      X[k + n ~/ 2] = even[k] - t;
    }
    return X;
  }

  /// Calculates power for each EEG band.
  Map<String, double> calculateBandPowers(List<double> mag, List<double> freq) {
    Map<String, List<double>> bandMags = {for (var band in BandConfig.bands.keys) band: []};
    for (int i = 0; i < freq.length; i++) {
      double f = freq[i];
      for (var band in BandConfig.bands.entries) {
        if (f >= band.value['range'][0] && f < band.value['range'][1]) {
          bandMags[band.key]!.add(mag[i] * mag[i]); // Power = magnitude squared
        }
      }
    }
    return bandMags.map((k, v) => MapEntry(k, v.isEmpty ? 0 : v.reduce((a, b) => a + b) / v.length));
  }

  /// Finds the dominant frequency in the spectrum.
  double findDominantFrequency(List<double> mag, List<double> freq) {
    if (mag.isEmpty) return 0;
    int idx = mag.indexOf(mag.reduce(max));
    return freq[idx];
  }
}