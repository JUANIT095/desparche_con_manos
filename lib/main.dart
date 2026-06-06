// ============================================================================
//  Desparche con Manos  —  Flutter Web + MediaPipe (detección de gestos)
// ----------------------------------------------------------------------------
//  FLUJO COMPLETO DE LA APP (de la cámara a la pantalla):
//
//    [cámara] --> <video> nativo --> web/hand_detection.js (MediaPipe)
//        --> detecta el gesto --> llama al callback de Dart (interop)
//        --> setState en Flutter --> se muestra la imagen del "perro" a la izq.
//
//  RESPONSABILIDADES:
//    - El ARCHIVO web/hand_detection.js hace todo el Machine Learning.
//    - ESTE archivo (Dart) solo: crea el <video>, lo muestra, escucha el
//      resultado y pinta la interfaz. Dart NO hace ML.
//
//  ⚠️ Este archivo usa APIs EXCLUSIVAS de Web:
//       dart:js_interop         -> llamar/recibir funciones de JavaScript
//       dart:js_interop_unsafe  -> consultar propiedades del objeto global
//       dart:ui_web             -> incrustar elementos HTML en Flutter
//       package:web             -> crear el <video> del navegador desde Dart
//     Por eso se ejecuta con:  flutter run -d chrome
// ============================================================================

import 'dart:async';
import 'dart:js_interop'; // base del interop (JSFunction, JSPromise, toJS...)
import 'dart:js_interop_unsafe'; // da el método .has() sobre el objeto global
import 'dart:ui_web' as ui_web; // platformViewRegistry (incrustar HTML)

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web; // HTMLVideoElement, etc.

// ===========================================================================
//  1) PUENTE CON JAVASCRIPT (interop)
// ---------------------------------------------------------------------------
//  `@JS('nombre')` + `external` le dice a Dart: "existe una función global de
//  JS llamada así, déjame llamarla desde Dart". Los tipos JS* (JSFunction,
//  JSPromise) son los "envoltorios" que Dart usa para hablar con JavaScript.
// ===========================================================================

/// Llama a `window.startHandDetection(video, onStatus, onGesture)` del JS.
/// Devuelve una Promesa de JS, que en Dart convertimos a Future con `.toDart`.
@JS('startHandDetection')
external JSPromise<JSAny?> _startHandDetection(
  web.HTMLVideoElement video,
  JSFunction onStatus,
  JSFunction onGesture,
);

/// Llama a `window.stopHandDetection()` para apagar la cámara al salir.
@JS('stopHandDetection')
external void _stopHandDetection();

// ===========================================================================
//  2) CATÁLOGO DE REACCIONES (la "tabla" gesto -> imagen)
// ---------------------------------------------------------------------------
//  Tener esto como un Map hace que AÑADIR un gesto nuevo sea trivial:
//  solo agregas una entrada aquí y pones la imagen en assets/images/.
// ===========================================================================

/// Describe qué mostrar cuando se detecta un gesto concreto.
class GestureReaction {
  final String label; // texto que se ve bajo la imagen
  final String asset; // ruta de la imagen a mostrar
  final Color background; // color de fondo del panel izquierdo
  const GestureReaction({
    required this.label,
    required this.asset,
    required this.background,
  });
}

/// La clave es el nombre del gesto TAL CUAL lo envía hand_detection.js.
/// Gestos predefinidos de MediaPipe: Closed_Fist, Thumb_Up, Pointing_Up, ...
/// Gesto personalizado calculado por nosotros: Call_Me (pulgar + meñique 🤙).
const Map<String, GestureReaction> kReactions = {
  'Closed_Fist': GestureReaction(
    label: 'Desparche ✊',
    asset: 'assets/images/desparche.png',
    background: Color(0xFF153B1A),
  ),
  'Thumb_Up': GestureReaction(
    label: 'Perro God 👍',
    asset: 'assets/images/perro_god.png',
    background: Color(0xFF12243F),
  ),
  'Call_Me': GestureReaction(
    label: 'Perro Facha 🤙',
    asset: 'assets/images/perro_facha.png',
    background: Color(0xFF3A2A0A),
  ),
  'Pointing_Up': GestureReaction(
    label: 'Perro Silence ☝️',
    asset: 'assets/images/perro_silence.png',
    background: Color(0xFF2A0A2E),
  ),
};

