import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

const int sampleRate = 256;
const int durationSec = 4;
const int bufferLength = sampleRate * durationSec;
const double alphaLow = 8.0;
const double alphaHigh = 13.0;

class Complex {
  final double real;
  final double imag;
  const Complex(this.real, this.imag);
  Complex operator +(Complex b) => Complex(real + b.real, imag + b.imag);
  Complex operator -(Complex b) => Complex(real - b.real, imag - b.imag);
  Complex operator *(Complex b) =>
      Complex(real * b.real - imag * b.imag, real * b.imag + imag * b.real);
  double magnitude() => sqrt(real * real + imag * imag);
}

List<Complex> fft(List<Complex> x) {
  int n = x.length;
  if (n <= 1) return x;
  final even = <Complex>[];
  final odd = <Complex>[];
  for (int i = 0; i < n; i++) {
    if (i.isEven) even.add(x[i]);
    else odd.add(x[i]);
  }
  final fe = fft(even);
  final fo = fft(odd);
  final result = List<Complex>.filled(n, const Complex(0, 0));
  for (int k = 0; k < n ~/ 2; k++) {
    final theta = -2 * pi * k / n;
    final wk = Complex(cos(theta), sin(theta));
    final t = wk * fo[k];
    result[k] = fe[k] + t;
    result[k + n ~/ 2] = fe[k] - t;
  }
  return result;
}

class SignalProcessor {
  static final Random _random = Random();
  static double generateSample(double t) {
    final alpha = sin(2 * pi * 10 * t);
    final theta = 0.5 * sin(2 * pi * 6 * t + pi/4);
    final beta = 0.2 * sin(2 * pi * 20 * t);
    final noise = 0.08 * (_random.nextDouble() * 2 - 1);
    return alpha + theta + beta + noise;
  }

  static List<double> spectrumFromBuffer(List<double> buffer) {
    int n = 1;
    while (n < buffer.length) n <<= 1;
    final complex = List<Complex>.generate(n, (i) {
      return i < buffer.length ? Complex(buffer[i], 0) : const Complex(0, 0);
    });
    final res = fft(complex);
    final half = res.sublist(0, n ~/ 2);
    return half.map((c) => c.magnitude()).toList();
  }

  static List<double> simplePSD(List<double> buffer) {
    final window = min(256, buffer.length);
    final step = (window / 2).floor();
    if (window < 8) return List.filled(window ~/ 2, 0.0);
    final accum = List<double>.filled(window ~/ 2, 0.0);
    int count = 0;
    for (int start = 0; start + window <= buffer.length; start += step) {
      final seg = buffer.sublist(start, start + window);
      final mags = spectrumFromBuffer(seg);
      for (int i = 0; i < accum.length && i < mags.length; i++) {
        accum[i] += mags[i] * mags[i];
      }
      count++;
    }
    if (count == 0) return accum;
    for (int i = 0; i < accum.length; i++) accum[i] /= count;
    return accum;
  }

  static double bandPower(List<double> spectrum, int fftSize, double freqLow,
      double freqHigh) {
    final df = sampleRate / fftSize;
    int startBin = (freqLow / df).floor().clamp(0, spectrum.length - 1);
    int endBin = (freqHigh / df).ceil().clamp(0, spectrum.length - 1);
    if (endBin <= startBin) return 0.0;
    double sum = 0;
    for (int i = startBin; i <= endBin; i++) sum += spectrum[i];
    return sum / (endBin - startBin + 1);
  }

  static Map<String, double> hjorthParameters(List<double> buffer) {
    if (buffer.isEmpty) return {'Activity': 0.0, 'Mobility': 0.0};

    final mean = buffer.reduce((a, b) => a + b) / buffer.length;
    final activity = buffer.map((v) => pow(v - mean, 2)).reduce((a, b) => a + b) / buffer.length;

    final diff = List.generate(buffer.length - 1, (i) => buffer[i + 1] - buffer[i]);
    if (diff.isEmpty) return {'Activity': activity, 'Mobility': 0.0};

    final meanDiff = diff.reduce((a, b) => a + b) / diff.length;
    final activityDiff = diff.map((v) => pow(v - meanDiff, 2)).reduce((a, b) => a + b) / diff.length;

    final mobility = activity > 1e-9 ? sqrt(activityDiff / activity) : 0.0;

    return {'Activity': activity, 'Mobility': mobility};
  }
}

