import 'dart:async';
import 'dart:math';
import 'dart:ui' show lerpDouble;
import 'dart:convert';
import 'dart:io' show Platform, File;
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/gestures.dart';
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
    final activity = buffer.map((v) => pow(v - mean, 2).toDouble()).reduce((a, b) => a + b) / buffer.length;

    final diff = List.generate(buffer.length - 1, (i) => buffer[i + 1] - buffer[i]);
    if (diff.isEmpty) return {'Activity': activity, 'Mobility': 0.0};

    final meanDiff = diff.reduce((a, b) => a + b) / diff.length;
    final activityDiff = diff.map((v) => pow(v - meanDiff, 2).toDouble()).reduce((a, b) => a + b) / diff.length;

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
      routes: {
        '/educational': (context) => const BrainDemoPage(),
      },
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

  String? _openAiApiKey;

  @override
  void initState() {
    super.initState();
    _loadApiKey(); // load saved API key
    for (int i = 0; i < bufferLength; i++) {
      final t = i / sampleRate;
      _buffer[i] = SignalProcessor.generateSample(t);
      _writeIndex = (i + 1) % bufferLength;
      _time = t;
    }
    _startRealtime();
    _updateAnalysis();
  }

  Future<File> _apiKeyFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/.openai_api_key');
  }

  Future<void> _saveApiKey(String key) async {
    try {
      final f = await _apiKeyFile();
      await f.writeAsString(key.trim(), flush: true);
      setState(() => _openAiApiKey = key.trim());
    } catch (_) {}
  }

  Future<void> _loadApiKey() async {
    try {
      final f = await _apiKeyFile();
      if (await f.exists()) {
        final key = (await f.readAsString()).trim();
        if (key.isNotEmpty) setState(() => _openAiApiKey = key);
      }
    } catch (_) {}
  }

  Future<void> _clearApiKey() async {
    try {
      final f = await _apiKeyFile();
      if (await f.exists()) await f.delete();
    } catch (_) {}
    setState(() => _openAiApiKey = null);
  }

  Future<void> _promptForApiKey() async {
    final controller = TextEditingController(text: _openAiApiKey ?? '');
    await showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('OpenAI API Key'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Paste your OpenAI API key (sk-...) here. It will be stored locally.'),
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                obscureText: true,
                decoration: const InputDecoration(hintText: 'sk-...'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () { Navigator.of(ctx).pop(); }, child: const Text('Cancel')),
            TextButton(onPressed: () { _clearApiKey(); Navigator.of(ctx).pop(); }, child: const Text('Clear')),
            ElevatedButton(onPressed: () { _saveApiKey(controller.text); Navigator.of(ctx).pop(); }, child: const Text('Save')),
          ],
        );
      },
    );
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

  Future<String> _callOpenAI(String prompt) async {
    final apiKey = (_openAiApiKey != null && _openAiApiKey!.isNotEmpty)
        ? _openAiApiKey!
        : (Platform.environment['OPENAI_API_KEY'] ?? '');
    if (apiKey.isEmpty) {
      throw Exception('OpenAI API key not set. Either set the OPENAI_API_KEY environment variable or open Settings (key icon) in the app and paste your key.');
    }
    final uri = Uri.parse('https://api.openai.com/v1/chat/completions');
    final body = {
      'model': 'gpt-4o-mini',
      'messages': [
        {'role': 'system', 'content': 'You are an expert EEG analyst. Provide concise clinical-style interpretation and recommended preprocessing steps.'},
        {'role': 'user', 'content': prompt}
      ],
      'max_tokens': 700,
      'temperature': 0.2,
    };
    final resp = await http.post(uri, headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $apiKey'
    }, body: jsonEncode(body));
    if (resp.statusCode == 200) {
      final j = jsonDecode(resp.body);
      final choice = j['choices']?[0];
      final content = choice?['message']?['content'] ?? choice?['text'] ?? '';
      return content.toString();
    } else {
      throw Exception('OpenAI error ${resp.statusCode}: ${resp.body}');
    }
  }

  Future<void> _performAIAnalysis() async {
    final view = _viewBuffer();
    final spectrum = SignalProcessor.spectrumFromBuffer(view);
    final fftSize = 1 << ((log(view.length) / log(2)).ceil());
    final features = {
      'alphaPeakFreq': alphaPeakFreq,
      'alphaPeakPower': alphaPeakPower,
      'activity': activity,
      'mobility': mobility,
      'alphaZScore': alphaZScore,
      'recentAlphaMean': recentAlphaPowers.reduce((a, b) => a + b) / recentAlphaPowers.length,
    };
    final snippet = view.sublist(max(0, view.length - 256));
    final prompt = StringBuffer();
    prompt.writeln('Provide a concise EEG interpretation and practical recommendations.');
    prompt.writeln('Features: ${jsonEncode(features)}');
    prompt.writeln('Short time-domain snippet (last 256 samples) stats: mean=${(snippet.reduce((a,b)=>a+b)/snippet.length).toStringAsFixed(4)}, rms=${(sqrt(snippet.map((v)=>v*v).reduce((a,b)=>a+b)/snippet.length)).toStringAsFixed(4)}');
    prompt.writeln('Notes: mention likely artifacts, preprocessing suggestions (filtering, notch, ICA), and a short summary line for clinicians.');
    String aiText = '';
    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
    try {
      aiText = await _callOpenAI(prompt.toString());
      if (mounted) Navigator.of(context).pop();
      _showAnalysisDialog(aiText);
    } catch (e) {
      if (mounted) Navigator.of(context).pop();
      _showAnalysisDialog('AI request failed: $e\n\nFallback local summary:\n\n${analysisSummary.replaceAll("### ", "").replaceAll("**", "")}');
    }
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
          IconButton(
            icon: const Icon(Icons.school_outlined, color: Colors.white70),
            onPressed: () => Navigator.pushNamed(context, '/educational'),
            tooltip: 'Educational Brain Demo',
          ),
          IconButton(
            icon: const Icon(Icons.vpn_key, color: Colors.white70),
            tooltip: 'OpenAI API Key',
            onPressed: _promptForApiKey,
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
                () => _performAIAnalysis(),
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

class BrainDemoPage extends StatefulWidget {
  const BrainDemoPage({super.key});
  @override
  State<BrainDemoPage> createState() => _BrainDemoPageState();
}

class _BrainDemoPageState extends State<BrainDemoPage> {
  bool bipolar = true;
  double zoom = 1.0;
  double rotX = 0.0;
  double rotY = 0.0;
  double rotZ = 0.0;
  double _startZoom = 1.0;
  bool showLabels = true;
  final GlobalKey _paintKey = GlobalKey();
  String? highlightedElectrode;

  final Map<String, String> learnTopics = {
    'Cortex & Folding': 'Short summary: The cortex is highly folded (gyri/sulci) to maximize surface area. Folds reflect functional organisation and are key to EEG source geometry.',
    'EEG Bands': 'Alpha (8–13Hz) often linked to relaxation, Beta (13–30Hz) to alertness, Theta (4–8Hz) to drowsiness, Delta (0.5–4Hz) to deep sleep.',
    'Montages': 'Bipolar connects adjacent electrodes emphasizing phase differences. Referential references all electrodes to a common point (e.g., Cz) emphasizing amplitude distribution.',
    'Artifacts': 'Common artifacts include eye blinks, muscle (EMG) and line noise. Recognising them is crucial before interpretation.',
  };

  Map<String, Offset> _computeProjectedElectrodes(Size size) {
    final center = size.center(Offset.zero);
    final baseR = min(size.width, size.height) * 0.36 * zoom;
    final focal = baseR * 3.2;
    final ellA = baseR * 0.9;
    final ellB = baseR * 0.76;
    final ellC = baseR * 0.55;
    Map<String, Offset3D> electrodeLocal = {
      'Fp1': const Offset3D(-0.62, -0.78, 0.0),
      'Fp2': const Offset3D(0.62, -0.78, 0.0),
      'F3': const Offset3D(-0.42, -0.42, 0.0),
      'F4': const Offset3D(0.42, -0.42, 0.0),
      'C3': const Offset3D(-0.48, 0.05, 0.0),
      'C4': const Offset3D(0.48, 0.05, 0.0),
      'P3': const Offset3D(-0.42, 0.5, 0.0),
      'P4': const Offset3D(0.42, 0.5, 0.0),
      'O1': const Offset3D(-0.62, 0.82, 0.0),
      'O2': const Offset3D(0.62, 0.82, 0.0),
      'Cz': const Offset3D(0.0, 0.08, 0.0),
    };

    Offset3D rotate3d(Offset3D p, double ax, double ay, double az) {
      double x = p.x, y = p.y, z = p.z;
      double cosX = cos(ax), sinX = sin(ax);
      double cosY = cos(ay), sinY = sin(ay);
      double cosZ = cos(az), sinZ = sin(az);
      double y1 = y * cosX - z * sinX;
      double z1 = y * sinX + z * cosX;
      double x2 = x * cosY + z1 * sinY;
      double z2 = -x * sinY + z1 * cosY;
      double x3 = x2 * cosZ - y1 * sinZ;
      double y3 = x2 * sinZ + y1 * cosZ;
      return Offset3D(x3, y3, z2);
    }

    Offset project(Offset3D p) {
      final double z = p.z + focal;
      final double k = z.abs() < 1e-6 ? 1.0 : focal / z;
      return center + Offset(p.x * k, p.y * k);
    }

    final Map<String, Offset> projected = {};
    electrodeLocal.forEach((k, v) {
      final nx = v.x;
      final ny = v.y;
      final inside = 1 - (nx * nx) - (ny * ny);
      final nz = inside > 0 ? sqrt(inside) : 0.0;
      final vx = nx * ellA;
      final vy = ny * ellB;
      final vz = nz * ellC;
      final rotated = rotate3d(Offset3D(vx, vy, vz), rotX, rotY, rotZ);
      projected[k] = project(rotated);
    });
    return projected;
  }

  void _handleTapDown(TapDownDetails details) {
    final RenderBox? box = _paintKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(details.globalPosition);
    final size = box.size;
    final proj = _computeProjectedElectrodes(size);
    String? nearest;
    double bestDist = double.infinity;
    proj.forEach((k, v) {
      final d = (v - local).distance;
      if (d < bestDist) {
        bestDist = d;
        nearest = k;
      }
    });
    if (nearest != null && bestDist < 28.0) {
      setState(() => highlightedElectrode = nearest);
      _showElectrodeInfo(nearest!, proj[nearest]!);
    } else {
      setState(() => highlightedElectrode = null);
    }
  }

  void _showElectrodeInfo(String label, Offset pos) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).cardColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      builder: (_) {
        return Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('Electrode: $label', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF00FFFF))),
              TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close', style: TextStyle(color: Colors.white70))),
            ]),
            const SizedBox(height: 8),
            Text('Position: ${pos.dx.toStringAsFixed(0)}, ${pos.dy.toStringAsFixed(0)}', style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 8),
            const Text('Quick Notes:', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(
              label == 'Cz'
                  ? 'Central reference point. Useful as a referential anchor.'
                  : 'Located on the scalp surface. Connects to adjacent electrodes in bipolar montage.',
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              icon: const Icon(Icons.school),
              label: const Text('Learn more (topics)'),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00FFFF)),
              onPressed: () {
                Navigator.of(context).pop();
                _openTopic('Montages');
              },
            ),
          ]),
        );
      },
    );
  }

  void _openTopic(String key) {
    final content = learnTopics[key] ?? 'Topic not found';
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Theme.of(context).cardColor,
        title: Text(key, style: const TextStyle(color: Color(0xFF00FFFF))),
        content: Text(content, style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close', style: TextStyle(color: Color(0xFFFF00FF)))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(bipolar ? 'Bipolar Montage' : 'Referential Montage'),
        actions: [
          Row(children: [
            const Text('Labels', style: TextStyle(fontSize: 12)),
            Switch(value: showLabels, onChanged: (v) => setState(() => showLabels = v)),
            IconButton(
              icon: const Icon(Icons.info_outline),
              onPressed: () {
                showDialog(context: context, builder: (_) => AlertDialog(
                  backgroundColor: Theme.of(context).cardColor,
                  title: const Text('LearnEEG Guide', style: TextStyle(color: Color(0xFF00FFFF))),
                  content: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Quick guided topics inspired by LearnEEG:', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    ...learnTopics.entries.map((e) => Padding(padding: const EdgeInsets.symmetric(vertical:4), child: Text('• ${e.key}: ${e.value}', style: const TextStyle(color: Colors.white70)))),
                  ])),
                  actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
                ));
              },
            ),
          ]),
          Switch(
            value: bipolar,
            onChanged: (v) => setState(() => bipolar = v),
          )
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final paintSize = Size(min(420.0, constraints.maxWidth * 0.66), min(420.0, constraints.maxHeight * 0.85));
          final proj = _computeProjectedElectrodes(paintSize);
          return Row(children: [
            Expanded(
              flex: 3,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Card(
                  color: Theme.of(context).cardColor,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  child: Stack(children: [
                    Positioned.fill(
                      child: Center(
                        child: GestureDetector(
                          onTapDown: _handleTapDown,
                          child: Container(
                            key: _paintKey,
                            width: paintSize.width,
                            height: paintSize.height,
                            alignment: Alignment.center,
                            child: CustomPaint(
                              size: paintSize,
                              painter: BrainPainter(bipolar: bipolar, rotX: rotX, rotY: rotY, rotZ: rotZ, zoom: zoom),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (showLabels)
                      ...proj.entries.map((e) {
                        final p = e.value;
                        return Positioned(
                          left: p.dx - 18,
                          top: p.dy - 18,
                          child: IgnorePointer(
                            child: Column(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal:6, vertical:2),
                                  decoration: BoxDecoration(color: highlightedElectrode == e.key ? const Color(0xFF00FFFF) : Colors.black.withOpacity(0.5), borderRadius: BorderRadius.circular(6)),
                                  child: Text(e.key, style: const TextStyle(fontSize: 10, color: Colors.white)),
                                ),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                    Positioned(
                      left: 12,
                      top: 12,
                      child: Card(
                        color: Colors.black.withOpacity(0.45),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal:8, vertical:6),
                          child: Row(children: [
                            const Icon(Icons.touch_app, size: 14, color: Colors.white70),
                            const SizedBox(width:6),
                            Text('Tap electrodes for info', style: TextStyle(color: Colors.white70, fontSize: 12)),
                          ]),
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.only(right:12.0, top:12, bottom:12),
                child: Column(
                  children: [
                    Card(
                      color: const Color(0xFF080820),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          const Text('LearnEEG Topics', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF00FFFF))),
                          const SizedBox(height: 8),
                          ...learnTopics.keys.map((k) => ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(k, style: const TextStyle(color: Colors.white70)),
                            trailing: IconButton(icon: const Icon(Icons.open_in_new, color: Colors.white70, size: 18), onPressed: () => _openTopic(k)),
                          )),
                        ]),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Card(
                      color: const Color(0xFF0E0E1A),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: Column(children: [
                          const Text('Visualization Controls', style: TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(height:8),
                          Row(children: [
                            const Text('Zoom', style: TextStyle(color: Colors.white70)),
                            Expanded(child: Slider(min:0.6, max:2.5, value: zoom, onChanged: (v) => setState(()=>zoom=v))),
                          ]),
                          Row(children: [
                            const Text('Rotation X', style: TextStyle(color: Colors.white70)),
                            Expanded(child: Slider(min:-pi/2, max:pi/2, value: rotX, onChanged: (v) => setState(()=>rotX=v))),
                          ]),
                          Row(children: [
                            const Text('Rotation Y', style: TextStyle(color: Colors.white70)),
                            Expanded(child: Slider(min:-pi/2, max:pi/2, value: rotY, onChanged: (v) => setState(()=>rotY=v))),
                          ]),
                          Row(children: [
                            const Text('Rotation Z', style: TextStyle(color: Colors.white70)),
                            Expanded(child: Slider(min:-pi, max:pi, value: rotZ, onChanged: (v) => setState(()=>rotZ=v))),
                          ]),
                          const SizedBox(height:8),
                          ElevatedButton.icon(
                            icon: const Icon(Icons.refresh),
                            label: const Text('Reset View'),
                            onPressed: () => setState(() { rotX = rotY = rotZ = 0.0; zoom = 1.0; }),
                            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00FFFF)),
                          ),
                        ]),
                      ),
                    ),
                  ],
                ),
              ),
            )
          ]);
        },
      ),
    );
  }
}

