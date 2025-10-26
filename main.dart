import 'dart:math';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

const int SAMPLE_RATE = 256;
const int DURATION_SEC = 4;
const int N_SAMPLES = SAMPLE_RATE * DURATION_SEC;

class Complex {
  final double real;
  final double imag;
  const Complex(this.real, this.imag);

  Complex operator +(Complex b) => Complex(real + b.real, imag + b.imag);
  Complex operator -(Complex b) => Complex(real - b.real, imag - b.imag);
  Complex operator *(Complex b) => Complex(real * b.real - imag * b.imag, real * b.imag + imag * b.real);

  double magnitude() => sqrt(real * real + imag * imag);
}

class SignalProcessor {
  static List<double> generateEEGSignal() {
    final random = Random();
    return List.generate(N_SAMPLES, (i) {
      double t = i / SAMPLE_RATE;
      return sin(2 * pi * 10 * t) + 0.5 * sin(2 * pi * 6 * t) + 0.1 * (random.nextDouble() * 2 - 1);
    });
  }

  static List<Complex> fft(List<Complex> x) {
    int n = x.length;
    if (n == 1) return x;
    List<Complex> even = fft(List.generate(n ~/ 2, (k) => x[2 * k]));
    List<Complex> odd = fft(List.generate(n ~/ 2, (k) => x[2 * k + 1]));
    List<Complex> result = List.filled(n, Complex(0, 0));
    for (int k = 0; k < n ~/ 2; k++) {
      double theta = -2 * pi * k / n;
      Complex t = Complex(cos(theta), sin(theta)) * odd[k];
      result[k] = even[k] + t;
      result[k + n ~/ 2] = even[k] - t;
    }
    return result;
  }

  static Map<String, double> calculateBandPowers(List<double> freqs, List<double> mags) {
    double getBandPower(double minFreq, double maxFreq) {
      double sum = 0;
      int count = 0;
      for (int i = 0; i < freqs.length; i++) {
        if (freqs[i] >= minFreq && freqs[i] < maxFreq) {
          sum += mags[i];
          count++;
        }
      }
      return count > 0 ? sum / count : 0;
    }

    return {
      'Delta': getBandPower(0.5, 4),
      'Theta': getBandPower(4, 8),
      'Alpha': getBandPower(8, 13),
      'Beta': getBandPower(13, 30),
    };
  }
}

void main() => runApp(const EEGAnalyzerApp());

class EEGAnalyzerApp extends StatelessWidget {
  const EEGAnalyzerApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EEG Analyzer',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF1A1A1A),
        cardTheme: CardTheme(
          color: const Color(0xFF2D2D2D),
          elevation: 8,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      home: const EEGAnalyzerHome(),
    );
  }
}

class EEGAnalyzerHome extends StatefulWidget {
  const EEGAnalyzerHome({Key? key}) : super(key: key);

  @override
  State<EEGAnalyzerHome> createState() => _EEGAnalyzerHomeState();
}

class _EEGAnalyzerHomeState extends State<EEGAnalyzerHome> {
  late final List<double> eegSignal;
  late final List<double> frequencies;
  late final List<double> magnitudes;
  late final Map<String, double> bandPowers;

  @override
  void initState() {
    super.initState();
    eegSignal = SignalProcessor.generateEEGSignal();
    List<Complex> complexSignal = eegSignal.map((x) => Complex(x, 0)).toList();
    List<Complex> fftResult = SignalProcessor.fft(complexSignal);
    frequencies = List.generate(N_SAMPLES ~/ 2, (i) => i * SAMPLE_RATE / N_SAMPLES);
    magnitudes = fftResult.sublist(0, N_SAMPLES ~/ 2).map((c) => c.magnitude()).toList();
    bandPowers = SignalProcessor.calculateBandPowers(frequencies, magnitudes);
  }

  void _regenerate() {
    setState(() {
      List<double> newSignal = SignalProcessor.generateEEGSignal();
      List<Complex> complexSignal = newSignal.map((x) => Complex(x, 0)).toList();
      List<Complex> fftResult = SignalProcessor.fft(complexSignal);
      eegSignal.clear();
      eegSignal.addAll(newSignal);
      magnitudes.clear();
      magnitudes.addAll(fftResult.sublist(0, N_SAMPLES ~/ 2).map((c) => c.magnitude()).toList());
      bandPowers = SignalProcessor.calculateBandPowers(frequencies, magnitudes);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('EEG Signal Analysis')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _buildSignalChart(),
            const SizedBox(height: 16),
            _buildSpectrumChart(),
            const SizedBox(height: 16),
            _buildBandPowers(),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _regenerate, child: const Text('Regenerate')),
          ],
        ),
      ),
    );
  }

  Widget _buildSignalChart() => _buildChart(
    'Raw EEG Signal',
    [for (int i = 0; i < eegSignal.length; i++) FlSpot(i / SAMPLE_RATE, eegSignal[i])],
    Colors.cyan,
  );

  Widget _buildSpectrumChart() => _buildChart(
    'Frequency Spectrum',
    [for (int i = 0; i < magnitudes.length; i++) FlSpot(frequencies[i], magnitudes[i])],
    Colors.amber,
  );

  Widget _buildChart(String title, List<FlSpot> spots, Color color) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: LineChart(
            LineChartData(
              gridData: FlGridData(show: true),
              titlesData: FlTitlesData(
                topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
              ),
              lineBarsData: [
                LineChartBarData(
                  spots: spots,
                  color: color,
                  dotData: FlDotData(show: false),
                  barWidth: 1,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBandPowers() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: bandPowers.entries.map((entry) => Column(
            children: [
              Text(entry.key, style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(entry.value.toStringAsFixed(2)),
            ],
          )).toList(),
        ),
      ),
    );
  }
}