void main() {
  runApp(const EEGAnalyzerApp());
}

class EEGAnalyzerApp extends StatelessWidget {
  const EEGAnalyzerApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EEG Realtime Dashboard',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
          scaffoldBackgroundColor: const Color(0xFF000000),
          cardColor: const Color(0xFF101018),
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFF00FFFF),
            secondary: Color(0xFFFF00FF),
            background: Color(0xFF0A0A10),
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF101018),
            elevation: 0,
          )
      ),
      home: const EEGHome(),
    );
  }
}

class EEGHome extends StatefulWidget {
  const EEGHome({super.key});
  @override
  State<EEGHome> createState() => _EEGHomeState();
}

class _EEGHomeState extends State<EEGHome> with SingleTickerProviderStateMixin {
  final List<double> _buffer = List<double>.filled(bufferLength, 0.0, growable: false);
  int _writeIndex = 0;

  int selectedTabIndex = 0;
  String analysisSummary = "Press 'AI Analysis' for a summary.";
  double minYRange = -3.0;
  double maxYRange = 3.0;

  bool playing = true;
  double speed = 1.0;
  double gain = 1.0;
  bool smoothing = false;
  double _ema = 0.0;
  Timer? _timer;
  final int refreshHz = 60;
  double _time = 0.0;

  double alphaPeakFreq = 0.0;
  double alphaPeakPower = 0.0;
  double activity = 0.0;
  double mobility = 0.0;
  List<double> recentAlphaPowers = List<double>.filled(60, 0.0);
  int powerHistoryIndex = 0;
  double alphaZScore = 0.0;

  @override
  void initState() {
    super.initState();
    for (int i = 0; i < bufferLength; i++) {
      final t = i / sampleRate;
      _buffer[i] = SignalProcessor.generateSample(t);
      _writeIndex = (i + 1) % bufferLength;
      _time = t;
    }
    _startRealtime();
    _updateAnalysis();
  }

  void _startRealtime() {
    _timer?.cancel();
    final frameMs = (1000 / refreshHz).round();
    _timer = Timer.periodic(Duration(milliseconds: frameMs), (_) {
      if (!playing) return;
      final double samplesPerFrame = speed * sampleRate / refreshHz;
      int nSamplesToAdd = max(1, samplesPerFrame.round());
      for (int k = 0; k < nSamplesToAdd; k++) {
        _time += 1.0 / sampleRate;
        double sample = SignalProcessor.generateSample(_time);
        if (smoothing) {
          const alpha = 0.15;
          _ema = alpha * sample + (1 - alpha) * _ema;
          sample = _ema;
        }
        sample *= gain;
        _buffer[_writeIndex] = sample;
        _writeIndex = (_writeIndex + 1) % bufferLength;
      }
      _updateAnalysis();
      if (selectedTabIndex == 0) {
        final view = _viewBuffer();
        final peak = view.map((v) => v.abs()).reduce(max);
        if (peak * gain > maxYRange) {
          maxYRange = peak * gain * 1.2;
          minYRange = -maxYRange;
        } else if (peak * gain < maxYRange / 1.5 && maxYRange > 3.0) {
          maxYRange = max(3.0, maxYRange / 1.1);
          minYRange = -maxYRange;
        }
      }
      setState(() {});
    });
  }