class BrainPainter extends CustomPainter {
  final bool bipolar;
  final double rotX;
  final double rotY;
  final double rotZ;
  final double zoom;
  BrainPainter({
    required this.bipolar,
    required this.rotX,
    required this.rotY,
    required this.rotZ,
    required this.zoom,
  });

  Offset _project(Offset3D p, Offset center, double focal) {
    final double z = p.z + focal;
    final double k = z.abs() < 1e-6 ? 1.0 : focal / z;
    return center + Offset(p.x * k, p.y * k);
  }

  Offset3D _rotate(Offset3D p, double ax, double ay, double az) {
    double x = p.x, y = p.y, z = p.z;
    double cosX = cos(ax), sinX = sin(ax);
    double cosY = cos(ay), sinY = sin(ay);
    double cosZ = cos(az), sinZ = sin(az);
    double y1 = y * cosX - z * sinX;
    double z1 = y * sinX + z * cosX;
    double x2 = x * cosY + z1 * sinY;
    double z2 = -x * sinY + z1 * cosY;
    double x3 = x2 * cosZ - y1 * sinZ;
    double y3 = x2 * sinZ + y1 * cosZ;
    return Offset3D(x3, y3, z2);
  }

  List<String> _labelsOrderByDepth(Map<String, Offset3D> pts) {
    final list = pts.entries.toList();
    list.sort((a, b) => b.value.z.compareTo(a.value.z));
    return list.map((e) => e.key).toList();
  }

