# 🖐️ Desparche con Manos

Aplicación **Flutter Web** que usa la cámara en tiempo real para **detectar gestos de la mano** con Machine Learning ([MediaPipe Tasks Vision](https://ai.google.dev/edge/mediapipe/solutions/vision/gesture_recognizer)). Cuando reconoce un gesto, muestra al instante una imagen reactiva (un "perro") en el lado izquierdo de la pantalla.

> La cámara va en el centro/derecha y la imagen reactiva a la izquierda. Todo ocurre en el navegador, sin servidor.

---

## ✨ Gestos soportados

| Gesto | Emoji | Reacción | Cómo se detecta |
|---|---|---|---|
| Puño cerrado | ✊ | Desparche | Modelo predefinido (`Closed_Fist`) |
| Pulgar arriba | 👍 | Perro God | Modelo predefinido (`Thumb_Up`) |
| Índice arriba | ☝️ | Perro Silence | Modelo predefinido (`Pointing_Up`) |
| Pulgar + meñique | 🤙 | Perro Facha | **Gesto propio** calculado por geometría (`Call_Me`) |

---

## 🧠 ¿Cómo funciona?

El flujo de datos, de la cámara a la pantalla:

```
[cámara] → <video> nativo → MediaPipe (JavaScript) → detecta el gesto
        → callback a Dart (interop) → setState → se muestra la imagen
```

Reparto de responsabilidades:

- **`web/hand_detection.js`** hace **todo el Machine Learning**: pide la cámara con `getUserMedia`, carga el modelo `GestureRecognizer`, analiza cada frame y avisa el gesto detectado.
- **`lib/main.dart`** **solo pinta la interfaz**: crea el `<video>`, lo incrusta con `HtmlElementView`, escucha el resultado y muestra la imagen. Dart no ejecuta ML.
- El puente entre ambos mundos es **interop** (`dart:js_interop`).

### Dos técnicas de detección
1. **Gestos predefinidos:** MediaPipe ya viene entrenado con 8 gestos; basta con leer `categoryName`.
2. **Gestos propios (geometría):** a partir de los 21 *landmarks* de la mano calculamos qué dedos están extendidos. Un dedo está extendido si su **punta** está más lejos de la muñeca que su **nudillo medio**. Así detectamos el 🤙, que el modelo no trae de fábrica.

---

## 📁 Estructura del proyecto

```
desparche_con_manos/
├── web/
│   ├── index.html            # carga el módulo hand_detection.js
│   └── hand_detection.js     # cámara + MediaPipe (la parte de ML)
├── lib/
│   └── main.dart             # UI dividida + interop JS↔Dart
├── assets/
│   └── images/               # imágenes reactivas (una por gesto)
├── test/
│   └── widget_test.dart      # smoke test
└── pubspec.yaml
```

---

## 🚀 Cómo ejecutarlo

> Requiere [Flutter](https://docs.flutter.dev/get-started/install) con soporte web habilitado.

```bash
flutter pub get
flutter run -d chrome
```

1. Acepta el **permiso de cámara** que pide el navegador.
2. Espera a que el indicador diga **"En vivo"** (la primera carga del modelo tarda unos segundos).
3. Haz un gesto frente a la cámara y observa la reacción a la izquierda. ✊👍🤙☝️

> ⚠️ La cámara solo funciona en `localhost` o sitios `https://` (requisito de seguridad del navegador). `flutter run -d chrome` ya usa `localhost`.

---

## 🖼️ Imágenes reactivas

Coloca una imagen por gesto en `assets/images/` con estos nombres exactos:

| Archivo | Gesto |
|---|---|
| `desparche.png` | ✊ Puño cerrado |
| `perro_god.png` | 👍 Pulgar arriba |
| `perro_facha.png` | 🤙 Pulgar + meñique |
| `perro_silence.png` | ☝️ Índice arriba |

> Si falta algún archivo, la app **no se rompe**: muestra un aviso con el nombre que falta.

---

## ➕ Añadir un gesto nuevo

1. Si **no** es un gesto predefinido de MediaPipe, créalo en `web/hand_detection.js` (función `detectCustomGesture`).
2. Agrega una entrada al mapa `kReactions` en `lib/main.dart`.
3. Pon la imagen en `assets/images/` con el nombre que usaste en el mapa.

---

## 🛠️ Tecnologías

- [Flutter](https://flutter.dev) (Web)
- [MediaPipe Tasks Vision](https://ai.google.dev/edge/mediapipe/solutions/vision/gesture_recognizer) · `GestureRecognizer`
- Interop con `dart:js_interop` + `package:web`