  void _updateAnalysis() {
    final view = _viewBuffer();

    final spectrum = SignalProcessor.spectrumFromBuffer(view);
    final fftSize = 1 << ( (log(view.length) / log(2)).ceil() );
    final n = fftSize.toInt();

    final df = sampleRate / (spectrum.length * 2);
    int startBin = (alphaLow / df).floor().clamp(0, spectrum.length - 1);
    int endBin = (alphaHigh / df).ceil().clamp(0, spectrum.length - 1);
    int peakBin = startBin;
    double peakVal = 0;
    for (int b = startBin; b <= endBin; b++) {
      if (spectrum[b] > peakVal) {
        peakVal = spectrum[b];
        peakBin = b;
      }
    }
    alphaPeakFreq = (peakBin * df);
    alphaPeakPower = peakVal;

    final hjorth = SignalProcessor.hjorthParameters(view);
    activity = hjorth['Activity'] ?? 0.0;
    mobility = hjorth['Mobility'] ?? 0.0;

    final currentAlphaPower = SignalProcessor.bandPower(spectrum, n, alphaLow, alphaHigh);

    recentAlphaPowers[powerHistoryIndex] = currentAlphaPower;
    powerHistoryIndex = (powerHistoryIndex + 1) % recentAlphaPowers.length;

    if (recentAlphaPowers.length > 5) {
      final meanAlpha = recentAlphaPowers.reduce((a, b) => a + b) / recentAlphaPowers.length;
      final varianceAlpha = recentAlphaPowers.map((v) => pow(v - meanAlpha, 2)).reduce((a, b) => a + b) / recentAlphaPowers.length;
      final stdDevAlpha = sqrt(varianceAlpha);

      if (stdDevAlpha > 1e-9) {
        alphaZScore = (currentAlphaPower - meanAlpha) / stdDevAlpha;
      } else {
        alphaZScore = 0.0;
      }
    } else {
      alphaZScore = 0.0;
    }
  }

  void _generateAnalysisSummary() {
    String alphaState = "";
    if (alphaZScore > 1.5) {
      alphaState = "Alpha power is **significantly high** (Z-Score: ${alphaZScore.toStringAsFixed(2)}). This may indicate a highly relaxed or meditative state.";
    } else if (alphaZScore < -1.5) {
      alphaState = "Alpha power is **significantly low** (Z-Score: ${alphaZScore.toStringAsFixed(2)}). This typically suggests high engagement, alertness, or mental effort.";
    } else {
      alphaState = "Alpha power is **within the expected range** (Z-Score: ${alphaZScore.toStringAsFixed(2)}). The signal is stable.";
    }

    String activityState = "";
    if (activity > 0.6) {
      activityState = "High overall **Activity** (${activity.toStringAsFixed(3)}), suggesting a noisy or highly dynamic signal.";
    } else {
      activityState = "Stable overall **Activity** (${activity.toStringAsFixed(3)}), indicating a relatively smooth signal.";
    }

    String mobilityState = "";
    if (mobility > 0.4) {
      mobilityState = "High **Mobility** (${mobility.toStringAsFixed(3)}), meaning the dominant frequency shifts often (spikier signal).";
    } else {
      mobilityState = "Low **Mobility** (${mobility.toStringAsFixed(3)}), suggesting a stable, rhythmic signal (smoother wave).";
    }

    final summary =
        "### Signal Analysis Summary 🧠\n\n"
        "**Alpha Rhythm:** $alphaState\n\n"
        "**Signal Dynamics:** $activityState $mobilityState\n\n"
        "**Peak Frequency:** The strongest rhythmic component is at **${alphaPeakFreq.toStringAsFixed(2)} Hz** (Alpha Peak Power: ${alphaPeakPower.toStringAsFixed(2)}).\n\n"
        "**Recommendation:** Check the 'Bands' chart for a visual breakdown of power distribution (Delta, Theta, Alpha, Beta).";

    setState(() {
      analysisSummary = summary;
    });

    _showAnalysisDialog(summary);
  }