  void _drawHemisphereMesh(Canvas canvas, Offset center, double ellA, double ellB, double ellC,
      double rotX, double rotY, double rotZ, bool left, Color fillBase) {
    final int lat = 18;
    final int lon = 48;
    final focal = ellA * 3.2;
    final meshPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9
      ..color = fillBase.withOpacity(0.85)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

    for (int r = 0; r < lat; r++) {
      final t = r / (lat - 1);
      final y = lerpDouble(0.95, -0.95, t)!;
      final ring = sqrt(max(0.0, 1 - y * y));
      final path = Path();
      for (int s = 0; s <= lon; s++) {
        final theta = (s / lon) * pi;
        final fold = 0.08 * sin(theta * 6 + t * 6 + rotY * 2.0) * (0.9 - t) * 0.9;
        final xNorm = cos(theta) * (ring + fold) * (left ? -1.0 : 1.0);
        final zNorm = sin(theta) * (ring + fold);
        final vx = xNorm * ellA;
        final vy = y * ellB;
        final vz = zNorm * ellC;
        final rotated = _rotate(Offset3D(vx, vy, vz), rotX, rotY + (left ? -0.06 : 0.06), rotZ * 0.6);
        final p = _project(rotated, center, focal);
        if (s == 0) path.moveTo(p.dx, p.dy);
        else path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, meshPaint);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final baseR = min(size.width, size.height) * 0.36 * zoom;
    final focal = baseR * 3.2;
    final ellA = baseR * 0.9;
    final ellB = baseR * 0.76;
    final ellC = baseR * 0.55;

    final bg = Rect.fromLTWH(0, 0, size.width, size.height);
    final Paint bgPaint = Paint()
      ..shader = RadialGradient(
        colors: [const Color(0xFF060217), const Color(0xFF0B0530)],
        center: Alignment(0.0, -0.25),
        radius: 1.0,
      ).createShader(bg);
    canvas.drawRect(bg, bgPaint);

    if (bipolar) {
      final meshBase = Colors.cyanAccent;
      _drawHemisphereMesh(canvas, center, ellA, ellB, ellC, rotX, rotY, rotZ, true, meshBase);
      _drawHemisphereMesh(canvas, center, ellA, ellB, ellC, rotX, rotY, rotZ, false, meshBase);

      final nodes = <Offset>[];
      final nodes3 = <Offset3D>[];
      for (int i = 2; i < 16; i += 2) {
        final phi = lerpDouble(-pi / 2, pi / 2, i / 16)!;
        final yNorm = sin(phi);
        final ring = sqrt(max(0.0, 1 - yNorm * yNorm));
        for (int j = 0; j < 40; j += 3) {
          final theta = (j / 40) * 2 * pi;
          final fold = 0.08 * sin(theta * 4 + i * 0.8 + rotY * 2.0);
          final xNorm = cos(theta) * (ring + fold);
          final zNorm = sin(theta) * (ring + fold);
          final vx = xNorm * ellA;
          final vy = yNorm * ellB * 1.02;
          final vz = zNorm * ellC;
          final r = _rotate(Offset3D(vx, vy, vz), rotX, rotY, rotZ);
          nodes3.add(r);
          nodes.add(_project(r, center, focal));
        }
      }

      final glow = Paint()..color = Colors.blueAccent.withOpacity(0.12)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14);
      final core = Paint()..color = Colors.lightBlueAccent;
      for (int k = 0; k < nodes.length; k++) {
        canvas.drawCircle(nodes[k], 10.0 * (0.5 + (k % 3) * 0.12), glow);
        canvas.drawCircle(nodes[k], 3.5, core);
      }

      final conn = Paint()
        ..strokeWidth = 0.9
        ..style = PaintingStyle.stroke
        ..color = Colors.cyanAccent.withOpacity(0.12);
      for (int a = 0; a < nodes3.length; a++) {
        for (int b = a + 1; b < nodes3.length; b++) {
          final d3 = sqrt(pow(nodes3[a].x - nodes3[b].x, 2) + pow(nodes3[a].y - nodes3[b].y, 2) + pow(nodes3[a].z - nodes3[b].z, 2));
          if (d3 < baseR * 0.36) {
            final pa = _project(nodes3[a], center, focal);
            final pb = _project(nodes3[b], center, focal);
            conn.color = Colors.cyanAccent.withOpacity((1.0 - d3 / (baseR * 0.36)).clamp(0.05, 0.4));
            canvas.drawLine(pa, pb, conn);
          }
        }
      }
    } else {
      final meshBase = Colors.deepPurpleAccent;
      _drawHemisphereMesh(canvas, center, ellA, ellB, ellC, rotX * 0.9, rotY * 0.9, rotZ * 0.9, true, meshBase);
      _drawHemisphereMesh(canvas, center, ellA, ellB, ellC, rotX * 0.9, rotY * 0.9, rotZ * 0.9, false, meshBase);

      final nodes = <Offset>[];
      final nodes3 = <Offset3D>[];
      for (int i = 2; i < 16; i += 3) {
        final phi = lerpDouble(-pi / 2, pi / 2, i / 16)!;
        final yNorm = sin(phi);
        final ring = sqrt(max(0.0, 1 - yNorm * yNorm));
        for (int j = 0; j < 36; j += 4) {
          final theta = (j / 36) * 2 * pi;
          final fold = 0.06 * sin(theta * 4 + i * 0.6 + rotY * 1.6);
          final xNorm = cos(theta) * (ring + fold);
          final zNorm = sin(theta) * (ring + fold);
          final vx = xNorm * ellA;
          final vy = yNorm * ellB * 1.01;
          final vz = zNorm * ellC;
          final r = _rotate(Offset3D(vx, vy, vz), rotX * 0.9, rotY * 0.9, rotZ * 0.7);
          nodes3.add(r);
          nodes.add(_project(r, center, focal));
        }
      }

      final glow = Paint()..color = Colors.purpleAccent.withOpacity(0.12)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14);
      final core = Paint()..color = Colors.deepPurpleAccent;
      for (int k = 0; k < nodes.length; k++) {
        canvas.drawCircle(nodes[k], 10.0 * (0.5 + (k % 3) * 0.12), glow);
        canvas.drawCircle(nodes[k], 3.5, core);
      }

      final conn = Paint()
        ..strokeWidth = 0.9
        ..style = PaintingStyle.stroke
        ..color = Colors.purpleAccent.withOpacity(0.12);
      for (int a = 0; a < nodes3.length; a++) {
        for (int b = a + 1; b < nodes3.length; b++) {
          final d3 = sqrt(pow(nodes3[a].x - nodes3[b].x, 2) + pow(nodes3[a].y - nodes3[b].y, 2) + pow(nodes3[a].z - nodes3[b].z, 2));
          if (d3 < baseR * 0.36) {
            final pa = _project(nodes3[a], center, focal);
            final pb = _project(nodes3[b], center, focal);
            conn.color = Colors.purpleAccent.withOpacity((1.0 - d3 / (baseR * 0.36)).clamp(0.04, 0.36));
            canvas.drawLine(pa, pb, conn);
          }
        }
      }
    }

