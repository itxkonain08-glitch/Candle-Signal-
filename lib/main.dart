import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

const base = 'https://fapi.binance.com';

/// Optional trained-model server (serves 5m only). Leave empty for built-in signals.
const backendUrl = '';

/// Candle lengths in minutes. Binance has no 2m candle, so 2m is built from 1m candles.
const timeframes = [1, 2, 3, 5];

/// Short timeframes scan only the most-traded coins, to stay fast and save mobile data.
const shortUniverse = 100;

// Trader palette
const kBg = Color(0xFF0B0E11);
const kPanel = Color(0xFF181A20);
const kGold = Color(0xFFF0B90B);
const kGreen = Color(0xFF0ECB81);
const kRed = Color(0xFFF6465D);
const kMuted = Color(0xFF848E9C);

void main() => runApp(const CandleSignalApp());

class CandleSignalApp extends StatelessWidget {
  const CandleSignalApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Futures Signals',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          scaffoldBackgroundColor: kBg,
          appBarTheme: const AppBarTheme(
            backgroundColor: kBg,
            elevation: 0,
            scrolledUnderElevation: 0,
          ),
        ),
        home: const SignalPage(),
      );
}

// ---------- Data ----------

class Candle {
  final int openTime;
  final double open, close;
  Candle(this.openTime, this.open, this.close);

  factory Candle.fromJson(List j) => Candle(
        j[0] as int,
        double.parse(j[1] as String),
        double.parse(j[4] as String),
      );
}

class Pred {
  final int candleTime;
  final bool up;
  bool top = false;
  Pred(this.candleTime, this.up);
}

class Signal {
  final String symbol;
  final double price, pUp, movePct;
  final bool model;
  Signal(this.symbol, this.price, this.pUp, this.movePct, {this.model = false});

  bool get up => pUp >= 0.5;
  double get strength => max(pUp, 1 - pUp);
  double get predicted => price * (1 + movePct);
  double get score => log(pUp / (1 - pUp)).abs();
  String get label => model
      ? 'Confidence ${(strength * 100).toStringAsFixed(0)}%'
      : 'Score ${score.toStringAsFixed(1)}';
  String get base =>
      symbol.endsWith('USDT') ? symbol.substring(0, symbol.length - 4) : symbol;
}

/// Builds n-minute candles out of 1-minute candles.
List<Candle> aggregate(List<Candle> m1, int n) {
  final ms = n * 60000;
  final out = <Candle>[];
  for (final c in m1) {
    final b = c.openTime ~/ ms * ms;
    if (out.isNotEmpty && out.last.openTime == b) {
      final l = out.last;
      out[out.length - 1] = Candle(b, l.open, c.close);
    } else {
      out.add(Candle(b, c.open, c.close));
    }
  }
  // Drop the first bucket if the data started in the middle of it.
  if (m1.isNotEmpty && out.isNotEmpty && m1.first.openTime != out.first.openTime) {
    out.removeAt(0);
  }
  return out;
}

// ---------- Built-in rule-based signal ----------

double ema(List<double> v, int n) {
  final k = 2 / (n + 1);
  var e = v.first;
  for (final x in v.skip(1)) {
    e = x * k + e * (1 - k);
  }
  return e;
}

double rsi(List<double> c, int n) {
  var gain = 0.0, loss = 0.0;
  for (var i = c.length - n; i < c.length; i++) {
    final d = c[i] - c[i - 1];
    if (d > 0) {
      gain += d;
    } else {
      loss -= d;
    }
  }
  if (loss == 0) return 100;
  final rs = (gain / n) / (loss / n);
  return 100 - 100 / (1 + rs);
}

double probUp(List<Candle> closed) {
  final closes = closed.map((c) => c.close).toList();
  final last = closes.last;
  final trend = (ema(closes, 9) - ema(closes, 21)) / last * 500;
  final meanRev = (50 - rsi(closes, 14)) / 50;
  final mom = (last - closes[closes.length - 4]) / last * 300;
  final z = (0.8 * trend + 0.6 * meanRev + 0.4 * mom).clamp(-6.0, 6.0).toDouble();
  return 1 / (1 + exp(-z));
}

double avgMove(List<Candle> closed) {
  final recent = closed.sublist(closed.length - 20);
  final sum = recent.fold<double>(0, (a, c) => a + (c.close - c.open).abs() / c.open);
  return sum / recent.length;
}

String fmt(double p) => p >= 100
    ? p.toStringAsFixed(2)
    : p >= 1
        ? p.toStringAsFixed(4)
        : p.toStringAsPrecision(4);

// ---------- UI ----------

class SignalPage extends StatefulWidget {
  const SignalPage({super.key});

  @override
  State<SignalPage> createState() => _SignalPageState();
}

class _SignalPageState extends State<SignalPage> {
  List<String> symbols = [];
  List<Signal> signals = [];
  final Map<String, Pred> preds = {};
  int allWins = 0, allTotal = 0, topWins = 0, topTotal = 0;
  bool scanning = false;
  int scanned = 0;
  int scanTotal = 0;
  int lastScanSlot = 0;
  int tf = 5; // candle length in minutes
  int tab = 0; // 0 all, 1 buy, 2 sell
  String? error;
  String query = '';
  DateTime now = DateTime.now();
  Timer? timer;