  void _showAnalysisDialog(String summary) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: Theme.of(context).cardColor,
          title: const Text('AI Signal Interpretation', style: TextStyle(color: Color(0xFF00FFFF), fontWeight: FontWeight.bold)),
          content: SingleChildScrollView(
            child: Text(
              summary.replaceAll('### ', '').replaceAll('\n\n', '\n').replaceAll('**', ''),
              style: const TextStyle(fontSize: 14),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close', style: TextStyle(color: Color(0xFFFF00FF))),
            ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  List<double> _viewBuffer() {
    final view = List<double>.filled(bufferLength, 0.0);
    for (int i = 0; i < bufferLength; i++) {
      final idx = (_writeIndex + i) % bufferLength;
      view[i] = _buffer[idx];
    }
    return view;
  }

  List<FlSpot> _bufferToSpots(List<double> buff) {
    final spots = <FlSpot>[];
    final int displayPoints = sampleRate * 2;
    final start = (buff.length - displayPoints).clamp(0, buff.length - 1);
    for (int i = 0; i < displayPoints; i++) {
      final idx = (start + i) % buff.length;
      final t = i / sampleRate;
      spots.add(FlSpot(t, buff[idx]));
    }
    return spots;
  }

  List<FlSpot> _spectrumSpots() {
    final view = _viewBuffer();
    final spectrum = SignalProcessor.spectrumFromBuffer(view);
    final n = spectrum.length * 2;
    final df = sampleRate / n;
    final spots = <FlSpot>[];
    for (int i = 0; i < spectrum.length; i++) {
      spots.add(FlSpot(i * df, spectrum[i]));
    }
    return spots;
  }

  List<FlSpot> _psdSpots() {
    final view = _viewBuffer();
    final psd = SignalProcessor.simplePSD(view);
    final n = (psd.length * 2);
    final df = sampleRate / n;
    final spots = <FlSpot>[];
    for (int i = 0; i < psd.length; i++) {
      spots.add(FlSpot(i * df, psd[i]));
    }
    return spots;
  }

  @override
  Widget build(BuildContext context) {
    final view = _viewBuffer();
    return Scaffold(
      appBar: AppBar(
        title: const Text('EEG Realtime Console', style: TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF00FFFF))),
        actions: [
          IconButton(
            icon: Icon(playing ? Icons.pause : Icons.play_arrow, color: Theme.of(context).colorScheme.primary),
            onPressed: () => setState(() => playing = !playing),
            tooltip: playing ? 'Pause' : 'Run',
          ),
          IconButton(
            icon: const Icon(Icons.settings_overscan, color: Colors.white70),
            onPressed: () => setState(() {
              maxYRange = 3.0;
              minYRange = -3.0;
            }),
            tooltip: 'Reset Signal Zoom',
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Row(children: [
        Expanded(
          flex: 7,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildControlsCard(context),
                const SizedBox(height: 10),
                _buildAnalysisBar(context),
                const SizedBox(height: 10),
                Expanded(
                  child: Card(
                    elevation: 4,
                    color: Theme.of(context).cardColor,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: Color(0xFF00FFFF), width: 0.5)),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: _buildSignalView(view, context),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        Expanded(
          flex: 3,
          child: _buildAnalysisDrawer(view, context),
        ),
      ]),
    );
  }

  Widget _buildAnalysisDrawer(List<double> view, BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF101018),
        border: Border(left: BorderSide(color: Theme.of(context).colorScheme.primary, width: 2)),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildActionButton(
                'Focus Alpha', Icons.trending_up,
                Theme.of(context).colorScheme.primary,
                    () => setState(() => selectedTabIndex = 3),
              ),
              _buildActionButton(
                'AI Analysis', Icons.insights,
                Theme.of(context).colorScheme.secondary,
                _generateAnalysisSummary,
              ),
            ],
          ),
          const Divider(height: 20, color: Colors.white12),

          _buildAnalysisTabSelector(context),
          const SizedBox(height: 12),

          Expanded(
            child: Card(
              color: const Color(0xFF151520),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: _buildCurrentAnalysis(view, context),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton(String label, IconData icon, Color color, VoidCallback onPressed) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4.0),
        child: ElevatedButton.icon(
          icon: Icon(icon, size: 16),
          label: Text(label, style: const TextStyle(fontSize: 12)),
          style: ElevatedButton.styleFrom(
            backgroundColor: color.withOpacity(0.1),
            foregroundColor: color,
            padding: const EdgeInsets.symmetric(vertical: 10),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          ),
          onPressed: onPressed,
        ),
      ),
    );
  }