    // electrodes projection and labels
    final Map<String, Offset3D> electrodeLocal = {
      'Fp1': Offset3D(-0.62, -0.78, 0.0),
      'Fp2': Offset3D(0.62, -0.78, 0.0),
      'F3': Offset3D(-0.42, -0.42, 0.0),
      'F4': Offset3D(0.42, -0.42, 0.0),
      'C3': Offset3D(-0.48, 0.05, 0.0),
      'C4': Offset3D(0.48, 0.05, 0.0),
      'P3': Offset3D(-0.42, 0.5, 0.0),
      'P4': Offset3D(0.42, 0.5, 0.0),
      'O1': Offset3D(-0.62, 0.82, 0.0),
      'O2': Offset3D(0.62, 0.82, 0.0),
      'Cz': Offset3D(0.0, 0.08, 0.0),
    };

    final Map<String, Offset3D> rotated = {};
    electrodeLocal.forEach((k, v) {
      final nx = v.x;
      final ny = v.y;
      final inside = 1 - (nx * nx) - (ny * ny);
      final nz = inside > 0 ? sqrt(inside) : 0.0;
      final vx = nx * ellA;
      final vy = ny * ellB;
      final vz = nz * ellC;
      rotated[k] = _rotate(Offset3D(vx, vy, vz), rotX, rotY, rotZ);
    });

