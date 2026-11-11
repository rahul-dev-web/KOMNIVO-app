/* KOMNIVO Firebase Cloud Messaging worker.
 * Build scripts replace the public Firebase Web config placeholders.
 * Do not put private keys or server credentials in this file.
 */
importScripts('https://www.gstatic.com/firebasejs/13.0.0/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/13.0.0/firebase-messaging-compat.js');

firebase.initializeApp({
  apiKey: "__FIREBASE_API_KEY__",
  authDomain: "__FIREBASE_AUTH_DOMAIN__",
  projectId: "__FIREBASE_PROJECT_ID__",
  storageBucket: "__FIREBASE_STORAGE_BUCKET__",
  messagingSenderId: "__FIREBASE_MESSAGING_SENDER_ID__",
  appId: "__FIREBASE_APP_ID__"
});

// Firebase automatically displays notification payloads while the web app is
// in the background. Foreground messages are handled by FirebaseMessaging.onMessage.
firebase.messaging();