  Widget _buildAnalysisTabSelector(BuildContext context) {
    final tabs = ['Signal Detail', 'Spectrum', 'PSD', 'Bands', 'Stats'];
    return Wrap(
      spacing: 6.0,
      runSpacing: 4.0,
      children: List<Widget>.generate(tabs.length, (index) {
        return ChoiceChip(
          label: Text(tabs[index], style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: selectedTabIndex == index ? Colors.black : Colors.white)),
          selected: selectedTabIndex == index,
          selectedColor: Theme.of(context).colorScheme.primary,
          backgroundColor: Theme.of(context).cardColor,
          side: BorderSide(color: selectedTabIndex == index ? Colors.transparent : Colors.white24),
          onSelected: (bool selected) {
            if (selected) {
              setState(() {
                selectedTabIndex = index;
              });
            }
          },
        );
      }),
    );
  }

  Widget _buildControlsCard(BuildContext context) {
    return Card(
      elevation: 2,
      color: const Color(0xFF101018),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.speed, color: Color(0xFF00FFFF), size: 18),
            const SizedBox(width: 4),
            Text('Speed (${speed.toStringAsFixed(1)}x)', style: const TextStyle(fontSize: 12)),
            Expanded(
              child: Slider(
                min: 0.5,
                max: 4.0,
                divisions: 7,
                value: speed,
                activeColor: Theme.of(context).colorScheme.primary,
                onChanged: (v) => setState(() => speed = v),
              ),
            ),
            const Icon(Icons.line_weight, color: Color(0xFFFF00FF), size: 18),
            const SizedBox(width: 4),
            Text('Gain (${gain.toStringAsFixed(1)}x)', style: const TextStyle(fontSize: 12)),
            SizedBox(
              width: 140,
              child: Slider(
                min: 0.2,
                max: 4.0,
                value: gain,
                activeColor: Theme.of(context).colorScheme.secondary,
                onChanged: (v) => setState(() => gain = v),
              ),
            ),
            const SizedBox(width: 8),
            const Text('Smooth', style: TextStyle(fontSize: 12)),
            Switch(
              value: smoothing,
              onChanged: (v) => setState(() => smoothing = v),
              activeColor: Theme.of(context).colorScheme.primary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnalysisBar(BuildContext context) {
    final zScoreColor = alphaZScore > 1.0 ? Colors.redAccent : alphaZScore < -1.0 ? Colors.lightGreenAccent : Colors.white70;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _buildAnalysisMetric(
            'Alpha Peak',
            '${alphaPeakFreq.toStringAsFixed(2)} Hz',
            Theme.of(context).colorScheme.primary
        ),
        _buildAnalysisMetric(
            'Activity (Var)',
            activity.toStringAsFixed(3),
            Colors.lightGreenAccent
        ),
        _buildAnalysisMetric(
            'Mobility',
            mobility.toStringAsFixed(3),
            Colors.orangeAccent
        ),
        _buildAnalysisMetric(
            'Alpha Z-Score',
            alphaZScore.toStringAsFixed(2),
            zScoreColor
        ),
      ],
    );
  }

  Widget _buildAnalysisMetric(String title, String value, Color color) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4.0),
        child: Card(
          elevation: 1,
          color: const Color(0xFF000000),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4), side: BorderSide(color: color.withOpacity(0.3), width: 0.5)),
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 10, color: color)),
                const SizedBox(height: 2),
                Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color.withOpacity(0.9))),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCurrentAnalysis(List<double> view, BuildContext context) {
    switch (selectedTabIndex) {
      case 0:
        return _buildSignalDetailView(view, context);
      case 1:
        return _buildSpectrumView(context);
      case 2:
        return _buildPSDView(context);
      case 3:
        return _buildBandsView(context);
      case 4:
        return _buildStatsView(context);
      default:
        return const Center(child: Text("Select an analysis view."));
    }
  }

  Widget _buildSignalView(List<double> view, BuildContext context) {
    final spots = _bufferToSpots(view);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('RAW EEG (2s Window)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Theme.of(context).colorScheme.primary)),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 8.0, right: 4.0),
            child: LineChart(
              LineChartData(
                minY: minYRange * gain,
                maxY: maxYRange * gain,
                minX: 0,
                maxX: (sampleRate * 2 / sampleRate).toDouble(),
                gridData: FlGridData(
                  show: true,
                  drawHorizontalLine: true,
                  getDrawingHorizontalLine: (value) => const FlLine(color: Color(0xFF00FFFF), strokeWidth: 0.2),
                  drawVerticalLine: false,
                ),
                titlesData: FlTitlesData(
                  leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 30, getTitlesWidget: (value, meta) => Text(value.toStringAsFixed(1), style: const TextStyle(fontSize: 10, color: Colors.white70)))),
                  bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, getTitlesWidget: (value, meta) => Text('${value.toInt()}s', style: const TextStyle(fontSize: 10, color: Colors.white70)))),
                  topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: true,
                    curveSmoothness: 0.1,
                    color: Theme.of(context).colorScheme.primary,
                    dotData: FlDotData(show: false),
                    barWidth: 1.0,
                  ),
                ],
                borderData: FlBorderData(show: true, border: Border.all(color: Colors.white24, width: 1)),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSignalDetailView(List<double> view, BuildContext context) {
    final detailSpots = <FlSpot>[];
    final int detailPoints = (sampleRate * 0.5).toInt();
    final start = (view.length - detailPoints).clamp(0, view.length - detailPoints);
    for (int i = 0; i < detailPoints; i++) {
      final t = i / sampleRate;
      detailSpots.add(FlSpot(t, view[start + i] * gain));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Signal Detail (Last 0.5s)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 8.0, right: 4.0),
            child: LineChart(
              LineChartData(
                minY: minYRange * gain,
                maxY: maxYRange * gain,
                minX: 0,
                maxX: 0.5,
                gridData: FlGridData(show: true, drawHorizontalLine: true, getDrawingHorizontalLine: (value) => const FlLine(color: Colors.white10, strokeWidth: 0.5)),
                titlesData: FlTitlesData(
                  leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 20, getTitlesWidget: (value, meta) => Text(value.toStringAsFixed(1), style: const TextStyle(fontSize: 8, color: Colors.white70)))),
                  bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, interval: 0.1, getTitlesWidget: (value, meta) => Text('${value.toStringAsFixed(1)}s', style: const TextStyle(fontSize: 8, color: Colors.white70)))),
                  topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: detailSpots,
                    isCurved: true,
                    curveSmoothness: 0.1,
                    color: Theme.of(context).colorScheme.secondary,
                    dotData: FlDotData(show: false),
                    barWidth: 1.0,
                  ),
                ],
                borderData: FlBorderData(show: true, border: Border.all(color: Colors.white24, width: 0.5)),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSpectrumView(BuildContext context) {
    final spots = _spectrumSpots();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Frequency Spectrum', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 8.0, right: 4.0),
            child: LineChart(
              LineChartData(
                minX: 0,
                maxX: sampleRate / 2,
                gridData: FlGridData(show: true, getDrawingHorizontalLine: (value) => const FlLine(color: Colors.white10, strokeWidth: 0.5)),
                titlesData: FlTitlesData(
                  leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 20, getTitlesWidget: (value, meta) => Text(value.toStringAsFixed(1), style: const TextStyle(fontSize: 8, color: Colors.white70)))),
                  bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, interval: 10, getTitlesWidget: (value, meta) => Text('${value.toInt()}Hz', style: const TextStyle(fontSize: 8, color: Colors.white70)))),
                  topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: false,
                    color: Theme.of(context).colorScheme.primary,
                    dotData: FlDotData(show: false),
                    barWidth: 1.0,
                  )
                ],
                borderData: FlBorderData(show: true, border: Border.all(color: Colors.white24, width: 0.5)),
                extraLinesData: ExtraLinesData(
                  verticalLines: [
                    VerticalLine(x: alphaLow, color: Colors.redAccent.withOpacity(0.6), strokeWidth: 1, dashArray: [5, 5]),
                    VerticalLine(x: alphaHigh, color: Colors.redAccent.withOpacity(0.6), strokeWidth: 1, dashArray: [5, 5]),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPSDView(BuildContext context) {
    final spots = _psdSpots();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Power Spectral Density (PSD)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 8.0, right: 4.0),
            child: LineChart(
              LineChartData(
                minX: 0,
                maxX: sampleRate / 2,
                gridData: FlGridData(show: true, getDrawingHorizontalLine: (value) => const FlLine(color: Colors.white10, strokeWidth: 0.5)),
                titlesData: FlTitlesData(
                  leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 20, getTitlesWidget: (value, meta) => Text(value.toStringAsFixed(2), style: const TextStyle(fontSize: 8, color: Colors.white70)))),
                  bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, interval: 10, getTitlesWidget: (value, meta) => Text('${value.toInt()}Hz', style: const TextStyle(fontSize: 8, color: Colors.white70)))),
                  topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: true,
                    curveSmoothness: 0.2,
                    color: Theme.of(context).colorScheme.secondary,
                    dotData: FlDotData(show: false),
                    barWidth: 1.0,
                  )
                ],
                borderData: FlBorderData(show: true, border: Border.all(color: Colors.white24, width: 0.5)),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBandsView(BuildContext context) {
    final view = _viewBuffer();
    final spectrum = SignalProcessor.spectrumFromBuffer(view);
    final n = (1 << ((log(view.length) / log(2)).ceil()));
    final delta = SignalProcessor.bandPower(spectrum, n, 0.5, 4);
    final theta = SignalProcessor.bandPower(spectrum, n, 4, 8);
    final alpha = SignalProcessor.bandPower(spectrum, n, 8, 13);
    final beta = SignalProcessor.bandPower(spectrum, n, 13, 30);
    final entries = [
      MapEntry('Delta\n(0.5-4Hz)', delta),
      MapEntry('Theta\n(4-8Hz)', theta),
      MapEntry('Alpha\n(8-13Hz)', alpha),
      MapEntry('Beta\n(13-30Hz)', beta),
    ];
    final maxValue = entries.map((e) => e.value).reduce(max) * 1.2;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Band Powers (Radar Chart)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
        Expanded(
          child: RadarChart(
            RadarChartData(
              radarShape: RadarShape.polygon,
              tickBorderData: const BorderSide(color: Colors.white12),
              gridBorderData: const BorderSide(color: Colors.white12),
              dataSets: [
                RadarDataSet(
                  dataEntries: entries.map((e) => RadarEntry(value: e.value.clamp(0.0, maxValue))).toList(),
                  fillColor: Theme.of(context).colorScheme.primary.withOpacity(0.25),
                  borderColor: Theme.of(context).colorScheme.primary,
                  borderWidth: 1.5,
                ),
              ],
              getTitle: (index, angle) => RadarChartTitle(
                text: entries[index].key,
                angle: angle,
              ),
              tickCount: 5,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStatsView(BuildContext context) {
    final view = _viewBuffer();
    final mean = view.reduce((a, b) => a + b) / view.length;
    final rms = sqrt(view.map((v) => v * v).reduce((a, b) => a + b) / view.length);
    final peak = view.map((v) => v.abs()).reduce(max);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Written Analysis', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Theme.of(context).colorScheme.secondary.withOpacity(0.5), width: 0.5)
            ),
            child: Text(
              analysisSummary.replaceAll('### ', '').replaceAll('**', ''),
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ),
          const SizedBox(height: 16),

          const Text('Key Metrics', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(height: 8),
          _buildStatRow('Signal Mean (DC Offset)', mean.toStringAsFixed(4), Colors.grey),
          _buildStatRow('RMS (Power Proxy)', rms.toStringAsFixed(4), Colors.greenAccent),
          _buildStatRow('Peak Amplitude', peak.toStringAsFixed(4), Colors.yellowAccent),
          _buildStatRow('Activity (Variance)', activity.toStringAsFixed(4), Colors.lightBlueAccent),
          _buildStatRow('Mobility (Mean Freq)', mobility.toStringAsFixed(4), Colors.orangeAccent),
        ],
      ),
    );
  }

  Widget _buildStatRow(String title, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title, style: const TextStyle(fontSize: 12, color: Colors.white70)),
          Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: color)),
        ],
      ),
    );
  }
}