    final projected = <String, Offset>{};
    rotated.forEach((k, v) {
      projected[k] = _project(v, center, focal);
    });

    // bipolar montage connections
    if (bipolar && projected.isNotEmpty) {
      final chains = [
        ['Fp1', 'F3', 'C3', 'P3', 'O1'],
        ['Fp2', 'F4', 'C4', 'P4', 'O2'],
      ];
      final connectionPaint = Paint()
        ..strokeWidth = 1.4
        ..style = PaintingStyle.stroke;
      for (var chain in chains) {
        for (int i = 0; i < chain.length - 1; i++) {
          final aKey = chain[i];
          final bKey = chain[i + 1];
          if (!projected.containsKey(aKey) || !projected.containsKey(bKey)) continue;
          final pa = projected[aKey]!;
          final pb = projected[bKey]!;
          final ra = rotated[aKey]!;
          final rb = rotated[bKey]!;
          final depthFactor = (((ra.z + rb.z) / 2) / (ellC * 0.6)).clamp(-1.0, 1.0);
          connectionPaint.color = Colors.cyanAccent.withOpacity((0.85 - depthFactor * 0.4).clamp(0.2, 0.95));
          canvas.drawLine(pa, pb, connectionPaint);
        }
      }
    } else {
      final connectionPaint = Paint()
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke
        ..color = Colors.orangeAccent.withOpacity(0.9);
      projected.forEach((k, p) {
        if (k != 'Cz') {
          canvas.drawLine(p, projected['Cz']!, connectionPaint);
        }
      });
    }

