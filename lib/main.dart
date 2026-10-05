import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

const base = 'https://fapi.binance.com';

/// Your backend address, e.g. 'http://192.168.1.5:8000'.
/// Leave empty to use the built-in rule-based signals instead.
const backendUrl = '';

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
        title: 'Futures 5m Signals',
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
  Signal(this.symbol, this.price, this.pUp, this.movePct);

  bool get up => pUp >= 0.5;
  double get strength => max(pUp, 1 - pUp);
  double get predicted => price * (1 + movePct);
  String get base =>
      symbol.endsWith('USDT') ? symbol.substring(0, symbol.length - 4) : symbol;
}

// ---------- Built-in rule-based signal (used only when backendUrl is empty) ----------

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
  final z = (0.8 * trend + 0.6 * meanRev + 0.4 * mom).clamp(-2.0, 2.0).toDouble();
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
  int lastScanSlot = 0;
  int tab = 0; // 0 all, 1 long, 2 short
  String? error;
  String query = '';
  DateTime now = DateTime.now();
  Timer? timer;

  int slotOf(DateTime t) => t.millisecondsSinceEpoch ~/ 300000;

  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => now = DateTime.now());
      // Scan once per candle, 3 seconds after it opens.
      if (!scanning &&
          slotOf(now) != lastScanSlot &&
          now.millisecondsSinceEpoch % 300000 >= 3000) {
        scan();
      }
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> loadSymbols() async {
    final r = await http
        .get(Uri.parse('$base/fapi/v1/exchangeInfo'))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw 'Could not load coin list (HTTP ${r.statusCode})';
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    symbols = (data['symbols'] as List)
        .where((s) =>
            s['contractType'] == 'PERPETUAL' &&
            s['quoteAsset'] == 'USDT' &&
            s['status'] == 'TRADING')
        .map<String>((s) => s['symbol'] as String)
        .toList();
  }

  Future<Signal?> fetchSignal(String sym) async {
    final r = await http
        .get(Uri.parse('$base/fapi/v1/klines?symbol=$sym&interval=5m&limit=60'))
        .timeout(const Duration(seconds: 10));
    if (r.statusCode == 429 || r.statusCode == 418) {
      throw 'Binance rate limit hit. Wait a minute, then tap refresh.';
    }
    if (r.statusCode != 200) return null;
    final list = (jsonDecode(r.body) as List)
        .map((e) => Candle.fromJson(e as List))
        .toList();
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
      if (age <= 90000) {
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
      final fresh = (d['candle_time'] as int) >= slotOf(DateTime.now()) * 300000;
      if (fresh || attempt == 7) {
        final out = (d['signals'] as List)
            .map((s) => Signal(
                  s['symbol'] as String,
                  (s['price'] as num).toDouble(),
                  (s['p_up'] as num).toDouble(),
                  (s['move_pct'] as num).toDouble(),
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
    lastScanSlot = slotOf(DateTime.now());
    setState(() {
      scanning = true;
      scanned = 0;
      error = null;
    });
    try {
      if (backendUrl.isNotEmpty) {
        await scanBackend();
        return;
      }
      if (symbols.isEmpty) await loadSymbols();
      final out = <Signal>[];
      for (var i = 0; i < symbols.length; i += 20) {
        final batch = symbols.sublist(i, min(i + 20, symbols.length));
        final res = await Future.wait(batch.map(fetchSignal));
        out.addAll(res.whereType<Signal>());
        if (!mounted) return;
        setState(() => scanned = min(i + 20, symbols.length));
      }
      out.sort((a, b) => b.strength.compareTo(a.strength));
      for (final s in out.take(10)) {
        preds[s.symbol]?.top = true;
      }
      if (mounted) setState(() => signals = out);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => scanning = false);
    }
  }

  // ----- widgets -----

  String pctShort(int w, int t) => t == 0 ? '--' : '${(w / t * 100).toStringAsFixed(0)}%';

  Widget statBox(String label, String value, String sub) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(color: kMuted, fontSize: 10, letterSpacing: 0.5)),
            const SizedBox(height: 2),
            Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            Text(sub, style: const TextStyle(color: kMuted, fontSize: 10)),
          ],
        ),
      );

  Widget tabChip(int i, String label, int count) {
    final sel = tab == i;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text('$label $count'),
        selected: sel,
        onSelected: (_) => setState(() => tab = i),
        selectedColor: kGold,
        backgroundColor: kPanel,
        showCheckmark: false,
        side: BorderSide.none,
        labelStyle: TextStyle(
          color: sel ? Colors.black : Colors.white70,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget detailRow(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(k, style: const TextStyle(color: kMuted)),
            Text(v, style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      );

  void showDetails(Signal s) {
    final c = s.up ? kGreen : kRed;
    showModalBottomSheet(
      context: context,
      backgroundColor: kPanel,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${s.base}USDT Perpetual',
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(s.up ? 'LONG bias' : 'SHORT bias',
                style: TextStyle(color: c, fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 14),
            detailRow('Price now', fmt(s.price)),
            detailRow('Est. close (5m)', fmt(s.predicted)),
            detailRow('Expected move', '${(s.movePct * 100).toStringAsFixed(3)}%'),
            detailRow('Signal strength', '${(s.strength * 100).toStringAsFixed(0)}%'),
            const SizedBox(height: 12),
            const Text(
              'Direction of the next 5-minute candle only. Not financial advice. '
              'Fees (about 0.1% round trip) can be larger than the expected move.',
              style: TextStyle(color: kMuted, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget signalTile(Signal s) {
    final c = s.up ? kGreen : kRed;
    return InkWell(
      onTap: () => showDetails(s),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Expanded(
              flex: 4,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(s.base,
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      const SizedBox(width: 5),
                      const Text('PERP', style: TextStyle(color: kMuted, fontSize: 10)),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text('Strength ${(s.strength * 100).toStringAsFixed(0)}%',
                      style: const TextStyle(color: kMuted, fontSize: 11)),
                ],
              ),
            ),
            Expanded(
              flex: 4,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(fmt(s.price),
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text('→ ${fmt(s.predicted)}', style: TextStyle(color: c, fontSize: 11)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Container(
              width: 72,
              padding: const EdgeInsets.symmetric(vertical: 9),
              decoration: BoxDecoration(
                color: c.withOpacity(0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              alignment: Alignment.center,
              child: Text(s.up ? 'LONG' : 'SHORT',
                  style: TextStyle(color: c, fontWeight: FontWeight.bold, fontSize: 13)),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final msInSlot = now.millisecondsSinceEpoch % 300000;
    final secsLeft = 300 - msInSlot ~/ 1000;
    final q = query.trim().toUpperCase();

    final longs = signals.where((s) => s.up).length;
    final shorts = signals.length - longs;
    final list = signals
        .where((s) => q.isEmpty || s.symbol.contains(q))
        .where((s) => tab == 0 || (tab == 1 ? s.up : !s.up))
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.show_chart, color: kGold),
            SizedBox(width: 8),
            Text('Futures 5m Signals', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: scanning ? null : scan,
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            color: kPanel,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text('NEXT CANDLE',
                        style: TextStyle(color: kMuted, fontSize: 11, letterSpacing: 0.5)),
                    const Spacer(),
                    Text(
                      '${secsLeft ~/ 60}:${(secsLeft % 60).toString().padLeft(2, '0')}',
                      style: const TextStyle(
                          color: kGold, fontSize: 22, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: msInSlot / 300000,
                  color: kGold,
                  backgroundColor: kBg,
                  minHeight: 3,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    statBox('ACCURACY (ALL)', pctShort(allWins, allTotal), '$allWins / $allTotal'),
                    statBox('ACCURACY (TOP 10)', pctShort(topWins, topTotal), '$topWins / $topTotal'),
                    statBox('COINS', '${signals.length}', '$longs long / $shorts short'),
                  ],
                ),
                if (scanning) ...[
                  const SizedBox(height: 10),
                  Text(
                    backendUrl.isNotEmpty
                        ? 'Getting signals from server...'
                        : 'Scanning $scanned / ${symbols.length} coins',
                    style: const TextStyle(color: kGold, fontSize: 12),
                  ),
                ],
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: const TextStyle(color: kRed, fontSize: 12)),
                ],
                const SizedBox(height: 8),
                const Text(
                  'Model score, not a guarantee. Trust it only if live accuracy stays well above 55%.',
                  style: TextStyle(color: kMuted, fontSize: 10),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: TextField(
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search, color: kMuted),
                hintText: 'Search coin, e.g. BTC',
                hintStyle: const TextStyle(color: kMuted),
                isDense: true,
                filled: true,
                fillColor: kPanel,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (v) => setState(() => query = v),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Row(
              children: [
                tabChip(0, 'ALL', signals.length),
                tabChip(1, 'LONG', longs),
                tabChip(2, 'SHORT', shorts),
              ],
            ),
          ),
          Expanded(
            child: list.isEmpty
                ? Center(
                    child: Text(
                      scanning ? 'Loading signals...' : 'No signals yet',
                      style: const TextStyle(color: kMuted),
                    ),
                  )
                : ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, color: kPanel),
                    itemBuilder: (_, i) => signalTile(list[i]),
                  ),
          ),
        ],
      ),
    );
  }
}