  int get slotMs => tf * 60000;
  int slotOf(DateTime t) => t.millisecondsSinceEpoch ~/ slotMs;

  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => now = DateTime.now());
      // Scan once per candle, 3 seconds after it opens.
      if (!scanning &&
          slotOf(now) != lastScanSlot &&
          now.millisecondsSinceEpoch % slotMs >= 3000) {
        scan();
      }
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  void setTf(int v) {
    if (v == tf) return;
    setState(() {
      tf = v;
      signals = [];
      preds.clear();
      allWins = 0;
      allTotal = 0;
      topWins = 0;
      topTotal = 0;
      lastScanSlot = 0;
      error = null;
    });
  }

  Future<void> loadSymbols() async {
    final r = await http
        .get(Uri.parse('$base/fapi/v1/exchangeInfo'))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw 'Could not load coin list (HTTP ${r.statusCode})';
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    final list = (data['symbols'] as List)
        .where((s) =>
            s['contractType'] == 'PERPETUAL' &&
            s['quoteAsset'] == 'USDT' &&
            s['status'] == 'TRADING')
        .map<String>((s) => s['symbol'] as String)
        .toList();

    // Sort by 24h trading volume so short timeframes can use the most liquid coins.
    final vol = <String, double>{};
    try {
      final t = await http
          .get(Uri.parse('$base/fapi/v1/ticker/24hr'))
          .timeout(const Duration(seconds: 15));
      if (t.statusCode == 200) {
        for (final e in jsonDecode(t.body) as List) {
          vol[e['symbol'] as String] = double.tryParse('${e['quoteVolume']}') ?? 0;
        }
      }
    } catch (_) {}
    list.sort((a, b) => (vol[b] ?? 0).compareTo(vol[a] ?? 0));
    symbols = list;
  }

  Future<Signal?> fetchSignal(String sym, int myTf) async {
    final iv = myTf == 2 ? '1m' : '${myTf}m';
    final lim = myTf == 2 ? 120 : 60;
    final r = await http
        .get(Uri.parse('$base/fapi/v1/klines?symbol=$sym&interval=$iv&limit=$lim'))
        .timeout(const Duration(seconds: 10));
    if (r.statusCode == 429 || r.statusCode == 418) {
      throw 'Binance rate limit hit. Wait a minute, then tap refresh.';
    }
    if (r.statusCode != 200) return null;
    if (myTf != tf) return null; // timeframe changed while loading

    var list = (jsonDecode(r.body) as List)
        .map((e) => Candle.fromJson(e as List))
        .toList();
    if (myTf == 2) list = aggregate(list, 2);
    if (list.length < 40) return null;
    final closed = list.sublist(0, list.length - 1);
    final cur = list.last;

    final prev = preds[sym];
    if (prev != null) {
      for (final c in closed) {
        if (c.openTime == prev.candleTime) {
          final ok = (c.close > c.open) == prev.up;
          allTotal++;
          if (ok) allWins++;
          if (prev.top) {
            topTotal++;
            if (ok) topWins++;
          }
          preds.remove(sym);
          break;
        }
      }
    }

    final p = probUp(closed);
    final move = (p - 0.5) * 2 * avgMove(closed);

    final existing = preds[sym];
    if (existing == null || existing.candleTime != cur.openTime) {
      final age = DateTime.now().millisecondsSinceEpoch - cur.openTime;
      if (age <= myTf * 60000 ~/ 3) {
        preds[sym] = Pred(cur.openTime, p >= 0.5);
      } else {
        preds.remove(sym);
      }
    }

    return Signal(sym, cur.close, p, move);
  }

  Future<void> scanBackend() async {
    for (var attempt = 0; attempt < 8; attempt++) {
      final r = await http
          .get(Uri.parse('$backendUrl/signals'))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) throw 'Backend error (HTTP ${r.statusCode})';
      final d = jsonDecode(r.body) as Map<String, dynamic>;
      final fresh = (d['candle_time'] as int) >= slotOf(DateTime.now()) * slotMs;
      if (fresh || attempt == 7) {
        final out = (d['signals'] as List)
            .map((s) => Signal(
                  s['symbol'] as String,
                  (s['price'] as num).toDouble(),
                  (s['p_up'] as num).toDouble(),
                  (s['move_pct'] as num).toDouble(),
                  model: true,
                ))
            .toList();
        final st = d['stats'] as Map<String, dynamic>;
        if (!mounted) return;
        setState(() {
          signals = out;
          allWins = st['all_wins'] as int;
          allTotal = st['all_total'] as int;
          topWins = st['top_wins'] as int;
          topTotal = st['top_total'] as int;
        });
        return;
      }
      await Future.delayed(const Duration(seconds: 8)); // server still scanning
      if (!mounted) return;
    }
  }

  Future<void> scan() async {
    if (scanning) return;
    final myTf = tf;
    lastScanSlot = slotOf(DateTime.now());
    setState(() {
      scanning = true;
      scanned = 0;
      error = null;
    });
    try {
      if (backendUrl.isNotEmpty && myTf == 5) {
        await scanBackend();
        return;
      }
      if (symbols.isEmpty) await loadSymbols();
      final syms = myTf == 5 ? symbols : symbols.take(shortUniverse).toList();
      if (mounted) setState(() => scanTotal = syms.length);
      final out = <Signal>[];
      for (var i = 0; i < syms.length; i += 20) {
        final batch = syms.sublist(i, min(i + 20, syms.length));
        final res = await Future.wait(batch.map((s) => fetchSignal(s, myTf)));
        out.addAll(res.whereType<Signal>());