    final order = _labelsOrderByDepth(rotated);

    for (final label in order) {
      final pos3 = rotated[label]!;
      final pos = projected[label]!;
      final depthNorm = ((pos3.z + ellC) / (ellC * 2)).clamp(0.0, 1.0);
      final glow = Paint()
        ..color = Colors.white.withOpacity(0.06 + depthNorm * 0.24)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
      canvas.drawCircle(pos, lerpDouble(8, 14, depthNorm)!, glow);
      final Paint electrodePaint = Paint()..color = Color.lerp(Colors.black, Colors.deepPurple.shade900, depthNorm)!;
      canvas.drawCircle(pos, lerpDouble(4.5, 7.5, depthNorm)!, electrodePaint);

      final tp = TextPainter(
        text: TextSpan(text: label, style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.95 - depthNorm * 0.6), fontWeight: FontWeight.w700)),
        textDirection: TextDirection.ltr,
      );
      tp.layout();
      final labelOffset = Offset(12 * (pos3.x >= 0 ? 1 : -1), -12);
      tp.paint(canvas, pos + labelOffset);
    }

    final hintPainter = TextPainter(
      text: TextSpan(
        text: 'Rotate • Pinch to zoom • Double-tap to reset',
        style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.75)),
      ),
      textDirection: TextDirection.ltr,
    );
    hintPainter.layout();
    hintPainter.paint(canvas, center + Offset(-hintPainter.width / 2, baseR + 28));
  }

  void _drawHemisphereSurface(Canvas canvas, Offset centerLocal, double a, double b, double c, bool left) {
    final int lat = 20;
    final int lon = 40;
    final focal = a * 3.2;
    final foldPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = Colors.white.withOpacity(0.06);

    for (int r = 0; r <= lat; r++) {
      final t = r / lat;
      final phi = lerpDouble(-pi / 2, pi / 2, t)!;
      final yNorm = sin(phi);
      final ring = sqrt(max(0.0, 1 - yNorm * yNorm));
      final path = Path();
      for (int s = 0; s <= lon; s++) {
        final theta = (s / lon) * pi;
        final fold = 0.06 * sin(theta * 5 + t * 6.0) * (1.0 - t);
        final xNorm = cos(theta) * (ring + fold) * (left ? -1 : 1);
        final zNorm = sin(theta) * (ring + fold);
        final vx = xNorm * a;
        final vy = yNorm * b;
        final vz = zNorm * c;
        final rotated = _rotate(Offset3D(vx, vy, vz), rotX * 0.5, rotY * 0.6, rotZ * 0.4);
        final p = _project(rotated, centerLocal + Offset(0, 0), a * 3.2);
        if (s == 0) path.moveTo(p.dx, p.dy);
        else path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, foldPaint);
    }
  }

  @override
  bool shouldRepaint(covariant BrainPainter oldDelegate) {
    return oldDelegate.rotX != rotX ||
        oldDelegate.rotY != rotY ||
        oldDelegate.rotZ != rotZ ||
        oldDelegate.zoom != zoom ||
        oldDelegate.bipolar != bipolar;
  }
}

class Offset3D {
  final double x;
  final double y;
  final double z;
  const Offset3D(this.x, this.y, this.z);
}
