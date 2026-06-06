// ============================================================================
//  hand_detection.js  —  El "cerebro" de Machine Learning de la app
// ----------------------------------------------------------------------------
//  ¿QUÉ HACE ESTE ARCHIVO?
//  1. Pide acceso a la cámara del navegador (getUserMedia).
//  2. Carga el modelo de MediaPipe "GestureRecognizer".
//  3. Analiza CADA frame del vídeo y decide qué gesto está haciendo la mano.
//  4. Le avisa a Flutter (Dart) el resultado mediante dos "callbacks".
//
//  ¿POR QUÉ EN JAVASCRIPT Y NO EN DART?
//  Porque MediaPipe Tasks Vision es una librería de JavaScript que corre
//  directamente en el navegador (con WebAssembly + WebGL). Flutter Web no
//  puede ejecutarla en Dart, así que hacemos la parte de ML aquí en JS y solo
//  le pasamos el RESULTADO ya masticado a Flutter. A esto se le llama "interop".
//
//  ¿CÓMO SE COMUNICA CON FLUTTER?
//  Definimos funciones en `window` (el objeto global del navegador). Flutter,
//  usando dart:js_interop, puede llamar a `window.startHandDetection(...)`.
//  Y nosotros, cuando detectamos un gesto, llamamos a los callbacks que Flutter
//  nos pasó como argumentos. Es una conversación de ida y vuelta JS <-> Dart.
//
//  Se carga como módulo ES (<script type="module"> en index.html) porque
//  usamos `import` para traer la librería desde un CDN.
// ============================================================================

// `import` trae las dos clases que necesitamos directamente desde el CDN:
//   - GestureRecognizer: el modelo que reconoce gestos.
//   - FilesetResolver:   utilidad que descarga el runtime de WebAssembly (.wasm).
import {
  GestureRecognizer,
  FilesetResolver,
} from "https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.18";

// Fijamos la versión para que la librería y su WASM coincidan SIEMPRE.
// Si actualizas el número, cámbialo en los dos sitios donde aparece.
const TASKS_VISION_VERSION = "0.10.18";

// Variables de módulo (viven mientras la página esté abierta).
let gestureRecognizer = null; // el modelo, una vez cargado
let running = false; // bandera para poder detener el bucle
let currentStream = null; // referencia a la cámara, para liberarla al cerrar

// ----------------------------------------------------------------------------
//  GEOMETRÍA DE LA MANO  —  Detección de gestos PERSONALIZADOS
// ----------------------------------------------------------------------------
//  MediaPipe nos da 21 "landmarks" (puntos) por mano, cada uno con coords
//  {x, y, z} normalizadas (0 a 1). La numeración estándar es:
//
//      0 = muñeca (wrist)
//      Pulgar:  1,  2,  3,  4 (4 = punta)
//      Índice:  5,  6,  7,  8 (8 = punta)
//      Medio:   9, 10, 11, 12 (12 = punta)
//      Anular: 13, 14, 15, 16 (16 = punta)
//      Meñique:17, 18, 19, 20 (20 = punta)
//
//  Con estos puntos PODEMOS inventar nuestros propios gestos. El truco para
//  saber si un dedo está "extendido" es comparar distancias a la muñeca:
//  si la PUNTA del dedo está más lejos de la muñeca que su nudillo medio,
//  el dedo está estirado. Este método funciona aunque la mano esté inclinada.
// ----------------------------------------------------------------------------

/** Distancia euclidiana 3D entre dos landmarks. */
function dist(a, b) {
  const dx = a.x - b.x;
  const dy = a.y - b.y;
  const dz = (a.z || 0) - (b.z || 0);
  return Math.sqrt(dx * dx + dy * dy + dz * dz);
}

/**
 * Devuelve qué dedos están extendidos, como objeto de booleanos.
 * @param {Array<{x:number,y:number,z:number}>} lm  Los 21 landmarks de UNA mano.
 */
function fingerStates(lm) {
  const wrist = lm[0];
  // Un dedo está extendido si su punta está más lejos de la muñeca que su
  // articulación media (PIP para los dedos largos; usamos la MCP del pulgar).
  const extended = (tip, joint) => dist(lm[tip], wrist) > dist(lm[joint], wrist);

  return {
    thumb: extended(4, 2), // punta del pulgar vs. su nudillo (MCP)
    index: extended(8, 6),
    middle: extended(12, 10),
    ring: extended(16, 14),
    pinky: extended(20, 18),
  };
}

/**
 * Detecta gestos que MediaPipe NO trae de fábrica, a partir de los landmarks.
 * Devuelve el nombre del gesto o null si no reconoce ninguno personalizado.
 */