void main() {
  runApp(const DesparcheApp());
}

class DesparcheApp extends StatelessWidget {
  const DesparcheApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Desparche con Manos',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const HandDetectionPage(),
    );
  }
}

// ===========================================================================
//  3) PANTALLA PRINCIPAL (StatefulWidget porque su contenido cambia en vivo)
// ===========================================================================
class HandDetectionPage extends StatefulWidget {
  const HandDetectionPage({super.key});

  @override
  State<HandDetectionPage> createState() => _HandDetectionPageState();
}

class _HandDetectionPageState extends State<HandDetectionPage> {
  /// Identificador único del "platform view" que envuelve al <video>.
  static const String _viewType = 'webcam-video-view';

  /// Confianza mínima para aceptar un gesto (0.0 a 1.0). Sube el valor si hay
  /// falsos positivos; bájalo si cuesta que reaccione.
  static const double _minConfidence = 0.5;

  late final web.HTMLVideoElement _videoElement;

  // --- Estado que la interfaz observa ---
  String _status = 'idle'; // estado de carga (para el chip superior)
  String _gesture = 'None'; // último gesto recibido (para el badge inferior)
  double _score = 0; // confianza del último gesto

  /// Reacción activa: la imagen a mostrar, o null si no hay gesto válido.
  /// Es un "getter calculado": deriva del gesto + la confianza actuales.
  GestureReaction? get _activeReaction {
    final reaction = kReactions[_gesture];
    if (reaction == null) return null; // gesto sin imagen asociada
    if (_score < _minConfidence) return null; // confianza insuficiente
    return reaction;
  }

  @override
  void initState() {
    super.initState();
    _setupVideoElement();
    _startDetection();
  }

  /// Crea el elemento <video> del navegador y lo registra para poder
  /// incrustarlo dentro del árbol de widgets con HtmlElementView.
  void _setupVideoElement() {
    _videoElement = web.HTMLVideoElement()
      ..autoplay = true
      ..muted =
          true // necesario para reproducir sin click del usuario
      ..setAttribute('playsinline', 'true');
    _videoElement.style
      ..width = '100%'
      ..height = '100%'
      ..setProperty('object-fit', 'cover')
      ..setProperty('transform', 'scaleX(-1)'); // espejo: efecto selfie

    // registerViewFactory asocia un id con una función que devuelve el HTML.
    // Lanza si se registra dos veces el mismo id (p. ej. tras un hot restart),
    // así que lo envolvemos en try/catch.
    try {
      ui_web.platformViewRegistry.registerViewFactory(
        _viewType,
        (int viewId) => _videoElement,
      );
    } catch (_) {
      /* ya estaba registrado, no pasa nada */
    }
  }

  /// Arranca la detección llamando a la función global de JavaScript.
  Future<void> _startDetection() async {
    try {
      await _waitForJsApi(); // asegurarnos de que el JS ya cargó

      // Convertimos nuestras funciones Dart a funciones JS con `.toJS` para
      // que JavaScript pueda invocarlas. `.toDart` convierte la Promesa de JS
      // de vuelta a un Future que podemos `await`-ear.
      await _startHandDetection(
        _videoElement,
        ((String status) => _onStatus(status)).toJS,
        ((String name, double score) => _onGesture(name, score)).toJS,
      ).toDart;
    } catch (e) {
      _onStatus('error: $e');
    }
  }

  /// El módulo JS carga de forma asíncrona; esperamos (máx. 5 s) a que la
  /// función global exista antes de intentar llamarla.
  Future<void> _waitForJsApi() async {
    for (var i = 0; i < 100; i++) {
      if (globalContext.has('startHandDetection')) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw StateError('hand_detection.js no se cargó (revisa web/index.html).');
  }

  /// Callback que JS invoca al cambiar el estado de carga.
  void _onStatus(String status) {
    if (!mounted) return;
    setState(() => _status = status);
  }

  /// Callback que JS invoca en CADA frame con el gesto detectado.
  void _onGesture(String name, double score) {
    // Optimización: si nada cambió respecto al frame anterior, no reconstruyas.
    if (name == _gesture && (score - _score).abs() < 0.001) return;
    if (!mounted) return;
    setState(() {
      _gesture = name;
      _score = score;
    });
  }

  @override
  void dispose() {
    // Apagamos la cámara al salir para liberar el dispositivo y la batería.
    try {
      _stopHandDetection();
    } catch (_) {
      /* el módulo podría no haberse cargado */
    }
    super.dispose();
  }

  // =========================================================================
  //  4) INTERFAZ
  // =========================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF12121A),
      appBar: AppBar(
        title: const Text('Desparche con Manos ajhjashja'),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
      ),
      // Row = dos columnas lado a lado. Cada Expanded se reparte el ancho
      // según su `flex` (2 y 3 -> 40% y 60% del ancho).
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 2, child: _buildReactivePanel()), // IZQUIERDA
          const VerticalDivider(width: 1, color: Colors.white12),
          Expanded(flex: 3, child: _buildCameraPanel()), // CENTRO/DERECHA
        ],
      ),
    );
  }

  /// Panel IZQUIERDO: muestra la imagen del perro según el gesto, o una
  /// pantalla de instrucciones si no hay gesto reconocido.
  Widget _buildReactivePanel() {
    final reaction = _activeReaction;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      color: reaction?.background ?? const Color(0xFF1A1A24),
      padding: const EdgeInsets.all(24),
      child: Center(
        // AnimatedSwitcher hace una transición suave (fade) cuando cambia su
        // hijo. La `key` distinta es lo que le indica que "cambió".
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: reaction == null ? _idleContent() : _reactionContent(reaction),
        ),
      ),
    );
  }

  /// Contenido cuando SÍ hay un gesto reconocido: imagen + etiqueta.
  Widget _reactionContent(GestureReaction reaction) {
    return Column(
      // La key incluye el asset para que cada gesto anime su propia transición.
      key: ValueKey(reaction.asset),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Image.asset(
            reaction.asset,
            width: 600,
            fit: BoxFit.contain,
            // Si la imagen aún no existe, mostramos un aviso (no se rompe).
            errorBuilder: (_, _, _) => _imagePlaceholder(reaction.asset),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          reaction.label,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  /// Contenido por defecto: lista de gestos disponibles.
  Widget _idleContent() {
    return Column(
      key: const ValueKey('idle'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.front_hand_outlined, color: Colors.white24, size: 160),
        const SizedBox(height: 64),
        const Text(
          'Parchate con unos gestos simples',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white54, fontSize: 18),
        ),
        const SizedBox(height: 20),
        // Construimos la leyenda a partir del mismo mapa de reacciones.
      ],
    );
  }

  /// Aviso visual cuando falta el archivo de imagen.
  Widget _imagePlaceholder(String asset) {
    return Container(
      width: 300,
      height: 200,
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white24),
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(16),
      child: Text(
        'Falta la imagen:\n$asset',
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white70, fontSize: 14),
      ),
    );
  }

  /// Panel CENTRO/DERECHA: el vídeo en vivo con overlays de estado y gesto.
  Widget _buildCameraPanel() {
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Aquí se "incrusta" el <video> nativo del navegador.
          HtmlElementView(viewType: _viewType),
          Positioned(top: 16, left: 16, child: _statusChip()),
          Positioned(
            bottom: 16,
            left: 0,
            right: 0,
            child: Center(child: _gestureBadge()),
          ),
        ],
      ),
    );
  }

  /// Chip superior: muestra el progreso de carga o un error.
  Widget _statusChip() {
    final bool isError = _status.startsWith('error');
    final bool isReady = _status == 'running';

    final String label = switch (_status) {
      'idle' => 'Iniciando…',
      'loading-model' => 'Cargando modelo…',
      'requesting-camera' => 'Pidiendo permiso de cámara…',
      'running' => 'En vivo',
      _ => _status, // mensaje de error completo
    };

    final Color bg = isError
        ? Colors.red.shade700
        : (isReady ? Colors.green.shade700 : Colors.black54);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isReady)
            Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
            )
          else if (!isError)
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(Colors.white),
              ),
            )
          else
            const Icon(Icons.error_outline, color: Colors.white, size: 16),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  /// Badge inferior: nombre del gesto crudo y su % de confianza (útil para
  /// depurar y entender qué está "viendo" el modelo en cada momento).
  Widget _gestureBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Text(
        _gesture == 'None'
            ? 'Sin mano detectada'
            : 'Gesto: $_gesture (${(_score * 100).toStringAsFixed(0)}%)',
        style: const TextStyle(color: Colors.white, fontSize: 14),
      ),
    );
  }
}