function detectCustomGesture(lm) {
  const f = fingerStates(lm);

  // 🤙 "Call_Me" (perro facha): solo pulgar y meñique extendidos,
  //    los tres dedos del medio cerrados.
  if (f.thumb && f.pinky && !f.index && !f.middle && !f.ring) {
    return "Call_Me";
  }

  // Aquí podrías añadir más gestos propios en el futuro, por ejemplo:
  //   if (f.index && f.pinky && !f.middle && !f.ring) return "Rock"; // 🤘
  return null;
}

// ----------------------------------------------------------------------------
//  FUNCIÓN PRINCIPAL  —  la que Flutter invoca para arrancar todo
// ----------------------------------------------------------------------------
/**
 * @param {HTMLVideoElement} video   El <video> que Flutter creó y nos presta.
 * @param {(status:string)=>void} onStatus   Callback para informar el estado.
 * @param {(name:string, score:number)=>void} onGesture  Callback por frame.
 */
window.startHandDetection = async function (video, onStatus, onGesture) {
  try {
    // --- PASO 1: cargar el runtime de WebAssembly de MediaPipe ---
    onStatus("loading-model");
    const vision = await FilesetResolver.forVisionTasks(
      `https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@${TASKS_VISION_VERSION}/wasm`
    );

    // --- PASO 2: crear el reconocedor de gestos ---
    // runningMode "VIDEO" = optimizado para fotogramas consecutivos.
    // delegate "GPU" = usa la tarjeta gráfica (más rápido); usa "CPU" si falla.
    gestureRecognizer = await GestureRecognizer.createFromOptions(vision, {
      baseOptions: {
        modelAssetPath:
          "https://storage.googleapis.com/mediapipe-models/gesture_recognizer/gesture_recognizer/float16/1/gesture_recognizer.task",
        delegate: "GPU",
      },
      runningMode: "VIDEO",
      numHands: 1, // sube a 2 si quieres detectar las dos manos
    });

    // --- PASO 3: pedir la cámara frontal ---
    onStatus("requesting-camera");
    currentStream = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: "user" },
      audio: false,
    });
    video.srcObject = currentStream;
    await video.play();

    // --- PASO 4: bucle de inferencia ---
    onStatus("running");
    running = true;

    // Evita re-analizar el mismo frame: solo procesamos si el tiempo del
    // vídeo cambió desde la última vuelta.
    let lastVideoTime = -1;

    const loop = () => {
      if (!running) return; // alguien llamó a stopHandDetection()

      // readyState >= 2 (HAVE_CURRENT_DATA) = ya hay un frame dibujable.
      if (video.readyState >= 2 && video.currentTime !== lastVideoTime) {
        lastVideoTime = video.currentTime;

        try {
          // El modelo analiza el frame actual del <video>.
          const results = gestureRecognizer.recognizeForVideo(
            video,
            performance.now()
          );

          // Valores por defecto: ninguna mano detectada.
          let name = "None";
          let score = 0;

          // (a) Gesto PREDEFINIDO de MediaPipe (el más probable de la 1ª mano).
          if (results.gestures && results.gestures.length > 0) {
            name = results.gestures[0][0].categoryName;
            score = results.gestures[0][0].score;
          }

          // (b) Gesto PERSONALIZADO calculado por nosotros: si encaja, manda.
          //     (results.landmarks trae los 21 puntos de cada mano detectada.)
          if (results.landmarks && results.landmarks.length > 0) {
            const custom = detectCustomGesture(results.landmarks[0]);
            if (custom) {
              name = custom;
              score = 0.99; // es un match geométrico, lo damos por seguro
            }
          }

          // Avisamos a Flutter el resultado de este frame.
          onGesture(name, score);
        } catch (e) {
          // Un frame aislado puede fallar; lo ignoramos y seguimos.
          console.warn("[hand_detection] error en frame:", e);
        }
      }

      // requestAnimationFrame vuelve a llamar a loop en el siguiente repintado
      // (normalmente ~60 veces por segundo), sincronizado con la pantalla.
      requestAnimationFrame(loop);
    };

    requestAnimationFrame(loop);
  } catch (err) {
    // Errores graves (sin permiso de cámara, sin internet para el CDN, etc.).
    console.error("[hand_detection] error de inicialización:", err);
    const msg = err && err.message ? err.message : String(err);
    onStatus("error: " + msg);
  }
};

// ----------------------------------------------------------------------------
//  Limpieza: detiene el bucle y apaga la cámara (Flutter la llama en dispose).
// ----------------------------------------------------------------------------
window.stopHandDetection = function () {
  running = false;
  if (currentStream) {
    currentStream.getTracks().forEach((track) => track.stop());
    currentStream = null;
  }
};
